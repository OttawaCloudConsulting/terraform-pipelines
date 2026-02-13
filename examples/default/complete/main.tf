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

module "pipeline" {
  source = "../../../modules/default"

  # Required
  project_name             = var.project_name
  github_repo              = var.github_repo
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn

  # Optional overrides
  github_branch             = "develop"
  iac_runtime               = "terraform"
  iac_version               = "1.11.0"
  codestar_connection_arn   = var.codestar_connection_arn
  create_state_bucket       = false
  state_bucket              = var.state_bucket
  state_key_prefix          = "my-project"
  sns_subscribers           = ["team-lead@example.com", "devops@example.com"]
  enable_review_gate        = true
  codebuild_compute_type    = "BUILD_GENERAL1_MEDIUM"
  codebuild_image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  codebuild_timeout_minutes = 90
  log_retention_days        = 365
  artifact_retention_days   = 60

  tags = {
    team        = "platform"
    cost-center = "12345"
    environment = "automation"
  }
}
