# ── Secrets Manager ─────────────────────────────────────────────────────────────
# V2: DB password moved from plain tfvars into Secrets Manager.
# The ECS task reads it at container startup via the `secrets` block — never
# exposed in task-definition JSON or environment variables.

# The secret itself — stores the master password for RDS PostgreSQL
resource "aws_secretsmanager_secret" "db_password" {
  name = "${var.project_name}-db-password"

  # V2: In production, generate the password with random_password and let
  # Secrets Manager handle rotation. Here we seed from the variable so the
  # secret matches what RDS was created with.
  # To enable rotation in production, uncomment:
  #   rotation_rules {
  #     automatically_after_days = 30
  #   }

  tags = {
    Name = "${var.project_name}-db-password-secret"
  }
}

# Secret value — seeded from the same db_password variable RDS uses
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
