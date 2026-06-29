# ── RDS ────────────────────────────────────────────────────────────────────────
# PostgreSQL instance in private subnets, encrypted, not publicly accessible.

# ── DB Subnet Group ────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id # spans both private subnets / both AZs

  tags = {
    Name = "${var.project_name}-db-subnet"
  }
}

# ── DB Instance ────────────────────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password # V2: move to Secrets Manager + rotation
  port     = var.db_port

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true # encryption at rest

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  publicly_accessible = false # never expose RDS to the internet
  skip_final_snapshot = true  # safe for toy project; set to false in production

  backup_retention_period = 1 # 7 days of automated backups
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  # Deletion protection OFF for toy project (enable in production)
  deletion_protection = false

  tags = {
    Name = "${var.project_name}-db"
  }
}
