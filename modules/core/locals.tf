locals {
  state_bucket_name       = var.create_state_bucket ? aws_s3_bucket.state[0].id : data.aws_s3_bucket.existing_state[0].id
  codestar_connection_arn = var.codestar_connection_arn != "" ? var.codestar_connection_arn : aws_codestarconnections_connection.github[0].arn
  state_key_prefix        = var.state_key_prefix != "" ? var.state_key_prefix : var.project_name

  # Configs repo feature
  configs_enabled             = var.configs_repo != ""
  configs_repo_connection_arn = var.configs_repo_codestar_connection_arn != "" ? var.configs_repo_codestar_connection_arn : local.codestar_connection_arn

  # Deduplicated list of CodeStar Connection ARNs for IAM policies.
  # When configs repo uses the same connection as the IaC repo, this is a single-element list.
  # When configs repo uses a different connection, this is a two-element list.
  all_codestar_connection_arns = distinct([
    local.codestar_connection_arn,
    local.configs_repo_connection_arn,
  ])

  default_tags = {
    project_name = var.project_name
    managed-by   = "terraform"
  }
  all_tags = merge(local.default_tags, var.tags)

  # Common environment variables shared across multiple project types
  common_env_vars = {
    PROJECT_NAME = var.project_name
    IAC_RUNTIME  = var.iac_runtime
    IAC_VERSION  = var.iac_version
  }

  # Per-environment CodeBuild project configuration map
  # Used by for_each on aws_codebuild_project and aws_cloudwatch_log_group
  codebuild_projects = {
    prebuild = {
      description = "Pre-build stage for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/prebuild.yml")
      env_vars    = local.common_env_vars
    }
    plan-dev = {
      description = "Plan DEV environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR      = var.iac_working_directory
        STATE_BUCKET         = local.state_bucket_name
        STATE_KEY_PREFIX     = local.state_key_prefix
        TARGET_ENV           = "dev"
        TARGET_ROLE          = var.dev_deployment_role_arn
        ENABLE_SECURITY_SCAN = tostring(var.enable_security_scan)
        CHECKOV_SOFT_FAIL    = tostring(var.checkov_soft_fail)
        CONFIGS_ENABLED      = tostring(local.configs_enabled)
        CONFIGS_PATH         = var.configs_repo_path
      })
    }
    plan-prod = {
      description = "Plan PROD environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR      = var.iac_working_directory
        STATE_BUCKET         = local.state_bucket_name
        STATE_KEY_PREFIX     = local.state_key_prefix
        TARGET_ENV           = "prod"
        TARGET_ROLE          = var.prod_deployment_role_arn
        ENABLE_SECURITY_SCAN = tostring(var.enable_security_scan)
        CHECKOV_SOFT_FAIL    = "false"
        CONFIGS_ENABLED      = tostring(local.configs_enabled)
        CONFIGS_PATH         = var.configs_repo_path
      })
    }
    deploy-dev = {
      description = "Deploy to DEV environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/deploy.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR  = var.iac_working_directory
        STATE_BUCKET     = local.state_bucket_name
        STATE_KEY_PREFIX = local.state_key_prefix
        TARGET_ENV       = "dev"
        TARGET_ROLE      = var.dev_deployment_role_arn
      })
    }
    deploy-prod = {
      description = "Deploy to PROD environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/deploy.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR  = var.iac_working_directory
        STATE_BUCKET     = local.state_bucket_name
        STATE_KEY_PREFIX = local.state_key_prefix
        TARGET_ENV       = "prod"
        TARGET_ROLE      = var.prod_deployment_role_arn
      })
    }
    test-dev = {
      description = "Test DEV environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/test.yml")
      env_vars = merge(local.common_env_vars, {
        TARGET_ENV  = "dev"
        TARGET_ROLE = var.dev_deployment_role_arn
      })
    }
    test-prod = {
      description = "Test PROD environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/test.yml")
      env_vars = merge(local.common_env_vars, {
        TARGET_ENV  = "prod"
        TARGET_ROLE = var.prod_deployment_role_arn
      })
    }
  }
}
