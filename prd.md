# PRD: Terraform Pipeline Module

## Summary

A reusable Terraform module that provisions a complete AWS CodePipeline V2 + CodeBuild CI/CD pipeline for deploying Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each module invocation creates a dedicated pipeline instance that is 1:1 with a Terraform project, promoting changes from DEV through PROD with approval gates, security scanning, and developer-managed test hooks.

## Goals

- Provide a single `module {}` invocation that creates all pipeline resources for a Terraform project
- Automate the full lifecycle: source → validate → plan → scan → approve → deploy DEV → test → approve → deploy PROD → test
- Support cross-account deployments via IAM role assumption (first-hop, no chaining limit)
- Support both Terraform and OpenTofu runtimes (mutually exclusive per pipeline)
- Be parameterized enough to support multiple independent pipeline instances from the same module

## Non-Goals

- Custom CodeBuild Docker images — MVP uses standard managed images with inline tool installation
- Automated (programmatic) approval via Lambda — MVP uses human click-ops
- Drift detection — not natively supported by CodePipeline
- GitHub PR plan comments — requires Lambda webhook
- Self-service pipeline provisioning UI/workflow
- Rollback automation — Terraform has no native rollback
- Approve-from-Slack — requires custom Lambda + API Gateway
- Creating deployment roles in target accounts — these are prerequisites
- Cost estimation (Infracost) — developers can add this in their prebuild scripts
- Policy-as-code (OPA/Sentinel) — MVP relies on IAM boundaries and SCPs

## Architecture

### Three-Account Model

- **Automation Account** — hosts CodePipeline, CodeBuild, S3 buckets, SNS topics, IAM service roles, CodeStar Connection
- **DEV Target Account** — receives DEV deployments via cross-account IAM role assumption
- **PROD Target Account** — receives PROD deployments via cross-account IAM role assumption

### Pipeline Stages (9 total)

1. **Source** — GitHub via CodeStar Connection, triggers on push to configured branch
2. **Pre-Build** — executes developer-managed `cicd/prebuild/main.sh`
3. **Plan + Security Scan** — `terraform plan` + checkov scan, outputs artifacts
4. **Optional Review** — manual approval gate (toggleable via `enable_review_gate` variable)
5. **Deploy DEV** — `terraform apply` via cross-account role assumption to DEV account
6. **Test DEV** — executes developer-managed `cicd/dev/smoke-test.sh`
7. **Mandatory Approval** — SNS notification, human approval required
8. **Deploy PROD** — `terraform apply` via cross-account role assumption to PROD account
9. **Test PROD** — executes developer-managed `cicd/prod/smoke-test.sh`

### Cross-Account Credential Flow

CodeBuild service role → `sts:AssumeRole` (first-hop) → target account deployment role. No role chaining. Session duration up to 8 hours (CodeBuild) / 12 hours (target role).

## Features

### Feature 1: Project Foundation and Module Structure

Set up the Terraform module skeleton with required providers, version constraints, variables, outputs, and file organization.

**Acceptance Criteria:**
- `required_version >= 1.11` constraint enforced in `versions.tf`
- AWS provider configured for `ca-central-1` default
- All input variables defined in `variables.tf` with types, descriptions, defaults, and validation blocks (iac_runtime, account ID format, ARN format)
- All outputs defined in `outputs.tf`
- `locals.tf` with computed values: `state_bucket_name`, `codestar_connection_arn`, merged tags
- Module file structure: `main.tf`, `iam.tf`, `storage.tf`, `codestar.tf`, `variables.tf`, `outputs.tf`, `locals.tf`, `versions.tf`
- Buildspec files in `buildspecs/` directory: `prebuild.yml`, `plan.yml`, `deploy.yml`, `test.yml`
- `terraform validate` passes with no errors

### Feature 2: IAM Roles and Policies

Create the CodePipeline and CodeBuild service roles with least-privilege policies.

**Acceptance Criteria:**
- `CodePipeline-<project_name>-ServiceRole` created with trust policy for `codepipeline.amazonaws.com`
- `CodeBuild-<project_name>-ServiceRole` created with trust policy for `codebuild.amazonaws.com`
- CodeBuild role has `sts:AssumeRole` scoped to exactly `dev_deployment_role_arn` and `prod_deployment_role_arn`
- CodeBuild role has S3 access for state bucket (read/write state + lockfiles) and artifact bucket
- CodeBuild role has CloudWatch Logs permissions scoped to the pipeline's log groups
- CodePipeline role has permissions for S3 artifact bucket, CodeBuild, CodeStar Connection, and SNS
- Fixed tags (`project_name`, `managed-by = terraform`) merged with consumer `tags` variable applied to all IAM resources

### Feature 3: S3 Buckets (State and Artifacts)

Create the S3 state bucket (conditional) and artifact bucket with security hardening.

**Acceptance Criteria:**
- State bucket: conditional creation via `create_state_bucket` variable (default: `true`)
- State bucket: SSE-S3 (AES256) encryption enabled
- State bucket: versioning enabled
- State bucket: bucket policy denying non-SSL requests and public access
- State bucket: S3 Block Public Access enabled (all four settings)
- Artifact bucket: created per pipeline instance, named `<project_name>-pipeline-artifacts`
- Artifact bucket: SSE-S3 encryption, versioning enabled
- Artifact bucket: bucket policy denying non-SSL and public access
- Artifact bucket: lifecycle rule expiring objects after configurable days (default: 30, via `artifact_retention_days` variable)
- When `create_state_bucket = false`, consumer provides `state_bucket` name and module validates it via `data.aws_s3_bucket`
- State bucket uses `count = var.create_state_bucket ? 1 : 0` for conditional creation

### Feature 4: SNS Topic and Subscriptions

Create the approval notification topic with optional email subscribers.

**Acceptance Criteria:**
- SNS topic created: `<project_name>-pipeline-approvals`
- Topic encrypted with AWS-managed SNS key (`alias/aws/sns`)
- Optional email subscriptions via `sns_subscribers` list variable
- Topic policy allows CodePipeline to publish
- Topic ARN exposed as module output

### Feature 5: CodeStar Connection

Support existing or auto-created GitHub connection.

**Acceptance Criteria:**
- When `codestar_connection_arn` is provided (non-empty), module references it directly
- When `codestar_connection_arn` is empty/not provided, module creates a new `aws_codestarconnections_connection`
- Created connection name follows `<project_name>-github` pattern
- Connection ARN exposed as module output (whether created or referenced)
- Documentation notes that new connections require one-time manual OAuth authorization in AWS Console

### Feature 6: CodeBuild Projects and Buildspecs

Create the four CodeBuild projects with their buildspec files.

**Acceptance Criteria:**
- Four CodeBuild projects created: `<project_name>-prebuild`, `<project_name>-plan`, `<project_name>-deploy`, `<project_name>-test`
- All projects use the configurable `codebuild_compute_type` and `codebuild_image` variables
- All projects reference the `CodeBuild-<project_name>-ServiceRole`
- CloudWatch log groups created with configurable retention (default: 30 days, via `log_retention_days` variable)
- Configurable build timeout via `codebuild_timeout_minutes` variable (default: 60)
- Four buildspec files stored in `buildspecs/` directory: `prebuild.yml`, `plan.yml`, `deploy.yml`, `test.yml`
- Buildspecs handle Terraform vs OpenTofu installation based on `iac_runtime` and `iac_version` environment variables
- Plan and deploy buildspecs gracefully handle missing var files — check if `environments/${TARGET_ENV}.tfvars` exists before passing `-var-file`
- Plan buildspec includes checkov security scan with JUnit XML report output
- Deploy buildspec includes cross-account role assumption and `terraform apply`
- Test buildspec includes cross-account role assumption and developer smoke test execution
- CodeBuild project names exposed as module outputs

### Feature 7: CodePipeline

Create the CodePipeline V2 pipeline with all nine stages.

**Acceptance Criteria:**
- CodePipeline V2 created: `<project_name>-pipeline`
- Stage 1 (Source): CodeStar Connection source action, configured branch, full clone
- Stage 2 (Pre-Build): CodeBuild action referencing `<project_name>-prebuild`
- Stage 3 (Plan): CodeBuild action referencing `<project_name>-plan`, outputs plan artifact
- Stage 4 (Optional Review): Manual Approval action, conditionally included via `enable_review_gate` variable (default: `false`)
- Stage 5 (Deploy DEV): CodeBuild action referencing `<project_name>-deploy` with DEV environment variables (TARGET_ROLE, TARGET_ENV=dev)
- Stage 6 (Test DEV): CodeBuild action referencing `<project_name>-test` with DEV environment variables
- Stage 7 (Mandatory Approval): Manual Approval action with SNS notification to approval topic
- Stage 8 (Deploy PROD): CodeBuild action referencing `<project_name>-deploy` with PROD environment variables (TARGET_ROLE, TARGET_ENV=prod)
- Stage 9 (Test PROD): CodeBuild action referencing `<project_name>-test` with PROD environment variables
- Pipeline uses the artifact bucket for inter-stage artifacts
- Pipeline ARN and console URL exposed as module outputs

### Feature 8: Examples and Validation

Create example root modules and validate the complete module.

**Acceptance Criteria:**
- Three example root modules in `examples/` directory: `minimal/` (required vars only), `complete/` (all vars), `opentofu/` (OpenTofu runtime)
- `terraform init && terraform validate` succeeds on all examples
- `terraform fmt -check` passes on all `.tf` files
- Module README or inline documentation covers all variables, outputs, and usage

### Feature 9: End-to-End Deployment Test

Deploy the pipeline to the Automation Account and verify it can deploy a simple Terraform project through the full pipeline.

**Prerequisites (manual, outside this module):**
- Cross-account deployment roles must be created in DEV and PROD target accounts before this test
- Deployment roles must trust the CodeBuild service role in the Automation Account
- User will be prompted when it is time to create these roles

**Test Environment:**

| Account | Account ID | CLI Profile | Role |
|---------|-----------|-------------|------|
| Automation | 389068787156 | `aft-automation` | Pipeline host |
| DEV | 914089393341 | `developer-account` | DEV target |
| PROD | 264675080489 | `network` | PROD target |

**Test Repository:** `OttawaCloudConsulting/terraform-test`, branch `s3-bucket`
- Deploys without customization or tfvars (validates graceful var-file handling)

**Acceptance Criteria:**
- Pipeline deployed to Automation Account (389068787156) via `terraform apply` using `aft-automation` profile
- CodeStar Connection authorized for GitHub (one-time manual step)
- Pipeline triggers on push to `s3-bucket` branch of `OttawaCloudConsulting/terraform-test`
- Pre-Build stage executes successfully
- Plan stage generates a plan and security scan results visible in CodeBuild Reports
- Deploy DEV creates resources in account 914089393341
- Mandatory Approval blocks pipeline and sends notification
- Deploy PROD creates resources in account 264675080489 after approval
- Pipeline can be destroyed cleanly via `terraform destroy`

### Feature 10: SecOps Security Hardening

Address three recommendations from the SecOps security assessment (Checkov + Trivy scans, 2026-02-12). No critical or high-severity findings exist — these are defense-in-depth improvements.

**Source:** `docs/working/secops-assessment-report.md`

#### 10.1 — S3 Access Logging

Add optional S3 server access logging for both the state bucket and artifact bucket. When a `logging_bucket` variable is provided, enable access logging on both buckets. When empty (default), no logging resources are created.

**Acceptance Criteria:**
- New variable `logging_bucket` (type `string`, default `""`) — name of an existing S3 bucket to receive access logs
- New variable `logging_prefix` (type `string`, default `""`) — optional prefix override; if empty, defaults to `s3-access-logs/<project_name>-<bucket_type>/`
- When `logging_bucket != ""`, create `aws_s3_bucket_logging.state` (conditional on `create_state_bucket && logging_bucket != ""`)
- When `logging_bucket != ""`, create `aws_s3_bucket_logging.artifacts`
- Target prefix pattern: `s3-access-logs/<project_name>-state/` and `s3-access-logs/<project_name>-artifacts/`
- When `logging_bucket == ""` (default), no logging resources are created — no breaking change to existing consumers
- Checkov CKV_AWS_18 resolves to PASSED when `logging_bucket` is provided

#### 10.2 — Abort Incomplete Multipart Uploads

Add an `abort_incomplete_multipart_upload` block to the artifact bucket lifecycle configuration. This prevents incomplete multipart uploads from accumulating indefinitely and incurring storage costs.

**Acceptance Criteria:**
- Add `abort_incomplete_multipart_upload { days_after_initiation = 7 }` to the existing `aws_s3_bucket_lifecycle_configuration.artifacts` resource
- No new variables required — 7-day abort period is a safe default for pipeline artifacts
- Checkov CKV_AWS_300 resolves to PASSED
- Existing `expire-artifacts` lifecycle rule is unchanged

#### 10.3 — Log Retention Compliance Documentation

Document the recommendation that production deployments should set `log_retention_days = 365` for compliance frameworks (SOC2, PCI-DSS). The default remains 30 days to avoid breaking existing consumers.

**Acceptance Criteria:**
- `examples/complete/` sets `log_retention_days = 365` to demonstrate the compliance-recommended value
- Variable description for `log_retention_days` updated to mention the 365-day compliance recommendation
- No change to the default value (remains 30)

### Feature 11: PR Review — Security Hardening

Address security findings from the PR #1 review (Security Engineer, Architect, Senior Developer, Copilot). Harden the security gate, add inline checkov suppressions for deferred items, and apply defense-in-depth improvements.

**Source:** `docs/working/pr-review/pr-review-response.md`

#### 11.1 — Fix Checkov Security Gate

Remove `|| true` from the checkov command in the plan buildspec. Use `--hard-fail-on` to fail on CRITICAL and HIGH findings. Add a `checkov_soft_fail` variable (default: `false`) that allows consumers to override during initial adoption.

**Acceptance Criteria:**
- Remove `|| true` from `buildspecs/plan.yml` checkov command
- Add `--hard-fail-on CRITICAL,HIGH` flag to the checkov command
- New variable `checkov_soft_fail` (type `bool`, default `false`) — when `true`, appends `--soft-fail` to checkov
- CodeBuild plan project passes `CHECKOV_SOFT_FAIL` environment variable to buildspec
- Update `docs/ARCHITECTURE_AND_DESIGN.md` SEC11-BP07 table to accurately reflect the `--hard-fail-on` behavior
- Checkov findings at CRITICAL or HIGH severity stop the pipeline (unless `checkov_soft_fail = true`)

#### 11.2 — Add Inline Checkov Suppressions for Deferred Items

Add `#checkov:skip=` comments to Terraform resources for all checks that fail due to documented design decisions (SSE-S3 vs KMS, log retention default, cross-region replication, event notifications). Each suppression must include a rationale comment.

**Acceptance Criteria:**
- Suppress the following checks with inline `#checkov:skip=` comments and rationale:

| Check ID | Resource(s) | Rationale |
|----------|------------|-----------|
| CKV_AWS_158 | 4 CloudWatch log groups (`main.tf`) | Post-MVP: KMS CMK encryption (design decision #4) |
| CKV_AWS_338 | 4 CloudWatch log groups (`main.tf`) | Consumer-configurable via log_retention_days; default 30d documented |
| CKV_AWS_147 | 4 CodeBuild projects (`main.tf`) | Post-MVP: CMK encryption (design decision #4) |
| CKV_AWS_219 | 1 CodePipeline (`main.tf`) | Post-MVP: CMK artifact encryption (design decision #4) |
| CKV_AWS_145 | 2 S3 buckets (`storage.tf`) | Post-MVP: SSE-KMS encryption (design decision #4) |
| CKV_AWS_144 | 2 S3 buckets (`storage.tf`) | Single-region design; cross-region replication out of scope |
| CKV2_AWS_62 | 2 S3 buckets (`storage.tf`) | Event notifications not required for state/artifact buckets |
| CKV_AWS_18 | 2 S3 buckets (`storage.tf`) | Conditional via logging_bucket variable (Feature 10.1) |
| CKV2_AWS_61 | 1 S3 state bucket (`storage.tf`) | State bucket intentionally retains all versions; no lifecycle expiry |
| CKV_AWS_21 | 1 S3 state bucket (`storage.tf`) | False positive: versioning configured via separate aws_s3_bucket_versioning resource |
| CKV2_AWS_6 | 1 S3 state bucket (`storage.tf`) | False positive: public access block configured via separate resource |

- After suppressions, `checkov -d .` against the module code produces zero failures (all suppressed or passing)
- Suppression rationale references design decision numbers where applicable

#### 11.3 — Add `codebuild_image` Validation

Add a validation block to the `codebuild_image` variable that enforces AWS-managed CodeBuild images only (prefix `aws/codebuild/`). Prevents supply chain attacks via custom Docker images.

**Acceptance Criteria:**
- Validation regex: `^aws/codebuild/`
- Error message: `"codebuild_image must be an AWS-managed CodeBuild image (prefix: aws/codebuild/)."`
- Existing default `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` passes validation

#### 11.4 — Add SNS Topic Policy `aws:SourceAccount` Condition

Add an `aws:SourceAccount` condition to the SNS topic policy to prevent confused deputy attacks from CodePipeline services in other AWS accounts.

**Acceptance Criteria:**
- SNS topic policy `AllowCodePipelinePublish` statement includes `Condition` block with `StringEquals` on `aws:SourceAccount` matching `data.aws_caller_identity.current.account_id`
- Existing pipeline functionality is unchanged (same-account CodePipeline can still publish)

#### 11.5 — Add `prevent_destroy` Lifecycle on State Bucket

Add `lifecycle { prevent_destroy = true }` to the state bucket to prevent catastrophic state loss via accidental `terraform destroy`.

**Acceptance Criteria:**
- `aws_s3_bucket.state` resource includes `lifecycle { prevent_destroy = true }`
- `terraform destroy` targeting the pipeline module will fail if a state bucket exists (user must manually remove the lifecycle rule to destroy)

#### 11.6 — Add `s3:GetBucketLocation` to CodeBuild IAM Policy

Add `s3:GetBucketLocation` to the `S3StateBucketAccess` IAM policy statement. Required by the Terraform S3 backend during `terraform init` for region determination.

**Acceptance Criteria:**
- `s3:GetBucketLocation` added to the `S3StateBucketAccess` statement in `iam.tf`
- No change to resource ARN scope (same state bucket ARN)

#### 11.7 — Pin Provider Constraint to `~> 6.0`

Change the AWS provider version constraint from `>= 5.0` to `~> 6.0` in the module and all examples. The installed version is 6.32.0 (verified via `.terraform.lock.hcl`), so pinning to `~> 6.0` allows 6.x minor/patch updates while blocking 7.0+ breaking changes.

**Acceptance Criteria:**
- `versions.tf` updated: `version = "~> 6.0"`
- `examples/minimal/main.tf` updated: `version = "~> 6.0"`
- `examples/complete/main.tf` updated: `version = "~> 6.0"`
- `examples/opentofu/main.tf` updated: `version = "~> 6.0"`
- `terraform init` succeeds with the pinned constraint (no downgrade)

### Feature 12: PR Review — Buildspec & Code Quality

Address code quality findings from the PR #1 review. Fix buildspec shell safety, variable validation bugs, and input constraint gaps.

**Source:** `docs/working/pr-review/pr-review-response.md`

#### 12.1 — Add `set -euo pipefail` to Buildspec Shell Blocks

Add `set -euo pipefail` as the first line in every multi-line shell block across all four buildspecs. Without this, intermediate command failures in `|` blocks are silently swallowed.

**Acceptance Criteria:**
- All multi-line shell blocks in `buildspecs/prebuild.yml`, `buildspecs/plan.yml`, `buildspecs/deploy.yml`, `buildspecs/test.yml` start with `set -euo pipefail`
- Existing shell logic continues to function correctly (no unintended failures from unset variables or pipe errors)

#### 12.2 — Fix Cross-Variable Validation in `state_bucket`

Remove the cross-variable validation from the `state_bucket` variable block (references `var.create_state_bucket`, which Terraform does not support in `validation` blocks). Move the invariant to a `precondition` on `data.aws_s3_bucket.existing_state`.

**Acceptance Criteria:**
- `state_bucket` variable validation block removed (the one referencing `var.create_state_bucket`)
- `data.aws_s3_bucket.existing_state` resource includes a `lifecycle { precondition }` block that validates `var.state_bucket != ""`
- `terraform validate` passes
- Setting `create_state_bucket = false` with empty `state_bucket` produces a clear error at plan time

#### 12.3 — Add `project_name` Length and Consecutive Hyphen Validation

Update the `project_name` validation regex to enforce a maximum length of 34 characters (prevents IAM role name overflow at 64-char limit) and reject consecutive hyphens (violates S3 naming rules).

**Acceptance Criteria:**
- Updated regex: `^[a-z][a-z0-9-]{1,32}[a-z0-9]$` (3-34 chars, starts with letter)
- Additional condition: no consecutive hyphens (`--`)
- Error message updated to explain both constraints
- Existing valid `project_name` values continue to pass validation

### Feature 13: PR Review — Repo Hygiene

Address repository hygiene findings from the PR #1 review.

**Source:** `docs/working/pr-review/pr-review-response.md`

#### 13.1 — Update `.gitignore`

Add missing entries for Terraform artifacts that are currently showing as untracked in git status.

**Acceptance Criteria:**
- `.gitignore` updated to include: `*.tfplan`, `*.tfplan.*`, `tfplan.binary`, `tfplan.json`, `.terraform.lock.hcl`
- Add `.claude/settings.local.json` to `.gitignore`
- Existing untracked files in `examples/` and `tests/e2e/` are no longer shown in `git status`

## Input Variables

### Required

| Variable | Type | Description |
|----------|------|-------------|
| `project_name` | `string` | Name of the Terraform project. Used in all resource names. |
| `github_repo` | `string` | GitHub repository in `org/repo` format. |
| `dev_account_id` | `string` | AWS Account ID for the DEV target environment. |
| `dev_deployment_role_arn` | `string` | ARN of the existing IAM role in the DEV account. |
| `prod_account_id` | `string` | AWS Account ID for the PROD target environment. |
| `prod_deployment_role_arn` | `string` | ARN of the existing IAM role in the PROD account. |

### Optional

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `github_branch` | `string` | `"main"` | Branch to trigger pipeline on push. |
| `iac_runtime` | `string` | `"terraform"` | IaC tool: `terraform` or `opentofu`. Validated. |
| `iac_version` | `string` | `"latest"` | Version of Terraform or OpenTofu to install. |
| `codestar_connection_arn` | `string` | `""` | Existing CodeStar Connection ARN. Empty = create new. |
| `state_bucket` | `string` | `""` | Existing S3 bucket name for Terraform state. Required when `create_state_bucket = false`. |
| `create_state_bucket` | `bool` | `true` | Whether the module creates the state bucket. |
| `state_key_prefix` | `string` | `project_name` | S3 key prefix for state files. |
| `sns_subscribers` | `list(string)` | `[]` | Email addresses for approval notifications. |
| `enable_review_gate` | `bool` | `false` | Whether to include the optional review approval stage. |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | CodeBuild compute type. |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | CodeBuild managed image. Validated to `aws/codebuild/` prefix. |
| `checkov_soft_fail` | `bool` | `false` | When true, checkov findings do not fail the pipeline. |
| `codebuild_timeout_minutes` | `number` | `60` | Build timeout for CodeBuild projects. |
| `log_retention_days` | `number` | `30` | CloudWatch log group retention in days. |
| `artifact_retention_days` | `number` | `30` | S3 artifact lifecycle expiry in days. |
| `logging_bucket` | `string` | `""` | Existing S3 bucket name for access logs. Empty = no logging. |
| `logging_prefix` | `string` | `""` | S3 key prefix override for access logs. Empty = auto-generated. |
| `tags` | `map(string)` | `{}` | Additional tags merged with module-managed tags. |

## Outputs

| Output | Description |
|--------|-------------|
| `pipeline_arn` | ARN of the CodePipeline. |
| `pipeline_url` | AWS Console URL for the pipeline. |
| `codebuild_project_names` | Map of CodeBuild project names (prebuild, plan, deploy, test). |
| `codebuild_service_role_arn` | ARN of the CodeBuild service role. |
| `codepipeline_service_role_arn` | ARN of the CodePipeline service role. |
| `sns_topic_arn` | ARN of the approval SNS topic. |
| `artifact_bucket_name` | Name of the pipeline artifact bucket. |
| `state_bucket_name` | Name of the state bucket (if created by module). |
| `codestar_connection_arn` | ARN of the CodeStar Connection (created or referenced). |
