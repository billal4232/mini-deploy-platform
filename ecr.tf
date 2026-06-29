# ── ECR ────────────────────────────────────────────────────────────────────────
# Private container image registry.  Images are pushed here and pulled by ECS.

resource "aws_ecr_repository" "app" {
  name = "${var.project_name}-${var.app_name}"

  # Image scanning on push — flags CVEs without blocking deploys
  image_scanning_configuration {
    scan_on_push = true
  }

  # Keep images immutable so tags can't be overwritten accidentally
  image_tag_mutability = "IMMUTABLE"

  # Force-delete images when the repo is destroyed (safe for dev / toy)
  force_delete = true

  tags = {
    Name = "${var.project_name}-ecr"
  }
}
