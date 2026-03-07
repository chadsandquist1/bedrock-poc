terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket         = "bedrock-rag-tfstate-741448928264"
    key            = "bedrock-poc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "bedrock-rag-tfstate-lock"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "bedrock-rag-poc"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
