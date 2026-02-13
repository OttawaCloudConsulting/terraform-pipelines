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

# Default-DevDestroy variant: 9 standard stages + optional destroy approval + destroy DEV.
# enable_destroy_approval defaults to true (safe by default).
module "pipeline" {
  source = "../../../modules/default-dev-destroy"

  project_name             = var.project_name
  github_repo              = var.github_repo
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn
}
