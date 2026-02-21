# Red Team Findings: Reliability Engineer -- CI/CD Pipeline Failure Mode Specialist

**Reviewer:** Reliability Engineer -- CI/CD Pipeline Failure Mode Specialist
**Focus Area:** Race conditions, artifact integrity, pipeline failure modes, state corruption scenarios, backward compatibility regressions, edge cases in conditional logic, and operational failure recovery.
**Document Under Review:** [MVP-DESIGN.md](../MVP-DESIGN.md) -- Discrete Configs Repository Support
**Date:** 2026-02-21

---

## Executive Summary

The MVP design for discrete configs repository support is structurally sound in its conditional architecture -- the `configs_enabled` gate, the artifact wiring, and the IAM changes are well-reasoned. However, analysis reveals **12 findings** across several risk categories, with the most critical concerns centered on dual-trigger race conditions that could produce config/code version mismatches, path construction edge cases in buildspecs that could silently resolve to wrong file locations, and a gap in the destroy stage where stale configs from a much earlier pipeline execution could diverge from the state being destroyed. None of these are design-breaking, but several require mitigation before production readiness.

---

## Findings

### Finding 1: Dual-Trigger Race Condition -- Config/Code Version Mismatch

**Severity: HIGH**

**Description:**
Both source actions have `DetectChanges = "true"`, meaning a push to either the IaC repo or the configs repo triggers the pipeline. CodePipeline V2 starts a new execution when either source detects a change. However, when a push to the configs repo triggers the pipeline, the IaC source action fetches the *latest* commit on its tracked branch at that moment -- not the commit that was paired with the previous successful deployment. Conversely, when the IaC repo triggers the pipeline, it fetches the latest configs repo commit.

This creates a window for version skew:

1. Developer A pushes an IaC change that adds a new required variable `foo` to a module.
2. Developer B has not yet pushed the corresponding `foo = "bar"` value to the configs repo.
3. Developer A's push triggers the pipeline. The Source stage pulls the latest IaC (with the new variable) and the latest configs repo (without the `foo` value).
4. `terraform plan` fails because the required variable has no value.

This is the *benign* case -- the plan fails loudly. The dangerous case is:

1. Developer A pushes an IaC change that *renames* a variable from `instance_type` to `compute_type`.
2. Developer B has not updated the configs repo yet.
3. Pipeline runs with new code + old configs. The old `instance_type` value is silently ignored (not an error in Terraform unless the old variable has no default), and `compute_type` gets its default value or no value.
4. The plan succeeds with *unintended* configuration -- potentially deploying with wrong instance sizes.

This is inherent to dual-source pipelines and not unique to this design. However, the design does not acknowledge this risk or provide guidance.

**Recommendation:**
- Document this race condition explicitly in the consumer guidance section.
- Recommend that teams use coordinated PRs (merge IaC change first, then configs change) or a single-commit strategy when variable interfaces change.
- Consider a post-MVP enhancement: add a `CONFIGS_COMMIT_SHA` environment variable logged during plan so operators can audit which exact config version was used.

---

### Finding 2: Path Construction Double-Slash When `configs_repo_path = "."`

**Severity: MEDIUM**

**Description:**
The buildspec constructs the var-file path as:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

When `configs_repo_path` defaults to `"."`, this resolves to:

```
/codebuild/output/src123/.../environments/dev.tfvars
```

The `"."` in the path becomes `${CONFIGS_DIR}/./environments/dev.tfvars`. While Linux filesystems treat `/./` as equivalent to `/`, this is:

1. **Fragile** -- relies on OS path normalization rather than explicit handling.
2. **Log noise** -- the echo statement `"Configs repo enabled -- looking for tfvars at: /codebuild/..././environments/dev.tfvars"` is confusing to operators reading build logs.
3. **Risk with `-f` test** -- while `-f` handles `./` correctly on Linux, some edge cases with symlinks or mounted filesystems could behave differently.

More critically, if a user accidentally sets `configs_repo_path = ""` (empty string, distinct from the default `"."`), the path becomes:

```
${CONFIGS_DIR}//environments/dev.tfvars
```

Double-slash is also handled by Linux, but the variable validation in the design does not prevent empty string. The variable has `default = "."` but no `validation` block to reject `""`.

**Recommendation:**
- Add a validation block on `configs_repo_path` that rejects empty string:
  ```hcl
  validation {
    condition     = var.configs_repo_path != ""
    error_message = "configs_repo_path must not be empty. Use '.' for the repo root."
  }
  ```
- In the buildspec, normalize the path to strip trailing slashes and handle `"."` explicitly:
  ```bash
  if [ "${CONFIGS_PATH}" = "." ] || [ -z "${CONFIGS_PATH}" ]; then
    VARFILE_PATH="${CONFIGS_DIR}/environments/${TARGET_ENV}.tfvars"
  else
    VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
  fi
  ```

---

### Finding 3: `CONFIGS_ENABLED` Is a String, Not a Boolean -- Fragile Comparison

**Severity: MEDIUM**

**Description:**
The design uses `tostring(local.configs_enabled)` to pass the boolean as a CodeBuild environment variable, then checks it in bash with:

```bash
if [ "${CONFIGS_ENABLED}" = "true" ]; then
```

This works correctly when the value is exactly `"true"`. However:

1. `tostring(true)` in Terraform produces `"true"` -- this is correct.
2. `tostring(false)` in Terraform produces `"false"` -- the else branch is taken, which is correct.

The risk is *operational*: if someone debugging a failed pipeline manually overrides the `CONFIGS_ENABLED` environment variable in the CodeBuild project console (a common troubleshooting step), they might set it to `"True"`, `"TRUE"`, `"yes"`, or `"1"` -- all of which would silently fall through to the `else` branch, disabling configs repo sourcing without any warning.

**Recommendation:**
- Add a case-insensitive comparison or explicit validation in the buildspec:
  ```bash
  CONFIGS_ENABLED_LOWER=$(echo "${CONFIGS_ENABLED}" | tr '[:upper:]' '[:lower:]')
  if [ "${CONFIGS_ENABLED_LOWER}" = "true" ]; then
  ```
- Alternatively, log the value explicitly before the branch so operators can see what decision was made:
  ```bash
  echo "CONFIGS_ENABLED=${CONFIGS_ENABLED}"
  ```

---

### Finding 4: Destroy Stage Operates on Stale Configs Artifact

**Severity: HIGH**

**Description:**
In the `default-dev-destroy` variant, the Destroy-DEV stage runs after Test-PROD -- potentially hours or days after the Source stage fetched the configs artifact (if there is a PROD approval gate and a Destroy approval gate in the way).

The `configs_output` artifact used by the Destroy-DEV action is the *same artifact* produced by the Source stage at the beginning of the pipeline execution. If the configs repo was updated between the time the pipeline started and the time the destroy stage executes, the destroy action uses the *old* configs -- not the current ones.

Scenario:
1. Pipeline starts, fetches IaC v1.0 + configs v1.0 (instance_type = t3.small).
2. DEV deploys successfully with t3.small.
3. PROD approval takes 24 hours.
4. During those 24 hours, someone pushes configs v1.1 (instance_type = t3.large) to the configs repo.
5. PROD deploys with configs v1.0 (t3.small) -- this is correct, plan-apply integrity is preserved.
6. Destroy-DEV runs with configs v1.0 (t3.small).

In this specific scenario, the destroy *should* use v1.0 because that is what was deployed. However, the problem arises if:

- The IaC code was also updated (v1.1) which added a new *required* variable.
- Configs v1.0 does not have that variable.
- The destroy action re-runs `terraform init` and `terraform destroy` using the IaC v1.0 code (from source_output), which is also stale -- but stale in a *consistent* way.

Actually, on closer analysis, this is internally consistent: both `source_output` and `configs_output` are from the same pipeline execution. The destroy uses the same code and config versions as the deploy. This is actually *correct* behavior for plan-apply-destroy integrity within a single pipeline execution.

**Revised assessment:** The staleness is not a bug -- it is the expected behavior of pipeline artifact immutability. However, the design should document this explicitly so operators understand why the destroy stage might use "old" configs.

**Revised Severity: LOW**

**Recommendation:**
- Document in consumer guidance that the destroy stage uses the configs artifact from the same pipeline execution that performed the deploy, which may differ from the current HEAD of the configs repo.
- This is correct behavior but should be called out to avoid operator confusion.

---

### Finding 5: `CODEBUILD_SRC_DIR_configs_output` Undefined When Configs Disabled

**Severity: MEDIUM**

**Description:**
The design correctly notes that when `CONFIGS_ENABLED` is `"false"`, the `configs_output` artifact is not passed to the CodeBuild action, so `CODEBUILD_SRC_DIR_configs_output` will not exist as an environment variable.

However, the buildspec unconditionally references `CODEBUILD_SRC_DIR_configs_output` inside the `if` block. If the condition is `true` but the artifact is actually missing (a misconfiguration where someone set `CONFIGS_ENABLED=true` as a CodeBuild env var override but the pipeline does not actually have a configs source action), the line:

```bash
CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output}"
```

would set `CONFIGS_DIR` to an empty string. The subsequent path construction:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

would resolve to `//./environments/dev.tfvars` or similar -- which would likely resolve to the filesystem root, fail the `-f` test, and proceed without a var-file. The plan would run without tfvars, potentially deploying with default values -- a silent misconfiguration.

The `set -euo pipefail` at the top of the buildspec phase does NOT catch this because:
- The variable expansion `${CODEBUILD_SRC_DIR_configs_output}` with `set -u` would fail if the variable is truly unset -- this IS caught.
- But if someone overrides `CONFIGS_ENABLED` to `"true"` manually while the pipeline *does* pass the artifact but the artifact is empty or corrupt, the `-f` test silently falls through.

**Recommendation:**
- Add an explicit guard after setting `CONFIGS_DIR`:
  ```bash
  if [ "${CONFIGS_ENABLED}" = "true" ]; then
    CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output}"
    if [ -z "${CONFIGS_DIR}" ] || [ ! -d "${CONFIGS_DIR}" ]; then
      echo "ERROR: CONFIGS_ENABLED is true but configs artifact directory is missing or empty: '${CONFIGS_DIR}'"
      exit 1
    fi
  ```
- This converts a silent misconfiguration into a hard failure, which is the correct behavior per the project's "let it crash" philosophy.

---

### Finding 6: Toggling `configs_repo` On/Off for an Existing Pipeline -- Terraform Plan Churn

**Severity: MEDIUM**

**Description:**
When an existing pipeline has been running without a configs repo and the consumer adds `configs_repo = "my-org/my-configs"`, the Terraform plan will show:

1. The `aws_codepipeline.this` resource is modified in-place (new source action added, plan actions gain secondary input artifacts, `PrimarySource` configuration added).
2. The `aws_codebuild_project.this["plan-dev"]` and `plan-prod` resources are modified in-place (new `CONFIGS_ENABLED` and `CONFIGS_PATH` environment variables added).

This is expected. However, when the consumer later *removes* `configs_repo` (sets it back to `""`), the reverse changes occur. The concern is:

- The CodePipeline resource update replaces the entire stage definition. During the update, there is a brief window where the pipeline is in a transitional state. If a source event triggers during this window, the pipeline could start with a partially-updated stage definition.
- AWS CodePipeline updates are not atomic at the stage level -- the `UpdatePipeline` API replaces the entire pipeline definition. If the API call succeeds, the new definition is active. If it fails, the old definition remains.

The real risk is **not during the Terraform apply** but during the **first pipeline execution after toggling**. If `configs_repo` was just disabled:
- The `CONFIGS_ENABLED` environment variable on the CodeBuild projects changes to `"false"`.
- The pipeline no longer has a configs source action.
- But if there is a pipeline execution already in-flight (started before the Terraform apply), that execution was built with the *old* pipeline definition (which included the configs source action). It will complete normally.
- The *next* execution uses the new definition without configs -- this is correct.

**Recommendation:**
- Document the toggle behavior: advise consumers to let any in-flight pipeline execution complete before toggling `configs_repo` on or off.
- Consider adding a `lifecycle { create_before_destroy = false }` note in the design documentation to clarify that CodePipeline updates are non-destructive to in-flight executions (CodePipeline handles this natively).

---

### Finding 7: `configs_repo_path` Trailing Slash Produces Invalid Path

**Severity: MEDIUM**

**Description:**
If a user sets `configs_repo_path = "projects/my-project/"` (with a trailing slash), the constructed path becomes:

```
${CONFIGS_DIR}/projects/my-project//environments/dev.tfvars
```

While Linux handles double slashes, this is:
1. Visually confusing in logs.
2. Not consistent with the documented examples (which never show trailing slashes).
3. A sign that input is not being sanitized.

Similarly, a leading slash (`configs_repo_path = "/projects/my-project"`) would produce:

```
${CONFIGS_DIR}//projects/my-project/environments/dev.tfvars
```

And a path with spaces or special characters is not validated.

**Recommendation:**
- Add a validation block on `configs_repo_path`:
  ```hcl
  validation {
    condition     = var.configs_repo_path == "." || can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_.-]*[a-zA-Z0-9]$", var.configs_repo_path))
    error_message = "configs_repo_path must be '.' or a relative path without leading/trailing slashes."
  }
  ```
- This prevents trailing slashes, leading slashes, empty strings, and most special characters.

---

### Finding 8: No Artifact Name Collision Guard Between Existing and New Artifacts

**Severity: LOW**

**Description:**
The design introduces a new artifact named `configs_output`. The existing artifacts are `source_output`, `dev_plan_output`, and `prod_plan_output`. There is no collision risk *today*, but the design should document the artifact namespace to prevent future features from accidentally reusing the name `configs_output`.

More concretely, if a future enhancement adds a third source action (e.g., a shared-modules repo), someone might name it `configs_output` without realizing the name is taken. CodePipeline would reject this with a duplicate artifact name error, but only at deploy time -- not at `terraform plan` time.

**Recommendation:**
- Add a comment in the variant `main.tf` files documenting the artifact namespace:
  ```hcl
  # Pipeline artifact namespace:
  #   source_output      - IaC repo checkout
  #   configs_output     - Configs repo checkout (conditional)
  #   dev_plan_output    - Saved DEV terraform plan
  #   prod_plan_output   - Saved PROD terraform plan
  ```
- This is a documentation-only recommendation.

---

### Finding 9: CodePipeline V2 Supersession Behavior with Dual Triggers

**Severity: HIGH**

**Description:**
CodePipeline V2 has an execution mode that determines how concurrent triggers are handled. The design does not specify the `execution_mode` for the pipeline. The default for CodePipeline V2 is `SUPERSEDED` mode, which means:

- If a new execution starts while a previous execution is in progress, the new execution *supersedes* the old one.
- The old execution is stopped at the next transition point (stage boundary).
- The new execution uses the latest source revisions.

With dual triggers, this creates a specific failure mode:

1. Push to IaC repo triggers execution A. Source stage fetches IaC v2 + configs v1.
2. Execution A reaches the DEV Plan stage.
3. Push to configs repo triggers execution B. Source stage fetches IaC v2 + configs v2.
4. Execution A is superseded and stops.
5. Execution B proceeds.

This is *generally correct* -- the latest code + config is what gets deployed. But:

- If execution A had already completed DEV deploy (IaC v2 + configs v1), and execution B supersedes A at the PROD plan stage, then:
  - DEV has IaC v2 + configs v1 deployed.
  - Execution B will plan and deploy PROD with IaC v2 + configs v2.
  - DEV and PROD now have *different* configs versions.

- In the `default-dev-destroy` variant, if execution A completed DEV deploy but execution B supersedes it before DEV tests or PROD, the DEV environment remains deployed with v1 configs and never gets destroyed (the destroy stage of execution A was superseded).

**Recommendation:**
- Document the interaction between `SUPERSEDED` execution mode and dual triggers.
- Consider recommending `QUEUED` mode for pipelines using configs repo to ensure sequential execution:
  ```hcl
  execution_mode = "QUEUED"
  ```
  This ensures each trigger completes fully before the next begins, preventing config version divergence between environments. However, this trades off deployment latency for consistency.
- At minimum, add a note in consumer guidance about this behavior.

---

### Finding 10: Configs Repo CodeStar Connection Fallback When `codestar_connection_arn = ""`

**Severity: MEDIUM**

**Description:**
The design specifies:

```hcl
configs_repo_connection_arn = var.configs_repo_codestar_connection_arn != "" ? var.configs_repo_codestar_connection_arn : local.codestar_connection_arn
```

When `codestar_connection_arn = ""` (the user did not provide one), the core module creates a new connection:

```hcl
codestar_connection_arn = var.codestar_connection_arn != "" ? var.codestar_connection_arn : aws_codestarconnections_connection.github[0].arn
```

This means `local.codestar_connection_arn` points to a *newly created* CodeStar Connection. The problem:

- A newly created CodeStar Connection is in `PENDING` state until manually authorized via the AWS Console.
- If the user enables a configs repo but does not provide `codestar_connection_arn` or `configs_repo_codestar_connection_arn`, the pipeline is created with a single PENDING connection used for both sources.
- The user must authorize the connection for it to work with *both* the IaC repo's GitHub org and the configs repo's GitHub org.
- If the IaC repo and configs repo are in different GitHub organizations, a single CodeStar Connection cannot access both (GitHub App installations are per-org). The pipeline would deploy successfully but fail when the source stage tries to fetch the configs repo.

This failure would only manifest at pipeline *runtime*, not at `terraform plan` or `terraform apply` time.

**Recommendation:**
- Add a validation rule: if `configs_repo` is set and the configs repo org differs from the IaC repo org (detectable by splitting on `/`), require `configs_repo_codestar_connection_arn` to be explicitly set.
  ```hcl
  validation {
    condition = (
      var.configs_repo == "" ||
      var.configs_repo_codestar_connection_arn != "" ||
      split("/", var.configs_repo)[0] == split("/", var.github_repo)[0]
    )
    error_message = "configs_repo_codestar_connection_arn is required when configs_repo is in a different GitHub organization than github_repo."
  }
  ```
- This catches the misconfiguration at plan time rather than runtime.

---

### Finding 11: `iac_working_directory` Interaction with Configs Path Resolution

**Severity: LOW**

**Description:**
The current plan buildspec changes directory to `${CODEBUILD_SRC_DIR}/${IAC_WORKING_DIR}` before looking for tfvars. In the current (non-configs) path, the tfvars lookup is:

```bash
if [ -f "environments/${TARGET_ENV}.tfvars" ]; then
```

This is relative to the working directory (`${IAC_WORKING_DIR}` within the IaC repo). So if `iac_working_directory = "infra"`, the pipeline looks for `infra/environments/dev.tfvars` within the IaC repo.

When configs repo is enabled, the lookup becomes:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

This is an *absolute* path within the configs artifact directory -- it is NOT relative to `IAC_WORKING_DIR`. This is correct behavior (the configs repo has its own directory structure independent of the IaC repo's working directory), but it is a subtle semantic difference that could confuse consumers.

A consumer who previously had `iac_working_directory = "infra"` with their tfvars at `infra/environments/dev.tfvars` in the IaC repo might expect to set `configs_repo_path = "infra"` in the configs repo. But in fact, the configs repo path is independent -- they should set `configs_repo_path = "."` if their configs repo has `environments/dev.tfvars` at the root.

**Recommendation:**
- Add a callout in the consumer usage section clarifying that `configs_repo_path` is relative to the configs repo root and is independent of `iac_working_directory`.
- Include an example showing the correct mapping for a consumer migrating from embedded tfvars to a configs repo.

---

### Finding 12: Plan Buildspec `set -euo pipefail` and Unbound `CONFIGS_ENABLED` on Legacy Builds

**Severity: LOW**

**Description:**
The current plan buildspec uses `set -euo pipefail`, where `-u` causes the shell to error on unset variables. When the updated buildspec is deployed, the `CONFIGS_ENABLED` environment variable is added to the CodeBuild project configuration. However, if there is a timing issue where the buildspec is updated (via the CodeBuild project's `buildspec` attribute) but the environment variable has not been propagated yet, the buildspec would fail on `${CONFIGS_ENABLED}` being unset.

In practice, this cannot happen because the CodeBuild project's `buildspec` and `environment_variable` blocks are attributes of the same resource -- they are applied atomically in a single `UpdateProject` API call. However, the design should note this for completeness.

A more realistic scenario: if someone manually triggers a CodeBuild build (outside of CodePipeline) without setting `CONFIGS_ENABLED`, the buildspec fails with `CONFIGS_ENABLED: unbound variable`. This is correct fail-fast behavior, but the error message is opaque.

**Recommendation:**
- Consider adding a default at the top of the buildspec:
  ```bash
  CONFIGS_ENABLED="${CONFIGS_ENABLED:-false}"
  ```
  This provides a safe default when the variable is unset (e.g., manual CodeBuild trigger) while preserving the intended behavior when the variable is properly set by the pipeline.
- Alternatively, document that manual CodeBuild triggers require setting `CONFIGS_ENABLED=false` explicitly.

---

## Summary Verdict

| Severity | Count | Findings |
|----------|-------|----------|
| CRITICAL | 0 | -- |
| HIGH | 2 | #1 (Dual-trigger race condition), #9 (V2 supersession with dual triggers) |
| MEDIUM | 5 | #2 (Path double-slash), #3 (String boolean comparison), #5 (Undefined CONFIGS_DIR guard), #6 (Toggle plan churn), #7 (Trailing slash), #10 (CodeStar Connection cross-org fallback) |
| LOW | 3 | #4 (Destroy stale configs -- revised), #8 (Artifact namespace), #11 (iac_working_directory interaction), #12 (Unbound variable on manual trigger) |

**Overall Assessment: CONDITIONALLY APPROVED**

The design is architecturally sound. The conditional pattern (`configs_enabled` gate at every layer) correctly isolates the feature and preserves backward compatibility. The artifact flow, IAM changes, and buildspec modifications are logically correct.

The two HIGH findings (#1 and #9) are inherent to dual-source, dual-trigger pipeline architectures and do not represent design flaws -- they represent operational risks that must be documented and mitigated through consumer guidance. Finding #9 specifically warrants a design decision on `execution_mode` that should be made explicitly rather than relying on the default.

The MEDIUM findings are implementation-level concerns that should be addressed during the build phase. The most important are #5 (hard-fail when configs artifact is missing) and #10 (cross-org connection validation), which prevent silent misconfigurations from reaching production.

**Recommended actions before implementation:**
1. Decide on CodePipeline `execution_mode` (`SUPERSEDED` vs. `QUEUED`) and document the tradeoffs.
2. Add input validation for `configs_repo_path` (reject empty string, trailing/leading slashes).
3. Add cross-org connection validation (Finding #10).
4. Add `CONFIGS_DIR` existence guard in buildspecs (Finding #5).
5. Document dual-trigger race conditions in consumer guidance.

None of the findings require redesign. All are addressable with validation rules, buildspec guards, and documentation.
