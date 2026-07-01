# ── Lambda — Deploy Worker ──────────────────────────────────────────────────────
# Python 3.12 function triggered by SQS. Reads deploy requests, calls ECS
# update-service, and publishes an SNS notification on completion.

# ── Package the Python code ─────────────────────────────────────────────────────
data "archive_file" "deploy_worker" {
  type        = "zip"
  source_file = "${path.module}/lambda/deploy_worker.py"
  output_path = "${path.module}/lambda/deploy_worker.zip"
}

# ── CloudWatch Log Group ────────────────────────────────────────────────────────
# Explicit log group so we can set retention (Lambda auto-creates one otherwise,
# but it defaults to "never expire").

resource "aws_cloudwatch_log_group" "deploy_worker" {
  name              = "/aws/lambda/${var.project_name}-deploy-worker"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-deploy-worker-logs"
  }
}

# ── Lambda Execution Role ───────────────────────────────────────────────────────
# Dedicated role — does NOT touch the existing ECS roles or GitHub Actions role.

resource "aws_iam_role" "deploy_worker" {
  name = "${var.project_name}-deploy-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-deploy-worker-role"
  }
}

# ── Least-privilege inline policy ───────────────────────────────────────────────

resource "aws_iam_role_policy" "deploy_worker" {
  name = "${var.project_name}-deploy-worker-policy"
  role = aws_iam_role.deploy_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ── CloudWatch Logs ─────────────────────────────────────────────────
      # CreateLogGroup cannot be resource-scoped (and is only needed on first
      # invocation — Lambda auto-creates the log group if it doesn't exist).
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      # CreateLogStream + PutLogEvents: scoped to THIS function's log group
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.deploy_worker.arn}:*"
      },

      # ── SQS: consume from the deploy queue ──────────────────────────────
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.deploy.arn
      },

      # ── ECR: pre-deploy image validation ──────────────────────────────
      # The Lambda calls ecr.describe_images() BEFORE registering a task
      # definition to verify the requested image tag exists. Scoped to
      # the specific repository ARN — never "*".
      {
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages"]
        Resource = aws_ecr_repository.app.arn
      },

      # ── ECS: update and describe ONLY the app service ───────────────────
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
        ]
        Resource = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${var.project_name}-cluster/${var.project_name}-svc"
      },

      # ── ECS: describe + register task definitions ──────────────────────
      # DescribeTaskDefinition and RegisterTaskDefinition do NOT support
      # resource-level permissions — must use "*" (AWS IAM limitation).
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
      },

      # ── IAM: allow the Lambda to pass ECS roles when registering a new
      # task-definition revision. Required because register_task_definition
      # references executionRoleArn and taskRoleArn — that counts as
      # "passing" the roles. Scoped to ONLY these two roles, never "*".
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn,
        ]
      },

      # ── SNS: publish to the deploy-notifications topic ──────────────────
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.deploy_notifications.arn
      },
    ]
  })
}

# ── Lambda Function ─────────────────────────────────────────────────────────────

resource "aws_lambda_function" "deploy_worker" {
  function_name = "${var.project_name}-deploy-worker"
  description   = "Async deploy worker: reads SQS messages, registers a new task-def revision with the requested image, updates ECS service, notifies SNS"

  filename         = data.archive_file.deploy_worker.output_path
  source_code_hash = data.archive_file.deploy_worker.output_base64sha256
  runtime          = "python3.12"
  handler          = "deploy_worker.lambda_handler"
  role             = aws_iam_role.deploy_worker.arn

  timeout     = 30 # 30 s is ample for a single ECS update_service call
  memory_size = 128

  environment {
    variables = {
      ECS_CLUSTER     = "${var.project_name}-cluster"
      ECS_SERVICE     = "${var.project_name}-svc"
      ECS_TASK_FAMILY = "${var.project_name}-${var.app_name}"
      # ECR repository URL without tag — the Lambda appends ":<image_tag>"
      ECR_IMAGE_BASE = aws_ecr_repository.app.repository_url
      # Repository name (no registry prefix) — used for ECR describe_images lookups
      ECR_REPO_NAME = aws_ecr_repository.app.name
      SNS_TOPIC_ARN = aws_sns_topic.deploy_notifications.arn
    }
  }

  tags = {
    Name = "${var.project_name}-deploy-worker"
  }
}

# ── SQS → Lambda event source mapping ───────────────────────────────────────────
# Triggers the Lambda whenever a message lands in the deploy queue.

resource "aws_lambda_event_source_mapping" "deploy_worker" {
  event_source_arn = aws_sqs_queue.deploy.arn
  function_name    = aws_lambda_function.deploy_worker.arn

  batch_size = 1 # process one deploy request at a time
  enabled    = true
}
