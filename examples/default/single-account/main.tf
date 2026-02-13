terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ca-central-1"
}

# Single-account deployment: DEV and PROD share the same account and role.
# Environment isolation is achieved via separate state keys (dev/ and prod/).
module "pipeline" {
  source = "../../../modules/default"

  project_name = var.project_name
  github_repo  = var.github_repo

  # Same account for both environments
  dev_account_id           = var.account_id
  dev_deployment_role_arn  = var.deployment_role_arn
  prod_account_id          = var.account_id
  prod_deployment_role_arn = var.deployment_role_arn
}
