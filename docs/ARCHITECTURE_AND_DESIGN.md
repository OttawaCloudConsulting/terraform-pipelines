# Architecture and Design: Per-Environment Plan-Apply Pipeline

## Overview

This repository provides reusable Terraform modules that provision AWS CodePipeline V2 + CodeBuild CI/CD pipelines for deploying Terraform (or OpenTofu) infrastructure across a multi-account AWS Control Tower environment. Each pipeline instance is 1:1 with a Terraform project.

The pipeline follows a **per-environment plan-apply** model: each environment (DEV, PROD) is a consolidated pipeline stage containing ordered actions — Plan (with environment-specific tfvars and real state), optional Approval, and Deploy (from saved plan). This guarantees that the plan reviewed is exactly the plan applied.

The authoritative requirements are in `prd.md`. The original refinement analysis is in `docs/REFINEMENT_1.md`. The original MVP scope is in `docs/shared/codepipeline-mvp-statement.md`.

### Variant Summary

| Variant | Module Source | Stages | Account Model | Use Case |
|---------|-------------|--------|---------------|----------|
| **Default** | `modules/default/` | 6 | 3 accounts (Automation + DEV + PROD) | Standard cross-account deployment. Also supports single-account when `dev_account_id == prod_account_id`. |
| **Default-DevDestroy** | `modules/default-dev-destroy/` | 7–8 | 3 accounts (Automation + DEV + PROD) | Cross-account with ephemeral DEV teardown after PROD success. |

## Module Architecture

### Shared Core + Overlay Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Consumer Root Module                         │
│                                                                     │
│   module "pipeline" {                                               │
│     source = "modules/<variant>"   # default | default-dev-destroy  │
│     ...                                                             │
│   }                                                                 │
└───────────┬─────────────────────────────────────┬───────────────────┘
            │                                     │
            ▼                                     ▼
┌───────────────────────┐    ┌────────────────────────────────────────┐
│   Variant Wrapper     │    │   Variant Wrapper creates:             │
│   (e.g. default/)     │    │   - CodePipeline V2 (stage config)     │
│                       │    │   - Variant-specific resources         │
│   Calls core module   │    │     (e.g. destroy CodeBuild project)   │
└───────────┬───────────┘    └────────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────────────────────────────────────┐
│                     Core Module (modules/core/)                       │
│                     Internal only — never called directly             │
│                                                                       │
│   Creates:                                                            │
│   - 2 IAM Roles + Policies (CodePipeline SR, CodeBuild SR)            │
│   - S3 State Bucket (conditional) + Artifact Bucket                   │
│   - SNS Approval Topic + Email Subscriptions                          │
│   - CodeStar Connection (conditional)                                 │
│   - 7 CloudWatch Log Groups (prebuild + 6 per-env)                    │
│   - 7 CodeBuild Projects (prebuild + 6 per-env)                       │
│                                                                       │
│   Outputs:                                                            │
│   - All resource ARNs, names, and IDs for variant wiring              │
└───────────────────────────────────────────────────────────────────────┘
```

### Resource Ownership

| Resource | Owner | Count | Notes |
|----------|-------|-------|-------|
| IAM Roles + Policies (x2) | Core | 2 | CodePipeline SR + CodeBuild SR |
| S3 State Bucket (conditional) | Core | 0-1 | Shared state storage |
| S3 Artifact Bucket | Core | 1 | Pipeline artifacts + plan files |
| SNS Approval Topic | Core | 1 | Approval notifications |
| CodeStar Connection (conditional) | Core | 0-1 | GitHub integration |
| CloudWatch Log Groups | Core | 7 | prebuild, plan-dev, plan-prod, deploy-dev, deploy-prod, test-dev, test-prod |
| CodeBuild Projects | Core | 7 | prebuild, plan-dev, plan-prod, deploy-dev, deploy-prod, test-dev, test-prod |
| CodePipeline V2 | Variant | 1 | Stage definitions are variant-specific |
| Destroy CodeBuild Project | Variant (DevDestroy only) | 0-1 | `<project>-destroy` + log group |

### Core Module Outputs

| Output | Type | Purpose |
|--------|------|---------|
| `codebuild_project_names` | `map(string)` | Keys: prebuild, plan-dev, plan-prod, deploy-dev, deploy-prod, test-dev, test-prod |
| `codebuild_service_role_arn` | `string` | For variant-created CodeBuild projects (destroy) |
| `codepipeline_service_role_arn` | `string` | For CodePipeline resource |
| `artifact_bucket_name` | `string` | For CodePipeline artifact store |
| `state_bucket_name` | `string` | Pass-through to consumer |
| `sns_topic_arn` | `string` | For approval actions |
| `codestar_connection_arn` | `string` | For source stage action |
| `log_group_arns` | `map(string)` | Log group ARNs for reference |
| `pipeline_url_prefix` | `string` | AWS Console URL prefix for pipeline URLs |
| `project_name` | `string` | Project name pass-through |
| `dev_account_id` | `string` | DEV account ID pass-through |
| `prod_account_id` | `string` | PROD account ID pass-through |
| `all_tags` | `map(string)` | Merged tags for variant-owned resources |
| `configs_enabled` | `bool` | Whether the configs repo feature is active (true when `configs_repo` is non-empty) |
| `configs_repo_connection_arn` | `string` | Resolved CodeStar Connection ARN for the configs repo (deduped; falls back to IaC repo connection) |

## Variant Architectures

### Default Variant (6 Stages)

```
Source → Pre-Build → DEV [Plan→Approve→Deploy] → Test DEV → PROD [Plan→Approve→Deploy] → Test PROD
```

**Stage 3 (DEV) internal actions:**
```
run_order=1: PlanDEV        (CodeBuild: plan-dev, output: dev_plan_output)
run_order=2: ApproveDEV     (Manual Approval, conditional on enable_review_gate)
run_order=3: DeployDEV      (CodeBuild: deploy-dev, input: dev_plan_output)
```

**Stage 5 (PROD) internal actions:**
```
run_order=1: PlanPROD       (CodeBuild: plan-prod, output: prod_plan_output)
run_order=2: ApprovePROD    (Manual Approval, mandatory, SNS notification)
run_order=3: DeployPROD     (CodeBuild: deploy-prod, input: prod_plan_output)
```

### Default-DevDestroy Variant (7-8 Stages)

```
Source → Pre-Build → DEV [Plan→Approve→Deploy] → Test DEV → PROD [Plan→Approve→Deploy] → Test PROD → [Destroy Approval] → Destroy DEV
```

Stages 1-6 identical to Default. Adds:
- Stage 7 (optional): Destroy Approval — controlled by `enable_destroy_approval` (default: `true`)
- Stage 7/8: Destroy DEV — `terraform destroy` against DEV state via cross-account role

### Cross-Account Credential Flow

```
Automation Account (pipeline host)
└── CodeBuild-<project>-ServiceRole (shared by all 7 projects)
    ├── Instance profile credentials (never overwritten) → S3 state bucket access
    └── Provider assume_role (via _pipeline_override.tf) →
        ├── DEV deployment role  → terraform plan/apply/destroy (provider operations)
        └── PROD deployment role → terraform plan/apply (provider operations)
```

**Provider override credential model:** Buildspecs generate a `_pipeline_override.tf` file at runtime containing `provider "aws" { assume_role { ... } }`. Terraform override files merge with the developer's existing provider block, adding cross-account role assumption without modifying developer code.

- **State operations** (S3 reads/writes, locking) — use the CodeBuild service role's instance profile credentials directly. No `assume_role` in backend config, no `export AWS_*` to overwrite them.
- **Provider operations** (AWS API calls to manage resources) — use the target account deployment role via the provider's `assume_role` attribute, injected by the override file.

The override file is generated via `cat <<'EOF'` + `envsubst` to expand `${TARGET_ROLE}` and `${TARGET_ENV}`, then cleaned up in `post_build`. No STS assume-role calls or exported credentials in buildspecs.

Plan and Deploy actions for the same environment use the same cross-account deployment role via the override file. Plan needs read access for accurate diffs; Deploy needs write access for apply.

## Repository Structure

```
terraform-pipelines/
├── modules/
│   ├── core/                          # Internal shared module
│   │   ├── main.tf                    # CodeBuild projects (x7) + CloudWatch log groups (x7) via for_each
│   │   ├── iam.tf                     # IAM roles + policies (CodePipeline SR, CodeBuild SR)
│   │   ├── storage.tf                 # S3 buckets, SNS topic, subscriptions
│   │   ├── codestar.tf                # CodeStar Connection (conditional)
│   │   ├── variables.tf               # All inputs needed by core resources
│   │   ├── outputs.tf                 # All resource references for variant wrappers
│   │   ├── locals.tf                  # Computed values including project config map
│   │   ├── versions.tf                # Terraform >= 1.11, AWS ~> 6.0
│   │   └── buildspecs/               # Shared buildspec files
│   │       ├── prebuild.yml
│   │       ├── plan.yml               # Per-env plan + security scan
│   │       ├── deploy.yml             # Apply from saved plan
│   │       └── test.yml
│   │
│   ├── default/                       # Default variant wrapper
│   │   ├── main.tf                    # module "core" + CodePipeline (6 stages)
│   │   ├── variables.tf               # Uniform interface
│   │   ├── outputs.tf                 # Uniform outputs
│   │   └── versions.tf
│   │
│   └── default-dev-destroy/           # Default-DevDestroy variant wrapper
│       ├── main.tf                    # module "core" + CodePipeline (7-8 stages) + destroy project
│       ├── variables.tf               # Uniform interface + enable_destroy_approval
│       ├── outputs.tf                 # Uniform outputs
│       ├── versions.tf
│       └── buildspecs/
│           └── destroy.yml            # Variant-specific destroy buildspec
│
├── examples/
│   ├── default/
│   │   ├── minimal/
│   │   ├── complete/
│   │   ├── opentofu/
│   │   ├── single-account/
│   │   └── configs-repo/              # Default variant with configs repo feature
│   ├── default-dev-destroy/
│   │   └── minimal/
│   └── cicd/                          # Developer-managed script templates (copy to your repo)
│       ├── prebuild/main.sh
│       ├── dev/smoke-test.sh
│       └── prod/smoke-test.sh
│
├── tests/
│   ├── test-terraform.sh              # Validation + E2E deploy script (7 gates)
│   ├── default/                       # Default variant E2E test config
│   ├── default-dev-destroy/           # DevDestroy variant E2E test config
│   ├── default-configs/               # Default variant + configs repo E2E test config
│   └── default-dev-destroy-configs/   # DevDestroy + configs repo E2E test config
│
├── docs/
│   ├── ARCHITECTURE_AND_DESIGN.md     # This file
│   ├── REFINEMENT_1.md                # Historical: refinement analysis
│   ├── shared/
│   │   ├── codepipeline-mvp-statement.md
│   │   └── diagrams/
│   ├── default/
│   ├── default-dev-destroy/
│   └── configs-repo/                  # Configs repo feature usage guide
│
├── CLAUDE.md
├── prd.md
├── CHANGELOG.md
└── progress.txt
```

## Buildspec Strategy

### Shared Buildspecs (core)

| Buildspec | Used By | Key Changes |
|-----------|---------|-------------|
| `prebuild.yml` | All variants (Stage 2) | Unchanged — not environment-specific |
| `plan.yml` | All variants (DEV + PROD stages, Plan action) | Rewritten: cross-account role assumption, per-env state, tfvars, integrated Checkov |
| `deploy.yml` | All variants (DEV + PROD stages, Deploy action) | Rewritten: applies saved tfplan artifact instead of re-planning |
| `test.yml` | All variants (Test DEV + Test PROD stages) | Unchanged — already accepts TARGET_ENV |

### Variant-Specific Buildspecs

| Buildspec | Used By | Notes |
|-----------|---------|-------|
| `destroy.yml` | Default-DevDestroy only (Destroy DEV stage) | Unchanged — already targets DEV only |

### plan.yml Flow

```
INSTALL:
  - Install IaC runtime (terraform or opentofu)
  - Install Checkov (if ENABLE_SECURITY_SCAN=true)

BUILD:
  - cd to IAC_WORKING_DIR (anchored to CODEBUILD_SRC_DIR)
  - Assume cross-account role (TARGET_ROLE)
  - terraform init with real env state (${STATE_KEY_PREFIX}/${TARGET_ENV}/terraform.tfstate)
  - terraform plan -out=tfplan [-var-file=environments/${TARGET_ENV}.tfvars]
  - If ENABLE_SECURITY_SCAN=true:
    - terraform show -json tfplan > tfplan.json
    - checkov scan on tfplan.json (soft-fail per CHECKOV_SOFT_FAIL)

ARTIFACTS:
  - tfplan (consumed by Deploy action)
```

### deploy.yml Flow

```
INSTALL:
  - Install IaC runtime (terraform or opentofu)

BUILD:
  - cd to IAC_WORKING_DIR (anchored to CODEBUILD_SRC_DIR)
  - Assume cross-account role (TARGET_ROLE)
  - terraform init with real env state
  - terraform apply tfplan (saved plan from Plan action artifact)
```

## Core Module — for_each Design

The 7 CodeBuild projects and 7 CloudWatch log groups are created via `for_each` over a local configuration map. This eliminates repetitive resource blocks while maintaining clear per-project configuration.

### Project Configuration Map

```hcl
locals {
  codebuild_projects = {
    prebuild = {
      description = "Pre-build stage"
      buildspec   = file("${path.module}/buildspecs/prebuild.yml")
      env_vars    = { PROJECT_NAME = var.project_name, IAC_RUNTIME = var.iac_runtime, IAC_VERSION = var.iac_version }
    }
    plan-dev = {
      description = "Plan DEV environment"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars    = {
        PROJECT_NAME        = var.project_name
        IAC_RUNTIME         = var.iac_runtime
        IAC_VERSION         = var.iac_version
        IAC_WORKING_DIR     = var.iac_working_directory
        STATE_BUCKET        = local.state_bucket_name
        STATE_KEY_PREFIX    = local.state_key_prefix
        TARGET_ENV          = "dev"
        TARGET_ROLE         = var.dev_deployment_role_arn
        ENABLE_SECURITY_SCAN = tostring(var.enable_security_scan)
        CHECKOV_SOFT_FAIL   = tostring(var.checkov_soft_fail)
      }
    }
    plan-prod = {
      description = "Plan PROD environment"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars    = {
        # ... same as plan-dev but:
        TARGET_ENV        = "prod"
        TARGET_ROLE       = var.prod_deployment_role_arn
        CHECKOV_SOFT_FAIL = "false"  # PROD always hard-fails
      }
    }
    deploy-dev = {
      description = "Deploy to DEV environment"
      buildspec   = file("${path.module}/buildspecs/deploy.yml")
      env_vars    = {
        # ... TARGET_ENV = "dev", TARGET_ROLE = var.dev_deployment_role_arn, state config ...
      }
    }
    deploy-prod = { ... }  # TARGET_ENV = "prod"
    test-dev    = { ... }  # TARGET_ENV = "dev"
    test-prod   = { ... }  # TARGET_ENV = "prod"
  }
}
```

### Resource Iteration

```hcl
resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.codebuild_projects
  name              = "/codebuild/${var.project_name}-${each.key}"
  retention_in_days = var.log_retention_days
  tags              = local.all_tags
}

resource "aws_codebuild_project" "this" {
  for_each       = local.codebuild_projects
  name           = "${var.project_name}-${each.key}"
  description    = each.value.description
  service_role   = aws_iam_role.codebuild.arn
  build_timeout  = var.codebuild_timeout_minutes
  # ... environment variables from each.value.env_vars
  # ... logs_config referencing aws_cloudwatch_log_group.this[each.key]
}
```

## Artifact Flow Detail

### Within a Consolidated Environment Stage

```
┌─────────────────────────────────────────────────────────────┐
│ Stage: DEV                                                   │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │ Plan DEV     │    │ Approve DEV  │    │ Deploy DEV   │   │
│  │ run_order=1  │───►│ run_order=2  │───►│ run_order=3  │   │
│  │              │    │ (optional)   │    │              │   │
│  │ output:      │    │              │    │ input:       │   │
│  │ dev_plan_out │    │ BLOCKS until │    │ dev_plan_out │   │
│  └──────────────┘    │ approved     │    └──────────────┘   │
│                      └──────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

The Plan action's `output_artifacts` produces `dev_plan_output` containing the `tfplan` file. The Deploy action's `input_artifacts` consumes `dev_plan_output`. The Approval action (when present) blocks between them.

### Plan Artifact Contents

The plan artifact contains only the `tfplan` binary file. The `tfplan.json` and `checkov-report.xml` are consumed within the Plan action and not passed downstream.

```yaml
# plan.yml artifacts section
artifacts:
  files:
    - tfplan
  base-directory: "${IAC_WORKING_DIR}"  # or CODEBUILD_SRC_DIR/IAC_WORKING_DIR
  discard-paths: "yes"
```

## Security Model

### Checkov Scan Policy

| Environment | `enable_security_scan=true` | `checkov_soft_fail=true` | `checkov_soft_fail=false` |
|-------------|---------------------------|-------------------------|--------------------------|
| DEV | Scan runs, soft-fail (advisory) | Scan runs, soft-fail | Scan runs, hard-fail |
| PROD | Scan runs, **always hard-fail** | Scan runs, **always hard-fail** | Scan runs, hard-fail |

When `enable_security_scan=false`, neither environment runs the Checkov scan.

### Encryption

- S3 artifact bucket: SSE-S3 encryption, SSL-only policy, Block Public Access
- S3 state bucket: SSE-S3 encryption, versioning enabled, SSL-only policy
- Plan artifacts (tfplan files): same SSE-S3 protection as all pipeline artifacts
- SNS topic: KMS encryption

### IAM Least Privilege

- CodeBuild service role: scoped to specific deployment role ARNs, specific S3 buckets, specific log groups
- CodePipeline service role: scoped to specific CodeBuild projects, specific S3 buckets, specific SNS topics
- Cross-account deployment roles: pre-existing, not managed by pipeline

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Per-environment plan-apply flow | Guarantees the plan reviewed is the plan applied. Eliminates drift between review and deploy. |
| 2 | Consolidated stages with run_order | Reduces stage count (9→6). Each environment is a logical unit. Approval action blocks deploy within the same stage. |
| 3 | Deploy re-initializes then applies plan | Plan artifact carries only tfplan file (small). Deploy runs terraform init independently for clean backend setup. Avoids large artifacts with .terraform directory. |
| 4 | for_each for CodeBuild projects + log groups | 7 projects defined via local config map instead of 7 repetitive resource blocks. Easier to maintain and extend. |
| 5 | Per-environment CodeBuild projects | Required for per-environment CloudWatch log groups. Log group is set on the project, not per build invocation. |
| 6 | Core loads its own buildspecs | Core uses `file("${path.module}/buildspecs/...")`. Variants that need different buildspecs (destroy) create their own projects outside core. Keeps core interface clean. |
| 7 | One shared CodeBuild IAM service role | All 7 projects share one role. Same permissions needed (STS AssumeRole to both DEV and PROD deployment roles). No benefit to separate roles. |
| 8 | PROD Checkov always hard-fails | `checkov_soft_fail` controls DEV only. PROD security scan is never advisory. Prevents accidental production deployment with security findings. |
| 9 | `enable_security_scan` defaults to true | Secure by default. Consumers opt out explicitly. |
| 10 | `enable_review_gate` repurposed for DEV | PROD approval is always mandatory. The existing toggle now controls the optional DEV approval action within the DEV stage. |
| 11 | Remove throwaway plan state path | The `plan/terraform.tfstate` path served no purpose beyond initializing providers for the old environment-agnostic plan. Per-env plans use real state. |
| 12 | Always proceed on empty plan | Even with zero changes, pipeline runs through Approve and Deploy (apply is a no-op). Avoids custom logic to signal downstream actions. Consistent flow. |
| 13 | No moved blocks | Clean implementation without migration baggage. |
| 14 | Artifact contains tfplan only | Deploy needs only the saved plan. JSON and Checkov report are consumed within the Plan action. Smaller artifact. |
| 15 | Keep current file layout | main.tf (CodeBuild + logs), iam.tf, storage.tf, codestar.tf. Minimal diff, familiar structure. |
| 16 | Provider override file for cross-account access | Buildspecs generate `_pipeline_override.tf` at runtime with `provider "aws" { assume_role { ... } }`. Terraform merges this with the developer's provider block, injecting cross-account role assumption transparently. No `aws sts assume-role` or `export AWS_*` in buildspecs. |
| 17 | Instance profile credentials for S3 backend | CodeBuild service role instance profile credentials handle S3 state access directly. No `assume_role` in backend config, no self-assumption needed. Simpler trust policy (only `codebuild.amazonaws.com`). |
| 18 | envsubst for override file generation | Override file written with `cat <<'EOF'` (no shell expansion) then `envsubst` expands `${TARGET_ROLE}` and `${TARGET_ENV}`. Cleanup via `rm -f` in `post_build`. |
| 19–30 | Original design decisions preserved | See `docs/shared/` for decisions from the original architecture (encryption, conditional resources, validation, tags, etc.) |

## Dependency Graph

### Resource Creation Order

```
1. Independent (parallel):
   ├── S3 State Bucket (conditional)
   ├── S3 Artifact Bucket
   ├── SNS Topic + Subscriptions
   ├── CodeStar Connection (conditional)
   └── CloudWatch Log Groups (x7)

2. Depends on buckets + log groups:
   └── IAM Roles + Policies (x2)
       ├── References: bucket ARNs, log group ARNs, deployment role ARNs
       └── References: additional_codebuild_project_arns, additional_log_group_arns

3. Depends on IAM roles + log groups:
   └── CodeBuild Projects (x7)
       ├── References: codebuild service role ARN
       └── References: log group names

4. Depends on core outputs (variant-owned):
   ├── Destroy CodeBuild Project (DevDestroy only)
   └── Destroy CloudWatch Log Group (DevDestroy only)

5. Depends on everything above:
   └── CodePipeline V2
       ├── References: codebuild project names
       ├── References: codepipeline service role ARN
       ├── References: artifact bucket name
       ├── References: codestar connection ARN
       └── References: sns topic ARN
```

## Test Environment

To run E2E tests, you need three AWS accounts with cross-account deployment roles:

| Account | Purpose |
|---------|---------|
| Automation | Pipeline host — all pipeline resources deployed here |
| DEV Target | DEV deployment target |
| PROD Target | PROD deployment target |

Four test configurations exist, one per variant + feature combination:

| Test Directory | Variant + Feature | `--deploy` target |
|----------------|-------------------|-------------------|
| `tests/default/` | Default | `--deploy default` |
| `tests/default-dev-destroy/` | Default-DevDestroy | `--deploy default-dev-destroy` |
| `tests/default-configs/` | Default + configs repo | `--deploy default-configs` |
| `tests/default-dev-destroy-configs/` | DevDestroy + configs repo | `--deploy default-dev-destroy-configs` |

Configure test values in `tests/<variant>/terraform.tfvars` (copy from `terraform.tfvars.example`). Set `AWS_PROFILE` to the Automation Account CLI profile before running `--deploy`.

## Out of Scope

| Item | Rationale |
|------|-----------|
| Deployment roles in target accounts | Prerequisite. Not managed by pipeline. |
| Custom Docker images | Standard images + inline install. |
| More than two environments | Each pipeline deploys to DEV and PROD only. |
| Core module as public API | Consumers must use variant wrappers. |
| Customer-managed KMS keys | SSE-S3 sufficient for artifact encryption. |
| Empty plan short-circuiting | Always proceed through Approve and Deploy. |
| Migration tooling / moved blocks | Not needed — clean implementation. |

## Configs Repo Feature

The configs repo feature allows `.tfvars` files to live in a dedicated repository, separate from the IaC repo. When enabled, plan and destroy actions source tfvars exclusively from the configs repo instead of the IaC repo. The pipeline triggers on push to either repository. This feature is entirely optional — when no configs repo is specified, the pipeline behaves identically to the base behavior.

### New Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `configs_repo` | `string` | `""` | GitHub repository in `org/repo` format containing tfvars files. When empty, tfvars are sourced from the IaC repo (default behavior). |
| `configs_repo_branch` | `string` | `"main"` | Branch of the configs repo to track. |
| `configs_repo_path` | `string` | `"."` | Path within configs repo where the `environments/` directory is located. Must be `"."` or a relative path without `..`, leading/trailing slashes, or absolute paths. |
| `configs_repo_codestar_connection_arn` | `string` | `""` | CodeStar Connection ARN for the configs repo. When empty, reuses the IaC repo's connection. Must be provided when the configs repo is in a different GitHub organization. |

### Source Stage Changes

When `configs_repo` is non-empty, the Source stage gains a second `CodeStarSourceConnection` action alongside the existing IaC repo action:

```
Source stage (configs_repo enabled):
  Action 1: checkout IaC repo     → artifact: source_output   (unchanged)
  Action 2: checkout configs repo → artifact: configs_output  (new)
```

Both actions have `DetectChanges = "true"`, so the pipeline triggers on push to either repository. The configs artifact is output in `CODE_ZIP` format. When `configs_repo = ""`, the Source stage is identical to the base implementation.

### Artifact Flow

Plan and Destroy actions receive `configs_output` as a secondary input artifact. CodeBuild exposes it at `$CODEBUILD_SRC_DIR_configs_output`. The `PrimarySource` is explicitly set to `source_output` (IaC repo) so the CodeBuild working directory defaults to the IaC source.

```
Plan-DEV / Plan-PROD / Destroy-DEV (configs enabled):
  input_artifacts: [source_output, configs_output]
  PrimarySource:   source_output

Deploy-DEV / Deploy-PROD / Test-DEV / Test-PROD / Pre-Build:
  unchanged — configs artifact not wired
```

Deploy and Test actions are not wired to the configs artifact. Deploy applies the saved `tfplan` binary (no tfvars resolution needed at apply time). Test scripts are developer-managed and unaffected.

### Buildspec Changes

`plan.yml` and `destroy.yml` use the `CONFIGS_ENABLED` and `CONFIGS_PATH` environment variables (baked into the CodeBuild project by core locals) to conditionally source tfvars:

```
When CONFIGS_ENABLED=true:
  Validate configs artifact directory exists and is non-empty (hard fail if missing)
  Resolve: ${CODEBUILD_SRC_DIR_configs_output}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars
  Validate resolved path stays within configs artifact directory (path traversal prevention)
  If file exists: pass -var-file to terraform plan/destroy
  If file missing: proceed without -var-file (graceful — same as base behavior)

When CONFIGS_ENABLED=false (or unset):
  Resolve: environments/${TARGET_ENV}.tfvars  (relative to IaC working directory)
  If file exists: pass -var-file to terraform plan/destroy
  If file missing: proceed without -var-file  (unchanged base behavior)
```

`CONFIGS_ENABLED` defaults to `"false"` when unset, making manual CodeBuild triggers safe. `prebuild.yml`, `deploy.yml`, and `test.yml` are unchanged.

### IAM Policy

When the configs repo uses a different CodeStar Connection than the IaC repo, both ARNs are included in the `CodeStarConnectionAccess` IAM policy statements for both the CodePipeline and CodeBuild service roles. When both repos share the same connection, the policy is unchanged — a single ARN after `distinct()` deduplication.

### Known Limitations

1. **Toggle unsupported** — toggling `configs_repo` on/off on an existing pipeline may force-replace the CodePipeline resource due to the change in Source stage action count. This is a prerequisite decision before first deployment, not a runtime toggle.
2. **Shared configs repo triggers all referencing pipelines** — a push to a shared configs repo triggers every pipeline that references it, not only those whose `configs_repo_path` subtree changed. Use per-project paths (via `configs_repo_path`) to scope changes, but triggering is still repo-wide.
3. **Version skew risk** — because either repo push can trigger the pipeline independently, a coordinated IaC + config change may run with mismatched versions. Best practice: merge IaC changes first, then config changes.
4. **Execution mode** — the pipeline uses `SUPERSEDED` execution mode. A new trigger supersedes in-progress executions, which can cause partially-applied plans to be discarded.
5. **Cross-org connection not auto-detected** — if the configs repo is in a different GitHub organization, the consumer must explicitly provide `configs_repo_codestar_connection_arn`. The module does not detect or validate cross-org usage at plan time; the pipeline will fail at runtime with a CodeStar Connections error if the wrong connection is used.
