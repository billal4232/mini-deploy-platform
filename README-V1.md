# Mini Deployment Platform — V1

A toy-scale Heroku/Render-style deployment platform on AWS, built with Terraform.
**V1 delivers the core deploy layer only** — a container running on Fargate behind
a TLS-terminated load balancer, with a PostgreSQL database.

Later versions (CI/CD, async deploys, auto-scaling) are out of scope for this version.

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  Route53 A record → ALB (HTTPS)                      │
│  HTTP→HTTPS redirect                                 │
└──────────────────────────┬──────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │  ALB (public subnets)   │
              │  TLS via ACM cert       │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  ECS Fargate            │
              │  (private subnets)      │  ◄── ECR (image registry)
              │  assign_public_ip=false │       │
              └────────┬────────────────┘       │
                       │               pull images via NAT
              ┌────────▼────────────┐
              │  RDS PostgreSQL     │
              │  (private subnets)  │
              │  storage encrypted  │
              └─────────────────────┘

Single NAT Gateway provides outbound internet access for:
  • ECS tasks pulling images from ECR / Docker Hub
  • ECS tasks reaching external APIs
  • RDS Enhanced Monitoring / CloudWatch Logs export
```

### What each resource does — and WHY

| Resource | Why it exists |
|---|---|
| **VPC** | Isolated network boundary for all platform resources. Everything lives inside this single VPC. |
| **Public subnets (×2)** | Host the ALB and NAT Gateway. Traffic from the internet enters here. Spread across 2 AZs for availability. |
| **Private subnets (×2)** | Host ECS tasks and RDS. No direct internet route in — they are unreachable from outside. Spread across 2 AZs. |
| **Internet Gateway** | Allows the public subnets (ALB) to receive traffic from and send traffic to the internet. |
| **NAT Gateway (×1)** | Allows private ECS tasks to reach the internet **outbound** (pull images, call APIs) without being reachable **inbound**. A single NAT instead of one per AZ is a deliberate cost tradeoff. |
| **Elastic IP** | Static public IP for the NAT Gateway so outbound traffic from private resources has a consistent source address. |
| **Public route table** | Routes `0.0.0.0/0` to the Internet Gateway — public subnets can reach the internet directly. |
| **Private route table** | Routes `0.0.0.0/0` to the single NAT Gateway — private subnets reach the internet through NAT, not directly. |
| **ALB (Application Load Balancer)** | Single entry point for all HTTP/S traffic. Terminates TLS, forwards requests to ECS tasks. Provides health checks so bad tasks are removed. |
| **Target Group (ip type)** | Routes traffic to Fargate tasks by their private IP (required for `awsvpc` network mode). Health checks ensure only healthy tasks receive traffic. |
| **HTTP Listener** | Listens on port 80 and issues a `301 Moved Permanently` redirect to HTTPS — enforces encrypted traffic. |
| **HTTPS Listener** | Listens on port 443, terminates TLS with the ACM certificate, and forwards to the target group. Uses a modern TLS 1.2+ policy (`ELBSecurityPolicy-TLS13-1-2-2021-06`). |
| **ACM Certificate** | Free TLS certificate provisioned by AWS. DNS-validated via Route53 so renewal is automatic. Covers both the apex domain and wildcard (`*.<domain>`). |
| **ECS Cluster** | Logical grouping of services and tasks. Required to run anything on ECS. |
| **ECS Task Definition** | Blueprint for containers — image, port, CPU, memory, logging config. Think of it as the "class" and the running container as the "instance." |
| **ECS Fargate Service** | Ensures the desired number of task replicas are running. Registers them with the target group so the ALB can route to them. `assign_public_ip = false` keeps tasks in private subnets. |
| **ECR Repository** | Private container image registry. Images are pushed here (via `docker push` or CI) and pulled by ECS tasks at startup. Immutable tags prevent accidental overwrites. |
| **RDS PostgreSQL** | Managed PostgreSQL database in private subnets. Storage is encrypted. No public IP — only reachable from ECS tasks via the private network. |
| **DB Subnet Group** | Tells RDS which subnets to place the database in (both private subnets, both AZs). Required for Multi-AZ or single-AZ RDS deployment. |
| **IAM Task Execution Role** | Grants the ECS **agent / Fargate** (not your app) permission to pull images from ECR and write logs to CloudWatch. Used while *starting* the container. Required by every Fargate task. |
| **IAM Task Role** | Grants your **application code** AWS permissions at runtime. In V1 this role exists (with its trust policy) but has **no permissions policy attached** — see note below. |
| **CloudWatch Log Group** | Collects stdout/stderr from containers. 30-day retention — enough for debugging without high cost. |

> **Note on the task role:** AWS rejects an IAM policy with an empty `Statement` array
> (`MalformedPolicyDocument`). The correct way to express "this role has no permissions yet"
> is to attach **no permissions policy at all** — the role still exists with its trust policy.
> V2 will attach a real least-privilege policy (e.g. `secretsmanager:GetSecretValue` on a
> specific secret) when the application first needs to call an AWS API.

---

## Security Model

### Security group chain (least-privilege)

```
Internet ──► ALB SG   ──► ECS SG   ──► RDS SG
             0.0.0.0/0   from ALB     from ECS
             :80, :443    :container   :5432
```

- **ALB SG**: Only ports 80 and 443 are open to `0.0.0.0/0`. Nothing else.
- **ECS SG**: Inbound is **only** from the ALB security group on the container port.
  Never opens to `0.0.0.0/0`, never opens to the VPC CIDR.
- **RDS SG**: Inbound is **only** from the ECS security group on port 5432.
  Never opens to `0.0.0.0/0`, never opens to the VPC CIDR.

Security group rules reference each other by **security group ID**, not by IP/CIDR.
This is both tighter (only members of the source SG are allowed) and more durable
(it does not break when the ALB's underlying IPs change).

### Subnet placement

| Resource | Subnet type | Inbound from internet |
|---|---|---|
| ALB | Public | Yes (ports 80, 443) |
| ECS (Fargate) | Private | No |
| RDS | Private | No |
| NAT Gateway | Public | No (only outbound) |

### Other security controls

- **TLS everywhere**: HTTP redirects to HTTPS. Modern TLS 1.2+ policy on the ALB.
- **Defense in depth on RDS**: three independent controls keep the database off the
  public internet — `publicly_accessible = false`, placement in private subnets,
  and an SG that only allows the ECS SG as source. Any one of them alone would block
  public access.
- **Storage encryption**: RDS storage is encrypted at rest using AWS KMS.
- **ECR immutability**: `image_tag_mutability = "IMMUTABLE"` — tags cannot be
  overwritten, so a running task always maps to exactly the image its tag refers to.
- **ECR scan on push**: `scan_on_push = true` — basic vulnerability scanning runs on
  every image push.
- **CloudWatch logging**: All container output is captured — audit trail for app behaviour.
- **`assign_public_ip = false`**: ECS tasks cannot be reached directly from the internet.
- **Separate IAM roles**: Task execution (Fargate infra) and task role (app perms) are
  two distinct roles, so the app cannot use the broader permissions of the execution role.
- **IMDSv2**: Fargate platform 1.4+ enforces IMDSv2 by default. (This is a platform
  default, not configured by this stack — noted here for completeness.)

---

## Prerequisites

1. **AWS account** with a named CLI profile configured (this stack uses the profile in
   `providers.tf`).
2. **Terraform >= 1.10** installed (uses native S3 state locking via `use_lockfile`).
3. **S3 bucket for remote state** — create it once, before `terraform init`:
   ```bash
   aws s3 mb s3://mini-deploy-platform-tfstate-<account-id> --region eu-north-1
   ```
   The state bucket is created out-of-band on purpose (Terraform reads its backend
   before it can create any resource — a bucket can't store the state of its own
   creation). It is intentionally not managed by this stack.
4. **Route53 hosted zone** for your domain must already exist (Terraform reads it
   as a data source — it is not created by this stack). The domain's nameservers
   must point at that Route53 zone.
5. **Docker image** pushed to ECR (or use the default `nginx:latest` from Docker Hub
   for a smoke test).

---

## Apply Steps

This stack uses a **`terraform.tfvars`** file for the two required variables. That file
is gitignored so secrets never reach the repo — do **not** pass secrets via `-var` on the
command line (they land in shell history).

```bash
cd mini-deploy-platform

# 1. Create terraform.tfvars (gitignored) with the two required values:
cat > terraform.tfvars <<'EOF'
domain_name = "your-domain.example"
db_password = "your-strong-password"
EOF

# 2. Confirm it is NOT tracked by git before doing anything else:
git status        # terraform.tfvars must NOT appear

# 3. Initialize Terraform (downloads providers, configures S3 backend)
terraform init

# 4. Preview what will be created (terraform.tfvars is auto-loaded)
terraform plan

# 5. Apply
terraform apply
```

### Deploying your own app image (optional)

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region eu-north-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-north-1.amazonaws.com

# Tag and push (use a UNIQUE tag — the repo is IMMUTABLE, :latest can't be pushed twice)
docker tag myapp:1.0 <account-id>.dkr.ecr.eu-north-1.amazonaws.com/mini-deploy-platform-app:1.0
docker push <account-id>.dkr.ecr.eu-north-1.amazonaws.com/mini-deploy-platform-app:1.0

# Point the service at the new image
terraform apply -var="container_image=<account-id>.dkr.ecr.eu-north-1.amazonaws.com/mini-deploy-platform-app:1.0"
```

---

## Required Variables

You **must** set these in `terraform.tfvars` before applying:

| Variable | Description |
|---|---|
| `domain_name` | Your domain (e.g. `your-domain.example`). A Route53 hosted zone must already exist. |
| `db_password` | RDS master password. Marked `sensitive` — Terraform won't print it. |

All other variables have sensible defaults (see `variables.tf`).

---

## Design Tradeoffs (Known)

| Tradeoff | Rationale |
|---|---|
| **Single NAT Gateway** (not one per AZ) | Saves the cost of a second NAT. If the AZ with the NAT fails, private tasks lose outbound internet — but the DB and ALB stay up in the other AZ. Acceptable for a toy platform; production HA would use one NAT per AZ. |
| **DB password as a variable** | V1 keeps it simple. V2 moves this to **AWS Secrets Manager** and passes the secret to ECS, so the password never sits in `tfvars` or state. |
| **`backup_retention_period = 1`** | Set to 1 day to stay within Free Tier limits (Free Tier caps RDS backup retention). Production would use 7+ days. |
| **`skip_final_snapshot = true`** | Avoids blocking `terraform destroy`. Never do this in production — you want a final snapshot before deletion. |
| **`deletion_protection = false`** | Makes it easy to tear down the toy platform. Enable in production to prevent accidental DB deletion. |
| **`force_delete = true` on ECR** | Allows `terraform destroy` to clean up images. In production, keep this `false` to prevent accidental image loss. |
| **Empty task role (no policy attached)** | The app has no AWS permissions yet. V2 will add least-privilege policies (e.g. `secretsmanager:GetSecretValue` on a specific secret). |

---

## Notes / Gotchas Hit During Build

Real issues encountered and fixed while deploying V1 (kept here as documentation):

- **Security group descriptions must be ASCII.** A non-ASCII em-dash (`—`) in an SG
  description fails with `InvalidParameterValue ... Character sets beyond ASCII are not
  supported`. Use a plain hyphen.
- **An IAM policy cannot have an empty `Statement` array.** "No permissions" is expressed
  by attaching no permissions policy, not by an empty policy document.
- **Free Tier caps RDS backup retention.** `backup_retention_period` was lowered to `1`.

---

## File Map

```
mini-deploy-platform/
├── providers.tf          # Terraform block, S3 backend, AWS provider (named profile)
├── variables.tf          # All variables; domain_name + db_password have no default (required)
├── network.tf            # VPC, subnets, IGW, NAT, EIP, route tables
├── security_groups.tf    # ALB SG, ECS SG, RDS SG (referenced by SG ID)
├── alb.tf                # ALB, target group, HTTP + HTTPS listeners
├── ecs.tf                # ECS cluster, task definition, service, CloudWatch logs
├── ecr.tf                # ECR repository (IMMUTABLE, scan_on_push)
├── rds.tf                # DB subnet group, RDS PostgreSQL instance
├── iam.tf                # Task execution role + task role (separate)
├── acm.tf                # ACM certificate + Route53 DNS validation
├── dns.tf                # Route53 A alias → ALB
├── outputs.tf            # Output values
├── .gitignore            # Ignores state, .terraform/, *.tfvars — keeps .terraform.lock.hcl
└── README.md             # This file
```