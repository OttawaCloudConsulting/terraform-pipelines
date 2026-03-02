# Problem Statement: Support Discrete Configs Repo

**GitHub Issue:** [#8 — Support discrete configs repo](https://github.com/OttawaCloudConsulting/terraform-pipelines/issues/8)
**Type:** Enhancement
**Date:** 2026-02-21

## Problem

The pipeline currently assumes that Terraform variable files (`environments/dev.tfvars`, `environments/prod.tfvars`) live inside the same repository as the Terraform code. This tight coupling forces teams to either:

1. **Co-locate config with code** — environment-specific values (account IDs, CIDR ranges, instance sizes, feature flags) are committed alongside infrastructure modules, meaning a config-only change triggers the full pipeline and a code review of the IaC repo.
2. **Workaround with manual processes** — teams maintain config externally but must manually synchronize it into the IaC repo before pipeline runs, defeating the automation purpose.

Many organizations separate infrastructure code from environment configuration for valid reasons:

- **Access control** — different teams own IaC modules vs. environment-specific parameters.
- **Change velocity** — config changes (e.g., scaling a parameter) should not require a code-repo PR.
- **Audit separation** — compliance frameworks may require distinct change histories for code vs. configuration.
- **Reuse** — a single IaC module repo can serve multiple projects/teams, each with their own configs repo.

## Current State

### How tfvars Are Consumed Today

The `plan.yml` buildspec (line 68-71) conditionally includes environment-specific var files:

```yaml
if [ -f "environments/${TARGET_ENV}.tfvars" ]; then
  echo "Using var file: environments/${TARGET_ENV}.tfvars"
  PLAN_ARGS="${PLAN_ARGS} -var-file=environments/${TARGET_ENV}.tfvars"
fi
```

This path is relative to `${CODEBUILD_SRC_DIR}/${IAC_WORKING_DIR}`, meaning the var files must exist within the checked-out source repository (or its `iac_working_directory` subdirectory).

### Pipeline Source Stage

The CodePipeline Source stage currently has a single source action (`GitHub`) that checks out the IaC repository. There is no mechanism to introduce a second source input.

### Artifact Flow

All downstream CodeBuild actions receive `source_output` as their input artifact. The plan buildspec operates entirely within `${CODEBUILD_SRC_DIR}/${IAC_WORKING_DIR}`.

## Requirements

From the issue:

1. **Configurable configs repository** — a new variable that accepts a separate GitHub repository (org/repo format) containing tfvars files.
2. **Branch configuration** — the configs repo must support specifying which branch to pull from.
3. **Path configuration** — support specifying folder paths within the configs repo where tfvars files are located.
4. **Variant compatibility** — the configs repo feature must work with both the `default` and `default-dev-destroy` pipeline variants.

## Constraints and Considerations

### CodePipeline Multi-Source

AWS CodePipeline supports multiple source actions in the Source stage. A second `CodeStarSourceConnection` action can output a separate artifact (e.g., `configs_output`). CodeBuild actions can accept multiple input artifacts — the primary source is mounted at `$CODEBUILD_SRC_DIR` and secondary sources at `$CODEBUILD_SRC_DIR_<artifact_name>`.

### Backward Compatibility

When no configs repo is specified, the pipeline must behave exactly as it does today — tfvars are expected in the IaC repo at `environments/${TARGET_ENV}.tfvars`. Existing consumers must not break.

### Scope

The following are in scope for this feature:
- New module variables for configs repo, branch, and path
- Second source action in CodePipeline (conditional)
- Buildspec modifications to locate tfvars from either the IaC repo or the configs repo
- IAM permissions for the second source connection (if needed)
- CodeStar Connection reuse or creation for the configs repo

The following are out of scope:
- Triggering the pipeline on configs repo changes (can be a follow-up)
- Validating the contents of the configs repo
- Supporting non-GitHub configs repos
