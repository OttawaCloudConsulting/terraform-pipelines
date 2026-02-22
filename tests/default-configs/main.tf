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

module "default_pipeline_with_configs" {
  source = "../../modules/default"

  project_name             = "test-dflt-cfgs"
  github_repo              = var.github_repo
  github_branch            = var.github_branch
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn

  # Configs repo feature
  configs_repo        = var.configs_repo
  configs_repo_branch = var.configs_repo_branch
  configs_repo_path   = var.configs_repo_path
}
