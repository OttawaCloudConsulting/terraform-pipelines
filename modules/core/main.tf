data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "prebuild" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  name              = "/codebuild/${var.project_name}-prebuild"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "plan" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  name              = "/codebuild/${var.project_name}-plan"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "deploy" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  name              = "/codebuild/${var.project_name}-deploy"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "test" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  name              = "/codebuild/${var.project_name}-test"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

# -----------------------------------------------------------------------------
# CodeBuild Projects
# -----------------------------------------------------------------------------

resource "aws_codebuild_project" "prebuild" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  name           = "${var.project_name}-prebuild"
  description    = "Pre-build stage for ${var.project_name} pipeline"
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

    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }

    environment_variable {
      name  = "IAC_RUNTIME"
      value = var.iac_runtime
    }

    environment_variable {
      name  = "IAC_VERSION"
      value = var.iac_version
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/prebuild.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.prebuild.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "plan" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  name           = "${var.project_name}-plan"
  description    = "Plan and security scan stage for ${var.project_name} pipeline"
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

    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }

    environment_variable {
      name  = "IAC_RUNTIME"
      value = var.iac_runtime
    }

    environment_variable {
      name  = "IAC_VERSION"
      value = var.iac_version
    }

    environment_variable {
      name  = "STATE_BUCKET"
      value = local.state_bucket_name
    }

    environment_variable {
      name  = "STATE_KEY_PREFIX"
      value = local.state_key_prefix
    }

    environment_variable {
      name  = "CHECKOV_SOFT_FAIL"
      value = tostring(var.checkov_soft_fail)
    }

    environment_variable {
      name  = "IAC_WORKING_DIR"
      value = var.iac_working_directory
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/plan.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.plan.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "deploy" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  name           = "${var.project_name}-deploy"
  description    = "Deploy stage for ${var.project_name} pipeline"
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

    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }

    environment_variable {
      name  = "IAC_RUNTIME"
      value = var.iac_runtime
    }

    environment_variable {
      name  = "IAC_VERSION"
      value = var.iac_version
    }

    environment_variable {
      name  = "STATE_BUCKET"
      value = local.state_bucket_name
    }

    environment_variable {
      name  = "STATE_KEY_PREFIX"
      value = local.state_key_prefix
    }

    environment_variable {
      name  = "IAC_WORKING_DIR"
      value = var.iac_working_directory
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/deploy.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.deploy.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "test" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  name           = "${var.project_name}-test"
  description    = "Test stage for ${var.project_name} pipeline"
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

    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }

    environment_variable {
      name  = "IAC_RUNTIME"
      value = var.iac_runtime
    }

    environment_variable {
      name  = "IAC_VERSION"
      value = var.iac_version
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/test.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.test.name
    }
  }

  tags = local.all_tags
}
