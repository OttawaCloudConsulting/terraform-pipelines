# PRD: Discrete Configs Repository Support

**GitHub Issue:** [#8 — Support discrete configs repo](https://github.com/OttawaCloudConsulting/terraform-pipelines/issues/8)
**Date:** 2026-02-22
**Status:** Draft
**Source Documents:**
- [Problem Statement](./docs/issue-8/PROBLEM-STATEMENT.md)
- [MVP Statement](./docs/issue-8/MVP.md)
- [Technical Design](./docs/issue-8/MVP-DESIGN.md)
- [Consolidated Red Team Review](./docs/issue-8/mvp-design-redteam/CONSOLIDATED-REVIEW.md)
- [Architecture and Design](./docs/ARCHITECTURE_AND_DESIGN.md)

---

## Summary

Add an optional second source repository ("configs repo") to the Terraform pipeline template. When enabled, `.tfvars` files are sourced exclusively from the configs repo instead of the IaC repo. The pipeline triggers on push to either repository. The feature is entirely optional — when no configs repo is specified, the pipeline behaves identically to today.

## Goals

- **Separate configuration from code** — allow `.tfvars` files to live in a dedicated repository, decoupled from infrastructure modules
- **Independent change velocity** — config-only changes (scaling parameters, feature flags, account IDs) run the pipeline without touching the IaC repo
- **Audit separation** — distinct commit histories for code vs. configuration to support compliance requirements
- **Reuse** — a single IaC module repo can serve multiple projects/teams, each with their own configs repo
- **Backward compatibility** — zero behavioral change for existing consumers who do not enable the feature

## Architecture

The feature extends the existing Shared Core + Overlay module pattern:

- **Core module** gains: new variables, computed locals, updated IAM policies, CodeBuild environment variables, buildspec conditional logic, and two new outputs for variant wiring
- **Variant modules** gain: pass-through variables, conditional second source action in CodePipeline, and configs artifact wiring to plan (and destroy) actions
- **No changes** to: prebuild, deploy, or test buildspecs; S3/SNS/CloudWatch resources; codestar.tf; variant-level outputs

Pipeline source stage conditionally includes a second `CodeStarSourceConnection` action. Plan and destroy CodeBuild actions receive the configs artifact as a secondary input (`$CODEBUILD_SRC_DIR_configs_output`).

## Non-Goals

| Item | Rationale |
|------|-----------|
| Merging tfvars from both repos | MVP uses exclusive sourcing. Overlay/merge is post-MVP. |
| Non-GitHub configs repos | Pipeline uses CodeStar Connections (GitHub only). |
| Configs repo content validation | Missing files handled gracefully by existing buildspec logic. |
| Per-environment configs repos | Single configs repo serves both DEV and PROD. |
| Configs repo webhook management | CodePipeline V2 handles change detection natively. |
| Toggle support (on/off on existing pipelines) | Single-repo vs. dual-repo is a prerequisite decision before first deployment. Toggling is at consumer's risk. |
| Repository governance (branch protection, access controls) | Consumer responsibility, not managed by the pipeline module. |

## Implementation Order

Features are implemented sequentially (1 through 8). Each feature builds on the previous:

| Phase | Features | Dependency |
|-------|----------|------------|
| Core foundation | 1, 2, 3 | None — core module changes |
| Core buildspec | 4 | Requires Feature 3 (env vars) |
| Default variant | 5 | Requires Features 1-4 (core complete) |
| DevDestroy variant | 6 | Requires Feature 5 (default pattern) |
| Testing | 7 | Requires Features 1-6 (all code complete) |
| Documentation | 8 | Requires Feature 7 (tests pass) |

## Features

### Feature 1: Core Module — Variables, Locals, and Outputs

Add 4 new optional variables (`configs_repo`, `configs_repo_branch`, `configs_repo_path`, `configs_repo_codestar_connection_arn`) with plan-time validation. Add computed locals (`configs_enabled`, `configs_repo_connection_arn`, `all_codestar_connection_arns`). Add two new outputs for variant wiring.

**Acceptance Criteria:**
- All 4 variables declared in `modules/core/variables.tf` with types, descriptions, defaults, and validation blocks
- `configs_repo` validates `org/repo` format (or empty)
- `configs_repo_branch` validates non-empty
- `configs_repo_path` validates against path traversal (`..`), absolute paths, and special characters
- `configs_repo_codestar_connection_arn` validates ARN format (or empty)
- `locals.tf` computes `configs_enabled`, resolves connection ARN with fallback to IaC repo connection
- `all_codestar_connection_arns` uses `distinct()` to deduplicate
- `outputs.tf` exposes `configs_enabled` and `configs_repo_connection_arn`
- When `configs_repo = ""`, all locals evaluate to inactive defaults

### Feature 2: Core Module — IAM Policy Updates

Update CodePipeline and CodeBuild IAM policies to authorize the configs repo's CodeStar Connection.

**Acceptance Criteria:**
- `CodeStarConnectionAccess` statement in CodePipeline service role policy uses `local.all_codestar_connection_arns`
- `CodeStarConnectionAccess` statement in CodeBuild service role policy uses `local.all_codestar_connection_arns`
- When configs repo uses the same connection, IAM policy is unchanged (single ARN via `distinct()`)
- When configs repo uses a different connection, IAM policy includes both ARNs
- No new IAM roles or cross-account changes

### Feature 3: Core Module — CodeBuild Environment Variables

Add `CONFIGS_ENABLED` and `CONFIGS_PATH` environment variables to plan-dev and plan-prod CodeBuild project entries.

**Acceptance Criteria:**
- `CONFIGS_ENABLED` = `tostring(local.configs_enabled)` on plan-dev and plan-prod
- `CONFIGS_PATH` = `var.configs_repo_path` on plan-dev and plan-prod
- No changes to prebuild, deploy-dev, deploy-prod, test-dev, test-prod entries
- `CONFIGS_ENABLED` evaluates to `"false"` when configs repo is not specified

### Feature 4: Buildspec plan.yml — Conditional tfvars Sourcing

Modify `modules/core/buildspecs/plan.yml` to conditionally source tfvars from the configs artifact.

**Acceptance Criteria:**
- When `CONFIGS_ENABLED=true`: tfvars resolved from `${CODEBUILD_SRC_DIR_configs_output}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars`
- When `CONFIGS_ENABLED=false` or unset: tfvars resolved from `environments/${TARGET_ENV}.tfvars` (current behavior)
- Missing tfvars file at either location proceeds without `-var-file` (graceful handling preserved)
- Artifact directory validation: when `CONFIGS_ENABLED=true`, hard failure if configs artifact directory is missing or empty
- Path traversal prevention: resolved path validated to stay within configs artifact directory
- Path normalization: `"."` default avoids `/./` in paths
- `CONFIGS_ENABLED` defaults to `false` when unset (safe for manual CodeBuild triggers)

### Feature 5: Default Variant — Pipeline Integration

Add configs repo support to `modules/default/`.

**Acceptance Criteria:**
- 4 new variables in `modules/default/variables.tf` (identical declarations to core)
- Variables passed through to `module "core"` block in `main.tf`
- Source stage gains conditional second source action (`dynamic "action"` block) with `CODE_ZIP` format and `DetectChanges = "true"`
- Plan-DEV and Plan-PROD actions conditionally include `configs_output` in `input_artifacts`
- `PrimarySource = "source_output"` set only when configs artifact is present (conditional merge)
- No changes to Deploy, Test, or Pre-Build actions
- When `configs_repo = ""`: pipeline definition identical to current implementation

### Feature 6: Default-DevDestroy Variant — Pipeline Integration

Add configs repo support to `modules/default-dev-destroy/`, including destroy action support.

**Acceptance Criteria:**
- All default variant changes applied (variables, source action, plan wiring)
- Destroy CodeBuild project gains `CONFIGS_ENABLED` and `CONFIGS_PATH` environment variables
- Destroy-DEV action conditionally includes `configs_output` in `input_artifacts` with conditional `PrimarySource`
- `buildspecs/destroy.yml` gains same conditional tfvars sourcing logic as plan.yml (with hardening)
- When `configs_repo = ""`: pipeline definition identical to current implementation

### Feature 7: Test Configurations

Create new test example directories that validate the configs repo feature alongside existing backward-compatible tests.

**Acceptance Criteria:**
- Existing test configurations continue to pass unchanged (backward compatibility)
- New test directory `tests/default-configs/` created for default variant with configs repo variables
- New test directory `tests/default-dev-destroy-configs/` created for dev-destroy variant with configs repo variables
- All test examples include `terraform.tfvars.example` with sample configs repo values
- `bash tests/test-terraform.sh` passes all gates (fmt, validate, tflint, checkov, trivy) for all test directories

### Feature 8: Documentation Updates

Update project-level documentation to reflect the new feature.

**Acceptance Criteria:**
- `CLAUDE.md` updated with configs repo parameters in the Pipeline Parameters section
- `CLAUDE.md` consumer usage section updated with configs repo examples
- `docs/ARCHITECTURE_AND_DESIGN.md` gains a self-contained "Configs Repo Feature" section at the end (not woven throughout the existing content)
- Architecture section covers: new parameters, source stage changes, artifact flow, buildspec changes, known limitations

## Input Variables (New)

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `configs_repo` | `string` | No | `""` | GitHub repository in `org/repo` format containing tfvars files. When empty, tfvars sourced from IaC repo. |
| `configs_repo_branch` | `string` | No | `"main"` | Branch of the configs repo to track. |
| `configs_repo_path` | `string` | No | `"."` | Path within configs repo where `environments/` directory is located. |
| `configs_repo_codestar_connection_arn` | `string` | No | `""` | CodeStar Connection ARN for configs repo. When empty, uses IaC repo's connection. |

## Outputs (New — Core Module Internal)

| Output | Type | Description |
|--------|------|-------------|
| `configs_enabled` | `bool` | Whether configs repo feature is active |
| `configs_repo_connection_arn` | `string` | Resolved CodeStar Connection ARN for configs repo |

No new variant-level outputs.

## Input Validation Rules

| Parameter | Validation | Enforcement |
|-----------|------------|-------------|
| `configs_repo` | Must be empty or match `org/repo` format | Plan-time (variable validation block) |
| `configs_repo_branch` | Must not be empty | Plan-time (variable validation block) |
| `configs_repo_path` | Must be `"."` or a relative path without `..`, leading/trailing slashes, absolute paths, or special characters | Plan-time (variable validation block) |
| `configs_repo_codestar_connection_arn` | Must be empty or a valid CodeStar Connection ARN | Plan-time (variable validation block) |
| Configs artifact directory | Must exist and be non-empty when `CONFIGS_ENABLED=true` | Runtime (buildspec assertion) |
| Resolved tfvars path | Must stay within configs artifact directory | Runtime (buildspec assertion) |

## Known Limitations

1. **Toggle unsupported** — toggling `configs_repo` on/off on existing pipelines may force-replace the pipeline resource. This is a prerequisite decision, not a runtime toggle.
2. **Shared repo triggers all pipelines** — a push to a shared configs repo triggers all referencing pipelines, not just those whose `configs_repo_path` changed.
3. **Version skew** — dual-trigger means coordinated changes may run with mismatched code/config versions. Best practice: merge IaC changes first, then config changes.
4. **Execution mode** — pipeline uses `SUPERSEDED` mode. A new trigger supersedes in-progress executions.
5. **Cross-org connection detection not enforced** — the module does not validate whether the configs repo is in a different GitHub organization. If the consumer uses a configs repo in a different org without providing `configs_repo_codestar_connection_arn`, the pipeline will fail at runtime with a CodeStar Connections error. The consumer must manually provide the override ARN.

## Accepted Risks (from Red Team Review)

| ID | Risk | Justification |
|----|------|---------------|
| CF-01 | No repository governance enforcement | Management of repositories is outside the scope of the code module. Consumer responsibility. |
| CF-02 | Toggle on → off may leave stale `PrimarySource` | Prerequisite decision before first deployment. Documented as unsupported toggle. |
| CF-03 | Toggle off → on not tested | Same rationale as CF-02. |

## Security Considerations

- CodeStar Connection scope follows same model as IaC repo (GitHub App-based OAuth)
- No new trust boundaries introduced
- Configs repo accessed via existing credential flow (CodePipeline → CodeStar Connection → GitHub App)
- Sensitive values in tfvars: same guidance as IaC repo (use Secrets Manager/Parameter Store for secrets)
- Path traversal prevention at both plan-time (variable validation) and runtime (buildspec assertion)

## Success Criteria

| # | Criterion |
|---|-----------|
| 1 | Pipeline deploys with configs repo specified |
| 2 | Pipeline deploys without configs repo (backward compatibility) |
| 3 | Pipeline triggers on configs repo push |
| 4 | Pipeline triggers on IaC repo push (unchanged) |
| 5 | Plan actions use tfvars from configs repo when specified |
| 6 | Plan actions use tfvars from IaC repo when not specified |
| 7 | `configs_repo_path` correctly targets subdirectory |
| 8 | Separate CodeStar Connection works for cross-org configs repo |
| 9 | Default-dev-destroy variant works with configs repo |
| 10 | Missing tfvars in configs repo handled gracefully |
