terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Values are supplied at `terraform init` time via -backend-config
  # (see .github/workflows/deploy.yml, or backend.hcl for local runs).
  # Left empty here on purpose — do not hardcode the bucket name.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "jenkins"
      ManagedBy = "terraform"
    }
  }
}
