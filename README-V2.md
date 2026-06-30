# Mini Deployment Platform — V2 (CI/CD + Secrets)

V2 adds automated deployments and proper secret handling on top of the V1 platform.

---

## What V2 adds (and WHY)

| V1 problem | V2 solution |
|---|---|
| **Deploying by hand**: `docker build/push`, then manually update the ECS service | **GitHub Actions CI/CD**: push to `main` → auto build, tag, push, deploy. No manual steps. |
| **DB password in `tfvars`**: plain text passed to RDS and visible in Terraform state | **Secrets Manager**: password stored as a secret. ECS reads it at runtime via the `secrets` block. Never appears in task definition JSON or env vars. |
| **AWS access keys stored in GitHub**: long-lived credentials with broad permissions | **OIDC**: GitHub Actions gets short-lived AWS credentials by exchanging a GitHub-issued token. No keys stored anywhere. |

---

## CI/CD flow (step by step)

```
git push origin main
        │
        ▼
┌───────────────────────────────────────────┐
│ 1. GitHub Actions workflow triggers       │
│    (.github/workflows/deploy.yml)         │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 2. OIDC: GitHub mints a JWT, exchanges it │
│    with AWS STS for temporary creds.      │
│    Role: aws_iam_role.github_actions      │
│    (No AWS access keys stored anywhere.)  │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 3. Login to ECR                           │
│    (aws-actions/amazon-ecr-login@v2)      │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 4. docker build + push                    │
│    Tag: mini-deploy-platform-app:$SHA     │
│    (SHA = unique, immutable — compatible  │
│     with ECR's IMMUTABLE tag policy.)     │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 5. Register new task-definition revision  │
│    (same family, new image tag)           │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 6. Update ECS service to new revision     │
│    + --force-new-deployment               │
│    → Fargate rolls out new tasks          │
└──────────────────┬────────────────────────┘
                   │
┌──────────────────▼────────────────────────┐
│ 7. Wait for services-stable               │
│    → Green deploy confirmed               │
└───────────────────────────────────────────┘
```

---

## OIDC: Why it matters

**V1 (bad)**: You'd create an IAM user, generate an access key, and paste it into GitHub
Secrets. That key lives forever (or until you rotate it), has a fixed scope, and if leaked
grants an attacker whatever that IAM user can do.

**V2 (good)**: OIDC (OpenID Connect) lets GitHub Actions request **temporary** AWS
credentials without any long-lived key. Here's how:

1. GitHub's OIDC provider (`token.actions.githubusercontent.com`) signs a JWT that
   includes claims about the workflow — which repo, which branch, who triggered it.
2. AWS trusts that OIDC provider (via the IAM OIDC identity provider resource in
   `oidc.tf`) and issues STS credentials based on the role's trust policy.
3. The credentials are **short-lived** (1 hour max) and scoped to exactly what the
   role allows.

The trust policy in `oidc.tf` is scoped to **one repo, one branch**:

```json
"Condition": {
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:billal4232/mini-deploy-platform:ref:refs/heads/main"
  }
}
```

This means:
- A workflow running in a **different repo** cannot assume this role.
- A workflow running on a **different branch** (e.g. a PR from a fork) cannot assume it.
- If the repo is deleted, the trust is inert — no residual key to revoke.

---

## Secrets Manager: How ECS reads the DB password

**V1 approach**: The password lived in `terraform.tfvars` → Terraform passed it to RDS at
creation time → the app got it via a plain environment variable in the task definition.
Anyone who could read the task definition (or the Terraform state) could see the password.

**V2 approach**:

```
┌─────────────────────────────────────────────────────┐
│ terraform.tfvars                                    │
│   db_password = "..."    ──→  RDS (master password) │
│                           ──→  Secrets Manager      │
│                                (aws_secretsmanager_  │
│                                 secret.db_password)  │
└──────────────────────────────┬──────────────────────┘
                               │
             At container startup, the ECS agent:
                               │
┌──────────────────────────────▼──────────────────────┐
│ 1. Uses the task EXECUTION role to call             │
│    secretsmanager:GetSecretValue on the secret ARN.  │
│                                                      │
│ 2. Injects the value as the DB_PASSWORD env var     │
│    inside the container.                             │
│                                                      │
│ The password is NEVER in the task definition JSON,   │
│ NEVER logged to CloudWatch, and NEVER visible in     │
│ `aws ecs describe-task-definition`.                  │
└─────────────────────────────────────────────────────┘
```

The task definition uses the `secrets` block (not `environment`):

```json
"secrets": [
  {
    "name":      "DB_PASSWORD",
    "valueFrom": "arn:aws:secretsmanager:eu-north-1:688600819246:secret:..."
  }
]
```

The **task execution role** (not the task role) needs `secretsmanager:GetSecretValue`
on this secret — because it's the ECS agent (running under the execution role) that
fetches secrets before launching the container. This permission is scoped to the
exact secret ARN in `iam.tf`.

---

## Pipeline scope: deliberate decision

The pipeline does **NOT** run `terraform apply`. Infra changes remain manual
(`terraform plan`/`apply` by a human).

**Why**: Giving CI/CD the ability to modify infrastructure (VPC, subnets, IAM roles,
security groups) dramatically expands the blast radius of a compromised workflow.
A pipeline that can only push images and update a service has a much smaller
surface area. If you need to change the ALB config or add a subnet, you do it
deliberately with `terraform apply`, reviewing the plan first.

The `lifecycle { ignore_changes = [task_definition] }` block on `aws_ecs_service.app`
(added in V2 to `ecs.tf`) ensures Terraform won't revert a pipeline deploy on the
next `terraform apply`. Terraform manages the **initial** task definition (the
template), and CI/CD creates new revisions from it.

---

## Manual setup steps (one-time)

### 1. Apply the V2 Terraform changes

```bash
cd mini-deploy-platform
terraform init    # if providers changed
terraform plan    # review: new OIDC provider, Secrets Manager secret, IAM changes
terraform apply
```

### 2. Copy the GitHub Actions role ARN to GitHub

After apply, Terraform outputs the role ARN:

```bash
terraform output github_actions_role_arn
```

Go to your GitHub repo → **Settings → Secrets and variables → Actions → Secrets**
and add:

| Secret name | Value |
|---|---|
| `AWS_ROLE_ARN` | The ARN from `terraform output github_actions_role_arn` |

### 3. Push to main

```bash
git add .
git commit -m "V2: CI/CD + Secrets Manager"
git push origin main
```

The first push will trigger the pipeline. Watch it in the **Actions** tab.

---

## Variables to set

Same V1 variables apply:

| Variable | Required | Notes |
|---|---|---|
| `domain_name` | Yes | e.g. `limonlab.online` |
| `db_password` | Yes | Now also stored in Secrets Manager |
| Everything else | No | Sensible defaults in `variables.tf` |

No new Terraform variables were introduced in V2.

---

## File changes from V1 → V2

| File | Change |
|---|---|
| `app/main.py` | **New** — minimal Flask app |
| `app/requirements.txt` | **New** |
| `app/Dockerfile` | **New** — multi-stage Python build |
| `.github/workflows/deploy.yml` | **New** — CI/CD pipeline |
| `oidc.tf` | **New** — OIDC provider + GitHub Actions IAM role |
| `secrets.tf` | **New** — Secrets Manager secret for DB password |
| `ecs.tf` | **Modified** — added `environment`, `secrets` blocks + `lifecycle` ignore |
| `iam.tf` | **Modified** — added `secretsmanager:GetSecretValue` to execution role policy |
| `outputs.tf` | **Modified** — added `github_actions_role_arn` output |
| `variables.tf` | **Modified** — updated `db_password` description |
| `README-V2.md` | **New** — this file |

All V1 files not listed above are unchanged.
