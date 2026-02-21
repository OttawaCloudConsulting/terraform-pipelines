# MVP Design: Discrete Configs Repository Support

**GitHub Issue:** [#8 — Support discrete configs repo](https://github.com/OttawaCloudConsulting/terraform-pipelines/issues/8)
**Date:** February 21, 2026
**Status:** Draft — Pending Architecture Review
**Companion Documents:**

- [Problem Statement](./PROBLEM-STATEMENT.md)
- [MVP Statement](./MVP.md)
- [Architecture and Design](../ARCHITECTURE_AND_DESIGN.md)

---

## Table of Contents

1. [Change Summary](#change-summary)
2. [New Pipeline Parameters](#new-pipeline-parameters)
3. [Core Module Changes](#core-module-changes)
4. [Default Variant Changes](#default-variant-changes)
5. [Default-DevDestroy Variant Changes](#default-devdestroy-variant-changes)
6. [Buildspec Changes](#buildspec-changes)
7. [IAM Policy Changes](#iam-policy-changes)
8. [Artifact Flow Diagrams](#artifact-flow-diagrams)
9. [Consumer Usage Examples](#consumer-usage-examples)

---

## Change Summary

This enhancement adds an optional second source repository to the pipeline for sourcing `.tfvars` files. The change touches three layers of the module hierarchy:

| Layer | Files Changed | Nature of Change |
|-------|---------------|------------------|
| **Core module** | `variables.tf`, `locals.tf`, `iam.tf`, `outputs.tf`, `buildspecs/plan.yml` | New variables, env vars on plan CodeBuild projects, IAM policy for configs connection, buildspec conditional logic |
| **Default variant** | `variables.tf`, `main.tf` | Pass-through variables, conditional second source action, configs artifact wired to plan actions |
| **Default-DevDestroy variant** | `variables.tf`, `main.tf`, `buildspecs/destroy.yml` | Same as default + configs artifact wired to destroy action, destroy buildspec conditional logic |

**No changes** to: `prebuild.yml`, `deploy.yml`, `test.yml`, `storage.tf`, `codestar.tf`, outputs for either variant.

### Design Principle

The configs repo feature is conditional at every level. When `configs_repo = ""` (default), all conditional blocks evaluate to empty and the module produces identical resources to the current implementation. Zero behavioral change for existing consumers.

---

## New Pipeline Parameters

Four new optional variables are added at every layer (core, default, default-dev-destroy). All default to empty/inactive values.

```hcl
variable "configs_repo" {
  description = "GitHub repository in org/repo format containing tfvars files. When empty, tfvars are sourced from the IaC repo."
  type        = string
  default     = ""

  validation {
    condition     = var.configs_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.configs_repo))
    error_message = "configs_repo must be empty or in org/repo format."
  }
}

variable "configs_repo_branch" {
  description = "Branch of the configs repo to track."
  type        = string
  default     = "main"
}

variable "configs_repo_path" {
  description = "Path within the configs repo where the environments/ directory is located. Use '.' for repo root."
  type        = string
  default     = "."
}

variable "configs_repo_codestar_connection_arn" {
  description = "CodeStar Connection ARN for the configs repo. When empty, uses the same connection as the IaC repo."
  type        = string
  default     = ""

  validation {
    condition     = var.configs_repo_codestar_connection_arn == "" || can(regex("^arn:aws:(codestar-connections|codeconnections):[a-z0-9-]+:[0-9]{12}:connection/.+$", var.configs_repo_codestar_connection_arn))
    error_message = "configs_repo_codestar_connection_arn must be empty or a valid CodeStar Connection ARN."
  }
}
```

### Variable Flow

```
Consumer root module
  └── modules/default/variables.tf        (declares 4 new vars)
        └── modules/core/variables.tf      (declares same 4 vars)
              └── modules/core/locals.tf   (resolves connection ARN, sets env vars)
```

---

## Core Module Changes

### `modules/core/variables.tf`

**Add** the four new variables at the end of the "Optional Variables" section (before the IAM Extensibility section).

### `modules/core/locals.tf`

**Add** new locals for configs repo feature:

```hcl
locals {
  # ... existing locals unchanged ...

  # Configs repo feature
  configs_enabled             = var.configs_repo != ""
  configs_repo_connection_arn = var.configs_repo_codestar_connection_arn != "" ? var.configs_repo_codestar_connection_arn : local.codestar_connection_arn

  # Deduplicated list of CodeStar Connection ARNs for IAM policies.
  # When configs repo uses the same connection as the IaC repo, this is a single-element list.
  # When configs repo uses a different connection, this is a two-element list.
  all_codestar_connection_arns = distinct([
    local.codestar_connection_arn,
    local.configs_repo_connection_arn,
  ])
}
```

**Modify** the `codebuild_projects` map to add two new environment variables to **plan-dev** and **plan-prod** entries:

```hcl
    plan-dev = {
      description = "Plan DEV environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR      = var.iac_working_directory
        STATE_BUCKET         = local.state_bucket_name
        STATE_KEY_PREFIX     = local.state_key_prefix
        TARGET_ENV           = "dev"
        TARGET_ROLE          = var.dev_deployment_role_arn
        ENABLE_SECURITY_SCAN = tostring(var.enable_security_scan)
        CHECKOV_SOFT_FAIL    = tostring(var.checkov_soft_fail)
        CONFIGS_ENABLED      = tostring(local.configs_enabled)      # NEW
        CONFIGS_PATH         = var.configs_repo_path                 # NEW
      })
    }
    plan-prod = {
      description = "Plan PROD environment for ${var.project_name} pipeline"
      buildspec   = file("${path.module}/buildspecs/plan.yml")
      env_vars = merge(local.common_env_vars, {
        IAC_WORKING_DIR      = var.iac_working_directory
        STATE_BUCKET         = local.state_bucket_name
        STATE_KEY_PREFIX     = local.state_key_prefix
        TARGET_ENV           = "prod"
        TARGET_ROLE          = var.prod_deployment_role_arn
        ENABLE_SECURITY_SCAN = tostring(var.enable_security_scan)
        CHECKOV_SOFT_FAIL    = "false"
        CONFIGS_ENABLED      = tostring(local.configs_enabled)      # NEW
        CONFIGS_PATH         = var.configs_repo_path                 # NEW
      })
    }
```

No changes to `prebuild`, `deploy-dev`, `deploy-prod`, `test-dev`, or `test-prod` entries. Deploy actions apply a saved plan (tfvars already encoded). Test and prebuild actions do not consume tfvars.

### `modules/core/iam.tf`

**Modify** the `CodeStarConnectionAccess` statement in **both** the CodePipeline and CodeBuild IAM policies to reference the deduplicated connection ARN list:

**CodePipeline service role policy** (`aws_iam_role_policy.codepipeline`):

```hcl
      {
        Sid    = "CodeStarConnectionAccess"
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection"
        ]
        Resource = local.all_codestar_connection_arns    # CHANGED from [local.codestar_connection_arn]
      },
```

**CodeBuild service role policy** (`aws_iam_role_policy.codebuild`):

```hcl
      {
        Sid    = "CodeStarConnectionAccess"
        Effect = "Allow"
        Action = "codestar-connections:UseConnection"
        Resource = local.all_codestar_connection_arns    # CHANGED from [local.codestar_connection_arn]
      },
```

**Rationale:** When the configs repo uses a different CodeStar Connection than the IaC repo, both connections must be authorized in the IAM policies. The `distinct()` function in the local ensures no duplicate ARNs when both use the same connection.

### `modules/core/outputs.tf`

**Add** new outputs for variant wiring:

```hcl
output "configs_enabled" {
  description = "Whether the configs repo feature is active."
  value       = local.configs_enabled
}

output "configs_repo_connection_arn" {
  description = "Resolved CodeStar Connection ARN for the configs repo."
  value       = local.configs_repo_connection_arn
}
```

### No Changes to `codestar.tf`

The configs repo reuses either the existing CodeStar Connection (IaC repo's connection) or a user-provided override. No new `aws_codestarconnections_connection` resource is created for the configs repo. The user is responsible for providing an authorized connection ARN if they use a separate one.

---

## Default Variant Changes

### `modules/default/variables.tf`

**Add** the four new variables (identical declarations to core). These pass through to the core module.

### `modules/default/main.tf`

#### Core Module Call

**Add** the four new variables to the `module "core"` block:

```hcl
module "core" {
  source = "../core"

  # ... existing variables unchanged ...

  configs_repo                         = var.configs_repo
  configs_repo_branch                  = var.configs_repo_branch
  configs_repo_path                    = var.configs_repo_path
  configs_repo_codestar_connection_arn = var.configs_repo_codestar_connection_arn
}
```

#### Source Stage — Conditional Second Source Action

**Add** a `dynamic "action"` block to the Source stage for the configs repo:

```hcl
  # Stage 1: Source
  stage {
    name = "Source"

    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = module.core.codestar_connection_arn
        FullRepositoryId     = var.github_repo
        BranchName           = var.github_branch
        DetectChanges        = "true"
        OutputArtifactFormat = "CODEBUILD_CLONE_REF"
      }
    }

    # Conditional: Configs repo source action
    dynamic "action" {
      for_each = module.core.configs_enabled ? [1] : []

      content {
        name             = "Configs"
        category         = "Source"
        owner            = "AWS"
        provider         = "CodeStarSourceConnection"
        version          = "1"
        output_artifacts = ["configs_output"]

        configuration = {
          ConnectionArn        = module.core.configs_repo_connection_arn
          FullRepositoryId     = var.configs_repo
          BranchName           = var.configs_repo_branch
          DetectChanges        = "true"
          OutputArtifactFormat = "CODE_ZIP"
        }
      }
    }
  }
```

**Design decisions:**

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Artifact format | `CODE_ZIP` (not `CODEBUILD_CLONE_REF`) | Configs repo only needs file contents, not git history. ZIP is simpler and faster. |
| `DetectChanges` | `"true"` | Enables dual-trigger — push to either repo starts the pipeline (MVP requirement). |
| `run_order` | Omitted (defaults to `1`) | Both source actions execute in parallel within the Source stage. |

#### Plan Actions — Conditional Configs Artifact Input

**Modify** Plan-DEV and Plan-PROD actions to conditionally include `configs_output` as a secondary input:

```hcl
    action {
      name             = "Plan-DEV"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = module.core.configs_enabled ? ["source_output", "configs_output"] : ["source_output"]
      output_artifacts = ["dev_plan_output"]

      configuration = merge(
        {
          ProjectName = module.core.codebuild_project_names["plan-dev"]
        },
        module.core.configs_enabled ? {
          PrimarySource = "source_output"
        } : {}
      )
    }
```

**Why `PrimarySource` is conditional:** When there is only one input artifact, `PrimarySource` must not be set (it defaults to the single artifact). When there are multiple input artifacts, `PrimarySource` is required and tells CodeBuild which artifact contains the buildspec. We set it to `source_output` (the IaC repo) because that's where the buildspec lives.

The same pattern applies to `Plan-PROD`.

#### Deploy and Test Actions — No Changes

Deploy actions receive the saved `tfplan` artifact. The tfvars are already encoded in the plan — no need for the configs artifact at deploy time. Test and prebuild actions do not consume tfvars.

---

## Default-DevDestroy Variant Changes

All changes from the default variant apply identically. Additionally:

### `modules/default-dev-destroy/variables.tf`

**Add** the same four new variables.

### `modules/default-dev-destroy/main.tf`

#### Core Module Call, Source Stage, Plan Actions

Identical changes to the default variant (new core module variables, conditional second source action, conditional configs artifact on plan actions).

#### Destroy CodeBuild Project — New Environment Variables

**Add** `CONFIGS_ENABLED` and `CONFIGS_PATH` environment variables to the `aws_codebuild_project.destroy` resource:

```hcl
    environment_variable {
      name  = "CONFIGS_ENABLED"
      value = tostring(module.core.configs_enabled)
    }

    environment_variable {
      name  = "CONFIGS_PATH"
      value = var.configs_repo_path
    }
```

#### Destroy Stage — Conditional Configs Artifact Input

**Modify** the Destroy-DEV stage action to conditionally include `configs_output`:

```hcl
  # Stage 7/8: Destroy DEV
  stage {
    name = "Destroy-DEV"

    action {
      name            = "DestroyDEV"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = module.core.configs_enabled ? ["source_output", "configs_output"] : ["source_output"]

      configuration = merge(
        {
          ProjectName = aws_codebuild_project.destroy.name
        },
        module.core.configs_enabled ? {
          PrimarySource = "source_output"
        } : {}
      )
    }
  }
```

---

## Buildspec Changes

### `modules/core/buildspecs/plan.yml`

The build phase currently locates tfvars with:

```yaml
if [ -f "environments/${TARGET_ENV}.tfvars" ]; then
  echo "Using var file: environments/${TARGET_ENV}.tfvars"
  PLAN_ARGS="${PLAN_ARGS} -var-file=environments/${TARGET_ENV}.tfvars"
fi
```

**Replace** this block with conditional logic that checks `CONFIGS_ENABLED`:

```yaml
        # Resolve tfvars location
        if [ "${CONFIGS_ENABLED}" = "true" ]; then
          # Configs repo: tfvars sourced from secondary input artifact
          CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output}"
          VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
          echo "Configs repo enabled — looking for tfvars at: ${VARFILE_PATH}"
        else
          # Default: tfvars sourced from IaC repo
          VARFILE_PATH="environments/${TARGET_ENV}.tfvars"
          echo "Using IaC repo for tfvars — looking at: ${VARFILE_PATH}"
        fi

        if [ -f "${VARFILE_PATH}" ]; then
          echo "Using var file: ${VARFILE_PATH}"
          PLAN_ARGS="${PLAN_ARGS} -var-file=${VARFILE_PATH}"
        else
          echo "No tfvars file found at ${VARFILE_PATH}, proceeding without var-file."
        fi
```

**Key details:**

- `CODEBUILD_SRC_DIR_configs_output` is automatically set by CodeBuild when the pipeline passes `configs_output` as a secondary input artifact. This is a CodeBuild built-in environment variable using the pattern `CODEBUILD_SRC_DIR_<artifactName>`.
- When `CONFIGS_ENABLED` is `"false"`, `CODEBUILD_SRC_DIR_configs_output` will not exist (the artifact is not passed), and the buildspec uses the IaC repo's relative path — identical to current behavior.
- The `CONFIGS_PATH` env var handles the user-configurable path within the configs repo. When `configs_repo_path = "."`, the path simplifies to `./environments/${TARGET_ENV}.tfvars`.

### `modules/default-dev-destroy/buildspecs/destroy.yml`

The destroy buildspec currently locates tfvars with:

```yaml
if [ -f "environments/dev.tfvars" ]; then
  DESTROY_ARGS="${DESTROY_ARGS} -var-file=environments/dev.tfvars"
  echo "Using var file: environments/dev.tfvars"
else
  echo "No environments/dev.tfvars found, proceeding without var-file."
fi
```

**Replace** this block with the same conditional pattern:

```yaml
        # Resolve tfvars location
        if [ "${CONFIGS_ENABLED}" = "true" ]; then
          CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output}"
          VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/dev.tfvars"
          echo "Configs repo enabled — looking for tfvars at: ${VARFILE_PATH}"
        else
          VARFILE_PATH="environments/dev.tfvars"
          echo "Using IaC repo for tfvars — looking at: ${VARFILE_PATH}"
        fi

        if [ -f "${VARFILE_PATH}" ]; then
          DESTROY_ARGS="${DESTROY_ARGS} -var-file=${VARFILE_PATH}"
          echo "Using var file: ${VARFILE_PATH}"
        else
          echo "No tfvars file found at ${VARFILE_PATH}, proceeding without var-file."
        fi
```

### Unchanged Buildspecs

| Buildspec | Reason No Change |
|-----------|------------------|
| `prebuild.yml` | Pre-build runs developer scripts; does not consume tfvars |
| `deploy.yml` | Applies a saved `tfplan` artifact; tfvars are already encoded in the plan |
| `test.yml` | Runs smoke test scripts; does not consume tfvars |

---

## IAM Policy Changes

### CodePipeline Service Role

The `CodeStarConnectionAccess` statement must include the configs repo connection ARN. The change in `iam.tf` (switching from `[local.codestar_connection_arn]` to `local.all_codestar_connection_arns`) handles this automatically.

**When configs repo uses the same connection (default):**

```json
{
  "Sid": "CodeStarConnectionAccess",
  "Effect": "Allow",
  "Action": ["codestar-connections:UseConnection"],
  "Resource": ["arn:aws:codestar-connections:ca-central-1:111111111111:connection/abc-123"]
}
```

No change — `distinct()` deduplicates to a single ARN.

**When configs repo uses a different connection:**

```json
{
  "Sid": "CodeStarConnectionAccess",
  "Effect": "Allow",
  "Action": ["codestar-connections:UseConnection"],
  "Resource": [
    "arn:aws:codestar-connections:ca-central-1:111111111111:connection/abc-123",
    "arn:aws:codestar-connections:ca-central-1:111111111111:connection/def-456"
  ]
}
```

### CodeBuild Service Role

Same pattern — the `CodeStarConnectionAccess` statement is updated to `local.all_codestar_connection_arns`. CodeBuild needs `codestar-connections:UseConnection` to fetch source artifacts via CodeStar Connection references.

### No New IAM Roles or Cross-Account Changes

The configs repo is fetched by CodePipeline/CodeBuild in the Automation Account. No cross-account role assumption is required. The existing deployment roles in target accounts are unaffected.

---

## Artifact Flow Diagrams

### Without Configs Repo (Current Behavior — Unchanged)

```
Source Stage                    DEV Stage                    PROD Stage
┌──────────┐                 ┌───────────────┐            ┌────────────────┐
│  GitHub  │─source_output──►│  Plan-DEV     │            │  Plan-PROD     │
│  (IaC)   │                 │  in: source   │            │  in: source    │
└──────────┘                 │  out: dev_plan│            │  out: prod_plan│
                             └──────┬────────┘            └──────┬─────────┘
                                    │                            │
                             ┌──────▼────────┐            ┌──────▼─────────┐
                             │  Deploy-DEV   │            │  Deploy-PROD   │
                             │  in: source   │            │  in: source    │
                             │    + dev_plan │            │    + prod_plan │
                             └───────────────┘            └────────────────┘
```

### With Configs Repo (New)

```
Source Stage                      DEV Stage                      PROD Stage
┌──────────┐                 ┌────────────────┐            ┌────────────────┐
│  GitHub  │─source_output──►│  Plan-DEV      │            │  Plan-PROD     │
│  (IaC)   │                 │  in: source    │            │  in: source    │
└──────────┘                 │    + configs ◄─┤            │    + configs ◄─┤
                             │  out: dev_plan │            │  out: prod_plan│
┌──────────┐                 └───────┬────────┘            └───────┬────────┘
│  Configs │─configs_output──►       │                             │
│  (tfvars)│                         │                             │
└──────────┘                 ┌───────▼────────┐            ┌───────▼────────┐
                             │  Deploy-DEV    │            │  Deploy-PROD   │
                             │  in: source    │            │  in: source    │
                             │    + dev_plan  │            │    + prod_plan │
                             └────────────────┘            └────────────────┘
```

### With Configs Repo — DevDestroy Variant (Destroy Stage)

```
                              Destroy-DEV Stage
                             ┌────────────────┐
  source_output ────────────►│  DestroyDEV    │
                             │  in: source    │
  configs_output ───────────►│    + configs   │
                             └────────────────┘
```

---

## Consumer Usage Examples

### Default Variant with Configs Repo

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "222222222222"
  dev_deployment_role_arn  = "arn:aws:iam::222222222222:role/deployment-role"
  prod_account_id          = "333333333333"
  prod_deployment_role_arn = "arn:aws:iam::333333333333:role/deployment-role"

  # Configs repo — separate repository for tfvars
  configs_repo        = "my-org/my-project-configs"
  configs_repo_branch = "main"
  configs_repo_path   = "."
}
```

### Configs Repo in a Different GitHub Org

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  # ... required variables ...

  # Configs repo in a different org — requires separate CodeStar Connection
  configs_repo                         = "other-org/shared-configs"
  configs_repo_branch                  = "main"
  configs_repo_path                    = "projects/my-project"
  configs_repo_codestar_connection_arn = "arn:aws:codestar-connections:ca-central-1:111111111111:connection/other-org-conn"
}
```

### Configs Repo Structure with Path

Given `configs_repo_path = "projects/my-project"`, the configs repo layout:

```
shared-configs/
├── projects/
│   ├── my-project/
│   │   └── environments/
│   │       ├── dev.tfvars
│   │       └── prod.tfvars
│   └── other-project/
│       └── environments/
│           ├── dev.tfvars
│           └── prod.tfvars
└── README.md
```

### DevDestroy Variant with Configs Repo

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"

  # ... required variables ...

  configs_repo               = "my-org/my-project-configs"
  configs_repo_branch        = "main"
  configs_repo_path          = "."
  enable_destroy_approval    = true
}
```

### Without Configs Repo (Backward Compatible — No Change)

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "222222222222"
  dev_deployment_role_arn  = "arn:aws:iam::222222222222:role/deployment-role"
  prod_account_id          = "333333333333"
  prod_deployment_role_arn = "arn:aws:iam::333333333333:role/deployment-role"
  # No configs_repo — uses environments/ from IaC repo (current behavior)
}
```

