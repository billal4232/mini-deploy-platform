# ── IAM ────────────────────────────────────────────────────────────────────────
# TWO separate roles: task execution role (ECS infra) and task role (app perms).
# Keep them separate — never collapse into one role.

# ── Task Execution Role ────────────────────────────────────────────────────────
# Grants ECS agent permission to pull images from ECR and write logs to CloudWatch.

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-execution-role"
  }
}

# Inline policy — scoped to the specific ECR repo and CloudWatch log group
resource "aws_iam_role_policy" "ecs_task_execution" {
  name = "${var.project_name}-ecs-execution-policy"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.ecs.arn}:*"
      },
      # V2: Allow ECS agent to read the DB password from Secrets Manager at
      # container startup. Scoped to the exact secret ARN — not wildcarded.
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
    ]
  })

  depends_on = [aws_ecr_repository.app, aws_cloudwatch_log_group.ecs, aws_secretsmanager_secret.db_password]
}

# ── Task Role ──────────────────────────────────────────────────────────────────
# The app's own AWS permissions.  Keep minimal/empty for V1.
# V2 will add permissions needed by the application (e.g. S3, SQS, Secrets Manager).

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ecs-task-role"
  }
}


