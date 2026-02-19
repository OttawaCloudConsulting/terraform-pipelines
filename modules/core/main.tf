data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups — one per CodeBuild project
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  for_each          = local.codebuild_projects
  name              = "/codebuild/${var.project_name}-${each.key}"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

# -----------------------------------------------------------------------------
# CodeBuild Projects — one per pipeline action
# -----------------------------------------------------------------------------

resource "aws_codebuild_project" "this" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  for_each       = local.codebuild_projects
  name           = "${var.project_name}-${each.key}"
  description    = each.value.description
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.codebuild_timeout_minutes
  queued_timeout = 480

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = var.codebuild_compute_type
    image           = var.codebuild_image
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    dynamic "environment_variable" {
      for_each = each.value.env_vars
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = each.value.buildspec
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.this[each.key].name
    }
  }

  tags = local.all_tags
}
