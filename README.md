# Terraform Pipeline Module

A reusable Terraform module that provisions AWS CodePipeline V2 + CodeBuild CI/CD pipelines for deploying Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each module invocation creates a complete, isolated pipeline for one Terraform project.

## Architecture

**Three-account model:**

| Account | Role | Description |
|---------|------|-------------|
| Automation | Pipeline host | CodePipeline, CodeBuild, S3 state/artifacts, SNS, IAM service roles |
| DEV Target | Deployment target | Receives DEV deployments via cross-account IAM role assumption |
| PROD Target | Deployment target | Receives PROD deployments via cross-account IAM role assumption |

**Pipeline stages (9 total):**

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

### Minimal

```hcl
module "pipeline" {
  source = "path/to/terraform-pipelines"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/org/org-default-deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/org/org-default-deployment-role"
}
```

### Complete

```hcl
module "pipeline" {
  source = "path/to/terraform-pipelines"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  github_branch            = "main"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/org/org-default-deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/org/org-default-deployment-role"

  iac_runtime             = "terraform"
  iac_version             = "1.11.0"
  create_state_bucket     = true
  enable_review_gate      = true
  sns_subscribers         = ["team@example.com"]
  codebuild_compute_type  = "BUILD_GENERAL1_SMALL"
  codebuild_image         = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  codebuild_timeout_minutes = 60
  log_retention_days      = 30
  artifact_retention_days = 30

  tags = {
    team        = "platform"
    cost-center = "12345"
  }
}
```

See `examples/` for runnable configurations: `minimal/`, `complete/`, and `opentofu/`.

## Prerequisites

1. **Terraform >= 1.11** (required for native S3 state locking with `use_lockfile`)
2. **AWS provider ~> 6.0**
3. **Deployment roles** must pre-exist in DEV and PROD target accounts
   - Must trust the CodeBuild service role from the Automation Account
   - See `docs/working/CROSS_ACCOUNT_ROLES.md` for trust policy templates
4. **CodeStar Connection** requires one-time manual OAuth authorization in AWS Console after creation

## Variables

### Required

| Name | Type | Description |
|------|------|-------------|
| `project_name` | `string` | Name of the Terraform project (3-34 chars, lowercase, no `--`). Used in all resource names. |
| `github_repo` | `string` | GitHub repository in `org/repo` format. |
| `dev_account_id` | `string` | AWS Account ID for the DEV target environment (12-digit). |
| `dev_deployment_role_arn` | `string` | IAM role ARN in DEV account for cross-account deployment. |
| `prod_account_id` | `string` | AWS Account ID for the PROD target environment (12-digit). |
| `prod_deployment_role_arn` | `string` | IAM role ARN in PROD account for cross-account deployment. |

### Optional

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `github_branch` | `string` | `"main"` | Branch to trigger pipeline on push. |
| `iac_runtime` | `string` | `"terraform"` | IaC tool: `terraform` or `opentofu`. |
| `iac_version` | `string` | `"latest"` | Version of Terraform/OpenTofu to install. |
| `codestar_connection_arn` | `string` | `""` | Existing CodeStar Connection ARN. Empty creates new. |
| `create_state_bucket` | `bool` | `true` | Whether to create the S3 state bucket. |
| `state_bucket` | `string` | `""` | Existing bucket name (required when `create_state_bucket = false`). |
| `state_key_prefix` | `string` | `""` | S3 key prefix for state files. Defaults to `project_name`. |
| `sns_subscribers` | `list(string)` | `[]` | Email addresses for approval notifications. |
| `enable_review_gate` | `bool` | `false` | Include optional review approval stage. |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | CodeBuild compute type. |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | CodeBuild managed image (`aws/codebuild/` prefix required). |
| `checkov_soft_fail` | `bool` | `false` | When true, checkov findings do not fail the pipeline. |
| `codebuild_timeout_minutes` | `number` | `60` | Build timeout (5-480 minutes). |
| `logging_bucket` | `string` | `""` | Existing S3 bucket for access logs. Empty disables logging. |
| `logging_prefix` | `string` | `""` | S3 key prefix for access logs. Empty uses auto-generated prefix. |
| `log_retention_days` | `number` | `30` | CloudWatch log retention in days. For compliance, set to 365. |
| `artifact_retention_days` | `number` | `30` | S3 lifecycle expiry for artifacts (1-365 days). |
| `tags` | `map(string)` | `{}` | Additional tags merged with module-managed tags. |

## Outputs

| Name | Description |
|------|-------------|
| `pipeline_arn` | ARN of the CodePipeline. |
| `pipeline_url` | AWS Console URL for the pipeline. |
| `codebuild_project_names` | Map of CodeBuild project names (prebuild, plan, deploy, test). |
| `codebuild_service_role_arn` | ARN of the CodeBuild service role. |
| `codepipeline_service_role_arn` | ARN of the CodePipeline service role. |
| `sns_topic_arn` | ARN of the approval SNS topic. |
| `artifact_bucket_name` | Name of the pipeline artifact bucket. |
| `state_bucket_name` | Name of the state bucket (created or existing). |
| `codestar_connection_arn` | ARN of the CodeStar Connection. |
| `dev_account_id` | DEV target account ID (pass-through). |
| `prod_account_id` | PROD target account ID (pass-through). |

## Resources Created

| Resource | Count | Description |
|----------|-------|-------------|
| `aws_codepipeline` | 1 | Pipeline V2 with 9 stages |
| `aws_codebuild_project` | 4 | prebuild, plan, deploy, test |
| `aws_cloudwatch_log_group` | 4 | One per CodeBuild project |
| `aws_iam_role` | 2 | CodePipeline + CodeBuild service roles |
| `aws_iam_role_policy` | 2 | Inline policies for each role |
| `aws_s3_bucket` + config | 2 | State (conditional) + artifacts |
| `aws_sns_topic` | 1 | Approval notifications |
| `aws_codestarconnections_connection` | 0-1 | GitHub connection (conditional) |
| `aws_sns_topic_subscription` | 0-N | Email subscriptions |

Total: ~27 resources (with state bucket and CodeStar connection created).

## Consumer Repository Structure

The pipeline expects this layout in the consumer's GitHub repository:

```
my-terraform-project/
├── main.tf                        # Terraform configuration
├── variables.tf
├── outputs.tf
├── environments/
│   ├── dev.tfvars                 # Optional — DEV variable values
│   └── prod.tfvars                # Optional — PROD variable values
└── cicd/
    ├── prebuild/
    │   └── main.sh                # Optional — pre-build validation script
    ├── dev/
    │   └── smoke-test.sh          # Optional — DEV smoke tests
    └── prod/
        └── smoke-test.sh          # Optional — PROD smoke tests
```

All `cicd/` scripts and `environments/*.tfvars` files are optional. The pipeline gracefully skips missing files.

## Cross-Account Credential Flow

```
CodeBuild Service Role (Automation Account)
    │
    ├── sts:AssumeRole ──► DEV Deployment Role (DEV Account)
    │                        └── terraform apply (DEV)
    │
    └── sts:AssumeRole ──► PROD Deployment Role (PROD Account)
                             └── terraform apply (PROD)
```

First-hop assumption only (no role chaining). Deployment roles must trust the CodeBuild service role.

## Project Structure

```
terraform-pipelines/
├── main.tf                         # CodePipeline + CodeBuild projects + log groups
├── iam.tf                          # IAM roles and policies
├── storage.tf                      # S3 buckets + SNS topic + subscriptions
├── codestar.tf                     # CodeStar Connection (conditional)
├── variables.tf                    # Input variables with validation
├── outputs.tf                      # Module outputs
├── locals.tf                       # Computed values
├── versions.tf                     # required_version, required_providers
├── buildspecs/                     # CodeBuild buildspec files (inline via file())
│   ├── prebuild.yml
│   ├── plan.yml
│   ├── deploy.yml
│   └── test.yml
├── examples/
│   ├── minimal/                    # Required variables only
│   ├── complete/                   # All variables with overrides
│   └── opentofu/                   # OpenTofu runtime
├── tests/
│   ├── e2e/                        # End-to-end test root module
│   │   └── main.tf
│   └── test-terraform.sh           # Validation and deployment test script
├── docs/
│   ├── ARCHITECTURE_AND_DESIGN.md  # Full architecture reference
│   ├── codepipeline-mvp-statement.md
│   ├── FEATURES_1-7.md
│   ├── FEATURE_8.md
│   ├── FEATURE_9.md
│   ├── FEATURE_10.md
│   ├── FEATURE_11.md
│   ├── FEATURE_12.md
│   ├── FEATURE_13.md
│   └── working/                    # Cross-account role docs and policies
├── CHANGELOG.md
├── CLAUDE.md
├── prd.md
├── progress.txt
└── README.md
```

## Validation

```bash
terraform init
terraform fmt -check -recursive
terraform validate
tflint
```

## Documentation

- **Architecture:** `docs/ARCHITECTURE_AND_DESIGN.md`
- **Cross-account roles:** `docs/working/CROSS_ACCOUNT_ROLES.md`
- **Feature history:** `docs/FEATURES_1-7.md`, `docs/FEATURE_8.md` through `docs/FEATURE_13.md`
- **Changelog:** `CHANGELOG.md`
