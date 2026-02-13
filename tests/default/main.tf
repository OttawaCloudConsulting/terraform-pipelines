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

module "default_pipeline" {
  source = "../../modules/default"

  project_name             = "test-default"
  github_repo              = "OttawaCloudConsulting/terraform-test"
  github_branch            = "s3-bucket"
  dev_account_id           = "914089393341"
  dev_deployment_role_arn  = "arn:aws:iam::914089393341:role/org/org-default-deployment-role"
  prod_account_id          = "264675080489"
  prod_deployment_role_arn = "arn:aws:iam::264675080489:role/org/org-default-deployment-role"
}
