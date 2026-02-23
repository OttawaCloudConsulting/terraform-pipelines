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

# Demonstrates the configs repo feature using the same GitHub repository
# on two different branches:
#   - IaC code:    OttawaCloudConsulting/terraform-test @ s3-bucket
#   - tfvars:      OttawaCloudConsulting/terraform-test @ tfvars (path: s3-bucket/)
#
# Because both repos are in the same GitHub org, no separate CodeStar
# Connection is required — configs_repo_codestar_connection_arn is omitted.
#
# The pipeline triggers on push to either branch. Plan actions source
# environments/<env>.tfvars from the tfvars branch at path s3-bucket/.

module "pipeline" {
  source = "../../../modules/default"

  # Required
  project_name             = var.project_name
  github_repo              = "OttawaCloudConsulting/terraform-test"
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn

  # IaC repo branch — Terraform files live here
  github_branch = "s3-bucket"

  # Configs repo — same repo, different branch, subdirectory path
  configs_repo        = "OttawaCloudConsulting/terraform-test"
  configs_repo_branch = "tfvars"
  configs_repo_path   = "s3-bucket" # environments/ found at s3-bucket/environments/
}
