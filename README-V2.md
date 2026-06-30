# Mini Deployment Platform — V2

**V2 adds automated CI/CD and proper secrets handling on top of V1's core deploy layer.**

V1 deployed a container by hand (`terraform apply` + a public `nginx` image). V2 makes the
platform deploy itself: push code to `main`, and a GitHub Actions pipeline builds the app
image, pushes it to ECR, and rolls it out to ECS — with **no long-lived AWS keys** and the
**DB password no longer in plaintext env vars**.

> Builds on V1 (see the V1 README). V2 only **adds** to the stack; it does not restructure it.

---

## What V2 adds and why

| Addition | Why it exists |
|---|---|
| **GitHub Actions pipeline** | Stop deploying by hand. Push to `main` → app is built and deployed automatically. |
| **OIDC trust (GitHub ↔ AWS)** | The pipeline gets **temporary** AWS credentials by proving its identity — no long-lived access keys stored in GitHub, nothing to leak. |
| **SHA-tagged images** | Every build is tagged with its git commit SHA — a unique, immutable tag per build (works with the IMMUTABLE ECR from V1). |
| **Secrets Manager** | The DB password is read by ECS at container startup from a vault, instead of sitting as a plaintext env var in the task definition. |
| **A real placeholder app** | A minimal Flask app (`app/`) so the pipeline has something to build and deploy (V1 ran a public `nginx` image with nothing to build). |

---

## How the CI/CD flow works

On every push to `main`:

1. **GitHub mints an OIDC token** describing the workflow (repo + branch). Enabled by
   `permissions: id-token: write`.
2. **Configure AWS credentials** — the pipeline presents that token and assumes the
   GitHub Actions IAM role. AWS verifies the token's signature and checks it against the
   role's trust condition (this repo, `main` branch only), then issues temporary credentials.
3. **Login to ECR** using those temporary credentials.
4. **Build + push** the Docker image from `app/`, tagged with the git SHA (`${{ github.sha }}`).
5. **Deploy to ECS** — fetch the current task definition, swap in the new image, register a
   new revision, update the service with `--force-new-deployment`, and wait for it to stabilise.

The whole thing is hands-free: push code, the platform deploys it.

---

## OIDC — the keyless auth model

**Problem it solves:** to deploy, the pipeline needs AWS permissions. The old way was to
create an IAM user, generate a long-lived access key, and store it in GitHub. That key works
forever and is a standing leak risk.

**OIDC instead:** GitHub and AWS share a trust relationship. When the pipeline runs, GitHub
issues a short-lived, cryptographically-signed token stating *which repo and branch* is
running. AWS verifies the signature and checks the identity against the role's trust policy,
then hands back **temporary** credentials (expire in ~1 hour). Nothing long-lived is stored.

**Scoping (the security-critical line):** the role's trust condition is locked to
`repo:billal4232/mini-deploy-platform:ref:refs/heads/main`. A fork running identical code
**cannot** assume the role — its token carries a different repo identity, so AWS denies it.
This is why the workflow can be fully public and still secure: the protection is identity,
not secrecy.

**The OIDC provider is a data source, not a resource.** The GitHub OIDC provider is unique
per AWS account (one per URL) and was already created by an earlier project. This stack
**references** it (`data "aws_iam_openid_connect_provider"`) rather than creating it — so a
`terraform destroy` here can't delete a provider other projects depend on.

---

## Secrets Manager — keeping the DB password out of the task definition

- The DB password is stored in a **Secrets Manager secret** (`secrets.tf`).
- The ECS **task definition** references it via the `secrets` block (`valueFrom = <secret ARN>`),
  not as a plain environment variable. The **execution role** fetches it and injects it into
  the container at startup.
- Non-sensitive DB details (host, port, name, username) stay as plain `environment` vars —
  only the password is vaulted.

**What this improves over V1:** in V1 the password sat in the task definition in plaintext —
anyone with ECS console/CLI read access could see it. In V2 the task definition holds only a
*reference*; the password value is only materialised inside the running container.

**What it does NOT fully fix (honest limitation):** the secret is still *seeded* from the
`db_password` variable, so the value also lives in `terraform.tfvars` and the Terraform state
(which is in S3 — keep that bucket private). A fuller production approach would generate the
password inside AWS (so no plaintext copy ever exists) and enable rotation. Deferred — V2's
goal is the CI/CD + secrets *pattern*, not full rotation.

---

## Deliberate scope decision: the pipeline does NOT run `terraform apply`

The pipeline only builds the image and updates the ECS service. It **never** runs
`terraform apply` and never changes infrastructure. Infra changes stay manual (a human runs
`terraform plan`, reads it, then `apply`).

**Why:** blast radius. App code changes constantly and is low-risk; infra changes are rare and
dangerous (a bad auto-apply could destroy the database). Keeping them separate means the
pipeline can run freely without ever threatening the network or RDS.

This separation is enforced in code: the ECS service has
`lifecycle { ignore_changes = [task_definition] }` — so Terraform ignores task-definition
changes (the pipeline owns those) and won't revert a pipeline deploy on the next `apply`.

---

## One-time setup

1. **Apply the V2 Terraform** (creates the GitHub Actions role, references the OIDC provider,
   creates the Secrets Manager secret, wires the secret into ECS):
   ```bash
   terraform apply
   ```
2. **Get the role ARN:**
   ```bash
   terraform output -raw github_actions_role_arn
   ```
3. **Add it to GitHub** as a repository secret named `AWS_ROLE_ARN`
   (Settings → Secrets and variables → Actions). Paste the raw value — **no quotes**.
4. **Push to `main`** — the pipeline runs automatically.

---

## Notes / Gotchas Hit During Build

Real failures encountered and fixed while getting V2 working end to end. These are the most
instructive part of the project — each was diagnosed by reading the actual error, not guessing.

**IAM scoping — some actions cannot be resource-scoped (must use `Resource = "*"`):**
- `ecr:GetAuthorizationToken` — required on both the GitHub Actions role *and* the ECS
  execution role. The execution-role version was a **latent V1 bug**: V1 ran `nginx` from
  Docker Hub (no ECR auth needed), so the broken scoping never fired. V2 pulls from ECR, which
  exercised the code path and exposed it.
- `ecs:DescribeTaskDefinition` and `ecs:RegisterTaskDefinition` — also cannot be
  resource-scoped; both need `"*"`.
- Actions that **can** be scoped were kept tight: `ecr` push (specific repo),
  `ecs:UpdateService` (specific service), `iam:PassRole` (the two specific roles only).

**`iam:PassRole`** — registering a task definition that references the execution/task roles
counts as *passing* those roles to ECS, which is a separately-guarded action. Scoped to
exactly those two roles (never `*`, which would be a privilege-escalation hole).

**OIDC provider already exists** — `EntityAlreadyExists`. The provider is account-wide and
unique per URL; an earlier project created it. Fixed by switching from `resource` (create) to
`data` (reference).

**IMMUTABLE ECR blocks pipeline re-runs** — "Re-run jobs" replays the same commit SHA, so it
tries to push an image tag that already exists, which the IMMUTABLE repo rejects. Fix: push a
fresh commit (new SHA) instead of re-running.

**Health check ordering** — pointing the ALB health check at `/health` failed while the
running app was still `nginx` (which has no `/health`). The endpoint only exists in the
not-yet-deployed Flask app. Lesson: a health check path must exist in whatever app is
*currently running*. (Kept on `/`, which both nginx and Flask answer 200 on — also avoids a
crash loop on a fresh `destroy`/`apply` that starts from the default image.)

**Security group description must be ASCII** (V1 carryover) — a non-ASCII em-dash failed.
**Empty IAM policy statement is invalid** (V1 carryover) — "no permissions" = no policy
attached, not an empty `Statement`. **Free Tier caps RDS backup retention** (V1 carryover).

The recurring theme: **read the error, find the exact denied action/resource, fix the cause.**
CI/CD IAM in particular fails one permission at a time — you grant them iteratively as each
call surfaces its own `AccessDenied`.

---

## New / changed files in V2

```
mini-deploy-platform/
├── .github/workflows/deploy.yml   # CI/CD pipeline (OIDC auth, build, push, ECS deploy)
├── app/
│   ├── main.py                    # minimal Flask app (200 on / and /health)
│   ├── Dockerfile                 # multi-stage build, EXPOSE 80
│   └── requirements.txt           # flask
├── oidc.tf                        # OIDC provider (data source) + GitHub Actions role/policy
├── secrets.tf                     # Secrets Manager secret + version (DB password)
├── ecs.tf        (modified)       # secrets block, ignore_changes on task_definition
├── iam.tf        (modified)       # execution role: GetAuthorizationToken split to "*" + GetSecretValue
├── outputs.tf    (modified)       # github_actions_role_arn output
└── README-V2.md                   # this file
```