# ── Outputs ────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB public DNS name — the entry point for your app"
  value       = "https://${var.app_subdomain}.${var.domain_name}"
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (useful for CloudWatch metrics)"
  value       = aws_lb.main.arn_suffix
}

output "ecr_repository_url" {
  description = "ECR repository URL — push images here"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
}

output "rds_endpoint" {
  description = "RDS endpoint (hostname:port) — connect your app to this"
  value       = "${aws_db_instance.main.address}:${aws_db_instance.main.port}"
}

output "rds_database_name" {
  description = "RDS database name"
  value       = aws_db_instance.main.db_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS tasks and RDS)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)"
  value       = aws_subnet.public[*].id
}
