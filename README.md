# Terraform Pipeline Modules

A family of reusable Terraform modules that provision AWS CodePipeline V2 + CodeBuild CI/CD pipelines for deploying Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each module invocation creates a complete, isolated pipeline for one Terraform project.

## Variants

| Variant | Module Source | Stages | Use Case |
|---------|-------------|--------|----------|
| **Default** | `modules/default/` | 9 | Standard cross-account DEV/PROD deployment |
| **Default-DevDestroy** | `modules/default-dev-destroy/` | 10-11 | Cross-account with ephemeral DEV teardown |

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
| `project_name` | `string` | Name of the Terraform project (3-34 chars, lowercase, no `--`). |
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
| `codestar_connection_arn` | `string` | `""` | Existing CodeStar ARN. Empty creates new. |
| `create_state_bucket` | `bool` | `true` | Create S3 state bucket. |
| `state_bucket` | `string` | `""` | Existing bucket (required when `create_state_bucket = false`). |
| `state_key_prefix` | `string` | `""` | S3 key prefix. Defaults to `project_name`. |
| `sns_subscribers` | `list(string)` | `[]` | Email addresses for approvals. |
| `enable_review_gate` | `bool` | `false` | Optional review approval stage. |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | CodeBuild compute type. |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | CodeBuild image. |
| `checkov_soft_fail` | `bool` | `false` | Checkov as warnings only. |
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

## Outputs (All Variants)

| Name | Description |
|------|-------------|
| `pipeline_arn` | ARN of the CodePipeline. |
| `pipeline_url` | AWS Console URL for the pipeline. |
| `codebuild_project_names` | Map of CodeBuild project names. |
| `codebuild_service_role_arn` | ARN of the CodeBuild service role. |
| `codepipeline_service_role_arn` | ARN of the CodePipeline service role. |
| `sns_topic_arn` | ARN of the approval SNS topic. |
| `artifact_bucket_name` | Name of the artifact bucket. |
| `state_bucket_name` | Name of the state bucket. |
| `codestar_connection_arn` | ARN of the CodeStar Connection. |
| `dev_account_id` | DEV account ID (pass-through). |
| `prod_account_id` | PROD account ID (pass-through). |

## Migration from Monolithic Module

If you previously used the root module directly, update your `source` to `modules/default/`:

```hcl
# Before
module "pipeline" {
  source = "path/to/terraform-pipelines"
  ...
}

# After
module "pipeline" {
  source = "path/to/terraform-pipelines//modules/default"
  ...
}
```

The Default variant includes `moved` blocks for all resources, so `terraform plan` will show moves (not destroy/create). No resource recreation occurs.

## Repository Structure

```
terraform-pipelines/
├── modules/
│   ├── core/                          # Internal shared module
│   ├── default/                       # Default variant (9 stages)
│   └── default-dev-destroy/           # DevDestroy variant (10-11 stages)
├── examples/
│   ├── default/
│   │   ├── minimal/
│   │   ├── complete/
│   │   ├── opentofu/
│   │   └── single-account/
│   └── default-dev-destroy/
│       └── minimal/
├── tests/
│   ├── default/
│   └── default-dev-destroy/
├── docs/
│   ├── ARCHITECTURE_AND_DESIGN.md
│   ├── shared/
│   ├── default/
│   └── default-dev-destroy/
├── CLAUDE.md
├── README.md
├── CHANGELOG.md
├── prd.md
└── progress.txt
```

## Documentation

- **Architecture:** `docs/ARCHITECTURE_AND_DESIGN.md`
- **Default variant:** `docs/default/`
- **DevDestroy variant:** `docs/default-dev-destroy/`
- **Original MVP statement:** `docs/shared/codepipeline-mvp-statement.md`
- **Changelog:** `CHANGELOG.md`
