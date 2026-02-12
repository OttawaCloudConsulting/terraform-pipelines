# Features 1-7 — Complete Pipeline Module Implementation

## Summary

Implemented the full Terraform pipeline module: module skeleton with versions/variables/outputs/locals, IAM service roles with least-privilege policies, conditional S3 state and artifact buckets, SNS approval topic, conditional CodeStar Connection, four CodeBuild projects with buildspec files, and a 9-stage CodePipeline V2.

## Files Changed

| File | Change |
|------|--------|
| `versions.tf` | Terraform >= 1.11, AWS provider >= 5.0 |
| `variables.tf` | 16 variables (6 required, 10 optional) with validation blocks |
| `outputs.tf` | 9 outputs referencing resource attributes |
| `locals.tf` | Computed values: state_bucket_name, codestar_connection_arn, state_key_prefix, merged tags |
| `main.tf` | 4 CloudWatch log groups, 4 CodeBuild projects, CodePipeline V2 with 9 stages |
| `iam.tf` | CodePipeline and CodeBuild service roles with inline policies |
| `storage.tf` | Conditional state bucket, artifact bucket, SNS topic + subscriptions |
| `codestar.tf` | Conditional CodeStar Connection for GitHub |
| `buildspecs/prebuild.yml` | Developer pre-build script execution |
| `buildspecs/plan.yml` | IaC runtime install, terraform plan, checkov scan |
| `buildspecs/deploy.yml` | Cross-account role assumption, terraform init + apply |
| `buildspecs/test.yml` | Cross-account role assumption, smoke test execution |

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project_name` | string | (required) | Name used in all resource names |
| `github_repo` | string | (required) | GitHub repo in org/repo format |
| `dev_account_id` | string | (required) | 12-digit DEV account ID |
| `dev_deployment_role_arn` | string | (required) | DEV cross-account role ARN |
| `prod_account_id` | string | (required) | 12-digit PROD account ID |
| `prod_deployment_role_arn` | string | (required) | PROD cross-account role ARN |
| `github_branch` | string | "main" | Trigger branch |
| `iac_runtime` | string | "terraform" | terraform or opentofu |
| `iac_version` | string | "latest" | IaC tool version |
| `codestar_connection_arn` | string | "" | Existing connection ARN (empty = create new) |
| `create_state_bucket` | bool | true | Create state bucket or use existing |
| `state_bucket` | string | "" | Existing bucket name (required when create_state_bucket=false) |
| `state_key_prefix` | string | "" | S3 key prefix (defaults to project_name) |
| `sns_subscribers` | list(string) | [] | Approval notification emails |
| `enable_review_gate` | bool | false | Include optional review stage |
| `codebuild_compute_type` | string | "BUILD_GENERAL1_SMALL" | CodeBuild instance size |
| `codebuild_image` | string | "aws/codebuild/amazonlinux-x86_64-standard:5.0" | CodeBuild image |
| `codebuild_timeout_minutes` | number | 60 | Build timeout |
| `log_retention_days` | number | 30 | CloudWatch log retention |
| `artifact_retention_days` | number | 30 | S3 artifact lifecycle expiry |
| `tags` | map(string) | {} | Additional tags |

## Decisions

1. **All features implemented together** — Features 1-7 were implemented as a single unit because `outputs.tf` references require all resources to exist for `terraform validate` to pass.

2. **Both deploys use source_output** — Both DEV and PROD deploy stages consume `source_output` (not `plan_output`) because each environment has different state keys, backend configs, and potentially different var-files. The plan stage output is informational for the review gate and checkov scan only. Architecture doc updated to reflect this.

3. **Plan stage is environment-agnostic** — The plan buildspec does not reference `TARGET_ENV` and runs without var-files. It uses a dedicated `/plan/` state key path for provider initialization.

4. **Single-phase buildspec commands** — Deploy and test buildspecs consolidate role assumption, init, and execution into a single `build` phase command block. This guarantees STS credentials (exported via `export`) persist across all operations, avoiding cross-phase environment variable loss in CodeBuild.

5. **SSE-S3 over KMS CMK** — Per architecture Design Decision #4, MVP uses AWS-managed encryption. Security scanner findings for KMS CMK are accepted risks. Post-MVP enhancement.

6. **Full clone source format** — Source stage uses `CODEBUILD_CLONE_REF` for full git clone as specified in the PRD.

7. **Cross-validation on state_bucket** — Added validation ensuring `state_bucket` is non-empty when `create_state_bucket = false` to prevent confusing data source errors.

## Validation

```
terraform validate: Success
terraform fmt -check: Pass (no formatting issues)
tflint: 2 warnings (dev_account_id, prod_account_id unused — intentionally declared per PRD)
checkov: 53 passed, 25 findings (KMS CMK, S3 logging — accepted per design decisions)
trivy: 9 findings (LOW: 6, HIGH: 3 — all KMS/logging accepted risks)
git-secrets: No secrets found
```

## Verification

After E2E deployment (Feature 9), verify with:

```bash
# Check pipeline exists
aws codepipeline get-pipeline --name <project>-pipeline --profile aft-automation

# Check CodeBuild projects
aws codebuild batch-get-projects --names <project>-prebuild <project>-plan <project>-deploy <project>-test --profile aft-automation

# Check IAM roles
aws iam get-role --role-name CodePipeline-<project>-ServiceRole --profile aft-automation
aws iam get-role --role-name CodeBuild-<project>-ServiceRole --profile aft-automation

# Check S3 buckets
aws s3api head-bucket --bucket <project>-terraform-state --profile aft-automation
aws s3api head-bucket --bucket <project>-pipeline-artifacts --profile aft-automation

# Check SNS topic
aws sns get-topic-attributes --topic-arn <sns_topic_arn> --profile aft-automation
```
