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
  github_repo              = "OttawaCloudConsulting/terraform-test"
  dev_account_id           = "914089393341"
  dev_deployment_role_arn  = "arn:aws:iam::914089393341:role/org-default-deployment-role"
  prod_account_id          = "264675080489"
  prod_deployment_role_arn = "arn:aws:iam::264675080489:role/org-default-deployment-role"

  # Variant-specific: test with approval enabled (default)
  enable_destroy_approval = true
}
