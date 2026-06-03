terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # Values are provided at init time:
    #   terraform init -backend-config="bucket=YOUR_BUCKET" \
    #                  -backend-config="key=vidcast/dev/terraform.tfstate" \
    #                  -backend-config="region=eu-west-2" \
    #                  -backend-config="dynamodb_table=vidcast-terraform-locks"
    #
    # Or configure in terraform.tfvars (gitignored).
    key    = "vidcast/dev/terraform.tfstate"
    region = "eu-west-2"
  }
}

provider "aws" {
  region = var.aws_region
}
