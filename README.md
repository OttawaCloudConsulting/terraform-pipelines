# Terraform Pipeline Modules

A family of reusable Terraform modules that provision AWS CodePipeline V2 + CodeBuild CI/CD pipelines for deploying Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each module invocation creates a complete, isolated pipeline for one Terraform project.

## Variants

| Variant | Module Source | Stages | Use Case |
|---------|-------------|--------|----------|
| **Default** | `modules/default/` | 6 | Standard cross-account DEV/PROD deployment |
| **Default-DevDestroy** | `modules/default-dev-destroy/` | 7-8 | Cross-account with ephemeral DEV teardown |

The **Default** variant also supports single-account deployment when `dev_account_id == prod_account_id`.

## Architecture

**Three-account model:**

| Account | Role | Description |
|---------|------|-------------|
| Automation | Pipeline host | CodePipeline, CodeBuild, S3, SNS, IAM service roles |
| DEV Target | Deployment target | Receives DEV deployments via cross-account IAM role assumption |
| PROD Target | Deployment target | Receives PROD deployments via cross-account IAM role assumption |

**Shared Core + Overlay:** All variants share an internal `modules/core/` module that provides IAM, S3, SNS, CodeBuild, and CloudWatch resources. Each variant composes the core differently and owns its own CodePipeline stage definitions.

See `docs/ARCHITECTURE_AND_DESIGN.md` for the full architecture reference.

## Quick Start

### Default Variant (Minimal)

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"
}
```

### Default-DevDestroy Variant

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  enable_destroy_approval = true  # Default — require approval before DEV destroy
}
```

### Single-Account Deployment

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "111111111111"       # Same account
  prod_deployment_role_arn = "arn:aws:iam::111111111111:role/deployment-role"
}
```

### With Configs Repo (tfvars in a separate repository)

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  configs_repo      = "my-org/my-project-configs"  # enables configs repo feature
  configs_repo_path = "."                           # environments/ at root of configs repo
}
```

See `docs/configs-repo/` for cross-org connections, shared repos, and full usage details.

See `examples/` for runnable configurations.

## Prerequisites

1. **Terraform >= 1.11** (required for native S3 state locking with `use_lockfile`)
2. **AWS provider ~> 6.0**
3. **Deployment roles** must pre-exist in DEV and PROD target accounts — they must trust the CodeBuild service role from the Automation Account
4. **CodeStar Connection** requires one-time manual OAuth authorization in AWS Console after creation

## Variables

### Required (All Variants)

| Name | Type | Description |
|------|------|-------------|
| `project_name` | `string` | Name of the Terraform project (3-30 chars, lowercase, no `--`). |
| `github_repo` | `string` | GitHub repository in `org/repo` format. |
| `dev_account_id` | `string` | 12-digit AWS Account ID for DEV. |
| `dev_deployment_role_arn` | `string` | IAM role ARN in DEV account. |
| `prod_account_id` | `string` | 12-digit AWS Account ID for PROD. |
| `prod_deployment_role_arn` | `string` | IAM role ARN in PROD account. |

### Optional (All Variants)

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `github_branch` | `string` | `"main"` | Branch to trigger pipeline. |
| `iac_runtime` | `string` | `"terraform"` | `terraform` or `opentofu`. |
| `iac_version` | `string` | `"latest"` | Version of IaC tool. |
| `iac_working_directory` | `string` | `"."` | Subdirectory containing Terraform files, relative to repo root. |
| `codestar_connection_arn` | `string` | `""` | Existing CodeStar ARN. Empty creates new. |
| `create_state_bucket` | `bool` | `true` | Create S3 state bucket. |
| `state_bucket` | `string` | `""` | Existing bucket (required when `create_state_bucket = false`). |
| `state_key_prefix` | `string` | `""` | S3 key prefix. Defaults to `project_name`. |
| `sns_subscribers` | `list(string)` | `[]` | Email addresses for approvals. |
| `enable_review_gate` | `bool` | `false` | Optional review approval stage. |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | CodeBuild compute type. |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | CodeBuild image. |
| `enable_security_scan` | `bool` | `true` | Run Checkov in Plan actions. PROD always hard-fails regardless of soft-fail setting. |
| `checkov_soft_fail` | `bool` | `false` | Checkov findings advisory (DEV only). PROD always hard-fails. |
| `codebuild_timeout_minutes` | `number` | `60` | Build timeout (5-480 min). |
| `logging_bucket` | `string` | `""` | S3 bucket for access logs. |
| `logging_prefix` | `string` | `""` | S3 key prefix for access logs. |
| `log_retention_days` | `number` | `30` | CloudWatch retention. |
| `artifact_retention_days` | `number` | `30` | Artifact lifecycle (1-365). |
| `tags` | `map(string)` | `{}` | Additional tags. |

### Variant-Specific (Default-DevDestroy)

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `enable_destroy_approval` | `bool` | `true` | Require manual approval before DEV destroy. |

### Configs Repo (Optional, All Variants)

Enables a separate GitHub repository for `.tfvars` files. When set, plan actions source tfvars exclusively from the configs repo. The pipeline triggers on push to either repository. Leave `configs_repo` empty (the default) to use the baseline single-repo behavior.

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `configs_repo` | `string` | `""` | GitHub repo in `org/repo` format containing tfvars. Enables the feature when non-empty. |
| `configs_repo_branch` | `string` | `"main"` | Branch to track in the configs repo. |
| `configs_repo_path` | `string` | `"."` | Path within configs repo where `environments/` lives. Use `"."` for repo root. |
| `configs_repo_codestar_connection_arn` | `string` | `""` | CodeStar Connection ARN for the configs repo. Defaults to IaC repo's connection. Required for cross-org repos. |

See `docs/configs-repo/` for full usage guide, cross-org setup, and known limitations.

## Outputs (All Variants)

| Name | Description |
|------|-------------|
| `pipeline_arn` | ARN of the CodePipeline. |
| `pipeline_url` | AWS Console URL for the pipeline. |
| `codebuild_project_names` | Map of CodeBuild project names (`prebuild`, `plan`, `deploy`, `test`; DevDestroy adds `destroy`). |
| `codebuild_service_role_arn` | ARN of the CodeBuild service role. |
| `codepipeline_service_role_arn` | ARN of the CodePipeline service role. |
| `sns_topic_arn` | ARN of the approval SNS topic. |
| `artifact_bucket_name` | Name of the artifact bucket. |
| `state_bucket_name` | Name of the state bucket. |
| `codestar_connection_arn` | ARN of the CodeStar Connection. |
| `dev_account_id` | DEV account ID (pass-through). |
| `prod_account_id` | PROD account ID (pass-through). |

## Repository Structure

```
terraform-pipelines/
├── modules/
│   ├── core/                          # Internal shared module
│   ├── default/                       # Default variant (6 stages)
│   └── default-dev-destroy/           # DevDestroy variant (7-8 stages)
├── examples/
│   ├── default/
│   │   ├── minimal/
│   │   ├── complete/
│   │   ├── opentofu/
│   │   ├── single-account/
│   │   └── configs-repo/
│   ├── default-dev-destroy/
│   │   └── minimal/
│   └── cicd/                                # Developer script templates (copy to your repo)
│       ├── prebuild/main.sh
│       ├── dev/smoke-test.sh
│       └── prod/smoke-test.sh
├── tests/
│   ├── test-terraform.sh                    # Validation + deploy test script
│   ├── default/                             # Default variant E2E test
│   ├── default-dev-destroy/                 # DevDestroy variant E2E test
│   ├── default-configs/                     # Default variant + configs repo E2E test
│   └── default-dev-destroy-configs/         # DevDestroy variant + configs repo E2E test
├── docs/
│   ├── ARCHITECTURE_AND_DESIGN.md
│   ├── configs-repo/                        # Configs repo feature guide
│   ├── shared/
│   ├── default/
│   └── default-dev-destroy/
├── CLAUDE.md
├── README.md
├── CHANGELOG.md
└── .gitignore
```

## Documentation

- **Architecture:** `docs/ARCHITECTURE_AND_DESIGN.md`
- **Default variant:** `docs/default/`
- **DevDestroy variant:** `docs/default-dev-destroy/`
- **Configs repo feature:** `docs/configs-repo/`
- **Original MVP statement:** `docs/shared/codepipeline-mvp-statement.md`
- **Changelog:** `CHANGELOG.md`
