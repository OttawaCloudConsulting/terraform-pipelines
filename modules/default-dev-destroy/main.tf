# -----------------------------------------------------------------------------
# Default-DevDestroy Variant — 10-11 Stage Pipeline
# Stages 1-9: identical to Default variant
# Stage 10 (optional): Destroy Approval gate (when enable_destroy_approval = true)
# Stage 10/11: Destroy DEV — runs terraform destroy against DEV environment
# -----------------------------------------------------------------------------

module "core" {
  source = "../core"

  project_name             = var.project_name
  github_repo              = var.github_repo
  dev_account_id           = var.dev_account_id
  dev_deployment_role_arn  = var.dev_deployment_role_arn
  prod_account_id          = var.prod_account_id
  prod_deployment_role_arn = var.prod_deployment_role_arn

  github_branch             = var.github_branch
  iac_runtime               = var.iac_runtime
  iac_version               = var.iac_version
  codestar_connection_arn   = var.codestar_connection_arn
  create_state_bucket       = var.create_state_bucket
  state_bucket              = var.state_bucket
  state_key_prefix          = var.state_key_prefix
  sns_subscribers           = var.sns_subscribers
  enable_review_gate        = var.enable_review_gate
  codebuild_compute_type    = var.codebuild_compute_type
  codebuild_image           = var.codebuild_image
  checkov_soft_fail         = var.checkov_soft_fail
  codebuild_timeout_minutes = var.codebuild_timeout_minutes
  logging_bucket            = var.logging_bucket
  logging_prefix            = var.logging_prefix
  log_retention_days        = var.log_retention_days
  artifact_retention_days   = var.artifact_retention_days
  iac_working_directory     = var.iac_working_directory
  tags                      = var.tags

  # IAM extensibility — register variant-owned destroy resources with core policies
  additional_codebuild_project_arns = [aws_codebuild_project.destroy.arn]
  additional_log_group_arns         = ["${aws_cloudwatch_log_group.destroy.arn}:*"]
}

# -----------------------------------------------------------------------------
# Variant-Owned Resources — Destroy Stage
# These are NOT in the core module because they are specific to this variant.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "destroy" {
  #checkov:skip=CKV_AWS_158:Post-MVP — KMS CMK encryption for CloudWatch logs (design decision #4)
  #checkov:skip=CKV_AWS_338:Consumer-configurable via log_retention_days variable; default 30d documented
  name              = "/codebuild/${var.project_name}-destroy"
  retention_in_days = var.log_retention_days
  tags              = module.core.all_tags
}

resource "aws_codebuild_project" "destroy" {
  #checkov:skip=CKV_AWS_147:Post-MVP — CMK encryption for CodeBuild projects (design decision #4)
  name           = "${var.project_name}-destroy"
  description    = "Destroy DEV environment for ${var.project_name} pipeline"
  service_role   = module.core.codebuild_service_role_arn
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
      value = module.core.state_bucket_name
    }

    environment_variable {
      name  = "STATE_KEY_PREFIX"
      value = var.state_key_prefix != "" ? var.state_key_prefix : var.project_name
    }

    environment_variable {
      name  = "IAC_WORKING_DIR"
      value = var.iac_working_directory
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/destroy.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.destroy.name
    }
  }

  tags = module.core.all_tags
}

# -----------------------------------------------------------------------------
# CodePipeline V2 — 10-11 Stage Pipeline
# -----------------------------------------------------------------------------

resource "aws_codepipeline" "this" {
  #checkov:skip=CKV_AWS_219:Post-MVP — CMK encryption for CodePipeline artifact store (design decision #4)
  name          = "${var.project_name}-pipeline"
  role_arn      = module.core.codepipeline_service_role_arn
  pipeline_type = "V2"

  artifact_store {
    location = module.core.artifact_bucket_name
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
        ConnectionArn        = module.core.codestar_connection_arn
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
        ProjectName = module.core.codebuild_project_names["prebuild"]
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
        ProjectName = module.core.codebuild_project_names["plan"]
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
        ProjectName = module.core.codebuild_project_names["deploy"]
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
        ProjectName = module.core.codebuild_project_names["test"]
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
        NotificationArn = module.core.sns_topic_arn
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
        ProjectName = module.core.codebuild_project_names["deploy"]
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
        ProjectName = module.core.codebuild_project_names["test"]
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

  # Stage 10 (optional): Destroy Approval Gate
  dynamic "stage" {
    for_each = var.enable_destroy_approval ? [1] : []

    content {
      name = "Destroy-Approval"

      action {
        name     = "DestroyApproval"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"

        configuration = {
          NotificationArn = module.core.sns_topic_arn
          CustomData      = "Approve destruction of ${var.project_name} DEV environment."
        }
      }
    }
  }

  # Stage 10/11: Destroy DEV
  stage {
    name = "Destroy-DEV"

    action {
      name            = "DestroyDEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.destroy.name
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

  tags = module.core.all_tags
}
