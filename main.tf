data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "prebuild" {
  name              = "/codebuild/${var.project_name}-prebuild"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "plan" {
  name              = "/codebuild/${var.project_name}-plan"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "deploy" {
  name              = "/codebuild/${var.project_name}-deploy"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_cloudwatch_log_group" "test" {
  name              = "/codebuild/${var.project_name}-test"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

# -----------------------------------------------------------------------------
# CodeBuild Projects
# -----------------------------------------------------------------------------

resource "aws_codebuild_project" "prebuild" {
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
    buildspec = "buildspecs/prebuild.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.prebuild.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "plan" {
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
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/plan.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.plan.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "deploy" {
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
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/deploy.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.deploy.name
    }
  }

  tags = local.all_tags
}

resource "aws_codebuild_project" "test" {
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
    buildspec = "buildspecs/test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.test.name
    }
  }

  tags = local.all_tags
}

# -----------------------------------------------------------------------------
# CodePipeline
# -----------------------------------------------------------------------------

resource "aws_codepipeline" "this" {
  name          = "${var.project_name}-pipeline"
  role_arn      = aws_iam_role.codepipeline.arn
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.artifacts.id
    type     = "S3"
  }

  # Stage 1: Source
  stage {
    name = "Source"

    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = local.codestar_connection_arn
        FullRepositoryId     = var.github_repo
        BranchName           = var.github_branch
        DetectChanges        = "true"
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }
  }

  # Stage 2: Pre-Build
  stage {
    name = "Pre-Build"

    action {
      name            = "PreBuild"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.prebuild.name
      }
    }
  }

  # Stage 3: Plan + Security Scan
  stage {
    name = "Plan"

    action {
      name             = "TerraformPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  # Stage 4: Optional Review Gate
  dynamic "stage" {
    for_each = var.enable_review_gate ? [1] : []

    content {
      name = "Review"

      action {
        name     = "ManualReview"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"

        configuration = {
          CustomData = "Review the Terraform plan before proceeding to DEV deployment."
        }
      }
    }
  }

  # Stage 5: Deploy DEV
  stage {
    name = "Deploy-DEV"

    action {
      name            = "DeployDEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
        EnvironmentVariables = jsonencode([
          {
            name  = "TARGET_ENV"
            value = "dev"
            type  = "PLAINTEXT"
          },
          {
            name  = "TARGET_ROLE"
            value = var.dev_deployment_role_arn
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # Stage 6: Test DEV
  stage {
    name = "Test-DEV"

    action {
      name            = "TestDEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
        EnvironmentVariables = jsonencode([
          {
            name  = "TARGET_ENV"
            value = "dev"
            type  = "PLAINTEXT"
          },
          {
            name  = "TARGET_ROLE"
            value = var.dev_deployment_role_arn
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # Stage 7: Mandatory Approval
  stage {
    name = "Approval"

    action {
      name     = "ProductionApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        NotificationArn = aws_sns_topic.approvals.arn
        CustomData      = "Approve deployment of ${var.project_name} to PROD."
      }
    }
  }

  # Stage 8: Deploy PROD
  stage {
    name = "Deploy-PROD"

    action {
      name            = "DeployPROD"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
        EnvironmentVariables = jsonencode([
          {
            name  = "TARGET_ENV"
            value = "prod"
            type  = "PLAINTEXT"
          },
          {
            name  = "TARGET_ROLE"
            value = var.prod_deployment_role_arn
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # Stage 9: Test PROD
  stage {
    name = "Test-PROD"

    action {
      name            = "TestPROD"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
        EnvironmentVariables = jsonencode([
          {
            name  = "TARGET_ENV"
            value = "prod"
            type  = "PLAINTEXT"
          },
          {
            name  = "TARGET_ROLE"
            value = var.prod_deployment_role_arn
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  tags = local.all_tags
}
