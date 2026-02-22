# Configs Repo Feature Guide

The configs repo feature allows `.tfvars` files to live in a dedicated GitHub repository, separate from the IaC repo. When enabled:

- Plan and destroy actions source tfvars **exclusively** from the configs repo — not the IaC repo
- The pipeline triggers on push to **either** repository
- A single configs repo can serve multiple IaC projects using different `configs_repo_path` values

This feature is entirely optional. When `configs_repo` is not set, the pipeline behaves identically to the baseline single-repo behavior.

**Supported variants:** Default (`modules/default/`) and Default-DevDestroy (`modules/default-dev-destroy/`)

---

## When to Use

| Scenario | Recommendation |
|----------|---------------|
| One team owns IaC code, another owns environment config values | Use configs repo |
| Config-only changes (scaling params, feature flags, account IDs) should trigger the pipeline without IaC commits | Use configs repo |
| Compliance requires separate audit trail for code vs. configuration | Use configs repo |
| One IaC module serves multiple projects or teams, each with their own tfvars | Use configs repo with per-project `configs_repo_path` |
| Single team, single repo, simple setup | Don't use configs repo — baseline behavior is simpler |

---

## Repository Layouts

### IaC Repo (unchanged from baseline)

```
my-iac-project/
├── main.tf
├── variables.tf
├── outputs.tf
├── environments/              ← ignored by the pipeline when configs_repo is set
│   ├── dev.tfvars
│   └── prod.tfvars
└── cicd/
    ├── prebuild/main.sh       # Optional — developer-managed
    ├── dev/smoke-test.sh      # Optional — developer-managed
    └── prod/smoke-test.sh     # Optional — developer-managed
```

When `configs_repo` is set, the `environments/` directory in the IaC repo is bypassed. The configs repo is the exclusive tfvars source. All other IaC repo content (Terraform files, `cicd/` scripts) is unchanged.

### Configs Repo — Root-Level Layout

When `configs_repo_path = "."` (the default), the `environments/` directory must be at the root of the configs repo:

```
my-project-configs/
└── environments/
    ├── dev.tfvars
    └── prod.tfvars
```

### Configs Repo — Subdirectory Layout

When `configs_repo_path = "my-project"`, the pipeline looks for `environments/` inside that subdirectory:

```
shared-configs/
├── project-a/
│   └── environments/
│       ├── dev.tfvars
│       └── prod.tfvars
└── my-project/                 ← configs_repo_path = "my-project"
    └── environments/
        ├── dev.tfvars
        └── prod.tfvars
```

Missing tfvars files are handled gracefully — the plan proceeds without `-var-file`, matching the baseline behavior.

---

## Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `configs_repo` | `string` | `""` | GitHub repo in `org/repo` format containing tfvars. Enables the feature when non-empty. |
| `configs_repo_branch` | `string` | `"main"` | Branch to track in the configs repo. |
| `configs_repo_path` | `string` | `"."` | Path within configs repo where `environments/` is located. Use `"."` for repo root. |
| `configs_repo_codestar_connection_arn` | `string` | `""` | CodeStar Connection ARN for configs repo. Defaults to IaC repo's connection. Required for cross-org repos. |

### Plan-Time Validation Rules

| Parameter | Rule |
|-----------|------|
| `configs_repo` | Must be empty or match `org/repo` format |
| `configs_repo_branch` | Must not be empty |
| `configs_repo_path` | Must be `"."` or a relative path — no `..`, no leading/trailing slashes, no absolute paths |
| `configs_repo_codestar_connection_arn` | Must be empty or a valid CodeStar Connection ARN (`arn:aws:codestar-connections:...` or `arn:aws:codeconnections:...`) |

---

## Usage Examples

### Same Organization — Root-Level Configs

Both repos are in the same GitHub org. `environments/` is at the root of the configs repo.

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  configs_repo        = "my-org/my-project-configs"
  # configs_repo_branch = "main"   # default
  # configs_repo_path   = "."      # default — environments/ at repo root
}
```

### Shared Configs Repo — Subdirectory per Project

Multiple IaC projects share one configs repo. Each pipeline uses a different `configs_repo_path`.

```hcl
# Project A — reads from shared-configs/project-a/environments/
module "pipeline_a" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"
  # ... required vars for project A ...
  configs_repo      = "my-org/shared-configs"
  configs_repo_path = "project-a"
}

# Project B — reads from shared-configs/project-b/environments/
module "pipeline_b" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"
  # ... required vars for project B ...
  configs_repo      = "my-org/shared-configs"
  configs_repo_path = "project-b"
}
```

> **Note:** A push anywhere in `my-org/shared-configs` triggers **both** pipelines, regardless of which subdirectory changed. See [Known Limitations](#known-limitations).

### Cross-Organization Configs Repo

The configs repo is in a different GitHub organization than the IaC repo. A separate CodeStar Connection must be provided and authorized.

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  configs_repo                        = "platform-team/central-configs"
  configs_repo_path                   = "my-project"
  configs_repo_codestar_connection_arn = "arn:aws:codestar-connections:ca-central-1:111111111111:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

The `configs_repo_codestar_connection_arn` connection must be manually authorized in the AWS Console (one-time OAuth) before the pipeline can access the configs repo.

### DevDestroy Variant with Configs Repo

The destroy action also sources tfvars from the configs repo when the feature is enabled.

```hcl
module "pipeline" {
  source = "git::https://github.com/org/terraform-pipelines.git//modules/default-dev-destroy"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/deployment-role"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/deployment-role"

  configs_repo            = "my-org/my-project-configs"
  enable_destroy_approval = true  # default
}
```

---

## Trigger Behavior

With configs repo enabled, the pipeline has two independent triggers:

| Push to | Pipeline trigger |
|---------|-----------------|
| IaC repo (`github_repo` branch) | ✓ Triggers |
| Configs repo (`configs_repo_branch`) | ✓ Triggers |

The pipeline uses `SUPERSEDED` execution mode. If a new push arrives while an execution is in progress, the in-progress execution is cancelled and a new one starts with the latest source from both repos.

**Best practice for coordinated changes:** Merge IaC changes first and verify the pipeline passes, then merge config changes. This avoids running a plan that mixes an unreleased IaC version with updated config values.

---

## Artifact Flow

When configs repo is enabled, CodePipeline checks out both repos in the Source stage and passes both artifacts to Plan (and Destroy) actions:

```
Source stage:
  Action 1: checkout IaC repo     → artifact: source_output   (primary)
  Action 2: checkout configs repo → artifact: configs_output  (secondary)

Plan-DEV / Plan-PROD / Destroy-DEV:
  input_artifacts: [source_output, configs_output]
  PrimarySource:   source_output    ← working directory defaults to IaC repo

  CodeBuild sees:
    $CODEBUILD_SRC_DIR              → IaC repo root
    $CODEBUILD_SRC_DIR_configs_output → configs repo root

Deploy-DEV / Deploy-PROD / Test-DEV / Test-PROD / Pre-Build:
  unchanged — configs artifact not wired (not needed)
```

The tfvars file is resolved at plan time from `$CODEBUILD_SRC_DIR_configs_output/<configs_repo_path>/environments/<TARGET_ENV>.tfvars`.

---

## Security

The buildspec applies the following hardening when `CONFIGS_ENABLED=true`:

1. **Artifact directory validation** — hard failure if the configs artifact directory is missing or empty at runtime
2. **Path traversal prevention** — the resolved tfvars path is validated to stay within the configs artifact directory
3. **Path normalization** — the `"."` default avoids `/./` in constructed paths
4. **Safe default** — `CONFIGS_ENABLED` defaults to `false` when unset, making manual CodeBuild invocations safe even when the feature is deployed

IAM: when the configs repo uses the same CodeStar Connection as the IaC repo (the default), there is no IAM change. When a separate `configs_repo_codestar_connection_arn` is provided, both ARNs are added to the `CodeStarConnectionAccess` statements in both the CodePipeline and CodeBuild service role policies.

---

## Known Limitations

1. **Toggle unsupported** — adding or removing `configs_repo` on an existing pipeline may force-replace the CodePipeline resource (the Source stage changes from 1 to 2 actions). Treat this as a prerequisite decision before first deployment, not a runtime toggle.

2. **Shared configs repo triggers all referencing pipelines** — a push anywhere in a shared configs repo triggers every pipeline that references it, regardless of which `configs_repo_path` subtree changed. This is a CodePipeline V2 limitation; change detection cannot be scoped to a subdirectory.

3. **Version skew risk** — because either repo push can independently trigger the pipeline, a config-only push may run against a different IaC commit than intended. Merge order matters: IaC first, then config.

4. **`SUPERSEDED` execution mode** — a new trigger cancels in-progress executions. Rapid pushes to both repos may cause repeated cancellations before a run completes.

5. **Cross-org connection not auto-detected** — the module cannot determine at plan time whether the configs repo is in a different GitHub organization. If `configs_repo_codestar_connection_arn` is omitted for a cross-org repo, the pipeline fails at runtime when CodePipeline attempts the checkout. The consumer must provide the correct ARN.

---

## Full Technical Reference

See `docs/ARCHITECTURE_AND_DESIGN.md` — **Configs Repo Feature** section for the complete technical design, including IAM policy detail, buildspec conditional logic, and design decisions.
