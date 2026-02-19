# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **multi-variant Terraform pipeline template** using AWS CodePipeline V2 and CodeBuild. It deploys Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each pipeline instance is 1:1 with a Terraform project.

**Variants:**
- **Default** (`modules/default/`) — 6-stage cross-account pipeline with consolidated environment stages. Also supports single-account when `dev_account_id == prod_account_id`.
- **Default-DevDestroy** (`modules/default-dev-destroy/`) — 7-8 stages. Default + destroy DEV after PROD tests pass. `enable_destroy_approval` (default: `true`) controls manual approval gate.

The authoritative design documents are `prd.md` (requirements), `docs/ARCHITECTURE_AND_DESIGN.md` (architecture), and `docs/shared/codepipeline-mvp-statement.md` (original MVP statement). Implementation progress is tracked in `progress.txt`.

## Architecture

**Three-account model:**
- **Automation Account** — hosts CodePipeline, CodeBuild, S3 state bucket, SNS topics, IAM service roles, CodeStar Connection
- **DEV Target Account** — receives DEV deployments via cross-account IAM role assumption
- **PROD Target Account** — receives PROD deployments via cross-account IAM role assumption

**Shared Core + Overlay Pattern:**
- `modules/core/` — internal shared module (IAM, S3, SNS, CodeBuild, CloudWatch). Never called directly by consumers.
- `modules/default/` and `modules/default-dev-destroy/` — variant wrappers that call core and define their own CodePipeline.

**Pipeline stages (Default, 6 total):**
1. Source — GitHub checkout via CodeStar Connection
2. Pre-Build — executes `cicd/prebuild/main.sh` (developer-managed)
3. DEV — consolidated stage with ordered actions:
   - Plan DEV (run_order=1) — `terraform plan` with real DEV state + optional Checkov scan
   - Approve DEV (run_order=2, optional) — controlled by `enable_review_gate`
   - Deploy DEV (run_order=3) — `terraform apply tfplan` (saved plan from Plan action)
4. Test DEV — executes `cicd/dev/smoke-test.sh` (developer-managed)
5. PROD — consolidated stage with ordered actions:
   - Plan PROD (run_order=1) — `terraform plan` with real PROD state + optional Checkov scan (always hard-fail)
   - Approve PROD (run_order=2, mandatory) — SNS notification, human approval required
   - Deploy PROD (run_order=3) — `terraform apply tfplan` (saved plan from Plan action)
6. Test PROD — executes `cicd/prod/smoke-test.sh` (developer-managed)

**Default-DevDestroy adds:**
7. Optional Destroy Approval — manual gate (when `enable_destroy_approval = true`)
8. Destroy DEV — `terraform destroy` via cross-account role

**Buildspec strategy:** Plan actions produce a saved `tfplan` artifact. Deploy actions receive the plan artifact as a secondary input and apply it exactly — no re-planning at deploy time. This ensures plan-apply integrity.

**Provider override credential flow:** Buildspecs generate a `_pipeline_override.tf` file at runtime containing `provider "aws" { assume_role { ... } }`. Terraform override files merge with the developer's existing provider block, adding cross-account role assumption without modifying developer code. The CodeBuild service role's instance profile credentials handle S3 backend access (state bucket in automation account), while the provider `assume_role` handles target account API calls. No `aws sts assume-role` or `export AWS_*` in buildspecs. Override files are cleaned up in `post_build`. Deployment roles are NOT created by the pipeline — they must pre-exist and their ARNs are passed as parameters.

**State management:** S3 backend in Automation Account with native S3 locking (`use_lockfile = true`). No DynamoDB. State keys follow `<project>/<env>/terraform.tfstate` pattern. CodeBuild service role instance profile credentials provide direct S3 access for the backend — no `assume_role` in backend config. Requires Terraform 1.11+.

## Module Structure

```
modules/
  core/              # Internal shared module — DO NOT call directly
    main.tf          # 7 CloudWatch log groups, 7 CodeBuild projects (per-env)
    iam.tf           # CodePipeline + CodeBuild IAM roles/policies (extensible)
    storage.tf       # S3 state bucket (conditional), artifact bucket, SNS topic
    codestar.tf      # CodeStar Connection (conditional)
    variables.tf     # All inputs + additional_codebuild_project_arns/additional_log_group_arns
    outputs.tf       # All resource references for variant wrappers
    buildspecs/      # Shared: prebuild.yml, plan.yml, deploy.yml, test.yml

  default/           # Default variant — 6-stage pipeline
    main.tf          # module "core" + CodePipeline V2 (consolidated env stages)
    variables.tf     # Uniform interface (22 vars)
    outputs.tf       # Uniform outputs (11)

  default-dev-destroy/  # DevDestroy variant — 7-8 stages
    main.tf          # module "core" + destroy CodeBuild + CodePipeline V2
    variables.tf     # Uniform interface + enable_destroy_approval
    outputs.tf       # Uniform outputs (codebuild_project_names includes "destroy")
    buildspecs/      # Variant-specific: destroy.yml
```

## Key Design Constraints

- Pipeline supports Terraform **or** OpenTofu per instance — mutually exclusive, set via `iac_runtime` parameter
- Each pipeline deploys to exactly two environments (DEV and PROD)
- Standard CodeBuild managed images only (no custom Docker images) — developers install tools inline in their shell scripts
- Deployment roles in target accounts are prerequisites, not managed by this template
- Core module is internal only — consumers always use variant wrappers
- Variants own CodePipeline (stage definitions are variant-specific)
- IAM extensibility: core policies accept `additional_codebuild_project_arns` and `additional_log_group_arns` for variant-owned resources
- Per-environment CodeBuild projects: `prebuild`, `plan-dev`, `plan-prod`, `deploy-dev`, `deploy-prod`, `test-dev`, `test-prod` — each with `TARGET_ENV` and `TARGET_ROLE` baked in
- Plan-apply integrity: Plan actions output saved `tfplan` artifact; Deploy actions apply that exact plan (no re-planning)
- Security scan: Checkov runs in Plan actions when `enable_security_scan=true`; PROD always hard-fails regardless of `checkov_soft_fail`
- Buildspecs gracefully handle missing var files — check if `environments/${TARGET_ENV}.tfvars` exists before passing `-var-file`
- `iac_working_directory` allows Terraform files to live in a subdirectory; `cicd/` scripts remain repo-root-relative

## Consumer Usage

```hcl
# Default variant
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"
  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "222222222222"
  dev_deployment_role_arn  = "arn:aws:iam::222222222222:role/deployment-role"
  prod_account_id          = "333333333333"
  prod_deployment_role_arn = "arn:aws:iam::333333333333:role/deployment-role"
}

# Terraform files in a subdirectory
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"
  iac_working_directory    = "infra"
  # ... same required variables ...
}

# DevDestroy variant
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"
  # ... same variables as above ...
  enable_destroy_approval = true  # default
}
```

## Build & Validate

```bash
# Validate a specific module
cd modules/default
terraform init -backend=false
terraform validate
terraform fmt -check

# Validate all examples
for dir in examples/*/*; do
  (cd "$dir" && terraform init -backend=false && terraform validate && terraform fmt -check)
done
```

## Terraform Conventions

- Use `ca-central-1` as the default region
- S3 backend with `use_lockfile = true` (no `dynamodb_table`)
- Environment-specific values go in `environments/dev.tfvars` and `environments/prod.tfvars`
- Resource naming pattern: `<project_name>-<resource>` (e.g., `myproject-pipeline`, `CodeBuild-myproject-ServiceRole`)
- IAM role naming: `CodePipeline-<project>-ServiceRole`, `CodeBuild-<project>-ServiceRole`
- SNS topic naming: `<project_name>-pipeline-approvals`

## Pipeline Parameters

Required: `project_name`, `github_repo`, `dev_account_id`, `dev_deployment_role_arn`, `prod_account_id`, `prod_deployment_role_arn`

Optional with defaults: `github_branch` (main), `iac_runtime` (terraform), `iac_version` (latest), `iac_working_directory` ("."), `codestar_connection_arn` (""), `create_state_bucket` (true), `state_bucket` (""), `state_key_prefix` (<project_name>), `sns_subscribers` ([]), `enable_review_gate` (false — controls optional DEV approval), `enable_security_scan` (true — Checkov in Plan actions), `checkov_soft_fail` (false — DEV only; PROD always hard-fails), `codebuild_compute_type` (BUILD_GENERAL1_SMALL), `codebuild_image` (aws/codebuild/amazonlinux-x86_64-standard:5.0), `codebuild_timeout_minutes` (60), `logging_bucket` (""), `logging_prefix` (""), `log_retention_days` (30), `artifact_retention_days` (30), `tags` ({})

Variant-specific: `enable_destroy_approval` (true) — Default-DevDestroy only

## Test Environment

| Account | Account ID | CLI Profile | Purpose |
|---------|-----------|-------------|---------|
| Automation | 389068787156 | `aft-automation` | Pipeline host — all pipeline resources deployed here |
| DEV Target | 914089393341 | `developer-account` | DEV deployment target |
| PROD Target | 264675080489 | `network` | PROD deployment target |

**Test repo:** `OttawaCloudConsulting/terraform-test`, branch `s3-bucket` (deploys without tfvars)

### Cross-Account Role Chain

```
 aft-automation account (389068787156)
├── org-automation-broker-role
│   └── Assumes (role-chain) →
│       ├── org-default-deployment-role (in target accounts)
│       └── application-default-deployment-role (in target accounts)
│
└── CodeBuild-<project>-ServiceRole (created by terraform-pipelines module)
    └── Assumes (direct, first-hop) →
        └── org-default-deployment-role (in target accounts)
```

**Deployment role in target accounts:** `org-default-deployment-role` (under `/org/` IAM path)
- DEV: `arn:aws:iam::914089393341:role/org/org-default-deployment-role`
- PROD: `arn:aws:iam::264675080489:role/org/org-default-deployment-role`

**Important:** Cross-account deployment roles in DEV and PROD accounts are manual prerequisites. Prompt the user when it is time to create them.
