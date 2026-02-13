output "pipeline_arn" {
  description = "ARN of the CodePipeline."
  value       = aws_codepipeline.this.arn
}

output "pipeline_url" {
  description = "AWS Console URL for the pipeline."
  value       = "https://${data.aws_region.current.id}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.this.name}/view"
}

output "codebuild_project_names" {
  description = "Map of CodeBuild project names."
  value = {
    prebuild = aws_codebuild_project.prebuild.name
    plan     = aws_codebuild_project.plan.name
    deploy   = aws_codebuild_project.deploy.name
    test     = aws_codebuild_project.test.name
  }
}

output "codebuild_service_role_arn" {
  description = "ARN of the CodeBuild service role."
  value       = aws_iam_role.codebuild.arn
}

output "codepipeline_service_role_arn" {
  description = "ARN of the CodePipeline service role."
  value       = aws_iam_role.codepipeline.arn
}

output "sns_topic_arn" {
  description = "ARN of the approval SNS topic."
  value       = aws_sns_topic.approvals.arn
}

output "artifact_bucket_name" {
  description = "Name of the pipeline artifact bucket."
  value       = aws_s3_bucket.artifacts.id
}

output "state_bucket_name" {
  description = "Name of the state bucket (created or existing)."
  value       = local.state_bucket_name
}

output "codestar_connection_arn" {
  description = "ARN of the CodeStar Connection (created or referenced)."
  value       = local.codestar_connection_arn
}

output "dev_account_id" {
  description = "AWS Account ID for the DEV target environment."
  value       = var.dev_account_id
}

output "prod_account_id" {
  description = "AWS Account ID for the PROD target environment."
  value       = var.prod_account_id
}
