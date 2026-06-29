# ── Security Groups ────────────────────────────────────────────────────────────
# Tightly chained, least-privilege.  Never opens to 0.0.0.0/0 except the ALB.

# ── ALB Security Group ─────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB - allows inbound HTTP/S from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ALB outbound to targets"
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ── ECS Security Group ─────────────────────────────────────────────────────────

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-ecs-sg"
  description = "ECS tasks - inbound only from ALB SG on container port"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # ONLY from the ALB
    description     = "Container port from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ECS tasks outbound via NAT (pull images, reach internet)"
  }

  tags = {
    Name = "${var.project_name}-ecs-sg"
  }
}

# ── RDS Security Group ─────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS - inbound only from ECS SG on DB port"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id] # ONLY from ECS tasks
    description     = "PostgreSQL from ECS tasks"
  }

  # No egress rule needed for RDS — it only responds to requests.
  # But CloudWatch Logs / Enhanced Monitoring needs outbound.  Keep a tight one.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound for CloudWatch / Enhanced Monitoring"
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}
