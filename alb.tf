# ── ALB, Target Group & Listeners ──────────────────────────────────────────────
# Internet-facing ALB with HTTP→HTTPS redirect. Target type = ip (Fargate).

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false # internet-facing
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # ALB in public subnets

  # Fail open so we can debug, but consider dropping_to_routing in production
  # (requires WAF association to be meaningful with this ALB config)
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ── Target Group ───────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for awsvpc / Fargate

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-299"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Allow enough time for container startup (cold start-safe for Fargate)
  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-tg"
  }
}

# ── HTTP Listener (redirect to HTTPS) ──────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${var.project_name}-http-listener"
  }
}

# ── HTTPS Listener ─────────────────────────────────────────────────────────────

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # modern TLS 1.2+ policy
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${var.project_name}-https-listener"
  }
}
