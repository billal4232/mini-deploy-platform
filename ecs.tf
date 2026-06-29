# ── ECS ────────────────────────────────────────────────────────────────────────
# Fargate cluster, task definition, and service.  Tasks run in private subnets.

# ── Cluster ────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# ── CloudWatch Log Group ───────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-${var.app_name}"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-logs"
  }
}

# ── Task Definition ────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-${var.app_name}"
  network_mode             = "awsvpc" # required for Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name  = var.app_name
      image = var.container_image

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # IMDSv2 is enforced by Fargate platform 1.4+ by default.
      # No additional configuration needed — the ECS agent honours the
      # ECS_ENABLE_CONTAINER_METADATA setting automatically.

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.app_name
        }
      }

      # Uncomment and set real values when the app needs to reach RDS:
      # environment = [
      #   { name = "DB_HOST",     value = aws_db_instance.main.address },
      #   { name = "DB_PORT",     value = tostring(var.db_port) },
      #   { name = "DB_NAME",     value = var.db_name },
      #   { name = "DB_USERNAME", value = var.db_username },
      # ]
      #
      # Pass the password via Secrets Manager in V2 — never via plain env vars.
    }
  ])

  tags = {
    Name = "${var.project_name}-taskdef"
  }
}

# ── Service ────────────────────────────────────────────────────────────────────

resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id # private subnets only
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false # never expose tasks directly
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  # Wait for steady state so terraform apply confirms the service is healthy
  wait_for_steady_state = true

  depends_on = [
    aws_lb_listener.https, # ensure ALB listener exists before registering targets
  ]

  tags = {
    Name = "${var.project_name}-svc"
  }
}
