# PRD: Multi-Variant Terraform Pipeline Repository

## Summary

Restructure the terraform-pipelines repository from a single monolithic pipeline module into a multi-variant architecture. A shared core module provides common CodePipeline/CodeBuild infrastructure, while variant-specific wrapper modules compose the core differently to serve distinct deployment patterns. The existing 9-stage pipeline becomes the "default" variant.

## Goals

- **Reuse across teams** — Different teams need different pipeline complexities; one repo provides all options
- **Right-size pipelines** — Not every project needs the full 9-stage cross-account pipeline; variants reduce blast radius and operational overhead
- **Shared core** — Common infrastructure (IAM, S3, CodeBuild, logging) is defined once and composed by variants, eliminating duplication
- **Backward compatibility** — The "default" variant must produce identical resources to the current monolithic module

## Variants

### 1. Default

The existing 9-stage pipeline: Source > Pre-Build > Plan+Scan > Optional Review > Deploy DEV > Test DEV > Mandatory Approval > Deploy PROD > Test PROD. Cross-account deployment to separate DEV and PROD accounts. Also supports single-account deployment when `dev_account_id == prod_account_id` (environment isolation via state keys).

**Stages:** 9 (same as current monolithic module)
**Account model:** Three accounts (Automation, DEV, PROD) — or two accounts for single-account use
**Module source:** `modules/default/`

### 2. Default-DevDestroy

Same as Default (9 stages, cross-account), plus a 10th stage that runs `terraform destroy` against the DEV environment after PROD smoke tests pass. An `enable_destroy_approval` variable (default: true) controls whether a manual approval gate is required before the destroy executes.

**Stages:** 10–11 (9 Default + Destroy DEV + optional Destroy Approval)
**Account model:** Three accounts (Automation, DEV, PROD)
**Module source:** `modules/default-dev-destroy/`

## Architecture

### Shared Core + Overlay Pattern

```
modules/
  core/              # Internal-only shared module (not consumer-facing)
    main.tf          # CodeBuild projects, CloudWatch log groups
    iam.tf           # CodePipeline + CodeBuild IAM roles and policies
    storage.tf       # S3 state bucket (conditional), artifact bucket, SNS topic
    codestar.tf      # CodeStar Connection (conditional)
    variables.tf     # Superset of all inputs needed by core resources
    outputs.tf       # All resource references needed by variant wrappers
    locals.tf        # Computed values
    versions.tf      # Provider constraints
    buildspecs/      # Shared buildspec files (prebuild.yml, plan.yml, deploy.yml, test.yml)

  default/           # Variant wrapper — current 9-stage pipeline
    main.tf          # Calls modules/core, defines CodePipeline with 9 stages
    variables.tf     # Consumer-facing inputs (passes through to core)
    outputs.tf       # Consumer-facing outputs (passes through from core)
    versions.tf

  default-dev-destroy/  # Variant wrapper — default + DEV destroy stage
    main.tf          # Calls modules/core, defines CodePipeline with 10-11 stages
                     # Also creates 5th CodeBuild project (destroy) + log group
    variables.tf     # Uniform interface + enable_destroy_approval
    outputs.tf
    buildspecs/      # Variant-specific: destroy.yml
    versions.tf
```

**Core module is internal only** — consumers never call `modules/core/` directly. They always use a variant wrapper.

**Buildspec strategy:** Shared buildspecs live in `modules/core/buildspecs/`. Variants can override specific buildspecs by placing them in their own `buildspecs/` directory (e.g., `modules/default-dev-destroy/buildspecs/destroy.yml`).

**IAM extensibility:** Core IAM policies (CodePipeline and CodeBuild roles) cover the 4 core-owned CodeBuild projects and log groups. Variants that create additional resources (e.g., a destroy CodeBuild project + log group) pass their ARNs to core via `additional_codebuild_project_arns` and `additional_log_group_arns` optional variables. Core merges these into its IAM policies, ensuring all variant-owned resources have proper permissions without supplemental policy attachments.

### Repository Root Structure (Post-Restructure)

```
terraform-pipelines/
  modules/              # All module code lives here
    core/
    default/
    default-dev-destroy/
  examples/             # Per-variant example configurations
    default/
      minimal/
      complete/
      opentofu/
    default-dev-destroy/
      minimal/
  tests/                # Per-variant test suites
    default/
    default-dev-destroy/
  docs/                 # Documentation (nested by variant)
    ARCHITECTURE_AND_DESIGN.md  # High-level multi-variant architecture
    codepipeline-mvp-statement.md
    shared/               # Core module docs + shared diagrams
      diagrams/
    default/              # Default variant docs (includes single-account usage guide)
    default-dev-destroy/  # Default-dev-destroy variant docs
  CLAUDE.md
  README.md
  CHANGELOG.md
  prd.md
  progress.txt
  .gitignore
```

Root-level Terraform files (main.tf, iam.tf, etc.) are moved into `modules/`. The repository root is clean — only docs, examples, tests, and module directories.

## Non-Goals

- **Custom Docker images** — MVP uses standard CodeBuild managed images only
- **More than two environments per pipeline** — Each pipeline deploys to DEV and PROD (or DEV and PROD within one account). Three-environment pipelines (dev/staging/prod) are out of scope.
- **Core module as public API** — The core module is an internal building block. Consumers must use variant wrappers.
- **Dynamic stage composition** — Variants have fixed stage structures. No runtime stage selection via variables (beyond existing toggles like `enable_review_gate`).
- **Cross-variant migration tooling** — No automated tooling to migrate a pipeline from one variant to another (consumers re-deploy with the new variant).
- **Deployment role management** — Deployment roles in target accounts remain manual prerequisites, not managed by any variant.
- **Separate single-account variant** — Single-account deployment is supported by the Default variant when `dev_account_id == prod_account_id`. A dedicated variant module is not warranted since the pipeline logic is identical.

## Input Variables (Uniform Interface)

All variants expose the same base variable interface for consistency. Variant-specific variables are additive.

### Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `project_name` | `string` | Name of the Terraform project. Used in all resource names. 3-34 chars, lowercase alphanumeric + hyphens. |
| `github_repo` | `string` | GitHub repository in `org/repo` format. |
| `dev_account_id` | `string` | 12-digit AWS Account ID for the DEV environment. |
| `dev_deployment_role_arn` | `string` | ARN of the IAM role in the DEV account for deployment. |
| `prod_account_id` | `string` | 12-digit AWS Account ID for the PROD environment. |
| `prod_deployment_role_arn` | `string` | ARN of the IAM role in the PROD account for deployment. |

### Optional Variables (Base — All Variants)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `github_branch` | `string` | `"main"` | Branch to trigger pipeline. |
| `iac_runtime` | `string` | `"terraform"` | `terraform` or `opentofu`. |
| `iac_version` | `string` | `"latest"` | Version of IaC tool to install. |
| `codestar_connection_arn` | `string` | `""` | Existing CodeStar Connection ARN. Empty = create new. |
| `create_state_bucket` | `bool` | `true` | Whether to create S3 state bucket. |
| `state_bucket` | `string` | `""` | Existing S3 bucket name (required when `create_state_bucket` is false). |
| `state_key_prefix` | `string` | `""` | S3 key prefix for state. Defaults to `project_name`. |
| `sns_subscribers` | `list(string)` | `[]` | Email addresses for approval notifications. |
| `enable_review_gate` | `bool` | `false` | Optional review approval stage (Stage 4). |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | CodeBuild compute type. |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | CodeBuild managed image. |
| `checkov_soft_fail` | `bool` | `false` | Checkov findings as warnings only. |
| `codebuild_timeout_minutes` | `number` | `60` | Build timeout (5-480 minutes). |
| `logging_bucket` | `string` | `""` | S3 bucket for access logs. Empty = disabled. |
| `logging_prefix` | `string` | `""` | S3 key prefix for access logs. |
| `log_retention_days` | `number` | `30` | CloudWatch log retention. |
| `artifact_retention_days` | `number` | `30` | S3 artifact lifecycle expiry. |
| `tags` | `map(string)` | `{}` | Additional tags for all resources. |

### Variant-Specific Variables

| Variant | Variable | Type | Default | Description |
|---------|----------|------|---------|-------------|
| Default-DevDestroy | `enable_destroy_approval` | `bool` | `true` | Require manual approval before DEV destroy. Set to `false` to auto-destroy after PROD tests pass. |

## Outputs (Uniform Interface)

All variants expose the same outputs:

| Output | Type | Description |
|--------|------|-------------|
| `pipeline_arn` | `string` | ARN of the CodePipeline. |
| `pipeline_url` | `string` | AWS Console URL for the pipeline. |
| `codebuild_project_names` | `map(string)` | Map of CodeBuild project names. |
| `codebuild_service_role_arn` | `string` | ARN of the CodeBuild service role. |
| `codepipeline_service_role_arn` | `string` | ARN of the CodePipeline service role. |
| `sns_topic_arn` | `string` | ARN of the approval SNS topic. |
| `artifact_bucket_name` | `string` | Name of the artifact bucket. |
| `state_bucket_name` | `string` | Name of the state bucket. |
| `codestar_connection_arn` | `string` | ARN of the CodeStar Connection. |
| `dev_account_id` | `string` | DEV account ID (pass-through). |
| `prod_account_id` | `string` | PROD account ID (pass-through). |

## Features

### Feature 1: Core Module Extraction and Repository Restructure

Move existing root-level Terraform files into `modules/core/` and establish the new directory structure. Refactor the shared infrastructure into a self-contained internal module. Create an empty module skeleton for `modules/default-dev-destroy/`.

**Acceptance criteria:**
- Root-level `.tf` files moved to appropriate module directories
- `modules/core/` creates: 2 IAM roles + policies, S3 state bucket (conditional), S3 artifact bucket, SNS topic, CodeStar Connection (conditional), 4 CloudWatch log groups, 4 CodeBuild projects
- Core IAM policies accept optional `additional_codebuild_project_arns` and `additional_log_group_arns` inputs to support variant-owned resources
- Core accepts all necessary inputs via variables
- Core exposes all resource references needed by variant wrappers via outputs
- Core does NOT create the CodePipeline resource (variants own that)
- `buildspecs/` moved to `modules/core/buildspecs/`
- `modules/default-dev-destroy/` skeleton exists
- Repository root is clean (no `.tf` files except potentially a root `versions.tf` for tooling)
- `terraform validate` passes for the core module in isolation

### Feature 2: Default Variant — Wrapper Module

Create `modules/default/` as a wrapper that calls `modules/core/` and defines the 9-stage CodePipeline.

**Acceptance criteria:**
- Calls `modules/core/` passing all required inputs
- Defines CodePipeline V2 with 9 stages (identical to current implementation)
- Exposes uniform variable interface (all base variables)
- Exposes uniform output interface
- Includes `moved` blocks (or equivalent migration strategy) so existing users of the root module can migrate without resource destruction
- Supports single-account deployment when `dev_account_id == prod_account_id`
- `terraform validate` passes
- Produces functionally identical resources to the current monolithic module

### Feature 3: Default-DevDestroy Variant — Wrapper Module

Create `modules/default-dev-destroy/` with a DEV teardown stage.

**Acceptance criteria:**
- Calls `modules/core/` passing all required inputs
- Creates a 5th CodeBuild project (`destroy`) and dedicated CloudWatch log group (variant-owned, not in core)
- Passes destroy CodeBuild project ARN and destroy log group ARN to core via `additional_codebuild_project_arns` and `additional_log_group_arns`
- Defines CodePipeline V2 with 10 stages (9 Default + Destroy DEV after PROD test)
- When `enable_destroy_approval = true` (the default), includes a manual approval stage before destroy
- When `enable_destroy_approval = false`, destroy runs automatically after PROD tests pass
- Destroy stage runs `terraform destroy` against DEV environment via cross-account role
- Destroy buildspec located at `modules/default-dev-destroy/buildspecs/destroy.yml`
- Destroy CodeBuild project uses the same CodeBuild service role from core (no separate restricted role)
- If the destroy stage fails, the pipeline execution shows as Failed and the DEV environment remains intact
- Uniform variable interface + `enable_destroy_approval`
- Uniform output interface
- `terraform validate` passes

### Feature 4: Destroy Buildspec

Create the `destroy.yml` buildspec for the Default-DevDestroy variant.

**Acceptance criteria:**
- Installs IaC runtime (terraform or opentofu)
- IaC installation logic must be kept consistent with the equivalent logic in core buildspecs (deploy.yml)
- Assumes cross-account DEV deployment role via `sts:AssumeRole`
- Initializes Terraform with DEV state key
- Runs `terraform destroy -auto-approve`
- Handles var-file gracefully (checks if `environments/dev.tfvars` exists)
- Uses `set -euo pipefail` for safety

### Feature 5: Per-Variant Examples

Create example configurations for each variant.

**Acceptance criteria:**
- `examples/default/minimal/` — minimal required variables only
- `examples/default/complete/` — all variables with production overrides
- `examples/default/opentofu/` — OpenTofu runtime example
- `examples/default/single-account/` — same-account deployment example (`dev_account_id == prod_account_id`)
- `examples/default-dev-destroy/minimal/` — minimal dev-destroy example
- All examples pass `terraform init && terraform validate && terraform fmt -check`

### Feature 6: Per-Variant Tests

Create test configurations for each variant.

**Acceptance criteria:**
- `tests/default/main.tf` — validates default variant
- `tests/default-dev-destroy/main.tf` — validates dev-destroy variant
- All tests pass `terraform init && terraform validate`

### Feature 7: Documentation Restructure

Restructure all documentation into a nested directory format and update content for the multi-variant architecture.

**Acceptance criteria:**
- `docs/` root contains high-level `ARCHITECTURE_AND_DESIGN.md` covering multi-variant overview
- `docs/shared/` contains core module documentation and `docs/shared/diagrams/` contains all shared diagrams (moved from `docs/diagrams/`)
- `docs/default/` contains default variant-specific documentation, including a single-account usage guide
- `docs/default-dev-destroy/` contains default-dev-destroy variant-specific documentation
- `CLAUDE.md` updated with new module structure, variant descriptions, consumer usage patterns, and corrected `state_bucket` documentation (optional, not required)
- `README.md` updated with variant overview, usage examples, directory structure
- `CHANGELOG.md` updated with restructuring entry
- Migration guide for existing monolithic module users (exact steps or `moved` block documentation)
- Existing feature docs and working docs moved to appropriate subdirectories

## Security Considerations

- All existing security controls (S3 encryption, SSL-only policies, public access blocks, checkov scanning, IAM least privilege) are preserved in the core module
- The destroy buildspec uses the same cross-account role assumption pattern — no elevated permissions
- The `enable_destroy_approval` gate defaults to `true` (safe by default) — teams must explicitly opt out to enable auto-destroy
- No new IAM roles are introduced for the destroy stage (reuses CodeBuild service role)
- Core IAM policies are extensible via `additional_codebuild_project_arns` and `additional_log_group_arns` inputs, ensuring variant-owned resources have proper permissions without overly broad wildcards

## Cost Implications

- No cost increase for existing Default variant users (~$2.65/month per pipeline)
- Default-DevDestroy variant adds one additional CodeBuild execution per pipeline run (destroy stage) — marginal cost increase
- Core module consolidation does not change resource count per pipeline instance
