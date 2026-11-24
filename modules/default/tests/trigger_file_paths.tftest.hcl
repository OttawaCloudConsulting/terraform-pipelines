# Plan-only tests for the optional trigger file path filters.
# Run with: terraform init -backend=false && terraform test
# Uses a mocked AWS provider, so no credentials or AWS calls are needed.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "389068787156"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "ca-central-1"
      region = "ca-central-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  project_name             = "tftest-trigger"
  github_repo              = "example-org/example-repo"
  dev_account_id           = "914089393341"
  dev_deployment_role_arn  = "arn:aws:iam::914089393341:role/deploy"
  prod_account_id          = "914089393342"
  prod_deployment_role_arn = "arn:aws:iam::914089393342:role/deploy"
}

run "no_filters_renders_no_trigger" {
  command = plan

  assert {
    condition     = length(aws_codepipeline.this.trigger) == 0
    error_message = "With no filters, the pipeline must not get a trigger block (backward compatible)."
  }
}

run "includes_and_excludes" {
  command = plan

  variables {
    github_branch              = "main"
    trigger_file_path_includes = ["src/**", "functions/**", "environments/**", "cicd/**", "*.tf", ".checkov.yaml", ".terraform.lock.hcl", "scripts/**"]
    trigger_file_path_excludes = ["scripts/diagrams/**"]
  }

  assert {
    condition     = length(aws_codepipeline.this.trigger) == 1
    error_message = "Expected exactly one trigger."
  }

  assert {
    condition     = aws_codepipeline.this.trigger[0].git_configuration[0].source_action_name == "GitHub"
    error_message = "Trigger must target the GitHub source action."
  }

  assert {
    condition     = aws_codepipeline.this.trigger[0].git_configuration[0].push[0].branches[0].includes == tolist(["main"])
    error_message = "Trigger must keep the github_branch branch filter."
  }

  assert {
    condition     = length(aws_codepipeline.this.trigger[0].git_configuration[0].push[0].file_paths[0].includes) == 8
    error_message = "All 8 include patterns must be passed through."
  }

  assert {
    condition     = aws_codepipeline.this.trigger[0].git_configuration[0].push[0].file_paths[0].excludes == tolist(["scripts/diagrams/**"])
    error_message = "Exclude patterns must be passed through."
  }
}

run "excludes_only_defaults_includes_to_all" {
  command = plan

  variables {
    trigger_file_path_excludes = ["docs/**"]
  }

  assert {
    condition     = aws_codepipeline.this.trigger[0].git_configuration[0].push[0].file_paths[0].includes == tolist(["**"])
    error_message = "Excludes-only must default includes to [\"**\"]."
  }
}

run "includes_only_sends_no_excludes" {
  command = plan

  variables {
    trigger_file_path_includes = ["src/**"]
  }

  assert {
    condition     = aws_codepipeline.this.trigger[0].git_configuration[0].push[0].file_paths[0].excludes == null
    error_message = "Empty excludes must not be sent (API minimum is 1 item)."
  }
}

run "configs_repo_keeps_branch_trigger" {
  command = plan

  variables {
    trigger_file_path_includes = ["src/**"]
    configs_repo               = "example-org/example-configs"
    configs_repo_branch        = "release"
  }

  assert {
    condition     = length(aws_codepipeline.this.trigger) == 2
    error_message = "With filters and a configs repo, expect a second trigger for GitHub-Configs."
  }

  assert {
    condition     = aws_codepipeline.this.trigger[1].git_configuration[0].source_action_name == "GitHub-Configs"
    error_message = "Second trigger must target GitHub-Configs."
  }

  assert {
    condition     = aws_codepipeline.this.trigger[1].git_configuration[0].push[0].branches[0].includes == tolist(["release"])
    error_message = "Configs trigger must use configs_repo_branch."
  }
}

run "configs_repo_without_filters_renders_no_trigger" {
  command = plan

  variables {
    configs_repo = "example-org/example-configs"
  }

  assert {
    condition     = length(aws_codepipeline.this.trigger) == 0
    error_message = "Configs repo alone must not add triggers."
  }
}

run "rejects_nine_includes" {
  command = plan

  variables {
    trigger_file_path_includes = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
  }

  expect_failures = [var.trigger_file_path_includes]
}

run "rejects_nine_excludes" {
  command = plan

  variables {
    trigger_file_path_excludes = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
  }

  expect_failures = [var.trigger_file_path_excludes]
}
