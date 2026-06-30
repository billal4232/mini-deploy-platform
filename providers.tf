# ── Provider & Backend ──────────────────────────────────────────────────────────
# Terraform 1.10+ with native S3 state locking (use_lockfile).
# The S3 bucket must exist before running `terraform init`.
# Create it manually or with a bootstrap apply:
#   aws s3 mb s3://mini-deploy-platform-tfstate-688600819246 --region eu-north-1

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "mini-deploy-platform-tfstate-688600819246"
    key          = "v1/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true # native S3 lock, no DynamoDB table needed (1.10+)
    profile      = "limonlab"
  }
}

provider "aws" {
  region  = var.region
  profile = "limonlab"
  default_tags {
    tags = {
      Project = var.project_name
    }
  }
}
