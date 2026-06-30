# ── Variables ───────────────────────────────────────────────────────────────────
# Every value that differs between environments lives here.
# Sensible defaults are provided so a minimal `terraform.tfvars` is enough.

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Project tag value applied to every resource"
  type        = string
  default     = "mini-deploy-platform"
}

# ── Networking ─────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_newbits" {
  description = "Newbits value for public subnet CIDR calculation (cidrsubnet)"
  type        = number
  default     = 8
}

variable "private_subnet_newbits" {
  description = "Newbits value for private subnet CIDR calculation (cidrsubnet)"
  type        = number
  default     = 8
}

# ── Compute ────────────────────────────────────────────────────────────────────

variable "app_name" {
  description = "Application name used in ECS service, task definition, and ECR naming"
  type        = string
  default     = "app"
}

variable "container_image" {
  description = "Container image to deploy (Docker Hub or ECR URI)"
  type        = string
  default     = "nginx:latest"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 80
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB (512, 1024, 2048, ...)"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of ECS tasks to run"
  type        = number
  default     = 1
}

# ── Database ───────────────────────────────────────────────────────────────────

variable "db_name" {
  description = "RDS database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "RDS master password — V2 stores this in Secrets Manager; ECS reads it at runtime via valueFrom"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = number
  default     = 5432
}

# ── DNS / TLS ──────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Root domain name (Route53 hosted zone must already exist)"
  type        = string
}

variable "app_subdomain" {
  description = "Subdomain pointing to the ALB (e.g. 'app' → app.example.com)"
  type        = string
  default     = "app"
}
