# -----------------------------------------------------------------------------
# Default Variant — Uniform Output Interface
# -----------------------------------------------------------------------------

output "pipeline_arn" {
  description = "ARN of the CodePipeline."
  value       = aws_codepipeline.this.arn
}

output "pipeline_url" {
  description = "AWS Console URL for the pipeline."
  value       = "${module.core.pipeline_url_prefix}/${aws_codepipeline.this.name}/view"
}

output "codebuild_project_names" {
  description = "Map of CodeBuild project names."
  value       = module.core.codebuild_project_names
}

output "codebuild_service_role_arn" {
  description = "ARN of the CodeBuild service role."
  value       = module.core.codebuild_service_role_arn
}

output "codepipeline_service_role_arn" {
  description = "ARN of the CodePipeline service role."
  value       = module.core.codepipeline_service_role_arn
}

output "sns_topic_arn" {
  description = "ARN of the approval SNS topic."
  value       = module.core.sns_topic_arn
}

output "artifact_bucket_name" {
  description = "Name of the pipeline artifact bucket."
  value       = module.core.artifact_bucket_name
}

output "state_bucket_name" {
  description = "Name of the state bucket (created or existing)."
  value       = module.core.state_bucket_name
}

output "codestar_connection_arn" {
  description = "ARN of the CodeStar Connection (created or referenced)."
  value       = module.core.codestar_connection_arn
}

output "dev_account_id" {
  description = "AWS Account ID for the DEV target environment."
  value       = module.core.dev_account_id
}

output "prod_account_id" {
  description = "AWS Account ID for the PROD target environment."
  value       = module.core.prod_account_id
}
