# -----------------------------------------------------------------------------
# Default-DevDestroy Variant — 7-8 Stage Pipeline
# Source > Pre-Build > DEV (Plan+Approve+Deploy) > Test DEV >
# PROD (Plan+Approve+Deploy) > Test PROD > [Destroy Approval] > Destroy DEV
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
  enable_security_scan      = var.enable_security_scan
  checkov_soft_fail         = var.checkov_soft_fail
  codebuild_timeout_minutes = var.codebuild_timeout_minutes
  logging_bucket            = var.logging_bucket
  logging_prefix            = var.logging_prefix
  log_retention_days        = var.log_retention_days
  artifact_retention_days   = var.artifact_retention_days
  iac_working_directory     = var.iac_working_directory
  tags                      = var.tags

  configs_repo                         = var.configs_repo
  configs_repo_branch                  = var.configs_repo_branch
  configs_repo_path                    = var.configs_repo_path
  configs_repo_codestar_connection_arn = var.configs_repo_codestar_connection_arn

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

    environment_variable {
      name  = "TARGET_ENV"
      value = "dev"
    }

    environment_variable {
      name  = "TARGET_ROLE"
      value = var.dev_deployment_role_arn
    }

    environment_variable {
      name  = "CONFIGS_ENABLED"
      value = tostring(module.core.configs_enabled)
    }

    environment_variable {
      name  = "CONFIGS_PATH"
      value = var.configs_repo_path
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
# CodePipeline V2 — 7-8 Stage Pipeline
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

    dynamic "action" {
      for_each = var.configs_repo != "" ? [1] : []

      content {
        name             = "GitHub-Configs"
        category         = "Source"
        owner            = "AWS"
        provider         = "CodeStarSourceConnection"
        version          = "1"
        output_artifacts = ["configs_output"]

        configuration = {
          ConnectionArn        = module.core.configs_repo_connection_arn
          FullRepositoryId     = var.configs_repo
          BranchName           = var.configs_repo_branch
          DetectChanges        = "true"
          OutputArtifactFormat = "CODE_ZIP"
        }
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

  # Stage 3: DEV — Plan > [Approve] > Deploy
  stage {
    name = "DEV"

    action {
      name             = "Plan-DEV"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = var.configs_repo != "" ? ["source_output", "configs_output"] : ["source_output"]
      output_artifacts = ["dev_plan_output"]

      configuration = merge(
        {
          ProjectName = module.core.codebuild_project_names["plan-dev"]
        },
        var.configs_repo != "" ? { PrimarySource = "source_output" } : {}
      )
    }

    dynamic "action" {
      for_each = var.enable_review_gate ? [1] : []

      content {
        name      = "Approve-DEV"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = 2

        configuration = {
          CustomData = "Review the Terraform plan before deploying to DEV."
        }
      }
    }

    action {
      name            = "Deploy-DEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 3
      input_artifacts = ["source_output", "dev_plan_output"]

      configuration = {
        ProjectName   = module.core.codebuild_project_names["deploy-dev"]
        PrimarySource = "source_output"
        EnvironmentVariables = jsonencode([
          {
            name  = "PLAN_ARTIFACT"
            value = "dev_plan_output"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # Stage 4: Test DEV
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
        ProjectName = module.core.codebuild_project_names["test-dev"]
      }
    }
  }

  # Stage 5: PROD — Plan > Approve > Deploy
  stage {
    name = "PROD"

    action {
      name             = "Plan-PROD"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = var.configs_repo != "" ? ["source_output", "configs_output"] : ["source_output"]
      output_artifacts = ["prod_plan_output"]

      configuration = merge(
        {
          ProjectName = module.core.codebuild_project_names["plan-prod"]
        },
        var.configs_repo != "" ? { PrimarySource = "source_output" } : {}
      )
    }

    action {
      name      = "Approve-PROD"
      category  = "Approval"
      owner     = "AWS"
      provider  = "Manual"
      version   = "1"
      run_order = 2

      configuration = {
        NotificationArn = module.core.sns_topic_arn
        CustomData      = "Approve deployment of ${var.project_name} to PROD."
      }
    }

    action {
      name            = "Deploy-PROD"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 3
      input_artifacts = ["source_output", "prod_plan_output"]

      configuration = {
        ProjectName   = module.core.codebuild_project_names["deploy-prod"]
        PrimarySource = "source_output"
        EnvironmentVariables = jsonencode([
          {
            name  = "PLAN_ARTIFACT"
            value = "prod_plan_output"
            type  = "PLAINTEXT"
          }
        ])
      }
    }
  }

  # Stage 6: Test PROD
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
        ProjectName = module.core.codebuild_project_names["test-prod"]
      }
    }
  }

  # Stage 7 (optional): Destroy Approval Gate
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

  # Stage 7/8: Destroy DEV
  stage {
    name = "Destroy-DEV"

    action {
      name            = "DestroyDEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = var.configs_repo != "" ? ["source_output", "configs_output"] : ["source_output"]

      configuration = merge(
        {
          ProjectName = aws_codebuild_project.destroy.name
        },
        var.configs_repo != "" ? { PrimarySource = "source_output" } : {}
      )
    }
  }

  tags = module.core.all_tags
}
