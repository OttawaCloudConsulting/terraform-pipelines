# -----------------------------------------------------------------------------
# CodeBuild Project References
# -----------------------------------------------------------------------------

output "codebuild_project_names" {
  description = "Map of CodeBuild project names for pipeline stage actions."
  value = {
    prebuild = aws_codebuild_project.prebuild.name
    plan     = aws_codebuild_project.plan.name
    deploy   = aws_codebuild_project.deploy.name
    test     = aws_codebuild_project.test.name
  }
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
  value = {
    prebuild = aws_cloudwatch_log_group.prebuild.arn
    plan     = aws_cloudwatch_log_group.plan.arn
    deploy   = aws_cloudwatch_log_group.deploy.arn
    test     = aws_cloudwatch_log_group.test.arn
  }
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
