# ── SQS ────────────────────────────────────────────────────────────────────────
# Async deploy request queue + dead-letter queue.
# Messages: { "image_tag": "abc123", "requested_by": "..." }

# ── Dead-Letter Queue ───────────────────────────────────────────────────────────
# Receives messages that failed processing after maxReceiveCount attempts.
# Inspect this queue to debug failed deploys.

resource "aws_sqs_queue" "deploy_dlq" {
  name = "${var.project_name}-deploy-dlq"

  # Retain failed messages for 14 days so we have time to inspect them
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name = "${var.project_name}-deploy-dlq"
  }
}

# ── Main Deploy Queue ───────────────────────────────────────────────────────────

resource "aws_sqs_queue" "deploy" {
  name = "${var.project_name}-deploy-queue"

  # visibility_timeout must be longer than the Lambda timeout (30 s).
  # 90 s gives the Lambda a full minute of headroom after its 30 s cap.
  visibility_timeout_seconds = 90

  # Messages that fail processing 3 times are sent to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deploy_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "${var.project_name}-deploy-queue"
  }
}
