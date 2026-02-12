provider "aws" {
  region  = "ca-central-1"
  profile = "aft-automation"
}

module "pipeline" {
  source = "../../"

  project_name             = "e2e-test"
  github_repo              = "OttawaCloudConsulting/terraform-test"
  github_branch            = "s3-bucket"
  dev_account_id           = "914089393341"
  dev_deployment_role_arn  = "arn:aws:iam::914089393341:role/org/org-default-deployment-role"
  prod_account_id          = "264675080489"
  prod_deployment_role_arn = "arn:aws:iam::264675080489:role/org/org-default-deployment-role"

  create_state_bucket     = true
  enable_review_gate      = false
  log_retention_days      = 1
  artifact_retention_days = 1

  tags = {
    Environment = "test"
    Purpose     = "e2e-validation"
  }
}

output "pipeline_url" {
  value = module.pipeline.pipeline_url
}

output "codestar_connection_arn" {
  value = module.pipeline.codestar_connection_arn
}

output "state_bucket_name" {
  value = module.pipeline.state_bucket_name
}

output "artifact_bucket_name" {
  value = module.pipeline.artifact_bucket_name
}
