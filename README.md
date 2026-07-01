# Mini Deployment Platform — V3 (Async Deploy Engine)

V3 adds an asynchronous, decoupled deploy path that coexists with the V2 CI/CD pipeline.
It is a **minimal** event-driven engine: SQS → Lambda → ECS → SNS.

---

## What V3 adds (and WHY)

| V1/V2 approach | V3 approach |
|---|---|
| Deploys happen **synchronously** as a pipeline step. You wait for CI/CD to finish. | A deploy request is a **queued background job**. Submit a message and move on. |
| Only GitHub Actions can trigger a deploy (push to main). | **Any system** that can write to SQS can trigger a deploy — a CLI command, a webhook, or (in the future) a "Deploy" button in a frontend. |
| Failures are "inline" — you watch the pipeline log. | Failures are **asynchronous but visible**: the message retries up to 3 times, then lands in a dead-letter queue for inspection. |

This is the "engine" — the backend plumbing. A future V4 could add a simple API or web UI that drops messages into the SQS queue.

---

## Flow (step by step)

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Someone sends a deploy request                               │
│    aws sqs send-message --queue-url ...                         │
│    --message-body '{"image_tag":"abc123","requested_by":"..."}'  │
└───────────────────────────┬──────────────────────────────────────┘
                            │
              ┌─────────────▼─────────────┐
              │  SQS deploy-queue         │
              │  (standard queue)         │
              └─────────────┬─────────────┘
                            │ Lambda trigger (event source mapping)
              ┌─────────────▼─────────────┐
              │  Lambda deploy_worker.py  │
              │  - Parses image_tag       │
              │  - Calls ECS update-      │
              │    service (force deploy) │
              └──┬───────────────────┬────┘
                 │                   │
          ┌──────▼──────┐    ┌──────▼──────┐
          │  Success?    │    │  Failure?    │
          │  Publish to  │    │  RAISE error │
          │  SNS topic   │    │  (SQS retry) │
          └──────┬───────┘    └──────┬───────┘
                 │                   │
    ┌────────────▼──────────┐  ┌────▼─────────────────┐
    │  SNS email → you      │  │  After 3 retries:     │
    │  "Deploy triggered!"  │  │  message → DLQ        │
    └───────────────────────┘  │  (inspectable dead     │
                               │   letter queue)        │
                               └────────────────────────┘
```

---

## How this relates to the V2 pipeline

V2 and V3 are **separate, parallel deploy paths** that coexist:

| Path | Trigger | Mechanism | Task def |
|---|---|---|---|
| **V2 pipeline** | `git push main` | GitHub Actions → build image → register new task def → update service | New revision with specific SHA-tagged image |
| **V3 async engine** | SQS message | Lambda → `update_service(forceNewDeployment=True)` | Current revision (no new task def registered) |

Both paths:
- Target the **same ECS service** (`mini-deploy-platform-svc`)
- Are governed by the **same SG chain, same VPC, same ALB**
- Do NOT interfere with each other

The V2 pipeline is **unchanged**. It continues to work exactly as before.

A future frontend "Deploy" button would simply drop a JSON message into the deploy queue — the Lambda doesn't care who sent it.

---

## Dead-Letter Queue (DLQ)

The DLQ (`mini-deploy-platform-deploy-dlq`) exists because **asynchronous failures are invisible** — there's no terminal output telling you a deploy failed.

**How a message ends up in the DLQ:**
1. The Lambda receives a message from the deploy queue.
2. The Lambda's ECS call fails (e.g. throttling, missing permissions, service not found).
3. The Lambda **raises** the exception — it does NOT catch and swallow errors.
4. SQS marks the message as "not deleted", so after `visibility_timeout` it becomes visible again.
5. The Lambda receives it a second time. Same failure → retry again.
6. After **3 failed attempts** (`maxReceiveCount: 3`), SQS moves the message to the DLQ.

**Inspecting the DLQ:**
```bash
# See how many failed messages are waiting
aws sqs get-queue-attributes \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/688600819246/mini-deploy-platform-deploy-dlq" \
  --attribute-names ApproximateNumberOfMessages

# Peek at a failed message (doesn't delete it)
aws sqs receive-message \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/688600819246/mini-deploy-platform-deploy-dlq" \
  --max-number-of-messages 1
```

Also check **Lambda CloudWatch logs** (`/aws/lambda/mini-deploy-platform-deploy-worker`) — each failure is logged with a full stack trace.

---

## Testing the flow

### 1. Confirm the SNS subscription

After `terraform apply`, AWS sends a confirmation email to `var.notification_email`. **Click the "Confirm subscription" link** in that email before testing.

### 2. Send a test deploy message

```bash
aws sqs send-message \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/688600819246/mini-deploy-platform-deploy-queue" \
  --message-body '{"image_tag":"test-v3","requested_by":"cli-test"}' \
  --profile limonlab
```

If it's the very first Lambda invocation, there may be a cold start (a few seconds).

### 3. Observe the result

- **CloudWatch Logs**: Check the log group `/aws/lambda/mini-deploy-platform-deploy-worker` for the Lambda's output.
- **ECS console**: The service should show a new deployment in progress.
- **Email**: You should receive an SNS notification once the Lambda finishes (subject: `[Mini Deploy Platform] Deploy Triggered`).

### 4. Test the DLQ (optional)

Send a message with e.g. a bad service name to trigger a failure:
```bash
# This simulates a failure by pointing at a nonexistent service
# (only works if you temporarily swap the env var — not worth doing live)

# Alternative: after applying, go to the Lambda console and edit the
# ECS_SERVICE env var to a nonexistent name, then send a test message.
# After 3 invocations, check the DLQ.
```

---

## Prerequisites / Apply Steps

```bash
cd mini-deploy-platform

# 1. Init (archive provider is new)
terraform init

# 2. Plan — review the 9 new resources (2 SQS queues, SNS topic + sub,
#    Lambda role/policy/function/event-mapping, CW log group)
terraform plan \
  -var="domain_name=limonlab.online" \
  -var="db_password=<your-password>" \
  -var="notification_email=you@example.com"

# 3. Apply
terraform apply \
  -var="domain_name=limonlab.online" \
  -var="db_password=<your-password>" \
  -var="notification_email=you@example.com"

# 4. Confirm the SNS email subscription (check your inbox!)

# 5. Test with the CLI command above
```

---

## Variables to set

| Variable | Required | Notes |
|---|---|---|
| `domain_name` | Yes | Same as V1/V2 |
| `db_password` | Yes | Same as V1/V2 |
| `notification_email` | Yes | **New in V3** — where SNS deploy emails go |
| Everything else | No | Defaults in `variables.tf` |

---

## New resources (inventory)

| Resource | Type | Purpose |
|---|---|---|
| `deploy-queue` | `aws_sqs_queue` | Holds deploy requests. Lambda reads from here. |
| `deploy-dlq` | `aws_sqs_queue` | Dead-letter queue — collects messages that failed 3 times. |
| `deploy-notifications` | `aws_sns_topic` | Deploy completion notifications. |
| Email subscription | `aws_sns_topic_subscription` | Delivers notifications to `var.notification_email`. |
| `deploy-worker` (Lambda) | `aws_lambda_function` | Async deploy worker — processes SQS messages, calls ECS. |
| `deploy-worker-role` | `aws_iam_role` | Dedicated execution role for the Lambda (not touching V1/V2 roles). |
| `deploy-worker-policy` | `aws_iam_role_policy` | Least-privilege: SQS consume, ECS update, SNS publish, CW logs. |
| Event source mapping | `aws_lambda_event_source_mapping` | Wires SQS queue → Lambda trigger. |
| CW log group | `aws_cloudwatch_log_group` | Captures Lambda stdout/stderr (30-day retention). |

---

## Files changed / added

| File | Status |
|---|---|
| `sqs.tf` | **New** — main queue + DLQ |
| `sns.tf` | **New** — SNS topic + email subscription |
| `lambda.tf` | **New** — Lambda function, IAM role/policy, archive_file, event source mapping, log group |
| `lambda/deploy_worker.py` | **New** — Python Lambda code |
| `variables.tf` | **Modified** — added `notification_email` |
| `providers.tf` | **Modified** — added `hashicorp/archive` provider |
| `README-V3.md` | **New** — this file |

All V1/V2 files not listed above are completely unchanged.
