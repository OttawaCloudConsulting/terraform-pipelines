# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **multi-variant Terraform pipeline template** using AWS CodePipeline V2 and CodeBuild. It deploys Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each pipeline instance is 1:1 with a Terraform project.

**Variants:**
- **Default** (`modules/default/`) — 9-stage cross-account pipeline. Also supports single-account when `dev_account_id == prod_account_id`.
- **Default-DevDestroy** (`modules/default-dev-destroy/`) — 10-11 stages. Default + destroy DEV after PROD tests pass. `enable_destroy_approval` (default: `true`) controls manual approval gate.

The authoritative design documents are `prd.md` (requirements), `docs/ARCHITECTURE_AND_DESIGN.md` (architecture), and `docs/shared/codepipeline-mvp-statement.md` (original MVP statement). Implementation progress is tracked in `progress.txt`.

## Architecture

**Three-account model:**
- **Automation Account** — hosts CodePipeline, CodeBuild, S3 state bucket, SNS topics, IAM service roles, CodeStar Connection
- **DEV Target Account** — receives DEV deployments via cross-account IAM role assumption
- **PROD Target Account** — receives PROD deployments via cross-account IAM role assumption

**Shared Core + Overlay Pattern:**
- `modules/core/` — internal shared module (IAM, S3, SNS, CodeBuild, CloudWatch). Never called directly by consumers.
- `modules/default/` and `modules/default-dev-destroy/` — variant wrappers that call core and define their own CodePipeline.

**Pipeline stages (Default, 9 total):**
1. Source (GitHub via CodeStar Connection)
2. Pre-Build — executes `cicd/prebuild/main.sh` (developer-managed)
3. Plan + Security Scan — `terraform plan` + checkov scan, outputs artifacts
4. Optional Review — manual approval gate
5. Deploy DEV — `terraform apply` via cross-account role assumption
6. Test DEV — executes `cicd/dev/smoke-test.sh` (developer-managed)
7. Mandatory Approval — SNS notification, human approval required
8. Deploy PROD — `terraform apply` via cross-account role assumption
9. Test PROD — executes `cicd/prod/smoke-test.sh` (developer-managed)

**Default-DevDestroy adds:**
10. Optional Destroy Approval — manual gate (when `enable_destroy_approval = true`)
11. Destroy DEV — `terraform destroy` via cross-account role

**Cross-account credential flow:** CodeBuild service role → `sts:AssumeRole` (first-hop, no chaining limit) → target account deployment role. Deployment roles are NOT created by the pipeline — they must pre-exist and their ARNs are passed as parameters.

**State management:** S3 backend in Automation Account with native S3 locking (`use_lockfile = true`). No DynamoDB. State keys follow `<project>/<env>/terraform.tfstate` pattern. Requires Terraform 1.11+.

## Module Structure

```
modules/
  core/              # Internal shared module — DO NOT call directly
    main.tf          # 4 CloudWatch log groups, 4 CodeBuild projects
    iam.tf           # CodePipeline + CodeBuild IAM roles/policies (extensible)
    storage.tf       # S3 state bucket (conditional), artifact bucket, SNS topic
    codestar.tf      # CodeStar Connection (conditional)
    variables.tf     # All inputs + additional_codebuild_project_arns/additional_log_group_arns
    outputs.tf       # All resource references for variant wrappers
    buildspecs/      # Shared: prebuild.yml, plan.yml, deploy.yml, test.yml

  default/           # Default variant — 9-stage pipeline
    main.tf          # module "core" + CodePipeline V2 + moved blocks (28)
    variables.tf     # Uniform interface (19 vars)
    outputs.tf       # Uniform outputs (11)

  default-dev-destroy/  # DevDestroy variant — 10-11 stages
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
- Buildspecs gracefully handle missing var files — check if `environments/${TARGET_ENV}.tfvars` exists before passing `-var-file`

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

Optional with defaults: `github_branch` (main), `iac_runtime` (terraform), `iac_version` (latest), `codestar_connection_arn` (""), `create_state_bucket` (true), `state_bucket` (""), `state_key_prefix` (<project_name>), `sns_subscribers` ([]), `enable_review_gate` (false), `codebuild_compute_type` (BUILD_GENERAL1_SMALL), `codebuild_image` (aws/codebuild/amazonlinux-x86_64-standard:5.0), `checkov_soft_fail` (false), `codebuild_timeout_minutes` (60), `logging_bucket` (""), `logging_prefix` (""), `log_retention_days` (30), `artifact_retention_days` (30), `tags` ({})

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
