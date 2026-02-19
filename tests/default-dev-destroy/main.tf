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

module "dev_destroy_pipeline" {
  source = "../../modules/default-dev-destroy"

  project_name             = "test-dev-destroy"
  github_repo              = var.github_repo
  github_branch            = var.github_branch
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn

  # Variant-specific: test with approval enabled (default)
  enable_destroy_approval = true
}
