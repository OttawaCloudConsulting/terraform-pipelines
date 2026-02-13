# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **parameterized, reusable Terraform pipeline template** using AWS CodePipeline V2 and CodeBuild. It deploys Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each pipeline instance is 1:1 with a Terraform project.

The authoritative design documents are `prd.md` (requirements), `docs/ARCHITECTURE_AND_DESIGN.md` (architecture), and `docs/codepipeline-mvp-statement.md` (original MVP statement). Implementation progress is tracked in `progress.txt`.

## Architecture

**Three-account model:**
- **Automation Account** — hosts CodePipeline, CodeBuild, S3 state bucket, SNS topics, IAM service roles, CodeStar Connection
- **DEV Target Account** — receives DEV deployments via cross-account IAM role assumption
- **PROD Target Account** — receives PROD deployments via cross-account IAM role assumption

**Pipeline stages (9 total):**
1. Source (GitHub via CodeStar Connection)
2. Pre-Build — executes `cicd/prebuild/main.sh` (developer-managed)
3. Plan + Security Scan — `terraform plan` + checkov scan, outputs artifacts
4. Optional Review — manual approval gate
5. Deploy DEV — `terraform apply` via cross-account role assumption
6. Test DEV — executes `cicd/dev/smoke-test.sh` (developer-managed)
7. Mandatory Approval — SNS notification, human approval required
8. Deploy PROD — `terraform apply` via cross-account role assumption
9. Test PROD — executes `cicd/prod/smoke-test.sh` (developer-managed)

**Cross-account credential flow:** CodeBuild service role → `sts:AssumeRole` (first-hop, no chaining limit) → target account deployment role. Deployment roles are NOT created by the pipeline — they must pre-exist and their ARNs are passed as parameters.

**State management:** S3 backend in Automation Account with native S3 locking (`use_lockfile = true`). No DynamoDB. State keys follow `<project>/<env>/terraform.tfstate` pattern. Requires Terraform 1.11+.

## Key Design Constraints

- Pipeline supports Terraform **or** OpenTofu per instance — mutually exclusive, set via `iac_runtime` parameter
- Each pipeline deploys to exactly two environments (DEV and PROD)
- Standard CodeBuild managed images only (no custom Docker images in MVP) — developers install tools inline in their shell scripts
- Deployment roles in target accounts are prerequisites, not managed by this template
- Secrets are split: automation secrets in Automation Account, application secrets in target accounts (never cross the account boundary)
- Pipeline buildspec files (`buildspecs/prebuild.yml`, `buildspecs/plan.yml`, `buildspecs/deploy.yml`, `buildspecs/test.yml`) are managed by the template, not by developers
- Buildspecs gracefully handle missing var files — check if `environments/${TARGET_ENV}.tfvars` exists before passing `-var-file`

## Build & Validate

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

## Terraform Conventions

- Use `ca-central-1` as the default region
- S3 backend with `use_lockfile = true` (no `dynamodb_table`)
- Environment-specific values go in `environments/dev.tfvars` and `environments/prod.tfvars`
- Resource naming pattern: `<project_name>-<resource>` (e.g., `myproject-pipeline`, `CodeBuild-myproject-ServiceRole`)
- IAM role naming: `CodePipeline-<project>-ServiceRole`, `CodeBuild-<project>-ServiceRole`
- SNS topic naming: `<project_name>-pipeline-approvals`

## Pipeline Parameters

Required: `project_name`, `github_repo`, `dev_account_id`, `dev_deployment_role_arn`, `prod_account_id`, `prod_deployment_role_arn`, `state_bucket`

Optional with defaults: `github_branch` (main), `iac_runtime` (terraform), `iac_version` (latest), `codestar_connection_arn` (""), `create_state_bucket` (true), `state_bucket` (""), `state_key_prefix` (<project_name>), `sns_subscribers` ([]), `enable_review_gate` (false), `codebuild_compute_type` (BUILD_GENERAL1_SMALL), `codebuild_image` (aws/codebuild/amazonlinux-x86_64-standard:5.0), `codebuild_timeout_minutes` (60), `log_retention_days` (30), `artifact_retention_days` (30), `tags` ({})

## Test Environment

| Account | Account ID | CLI Profile |
|---------|-----------|-------------|
| Automation | 111111111111 | `automation` |
| DEV Target | 222222222222 | `developer-account` |
| PROD Target | 333333333333 | `production-account` |

**Test repo:** `OttawaCloudConsulting/terraform-test`, branch `s3-bucket` (deploys without tfvars)

**Important:** Cross-account deployment roles in DEV and PROD accounts are manual prerequisites. Prompt the user when it is time to create them.
