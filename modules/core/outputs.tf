# -----------------------------------------------------------------------------
# CodeBuild Project References
# -----------------------------------------------------------------------------

output "codebuild_project_names" {
  description = "Map of CodeBuild project names for pipeline stage actions."
  value       = { for k, v in aws_codebuild_project.this : k => v.name }
}

# -----------------------------------------------------------------------------
# IAM Role References
# -----------------------------------------------------------------------------

output "codebuild_service_role_arn" {
  description = "ARN of the CodeBuild service role. Used by variants to create additional CodeBuild projects."
  value       = aws_iam_role.codebuild.arn
}

output "codepipeline_service_role_arn" {
  description = "ARN of the CodePipeline service role."
  value       = aws_iam_role.codepipeline.arn
}

# -----------------------------------------------------------------------------
# Storage References
# -----------------------------------------------------------------------------

output "artifact_bucket_name" {
  description = "Name of the pipeline artifact S3 bucket."
  value       = aws_s3_bucket.artifacts.id
}

output "state_bucket_name" {
  description = "Name of the state bucket (created or existing)."
  value       = local.state_bucket_name
}

# -----------------------------------------------------------------------------
# SNS Reference
# -----------------------------------------------------------------------------

output "sns_topic_arn" {
  description = "ARN of the approval SNS topic."
  value       = aws_sns_topic.approvals.arn
}

# -----------------------------------------------------------------------------
# CodeStar Reference
# -----------------------------------------------------------------------------

output "codestar_connection_arn" {
  description = "ARN of the CodeStar Connection (created or referenced)."
  value       = local.codestar_connection_arn
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group References
# -----------------------------------------------------------------------------

output "log_group_arns" {
  description = "Map of CloudWatch log group ARNs for reference."
  value       = { for k, v in aws_cloudwatch_log_group.this : k => v.arn }
}

# -----------------------------------------------------------------------------
# Pass-through values for variant outputs
# -----------------------------------------------------------------------------

output "pipeline_url_prefix" {
  description = "AWS Console URL prefix for pipeline URLs."
  value       = "https://${data.aws_region.current.id}.console.aws.amazon.com/codesuite/codepipeline/pipelines"
}

output "project_name" {
  description = "Project name pass-through for variant outputs."
  value       = var.project_name
}

output "dev_account_id" {
  description = "DEV account ID pass-through."
  value       = var.dev_account_id
}

output "prod_account_id" {
  description = "PROD account ID pass-through."
  value       = var.prod_account_id
}

output "all_tags" {
  description = "Merged tags for variant-owned resources."
  value       = local.all_tags
}

# -----------------------------------------------------------------------------
# Configs Repo References
# -----------------------------------------------------------------------------

output "configs_enabled" {
  description = "Whether the configs repo feature is active."
  value       = local.configs_enabled
}

output "configs_repo_connection_arn" {
  description = "Resolved CodeStar Connection ARN for the configs repo."
  value       = local.configs_repo_connection_arn
}
