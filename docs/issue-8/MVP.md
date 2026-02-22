# MVP Statement: Discrete Configs Repository Support

**GitHub Issue:** [#8 — Support discrete configs repo](https://github.com/OttawaCloudConsulting/terraform-pipelines/issues/8)
**Prepared for:** Ottawa Cloud Consulting — Architecture & Project Team
**Date:** February 21, 2026
**Status:** Draft — Pending Architecture Review
**Author:** Claude (AI-Assisted Analysis)
**Companion Documents:**

- [Problem Statement](./PROBLEM-STATEMENT.md)
- [Technical Design](./MVP-DESIGN.md)
- [Consolidated Red Team Review](./mvp-design-redteam/CONSOLIDATED-REVIEW.md)
- [Original Pipeline MVP Statement](../shared/codepipeline-mvp-statement.md)
- [Architecture and Design](../ARCHITECTURE_AND_DESIGN.md)

---

## Table of Contents

1. [Purpose](#purpose)
2. [MVP Definition](#mvp-definition)
3. [Scope](#scope)
4. [Feature Behavior](#feature-behavior)
5. [New Pipeline Parameters](#new-pipeline-parameters)
6. [Architecture Impact](#architecture-impact)
7. [Security Considerations](#security-considerations)
8. [Known Limitations](#known-limitations)
9. [Success Criteria](#success-criteria)
10. [Assumptions & Constraints](#assumptions--constraints)
11. [Post-MVP Enhancements](#post-mvp-enhancements)

---

## Purpose

This document defines the Minimum Viable Product (MVP) for adding discrete configs repository support to the existing Terraform pipeline template. The feature allows teams to store environment-specific Terraform variable files (`.tfvars`) in a separate GitHub repository from the infrastructure code, enabling independent ownership, change velocity, and audit trails for configuration versus code.

---

## MVP Definition

The MVP extends the existing pipeline template with an **optional second source repository** ("configs repo") that provides `.tfvars` files for Terraform plan and apply operations. When enabled:

1. The pipeline pulls from **two GitHub repositories** — the IaC code repo and the configs repo.
2. The pipeline **triggers on push to either repository** — a config-only change (e.g., adjusting an instance size) runs the full pipeline without touching the IaC repo.
3. Terraform plan and apply actions source their `-var-file` arguments from the **configs repo instead of the IaC repo**.
4. The feature is **entirely optional** — when no configs repo is specified, the pipeline behaves exactly as it does today.
5. The feature works with **both the `default` and `default-dev-destroy` pipeline variants**.

**Key design principle:** The configs repo is a drop-in replacement for the `environments/` directory that would otherwise live in the IaC repo. The pipeline's existing plan-apply integrity, cross-account credential flow, and approval gates are unaffected.

---

## Scope

### In Scope (MVP)

| Item | Detail |
|------|--------|
| **Second source action** | A conditional CodeStarSourceConnection action in the Source stage that checks out the configs repo as a separate pipeline artifact |
| **Dual-trigger** | Pipeline triggers on push to either the IaC repo or the configs repo |
| **Configs repo parameters** | New variables for repo name, branch, path within the repo, and optional CodeStar Connection override |
| **Buildspec integration** | Plan actions locate tfvars from the configs repo artifact when the feature is enabled |
| **Exclusive sourcing** | When a configs repo is specified, tfvars are sourced exclusively from the configs repo; any `environments/` directory in the IaC repo is ignored |
| **Expected folder convention** | Under the configured path, tfvars follow the existing `environments/{env}.tfvars` convention |
| **Connection reuse** | Defaults to the same CodeStar Connection as the IaC repo, with an optional override for repos in different GitHub organizations |
| **Variant support** | Works with both `default` and `default-dev-destroy` variants |
| **Backward compatibility** | No behavior change when configs repo parameters are not provided |
| **Destroy action support** | The `default-dev-destroy` variant's destroy action respects the configs repo for var-file sourcing |

### Out of Scope (MVP)

| Item | Rationale |
|------|-----------|
| **Merging tfvars from both repos** | MVP uses exclusive sourcing — configs repo replaces IaC repo for tfvars. Overlay/merge is a post-MVP enhancement if needed. |
| **Non-GitHub configs repos** | The pipeline uses CodeStar Connections, which support GitHub. Other VCS providers are out of scope. |
| **Configs repo content validation** | The pipeline does not validate that the configs repo contains the expected tfvars files before plan execution. Missing files are handled gracefully by the existing buildspec logic. |
| **Per-environment configs repos** | A single configs repo serves both DEV and PROD. Separate repos per environment is a post-MVP enhancement. |
| **Configs repo webhook management** | CodePipeline V2 handles change detection natively via CodeStar Connections. No custom webhook setup is required. |

---

## Feature Behavior

### When Configs Repo Is Not Specified (Default — No Change)

The pipeline operates exactly as it does today:

1. Single source action checks out the IaC repo.
2. Plan actions look for `environments/${TARGET_ENV}.tfvars` within the IaC repo.
3. If the file exists, it is passed as `-var-file`. If not, the plan proceeds without it.

### When Configs Repo Is Specified

1. **Source stage** gains a second source action that checks out the configs repo as a separate artifact (e.g., `configs_output`).
2. **Trigger behavior** — a push to either repo starts the pipeline. CodePipeline V2 natively supports multiple source actions with independent change detection.
3. **Plan actions** receive the configs repo artifact as a secondary input. The buildspec locates tfvars at `${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars` within the configs artifact.
4. **Deploy actions** — no change. Deploy actions apply the saved `tfplan` artifact, which already encodes the var-file values from the plan step.
5. **Destroy actions** (default-dev-destroy variant) — the destroy buildspec sources var files from the configs repo artifact when the feature is enabled, ensuring destroy uses the same configuration as the original deployment.
6. **Pre-Build and Test actions** — no change. These do not consume tfvars.

### Buildspec Hardening

When configs repo support is enabled, the buildspec enforces the following guards:

- **Artifact directory validation** — when `CONFIGS_ENABLED` is `true`, the buildspec verifies the configs artifact directory exists and is non-empty before proceeding. Missing or empty directories cause a hard failure.
- **Path traversal prevention** — the resolved tfvars path is validated to remain within the configs artifact directory at runtime. Paths that resolve outside the artifact boundary cause a hard failure.
- **Path normalization** — the `"."` default for `configs_repo_path` is normalized to avoid `/./` in constructed paths.
- **Safe defaults** — `CONFIGS_ENABLED` defaults to `false` when unset, allowing manual CodeBuild triggers without requiring the variable to be explicitly provided.

### Configs Repo Expected Structure

Given a `configs_repo_path` of `"projects/my-project"`, the pipeline expects:

```
<configs-repo>/
└── projects/
    └── my-project/
        └── environments/
            ├── dev.tfvars
            └── prod.tfvars
```

When `configs_repo_path` is empty or `"."`, the pipeline expects:

```
<configs-repo>/
└── environments/
    ├── dev.tfvars
    └── prod.tfvars
```

---

## New Pipeline Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `configs_repo` | No | `""` | GitHub repository in `org/repo` format containing tfvars files. When empty, tfvars are sourced from the IaC repo (current behavior). |
| `configs_repo_branch` | No | `"main"` | Branch of the configs repo to track. |
| `configs_repo_path` | No | `"."` | Path within the configs repo where the `environments/` directory is located. |
| `configs_repo_codestar_connection_arn` | No | `""` | CodeStar Connection ARN for the configs repo. When empty, uses the same connection as the IaC repo. |

All parameters are optional. When `configs_repo` is empty, the remaining configs repo parameters are ignored and the pipeline behaves identically to the current implementation.

### Input Validation

The following validations are enforced at plan time to prevent runtime failures:

| Parameter | Validation |
|-----------|------------|
| `configs_repo` | Must be empty or match `org/repo` format |
| `configs_repo_branch` | Must not be empty |
| `configs_repo_path` | Must be `"."` or a relative path without path traversal (`..`), leading/trailing slashes, absolute paths, or special characters |
| `configs_repo_codestar_connection_arn` | Required when `configs_repo` is in a different GitHub organization than `github_repo`. When both repos share the same org, the IaC repo's connection is reused |

---

## Architecture Impact

### Pipeline Source Stage

The Source stage conditionally includes a second source action:

```
Stage: Source
├── Action: GitHub (IaC repo)         → output: source_output
└── Action: Configs (configs repo)    → output: configs_output    [conditional]
```

### Artifact Flow

When the configs repo is enabled, plan and destroy CodeBuild actions receive an additional input artifact:

- **Primary input:** `source_output` (IaC code)
- **Secondary input:** `configs_output` (tfvars files)

CodeBuild mounts the secondary input at `$CODEBUILD_SRC_DIR_configs_output`. The buildspec reads tfvars from this path instead of the IaC repo's `environments/` directory.

### CodeStar Connection

The configs repo connection defaults to the same CodeStar Connection used by the IaC repo. An optional override (`configs_repo_codestar_connection_arn`) supports cases where the configs repo lives in a different GitHub organization requiring a separate GitHub App installation.

### Core vs. Variant Impact

- **Core module** — buildspec changes to conditionally source tfvars from the configs artifact. New environment variables on affected CodeBuild projects (`CONFIGS_ENABLED`, `CONFIGS_PATH`). Two new internal-wiring outputs (`configs_enabled`, `configs_repo_connection_arn`).
- **Variant modules** — CodePipeline stage definitions gain the conditional second source action and pass the configs artifact to plan/destroy actions. No changes to variant-level outputs.

---

## Security Considerations

### CodeStar Connection Scope

When a separate CodeStar Connection is used for the configs repo, it follows the same security model as the IaC repo connection — GitHub App-based OAuth with organization-level installation. The CodePipeline service role IAM policy must include the additional connection ARN.

### Configs Repo Access

The configs repo is accessed using the same credential flow as the IaC repo (CodeStar Connection → GitHub App). No additional IAM roles or cross-account access is required beyond what the pipeline already has.

### Sensitive Values in Tfvars

Tfvars files may contain sensitive values. The same guidance applies to the configs repo as to the IaC repo:

- Do not store secrets (passwords, API keys) in tfvars files.
- Use Secrets Manager or Parameter Store references in Terraform code for sensitive values.
- The configs repo should have appropriate branch protection and access controls.

### No New Trust Boundaries

This feature does not introduce new AWS trust boundaries. The configs repo is fetched by CodePipeline in the Automation Account using an existing (or newly created) CodeStar Connection — the same mechanism already used for the IaC repo.

---

## Known Limitations

### Toggling Configs Repo on Existing Pipelines Is Unsupported

The decision to use a single repository or a configs + code repo pattern is a **primary prerequisite that must be made before first deployment**. Toggling `configs_repo` on or off on an existing pipeline may trigger resource force-replacement (pipeline destroy-and-recreate) rather than an in-place update, resulting in loss of pipeline execution history, termination of in-flight executions, and changed pipeline ARNs. Additionally, API-side configuration (such as `PrimarySource`) may retain stale values after toggle-off. Consumers who change this setting post-deployment do so at their own risk.

### Shared Configs Repos Trigger All Referencing Pipelines

When a configs repo serves multiple projects (using `configs_repo_path` to target a subdirectory), a push to the tracked branch triggers **all pipelines** referencing that configs repo, regardless of whether the change is within their `configs_repo_path`. CodePipeline V2 file-path trigger filtering is a post-MVP enhancement.

### Config/Code Version Skew During Coordinated Changes

The dual-trigger architecture means that when both repositories change in close succession, the pipeline may run with a mismatched combination — for example, new IaC code with old configs, or new configs with old IaC code. Best practice: when variable interfaces change, merge IaC changes first, then merge configs changes.

### Pipeline Execution Mode

The pipeline uses the default CodePipeline V2 `execution_mode` of `SUPERSEDED`. With dual triggers, a new execution supersedes an in-progress one. This means a configs repo push that triggers a new execution while a previous execution is mid-pipeline will supersede it. DEV and PROD may temporarily have different config versions until the superseding execution completes.

---

## Success Criteria

| # | Criterion | Validation Method |
|---|-----------|-------------------|
| 1 | Pipeline deploys successfully with a configs repo specified | End-to-end pipeline run with IaC repo + configs repo |
| 2 | Pipeline deploys successfully without a configs repo (backward compatibility) | End-to-end pipeline run with no configs repo parameters |
| 3 | Pipeline triggers on push to the configs repo | Push a tfvars change to the configs repo and observe pipeline start |
| 4 | Pipeline triggers on push to the IaC repo (unchanged behavior) | Push a code change and observe pipeline start |
| 5 | Plan actions use tfvars from the configs repo when specified | Review CodeBuild logs showing var-file path from configs artifact |
| 6 | Plan actions use tfvars from the IaC repo when no configs repo is specified | Review CodeBuild logs showing var-file path from source artifact |
| 7 | Configs repo path parameter correctly targets a subdirectory | Specify a non-root path and verify correct tfvars resolution |
| 8 | Separate CodeStar Connection works for configs repo in a different org | Configure override connection and verify successful checkout |
| 9 | Default-dev-destroy variant works with configs repo | End-to-end pipeline run including destroy stage with configs repo |
| 10 | Missing tfvars in configs repo is handled gracefully | Run pipeline without tfvars at the expected path and verify plan proceeds without var-file |

---

## Assumptions & Constraints

### Assumptions

1. The configs repo is a standard GitHub repository accessible via a CodeStar Connection.
2. The configs repo follows the `environments/{env}.tfvars` convention under the specified path.
3. Teams adopting this feature will configure branch protection on the configs repo to prevent unauthorized config changes from reaching the pipeline.
4. A single configs repo serves both DEV and PROD environments for a given pipeline instance.

### Constraints

1. CodePipeline V2 supports multiple source actions in a single stage — this is a platform capability, not a workaround.
2. The configs repo must be accessible via the same CodeStar Connection as the IaC repo, unless an override connection is provided.
3. When the configs repo is specified, it **exclusively** provides tfvars — the IaC repo's `environments/` directory is not used. There is no merge behavior.
4. The configs repo trigger uses the same CodePipeline change detection as the IaC repo — push-based via CodeStar Connection.

---

## Post-MVP Enhancements

| Enhancement | Description | Priority |
|------------|-------------|----------|
| **Tfvars merge/overlay** | Support loading base tfvars from the IaC repo and overrides from the configs repo (dual `-var-file` with ordering) | Medium |
| **Per-environment configs repos** | Allow different configs repos for DEV and PROD environments | Low |
| **Configs repo validation stage** | Add a pre-plan step that validates the configs repo contains expected tfvars files | Low |
| **Configs repo change filtering** | Only trigger the pipeline when changes occur in the specific `configs_repo_path`, not on any push to the configs repo | Medium |
