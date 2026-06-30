# ── OIDC ────────────────────────────────────────────────────────────────────────
# GitHub Actions OIDC identity provider + least-privilege IAM role.
# Eliminates long-lived AWS access keys stored in GitHub secrets.

# AWS account ID — needed for constructing ECS resource ARNs
data "aws_caller_identity" "current" {}

# ── OIDC Identity Provider (existing, account-wide) ─────────────────────────────
# The GitHub Actions OIDC provider is UNIQUE per AWS account (one per URL) and was
# already created by an earlier project. It is shared account-wide infrastructure,
# so this stack only REFERENCES it via a data source — it does not create or own it.
# (Owning it here would mean `terraform destroy` could delete a provider other
# projects depend on.)

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ── GitHub Actions IAM Role ─────────────────────────────────────────────────────
# This is the role the CI/CD pipeline assumes. Trust is scoped to ONE repo
# (billal4232/mini-deploy-platform) on the main branch only.

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # Reference the existing account-wide provider (data source, not resource)
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            # Only workflows running in THIS repo, on main branch, can assume this role
            "token.actions.githubusercontent.com:sub" = "repo:billal4232/mini-deploy-platform:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions-role"
  }
}

# ── Least-privilege policy for the CI/CD pipeline ───────────────────────────────
# Exactly the permissions needed: push/pull ECR + register task def + update service.
# Every ARN is fully qualified — no wildcarding where avoidable.

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project_name}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ecr:GetAuthorizationToken cannot be scoped to a resource (AWS limitation)
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      # ECR push/pull on the specific app repository
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      # ECS: read current task definition and register new revisions (any revision
      # within the app family — needed because CI/CD creates revision N+1 each push)
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.project_name}-${var.app_name}:*"
      },
      # ECS: update and describe ONLY the app service (not every service in the cluster)
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
        ]
        Resource = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${var.project_name}-cluster/${var.project_name}-svc"
      },
    ]
  })
}