############################################
# One-time bootstrap: Terraform remote state
############################################
# Run this ONCE, manually, from your own machine (not from CI):
#   cd bootstrap
#   terraform init
#   terraform apply
#
# It creates the S3 bucket + DynamoDB lock table that the main
# ../infra stack uses as its remote state backend. GitHub Actions
# never creates or destroys these — they must outlive every CI run.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for the state bucket + lock table"
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state. Defaults to a random suffix so it doesn't collide with anyone else's bucket."
  type        = string
  default     = ""
}

resource "random_id" "suffix" {
  count       = var.state_bucket_name == "" ? 1 : 0
  byte_length = 4
}

locals {
  bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "jenkins-tfstate-${random_id.suffix[0].hex}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "jenkins-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
