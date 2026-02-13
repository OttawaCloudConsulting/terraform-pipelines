locals {
  state_bucket_name       = var.create_state_bucket ? aws_s3_bucket.state[0].id : data.aws_s3_bucket.existing_state[0].id
  codestar_connection_arn = var.codestar_connection_arn != "" ? var.codestar_connection_arn : aws_codestarconnections_connection.github[0].arn
  state_key_prefix        = var.state_key_prefix != "" ? var.state_key_prefix : var.project_name

  default_tags = {
    project_name = var.project_name
    managed-by   = "terraform"
  }
  all_tags = merge(local.default_tags, var.tags)
}
