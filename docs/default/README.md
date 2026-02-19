# Default Variant

The Default variant implements a 9-stage pipeline for cross-account Terraform deployments.

## Pipeline Stages

| # | Stage | Type | Description |
|---|-------|------|-------------|
| 1 | Source | CodeStar | GitHub via CodeStar Connection |
| 2 | Pre-Build | CodeBuild | Runs `cicd/prebuild/main.sh` (developer-managed) |
| 3 | Plan | CodeBuild | `terraform plan` + checkov security scan |
| 4 | Review | Manual Approval | Optional gate (`enable_review_gate = true`) |
| 5 | Deploy DEV | CodeBuild | `terraform apply` via cross-account role |
| 6 | Test DEV | CodeBuild | Runs `cicd/dev/smoke-test.sh` (developer-managed) |
| 7 | Approval | Manual Approval | Mandatory, SNS notification to subscribers |
| 8 | Deploy PROD | CodeBuild | `terraform apply` via cross-account role |
| 9 | Test PROD | CodeBuild | Runs `cicd/prod/smoke-test.sh` (developer-managed) |

## Usage

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

## Single-Account Deployment

See [single-account.md](single-account.md) for deploying DEV and PROD to the same AWS account.

## Migration from Root Module

If upgrading from the monolithic root module, change your `source` to `modules/default/`:

```hcl
module "pipeline" {
  source = "path/to/terraform-pipelines//modules/default"
  # ... same variables, no changes needed
}
```

The Default variant includes `moved` blocks that map all 28 resources from the old root module to their new locations inside `module.core`. Running `terraform plan` after the source change will show resource moves, not destroy/create operations.

### Moved Resources

| Old Address | New Address |
|------------|------------|
| `aws_codepipeline.this` | `aws_codepipeline.this` (stays in variant) |
| `aws_iam_role.codepipeline` | `module.core.aws_iam_role.codepipeline` |
| `aws_iam_role.codebuild` | `module.core.aws_iam_role.codebuild` |
| `aws_iam_role_policy.codepipeline` | `module.core.aws_iam_role_policy.codepipeline` |
| `aws_iam_role_policy.codebuild` | `module.core.aws_iam_role_policy.codebuild` |
| `aws_codebuild_project.*` | `module.core.aws_codebuild_project.*` |
| `aws_cloudwatch_log_group.*` | `module.core.aws_cloudwatch_log_group.*` |
| `aws_s3_bucket.*` | `module.core.aws_s3_bucket.*` |
| `aws_s3_bucket_*.*` | `module.core.aws_s3_bucket_*.*` |
| `aws_sns_topic.*` | `module.core.aws_sns_topic.*` |
| `aws_sns_topic_policy.*` | `module.core.aws_sns_topic_policy.*` |
| `aws_codestarconnections_connection.*` | `module.core.aws_codestarconnections_connection.*` |

*Table summarizes moved resource types. The module contains 28 individual `moved` blocks. See `modules/default/main.tf` for the complete list.*

## Examples

- `examples/default/minimal/` — required variables only
- `examples/default/complete/` — all variables with production overrides
- `examples/default/opentofu/` — OpenTofu runtime
- `examples/default/single-account/` — same-account deployment

## Consumer Repository Structure

The pipeline expects this layout in the consumer's GitHub repository:

```
my-terraform-project/
├── main.tf
├── variables.tf
├── outputs.tf
├── environments/
│   ├── dev.tfvars        # Optional
│   └── prod.tfvars       # Optional
└── cicd/
    ├── prebuild/
    │   └── main.sh       # Optional
    ├── dev/
    │   └── smoke-test.sh # Optional
    └── prod/
        └── smoke-test.sh # Optional
```

All `cicd/` scripts and `environments/*.tfvars` files are optional. The pipeline gracefully skips missing files.
