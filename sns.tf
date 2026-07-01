# ── SNS ────────────────────────────────────────────────────────────────────────
# SNS topic for deploy notifications + email subscription.

resource "aws_sns_topic" "deploy_notifications" {
  name = "${var.project_name}-deploy-notifications"

  tags = {
    Name = "${var.project_name}-deploy-notifications"
  }
}

# Email subscription — AWS sends a confirmation email to this address.
# The recipient MUST click the confirmation link before notifications are delivered.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.deploy_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
