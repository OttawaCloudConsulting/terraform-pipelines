# -----------------------------------------------------------------------------
# Default Variant — 9-Stage Pipeline
# Source > Pre-Build > Plan+Scan > Optional Review > Deploy DEV > Test DEV >
# Mandatory Approval > Deploy PROD > Test PROD
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
  tags                      = var.tags
}

# -----------------------------------------------------------------------------
# CodePipeline V2 — 9-Stage Pipeline
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

  tags = module.core.all_tags
}

# -----------------------------------------------------------------------------
# Moved Blocks — Migration from monolithic root module
# When consumers switch from the old root module to modules/default/, these
# blocks tell Terraform that resources moved into module.core rather than
# being destroyed and recreated.
# -----------------------------------------------------------------------------

# IAM
moved {
  from = aws_iam_role.codepipeline
  to   = module.core.aws_iam_role.codepipeline
}

moved {
  from = aws_iam_role_policy.codepipeline
  to   = module.core.aws_iam_role_policy.codepipeline
}

moved {
  from = aws_iam_role.codebuild
  to   = module.core.aws_iam_role.codebuild
}

moved {
  from = aws_iam_role_policy.codebuild
  to   = module.core.aws_iam_role_policy.codebuild
}

# CloudWatch Log Groups
moved {
  from = aws_cloudwatch_log_group.prebuild
  to   = module.core.aws_cloudwatch_log_group.prebuild
}

moved {
  from = aws_cloudwatch_log_group.plan
  to   = module.core.aws_cloudwatch_log_group.plan
}

moved {
  from = aws_cloudwatch_log_group.deploy
  to   = module.core.aws_cloudwatch_log_group.deploy
}

moved {
  from = aws_cloudwatch_log_group.test
  to   = module.core.aws_cloudwatch_log_group.test
}

# CodeBuild Projects
moved {
  from = aws_codebuild_project.prebuild
  to   = module.core.aws_codebuild_project.prebuild
}

moved {
  from = aws_codebuild_project.plan
  to   = module.core.aws_codebuild_project.plan
}

moved {
  from = aws_codebuild_project.deploy
  to   = module.core.aws_codebuild_project.deploy
}

moved {
  from = aws_codebuild_project.test
  to   = module.core.aws_codebuild_project.test
}

# S3 State Bucket (conditional — count-based)
moved {
  from = aws_s3_bucket.state
  to   = module.core.aws_s3_bucket.state
}

moved {
  from = aws_s3_bucket_versioning.state
  to   = module.core.aws_s3_bucket_versioning.state
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.state
  to   = module.core.aws_s3_bucket_server_side_encryption_configuration.state
}

moved {
  from = aws_s3_bucket_public_access_block.state
  to   = module.core.aws_s3_bucket_public_access_block.state
}

moved {
  from = aws_s3_bucket_policy.state
  to   = module.core.aws_s3_bucket_policy.state
}

moved {
  from = aws_s3_bucket_logging.state
  to   = module.core.aws_s3_bucket_logging.state
}

# S3 Artifact Bucket
moved {
  from = aws_s3_bucket.artifacts
  to   = module.core.aws_s3_bucket.artifacts
}

moved {
  from = aws_s3_bucket_versioning.artifacts
  to   = module.core.aws_s3_bucket_versioning.artifacts
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.artifacts
  to   = module.core.aws_s3_bucket_server_side_encryption_configuration.artifacts
}

moved {
  from = aws_s3_bucket_public_access_block.artifacts
  to   = module.core.aws_s3_bucket_public_access_block.artifacts
}

moved {
  from = aws_s3_bucket_policy.artifacts
  to   = module.core.aws_s3_bucket_policy.artifacts
}

moved {
  from = aws_s3_bucket_logging.artifacts
  to   = module.core.aws_s3_bucket_logging.artifacts
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.artifacts
  to   = module.core.aws_s3_bucket_lifecycle_configuration.artifacts
}

# SNS
moved {
  from = aws_sns_topic.approvals
  to   = module.core.aws_sns_topic.approvals
}

moved {
  from = aws_sns_topic_policy.approvals
  to   = module.core.aws_sns_topic_policy.approvals
}

moved {
  from = aws_sns_topic_subscription.email
  to   = module.core.aws_sns_topic_subscription.email
}

# CodeStar Connection (conditional — count-based)
moved {
  from = aws_codestarconnections_connection.github
  to   = module.core.aws_codestarconnections_connection.github
}
