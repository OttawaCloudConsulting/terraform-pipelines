# Red Team Findings: Discrete Configs Repository MVP Design

**Reviewer:** Terraform Module Architect -- IaC Design Patterns & API Surface Specialist
**Role:** Red Team Analyst
**Focus Area:** Module API design flaws, variable interface inconsistencies, Terraform plan/apply behavioral surprises, provider and resource-level gotchas, consumer experience pitfalls, and violations of established module architecture patterns.
**Document Under Review:** `docs/issue-8/MVP-DESIGN.md`
**Date:** 2026-02-21

---

## Table of Contents

1. [CRITICAL Findings](#critical-findings)
2. [HIGH Findings](#high-findings)
3. [MEDIUM Findings](#medium-findings)
4. [LOW Findings](#low-findings)
5. [Summary Verdict](#summary-verdict)

---

## CRITICAL Findings

### C-1: CodePipeline In-Place Update Replaces Pipeline When Toggling `configs_repo`

**Severity:** CRITICAL
**Category:** Terraform Plan/Apply Behavioral Surprise

**Problem:**

The design uses a `dynamic "action"` block inside the Source stage that is conditionally present based on `module.core.configs_enabled`. When an existing pipeline consumer adds `configs_repo = "org/repo"` to their module call (or removes it), the following changes happen to the `aws_codepipeline.this` resource in a single apply:

1. The Source stage gains (or loses) an action.
2. Plan-DEV and Plan-PROD actions change their `input_artifacts` list.
3. Plan-DEV and Plan-PROD actions change their `configuration` block (adding/removing `PrimarySource`).

While CodePipeline V2 supports in-place updates for stage/action changes, the Terraform AWS provider's handling of `aws_codepipeline` stage blocks is notoriously sensitive. Adding or removing an action within a stage -- particularly a source action that introduces a new artifact name referenced by downstream stages -- has historically caused Terraform to compute a force-replacement (`-/+`) rather than an in-place update, depending on provider version.

**Risk:** A consumer toggling `configs_repo` on or off may trigger a **pipeline destroy-and-recreate** rather than an in-place update. This means:
- The pipeline execution history is lost.
- Any in-flight pipeline executions are terminated.
- The pipeline ARN changes, breaking any downstream references (CloudWatch alarms, EventBridge rules, dashboards).

**Evidence from current code:** The existing `dynamic "action"` for `enable_review_gate` (Approve-DEV) operates within a stage that already has static actions. The configs repo dynamic is structurally similar but affects the Source stage AND changes downstream action configurations simultaneously -- a more complex diff for the provider to reconcile.

**Recommendation:**

1. **Test this explicitly** before shipping. Create a pipeline without `configs_repo`, apply it, then add `configs_repo` and run `terraform plan`. Verify the plan shows `~ update in-place` and NOT `must be replaced` or `-/+ (destroy and then create replacement)`.
2. If force-replacement occurs, document it as a known limitation with a migration path (e.g., `terraform state rm` + `terraform import`, or a `lifecycle { create_before_destroy = true }` pattern).
3. Consider adding a note in the consumer documentation that toggling `configs_repo` on an existing pipeline should be done during a maintenance window.

---

### C-2: `PrimarySource` Conditional Merge Pattern Causes Silent Configuration Drift Risk

**Severity:** CRITICAL
**Category:** Terraform Plan/Apply Behavioral Surprise

**Problem:**

The design uses a conditional `merge()` for the Plan action `configuration` block:

```hcl
configuration = merge(
  {
    ProjectName = module.core.codebuild_project_names["plan-dev"]
  },
  module.core.configs_enabled ? {
    PrimarySource = "source_output"
  } : {}
)
```

When `configs_enabled` is false, this produces `{ ProjectName = "..." }`. When true, it produces `{ ProjectName = "...", PrimarySource = "source_output" }`.

This is a valid Terraform pattern, but there is a critical behavioral nuance with the CodePipeline provider: **once `PrimarySource` is set on an action and then removed**, the AWS API may retain the previously-set value server-side while Terraform believes it has been unset. The `aws_codepipeline` resource does not explicitly send `PrimarySource = null` when the key is absent from the configuration map -- it simply omits it from the API call. Whether the API clears the field or retains the previous value is AWS API behavior, not Terraform behavior.

**Risk:** If a consumer toggles configs repo OFF after it was previously ON, the Plan actions may silently retain `PrimarySource = "source_output"` server-side. Since there is now only one input artifact, CodeBuild may either:
- Ignore `PrimarySource` (benign), or
- Error at runtime because `PrimarySource` references an artifact name that no longer exists in the action's `input_artifacts` list.

**Recommendation:**

1. Test the toggle-off scenario end-to-end: enable configs repo, apply, disable configs repo, apply, then trigger the pipeline and verify Plan actions succeed.
2. If the API retains stale `PrimarySource`, consider always setting `PrimarySource = "source_output"` regardless of configs_enabled. The CodeBuild documentation states that when there is only one input artifact and `PrimarySource` is set to that artifact, it is accepted. This removes the conditional entirely and eliminates the drift risk.

---

## HIGH Findings

### H-1: No Cross-Variable Validation Between `configs_repo` and Its Companion Variables

**Severity:** HIGH
**Category:** Variable Interface Design / Validation Gap

**Problem:**

The four new variables are independent with no cross-validation. This allows several invalid configurations that will fail at runtime, not at `terraform plan`:

1. **`configs_repo = ""` with `configs_repo_codestar_connection_arn = "arn:aws:..."`** -- Consumer provides a connection for a repo that does not exist. The IAM policy will include an unnecessary ARN, but otherwise no functional harm. Low risk, but confusing.

2. **`configs_repo = "org/repo"` with `configs_repo_branch = ""`** -- The branch defaults to `"main"`, so this specific case is safe. But there is no validation preventing `configs_repo_branch = ""` explicitly. An empty string passed to CodePipeline's `BranchName` configuration will cause an API error at apply time, not plan time.

3. **`configs_repo_path` with trailing slashes or leading slashes** -- The buildspec constructs `${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars`. If `configs_repo_path = "./projects/my-project/"`, the resolved path becomes `${CONFIGS_DIR}/./projects/my-project//environments/dev.tfvars`. While shell path resolution usually handles doubled slashes, the leading `./` may cause issues with some tools.

**Recommendation:**

Add a cross-variable validation block in the core module (Terraform 1.9+ supports cross-variable validation via `validation` blocks with `var` references in conditions):

```hcl
variable "configs_repo_branch" {
  # ...
  validation {
    condition     = var.configs_repo_branch != ""
    error_message = "configs_repo_branch must not be empty."
  }
}

variable "configs_repo_path" {
  # ...
  validation {
    condition     = var.configs_repo_path == "." || !can(regex("^[./]|[/.]$", var.configs_repo_path))
    error_message = "configs_repo_path must be '.' for repo root or a relative path without leading/trailing slashes or dots."
  }
}
```

If cross-variable validation is not available in the minimum supported Terraform version, add a `locals`-based assertion or at minimum a `precondition` on the CodePipeline resource:

```hcl
lifecycle {
  precondition {
    condition     = !local.configs_enabled || var.configs_repo_branch != ""
    error_message = "configs_repo_branch must not be empty when configs_repo is specified."
  }
}
```

---

### H-2: Variable Duplication Across Three Layers Without a Grouped Object Variable

**Severity:** HIGH
**Category:** Module API Design / Consumer Experience

**Problem:**

The design adds 4 identical variable declarations across 3 files (core `variables.tf`, default `variables.tf`, default-dev-destroy `variables.tf`) -- that is 12 variable blocks, all with identical types, descriptions, defaults, and validations. This is the existing pattern (all variables are pass-through), so it is consistent. However, the configs repo variables are *conceptually a single feature with multiple fields*, unlike the existing variables which are independent concerns.

The current approach has two design problems:

1. **Maintenance burden:** Any change to a validation rule, description, or default must be replicated in 3 files. The existing codebase already has 22+ variables per variant, and this adds 4 more. The variant `variables.tf` files are now approaching 30 variables of pure boilerplate duplication.

2. **Consumer API surface inflation:** Consumers see 4 new top-level variables for what is conceptually a single feature. This makes the module call noisier and the variable list harder to scan.

**Counterargument (why the design may be acceptable):** The existing codebase uses flat variables exclusively. No variable in the current interface is an object type. Introducing an object variable for this feature would break the established pattern. Additionally, object variables with optional fields require Terraform 1.3+ for `optional()` support and are harder to document.

**Recommendation:**

Accept the flat variable approach for MVP as it is consistent with the existing pattern. However, **document this as tech debt** and consider a post-MVP refactor if additional multi-field feature configurations are added. A grouping convention like prefix (`configs_*`) is already used and is sufficient for now.

If the team does want to consider an object variable, here is what it would look like:

```hcl
variable "configs_repo" {
  description = "Optional external repository for tfvars files."
  type = object({
    repo           = string
    branch         = optional(string, "main")
    path           = optional(string, ".")
    connection_arn = optional(string, "")
  })
  default = null
}
```

This reduces 4 variables to 1 and makes `configs_enabled = var.configs_repo != null` trivially clear. But it is a pattern break. **Decision is for the team, not the architect.**

---

### H-3: Core Module Outputs Added Without Variant Output Pass-Through

**Severity:** HIGH
**Category:** Output Contract Violation / Inconsistency with Established Pattern

**Problem:**

The design adds two new outputs to the core module:

```hcl
output "configs_enabled" { ... }
output "configs_repo_connection_arn" { ... }
```

The core module's existing outputs (13 total) are all consumed by the variant wrappers. Some are used internally for wiring (e.g., `codebuild_project_names`, `codestar_connection_arn`) and some are passed through to the variant's consumer-facing outputs.

The MVP design states "No changes to outputs for either variant." This means the two new core outputs are used ONLY for internal wiring within the variant `main.tf` (the `dynamic "action"` and `configuration` blocks reference `module.core.configs_enabled`). They are not exposed to consumers.

This is acceptable for internal wiring outputs, and follows the existing pattern where `pipeline_url_prefix`, `project_name`, `dev_account_id`, `prod_account_id`, and `all_tags` are core outputs consumed by variants but not all are directly consumer-facing.

However, there is a consumer experience question: **should the variant expose `configs_enabled` and `configs_repo_connection_arn` as consumer outputs?** A consumer might want to:
- Confirm their pipeline has configs repo enabled (for validation in a wrapper module).
- Reference the resolved connection ARN for use in other resources.

**Recommendation:**

For MVP, the current approach (internal-only outputs) is acceptable. Add a TODO comment noting that consumer-facing outputs for configs repo status should be evaluated post-MVP. The variant output interface is documented as "Uniform outputs (11)" in `CLAUDE.md` and adding outputs is a non-breaking change.

---

### H-4: Buildspec Path Construction Is Fragile When `configs_repo_path = "."`

**Severity:** HIGH
**Category:** Buildspec Runtime Behavior

**Problem:**

The buildspec constructs the tfvars path as:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

When `configs_repo_path = "."` (the default), this resolves to:

```
/codebuild/output/src123/configs_output/./environments/dev.tfvars
```

The `/.` in the path is technically valid in POSIX, but:

1. The `[ -f "${VARFILE_PATH}" ]` test should handle this correctly.
2. However, the echo statements will show the `/.` in the log output, which looks like a bug to operators debugging pipeline failures.
3. If any downstream tooling uses string comparison on the path (unlikely but possible), the `/.` will cause mismatches.

More importantly, the `CONFIGS_PATH` variable is set as a CodeBuild environment variable at project creation time from `var.configs_repo_path`. The default value `"."` is baked into the CodeBuild project configuration. If a consumer later changes `configs_repo_path`, the CodeBuild project must be updated (in-place) to reflect the new env var value.

**Recommendation:**

Normalize the path in the locals:

```hcl
locals {
  configs_repo_path_normalized = var.configs_repo_path == "." ? "" : var.configs_repo_path
}
```

Then in the buildspec:

```bash
if [ -n "${CONFIGS_PATH}" ]; then
  VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
else
  VARFILE_PATH="${CONFIGS_DIR}/environments/${TARGET_ENV}.tfvars"
fi
```

This produces cleaner paths and cleaner log output.

---

## MEDIUM Findings

### M-1: `CODEBUILD_SRC_DIR_configs_output` Is Undefined When `CONFIGS_ENABLED = "false"`

**Severity:** MEDIUM
**Category:** Buildspec Robustness

**Problem:**

The buildspec references `CODEBUILD_SRC_DIR_configs_output` inside the `if [ "${CONFIGS_ENABLED}" = "true" ]` branch, which is correct -- it will only be referenced when configs are enabled.

However, shell scripts running under `set -euo pipefail` (which the buildspec uses) will **fail on reference to an unset variable** due to the `set -u` flag. If there is any code path (now or in a future edit) that references `CODEBUILD_SRC_DIR_configs_output` outside the conditional, the build will fail with "unbound variable."

The current design is safe because the reference is inside the conditional. But this is fragile -- a future maintainer adding debug logging like `echo "Configs dir: ${CODEBUILD_SRC_DIR_configs_output}"` outside the conditional would break the non-configs-repo path.

**Recommendation:**

Add a defensive default near the top of the build phase:

```bash
CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output:-}"
```

This allows safe reference anywhere in the script. The `:-` syntax provides an empty default when the variable is unset, satisfying `set -u`.

---

### M-2: Destroy BuildSpec Environment Variables Are Set Differently Than Plan BuildSpec

**Severity:** MEDIUM
**Category:** Inconsistency Between Core and Variant Patterns

**Problem:**

For the Plan CodeBuild projects (managed by core), `CONFIGS_ENABLED` and `CONFIGS_PATH` are set via the `codebuild_projects` map's `env_vars` field and rendered through the `dynamic "environment_variable"` pattern in `core/main.tf`.

For the Destroy CodeBuild project (managed by the default-dev-destroy variant), the design shows `CONFIGS_ENABLED` and `CONFIGS_PATH` being added as individual `environment_variable` blocks directly in the `aws_codebuild_project.destroy` resource.

Both approaches work, but they use different mechanisms:
- **Core projects:** map-based, declarative, all env vars in one place in `locals.tf`.
- **Destroy project:** individual HCL blocks, imperative, env vars scattered across the resource definition.

This is the same inconsistency that already exists in the codebase (the destroy project was written before the core `codebuild_projects` map pattern was established). However, this design widens the gap by adding more env vars to the inconsistent pattern.

**Recommendation:**

Accept for MVP as extending the existing pattern. Document as tech debt -- the destroy project's environment variables should be refactored to use a map-based pattern similar to core's `codebuild_projects` in a future cleanup pass.

---

### M-3: IAM Policy Change Is Not Idempotent When `configs_repo` Uses the Same Connection

**Severity:** MEDIUM
**Category:** Terraform Plan Noise / Operational Surprise

**Problem:**

The design changes the IAM policy `Resource` field from:

```hcl
Resource = [local.codestar_connection_arn]
```

to:

```hcl
Resource = local.all_codestar_connection_arns
```

Where `all_codestar_connection_arns` is `distinct([local.codestar_connection_arn, local.configs_repo_connection_arn])`.

When configs repo is NOT enabled (`configs_repo = ""`), `configs_repo_connection_arn` resolves to `local.codestar_connection_arn` (the fallback). So `distinct()` produces a single-element list identical to the current value.

**However**, Terraform will still show a plan diff on initial adoption. The IAM policy JSON is rendered as a string via `jsonencode()`. Terraform compares the rendered JSON string. Even though the policy is semantically identical, the Terraform resource address for the IAM policy is changing from a single literal ARN to a `local` reference. On the first `terraform plan` after upgrading the module (even without enabling configs repo), the plan may show:

```
~ Resource = [
    "arn:aws:codestar-connections:...:connection/abc-123",
  ]
```

...being "changed" to the same value, because the Terraform expression path changed (literal vs. local reference). In practice, Terraform is smart enough to compare the rendered values and show "no changes" if the values are identical. But this depends on the IAM policy `jsonencode` producing byte-identical JSON.

**Risk:** This is likely a non-issue in practice because the current code already uses `local.codestar_connection_arn` (not a literal). The change is from `[local.codestar_connection_arn]` to `local.all_codestar_connection_arns`. Since `distinct()` preserves element order and the first element is the same reference, the rendered JSON should be identical.

**Recommendation:**

Low risk, but verify by running `terraform plan` on an existing deployment after upgrading the module without setting `configs_repo`. Confirm zero diff on the IAM policies.

---

### M-4: The Design Does Not Address `configs_repo` Triggering on ALL Pushes, Not Just `configs_repo_path` Changes

**Severity:** MEDIUM
**Category:** Design Gap / Operational Surprise

**Problem:**

The design sets `DetectChanges = "true"` on the Configs source action. CodePipeline V2 with CodeStar Connections triggers on **any push to the tracked branch**, not on pushes that change files within a specific path.

If a configs repo serves multiple projects (the design's "Configs Repo in a Different GitHub Org" example shows `configs_repo_path = "projects/my-project"`), then a push that changes `projects/other-project/environments/dev.tfvars` will trigger ALL pipelines tracking that configs repo, even those whose `configs_repo_path` points to a different directory.

The MVP statement lists "Configs repo change filtering" as a post-MVP enhancement. This is acknowledged. However, the design document does not mention this limitation or its operational impact.

**Recommendation:**

Add an explicit "Known Limitations" section to the MVP design document stating:
- When a configs repo serves multiple projects, any push to the tracked branch triggers all pipelines that reference that configs repo, regardless of `configs_repo_path`.
- This may cause unnecessary pipeline executions for projects whose configs were not changed.
- CodePipeline V2 trigger filtering (by file path) is a post-MVP enhancement.

This sets correct expectations for operators adopting the feature.

---

### M-5: Document States "No Changes to Outputs" but Core Module Outputs Are Changed

**Severity:** MEDIUM
**Category:** Documentation Accuracy

**Problem:**

The Change Summary table states:

> **No changes** to: `prebuild.yml`, `deploy.yml`, `test.yml`, `storage.tf`, `codestar.tf`, **outputs for either variant**.

This is accurate for the variant outputs (`modules/default/outputs.tf` and `modules/default-dev-destroy/outputs.tf`). However, the core module's `outputs.tf` IS changed (two new outputs added). The Change Summary table lists `outputs.tf` in the Core module row's "Files Changed" column, so there is no factual error -- but the "No changes to outputs" statement at the bottom is ambiguous and could be read as "no output changes anywhere."

**Recommendation:**

Clarify the statement to: "No changes to variant-level outputs (`modules/default/outputs.tf`, `modules/default-dev-destroy/outputs.tf`). Core module gains two new internal-wiring outputs."

---

## LOW Findings

### L-1: `configs_repo` Variable Name Collides with the Conceptual Feature Name

**Severity:** LOW
**Category:** Naming Convention / Consumer Experience

**Problem:**

The variable `configs_repo` serves double duty as both the feature toggle (`""` = disabled) and the repo identifier. This is the same pattern used by `codestar_connection_arn` (empty = create new) and `state_bucket` (empty = create new), so it is consistent.

However, in the existing patterns, the "empty = create" semantics mean the resource is created internally. For `configs_repo`, "empty" means "feature disabled entirely." This is a subtle semantic difference -- the consumer might expect `configs_repo = ""` to mean "use a default configs repo" rather than "disable the feature."

**Recommendation:**

The current approach is acceptable and consistent enough. The variable description clearly states the behavior. No change needed, but consider whether an `enable_configs_repo` boolean + separate `configs_repo_name` would be clearer. The boolean pattern is used elsewhere (`enable_review_gate`, `enable_security_scan`, `enable_destroy_approval`). Counter-argument: adding a boolean + name when the name being empty already conveys "disabled" is over-engineering.

---

### L-2: `CODE_ZIP` Artifact Format for Configs Repo May Interact Unexpectedly with Large Repos

**Severity:** LOW
**Category:** Operational Consideration

**Problem:**

The design uses `OutputArtifactFormat = "CODE_ZIP"` for the configs source action, reasoning that "Configs repo only needs file contents, not git history. ZIP is simpler and faster."

This is a sound decision. However, `CODE_ZIP` downloads the entire repo contents at the specified branch ref. If the configs repo is large (many projects, many files), the ZIP artifact will be large and consume more artifact bucket storage. The `artifact_retention_days` lifecycle policy will clean this up, but the per-execution storage cost is higher than necessary.

**Recommendation:**

Document that configs repos should be kept lean. The `configs_repo_path` feature mitigates this somewhat (only the relevant tfvars are consumed), but the entire repo is still downloaded and stored as an artifact. This is a CodePipeline limitation, not a module design issue. No code change needed.

---

### L-3: Missing Explicit `namespace` on the Dynamic Source Action

**Severity:** LOW
**Category:** Terraform Resource Configuration Completeness

**Problem:**

The dynamic Configs source action omits the `namespace` attribute. The existing GitHub source action also omits `namespace`. For `CodeStarSourceConnection` actions, the `namespace` attribute is optional and defaults to the action name. This is fine.

However, when two source actions exist in the same stage, their namespace values must be unique. Since `namespace` defaults to the action name, and the two actions have different names ("GitHub" and "Configs"), there is no collision.

**Recommendation:**

No change needed. The implicit namespace behavior is correct.

---

### L-4: The Design Does Not Show the Updated `CLAUDE.md` Parameter Table

**Severity:** LOW
**Category:** Documentation Completeness

**Problem:**

The `CLAUDE.md` file documents all pipeline parameters in the "Pipeline Parameters" section. The design adds 4 new parameters but does not include an update to `CLAUDE.md` in its scope.

**Recommendation:**

Add a task to update `CLAUDE.md` with the new parameters after implementation. This is standard post-implementation documentation work and does not need to be in the design document, but it should be tracked.

---

### L-5: The `all_codestar_connection_arns` Local Uses `distinct()` on a Two-Element List That May Contain Empty Strings

**Severity:** LOW
**Category:** Edge Case / Defensive Coding

**Problem:**

When `configs_repo = ""` and `codestar_connection_arn = ""` (i.e., the module creates its own connection and no configs repo), the local `configs_repo_connection_arn` resolves to:

```hcl
var.configs_repo_codestar_connection_arn != "" ? var.configs_repo_codestar_connection_arn : local.codestar_connection_arn
```

Since `configs_repo_codestar_connection_arn` defaults to `""`, it falls through to `local.codestar_connection_arn`, which is the created connection's ARN. So `all_codestar_connection_arns` becomes `distinct([created_arn, created_arn])` = `[created_arn]`. This is correct.

But if there were ever a code path where `codestar_connection_arn` remained empty AND the `aws_codestarconnections_connection.github[0]` resource failed to create (plan-time error), the local would contain empty strings, and the IAM policy would have `Resource = [""]` which is an invalid IAM policy.

**Recommendation:**

This is defensive paranoia -- the existing code has the same exposure for `local.codestar_connection_arn`. No change needed for MVP. If desired, add a `precondition` asserting the resolved connection ARN is non-empty.

---

## Summary Verdict

### Overall Assessment: APPROVED WITH CONDITIONS

The MVP design is **well-structured, follows established patterns, and demonstrates thoughtful consideration** of backward compatibility, artifact flow, and IAM implications. The conditional-at-every-level approach is clean and ensures zero behavioral change for existing consumers.

### Conditions for Approval

| # | Condition | Severity | Blocking? |
|---|-----------|----------|-----------|
| 1 | **Test pipeline resource recreation behavior** when toggling `configs_repo` on an existing deployment. Verify `terraform plan` shows in-place update, not replacement. (C-1) | CRITICAL | Yes |
| 2 | **Test the `PrimarySource` toggle-off scenario** end-to-end. Verify that removing `configs_repo` from an existing pipeline does not leave stale `PrimarySource` configuration. (C-2) | CRITICAL | Yes |
| 3 | **Add validation** preventing empty `configs_repo_branch` and normalizing `configs_repo_path`. (H-1) | HIGH | Yes |
| 4 | **Normalize the `configs_repo_path = "."`** case in locals or buildspec to avoid `/.` in constructed paths. (H-4) | HIGH | Recommended |
| 5 | **Clarify the Change Summary** regarding core vs. variant output changes. (M-5) | MEDIUM | No |
| 6 | **Add a Known Limitations section** documenting the all-pushes-trigger-all-pipelines behavior for shared configs repos. (M-4) | MEDIUM | Recommended |

### Strengths of the Design

1. **Zero-change backward compatibility** -- the `configs_repo = ""` default produces identical resources to the current implementation.
2. **Proper artifact flow** -- configs artifact is wired only to Plan and Destroy actions, not Deploy (which uses saved plans) or Test/PreBuild (which do not consume tfvars).
3. **IAM is minimal** -- only `codestar-connections:UseConnection` is added, using `distinct()` to avoid duplicate ARNs.
4. **Consistent with existing patterns** -- flat variables, pass-through wiring, dynamic blocks for conditional features.
5. **Correct CodeBuild multi-source handling** -- the `CODEBUILD_SRC_DIR_<artifactName>` pattern is properly documented and used.

### Risk Areas to Monitor Post-MVP

1. **Shared configs repo triggering** -- the post-MVP "change filtering" enhancement will be important for organizations using a mono-configs-repo pattern.
2. **Variable count growth** -- the module now has 26+ variables per variant. Future features should consider whether a grouped object variable pattern would reduce the API surface.
3. **Destroy project env var pattern divergence** -- the variant-owned destroy CodeBuild project continues to use a different env var pattern than core-managed projects.
