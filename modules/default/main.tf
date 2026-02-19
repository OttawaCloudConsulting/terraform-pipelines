# -----------------------------------------------------------------------------
# Default Variant — 6-Stage Pipeline
# Source > Pre-Build > DEV (Plan+Approve+Deploy) > Test DEV >
# PROD (Plan+Approve+Deploy) > Test PROD
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
}

# -----------------------------------------------------------------------------
# CodePipeline V2 — 6-Stage Pipeline
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
      input_artifacts  = ["source_output"]
      output_artifacts = ["dev_plan_output"]

      configuration = {
        ProjectName = module.core.codebuild_project_names["plan-dev"]
      }
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
      input_artifacts  = ["source_output"]
      output_artifacts = ["prod_plan_output"]

      configuration = {
        ProjectName = module.core.codebuild_project_names["plan-prod"]
      }
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

  tags = module.core.all_tags
}
