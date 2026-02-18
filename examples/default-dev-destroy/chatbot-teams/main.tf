terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "shared-terraform-state-389068787156"
    key          = "pipeline/aws-chatbot-teams-integration/terraform.tfstate"
    region       = "ca-central-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "ca-central-1"
}

# Default-DevDestroy variant for aws-chatbot-teams-integration.
# Terraform files live in the terraform/ subdirectory of the target repo.
# DEV environment is destroyed after PROD tests pass (with approval gate).
#
# Pipeline flow (7-8 stages):
# Source > Pre-Build > DEV (Plan+Deploy) > Test DEV >
# PROD (Plan+Approve+Deploy) > Test PROD > [Destroy Approval] > Destroy DEV
module "pipeline" {
  source = "../../../modules/default-dev-destroy"

  project_name             = "chatbot-teams"
  codestar_connection_arn  = "arn:aws:codeconnections:ca-central-1:389068787156:connection/ee81e6bb-f41d-4983-ae31-079a60eb6550"
  github_repo              = "OttawaCloudConsulting/aws-chatbot-teams-integration"
  github_branch            = "development/mvp"
  dev_account_id           = "914089393341"
  dev_deployment_role_arn  = "arn:aws:iam::914089393341:role/org/org-default-deployment-role"
  prod_account_id          = "264675080489"
  prod_deployment_role_arn = "arn:aws:iam::264675080489:role/org/org-default-deployment-role"

  # Terraform files are in the terraform/ subdirectory, not repo root
  iac_working_directory = "terraform"

  # Security scan enabled by default; soft-fail for DEV, always hard-fail for PROD
  enable_security_scan = true
  checkov_soft_fail    = true # DEV only — PROD always hard-fails

  # Safe by default — require manual approval before destroying DEV
  enable_destroy_approval = true
}
