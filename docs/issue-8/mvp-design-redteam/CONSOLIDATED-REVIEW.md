# Consolidated Red Team Review: Discrete Configs Repository MVP Design

**Date:** 2026-02-21
**Document Under Review:** [MVP-DESIGN.md](../MVP-DESIGN.md)
**Status:** Consolidated from three independent Red Team analyses

This document consolidates findings from three Red Team reviewers:

1. **Security Analyst** -- AWS IAM & Pipeline Security Specialist (10 findings)
2. **Reliability Engineer** -- CI/CD Pipeline Failure Mode Specialist (12 findings)
3. **Terraform Architect** -- IaC Design Patterns & API Surface Specialist (12 findings)

---

## Executive Summary

The MVP design for discrete configs repository support is architecturally sound. All three reviewers independently confirmed that the conditional-at-every-level approach, backward compatibility preservation, and minimal IAM changes demonstrate strong design judgment. The artifact flow (configs wired only to Plan and Destroy, not Deploy or Test) is correct, and the `CODEBUILD_SRC_DIR_<artifactName>` pattern is properly leveraged.

However, the review surfaced significant concerns that cluster around three themes: (1) the configs repo introduces a second trust domain with equivalent influence over deployed infrastructure but potentially weaker governance, (2) the `configs_repo_path` variable lacks validation against path traversal, empty strings, and malformed input, and (3) toggling `configs_repo` on or off for an existing pipeline may trigger resource force-replacement rather than in-place update, with additional risk of stale API-side configuration.

After deduplication, **17 consolidated findings** remain from the original 34 raw findings across all three reviewers.

| Severity | Count |
|----------|-------|
| CRITICAL | 3 (all out of scope) |
| HIGH     | 5 |
| MEDIUM   | 7 |
| LOW      | 2 |

**Overall Verdict: APPROVED WITH CONDITIONS** -- The design does not require a redesign. All findings are addressable through input validation, buildspec guards, and documentation. All three CRITICAL findings are out of scope (repository governance and toggle behavior are consumer responsibilities). The two blocking HIGH findings (CF-04, CF-06) must be resolved before implementation begins.

---

## Consolidated Findings

### CF-01: Configs Repo as Unvalidated Terraform Input Injection Vector (Trust Boundary Expansion)

**Severity:** CRITICAL
**Flagged by:** Security Analyst (FINDING-01)

**Description:**

The configs repo provides `.tfvars` files that are passed directly to `terraform plan -var-file=...` and `terraform destroy -var-file=...`. Terraform `.tfvars` files can set any declared variable, including those that control IAM role ARNs, CIDR ranges, resource names, S3 bucket names, and any other infrastructure parameter. A compromised or maliciously modified configs repo can silently alter the infrastructure plan in ways that are not visible from the IaC code review alone.

The design explicitly separates the trust domain. The IaC repo and configs repo may have different owners, different branch protection policies, different access control lists, and different review cadences. Key concerns:

1. No code review gate on config changes that trigger PROD deployments. A push to the configs repo triggers the full pipeline including PROD. While the PROD stage has a mandatory manual approval, the approver sees a Terraform plan generated from the configs repo's values. If the approver does not deeply review the plan output for unexpected variable changes, a malicious tfvars change (e.g., widening a security group CIDR, changing an IAM policy ARN) can pass through.

2. The configs repo bypasses the IaC repo's PR review process entirely. The design explicitly enables config-only changes to run the full pipeline without touching the IaC repo. This means the IaC repo's branch protection, CODEOWNERS, required reviewers, and status checks are all irrelevant for config-driven changes.

3. The `configs_repo_path` variable allows targeting arbitrary subdirectories, meaning a shared configs repo serving multiple projects could have cross-project impact if path boundaries are misconfigured.

**Recommendation:**

1. Add prominent documentation and consumer guidance that the configs repo **must** be governed with equivalent or stricter branch protection and access controls compared to the IaC repo, because it has equivalent influence over deployed infrastructure.
2. The PROD approval gate's `CustomData` should include a note reminding the approver to review the plan for unexpected variable-driven changes, especially when the pipeline was triggered by a configs repo push.
3. Consider a post-MVP validation stage that diffs the tfvars against a baseline and flags unexpected changes to security-sensitive variables.
4. Consider whether `enable_review_gate` (DEV approval) should be recommended when using a configs repo, to provide an additional checkpoint for config-driven changes.

---

### CF-02: CodePipeline Resource Force-Replacement When Toggling `configs_repo`

**Severity:** CRITICAL
**Flagged by:** Terraform Architect (C-1), Reliability Engineer (Finding 6)

**Description:**

When an existing pipeline consumer adds or removes `configs_repo`, the `aws_codepipeline.this` resource undergoes significant structural changes in a single apply: the Source stage gains or loses an action, Plan actions change their `input_artifacts` list, and Plan actions change their `configuration` block (adding/removing `PrimarySource`).

The Terraform AWS provider's handling of `aws_codepipeline` stage blocks is sensitive to structural changes. Adding or removing an action within a stage -- particularly a source action that introduces a new artifact name referenced by downstream stages -- has historically caused Terraform to compute a force-replacement (`-/+`) rather than an in-place update, depending on provider version.

**Risk:** A consumer toggling `configs_repo` on or off may trigger a pipeline destroy-and-recreate rather than an in-place update. This means:
- Pipeline execution history is lost.
- Any in-flight pipeline executions are terminated.
- The pipeline ARN changes, breaking downstream references (CloudWatch alarms, EventBridge rules, dashboards).

The Reliability Engineer additionally noted that during the update window, if a source event triggers, the pipeline could start with a partially-updated stage definition. The `UpdatePipeline` API replaces the entire pipeline definition atomically, but in-flight executions use the old definition.

**Recommendation:**

1. **Test this explicitly before shipping.** Create a pipeline without `configs_repo`, apply it, then add `configs_repo` and run `terraform plan`. Verify the plan shows `~ update in-place` and NOT `must be replaced` or `-/+ (destroy and then create replacement)`.
2. If force-replacement occurs, document it as a known limitation with a migration path (e.g., `terraform state rm` + `terraform import`, or a `lifecycle` pattern).
3. Add consumer documentation that toggling `configs_repo` on an existing pipeline should be done during a maintenance window, and any in-flight pipeline execution should be allowed to complete first.

---

### CF-03: `PrimarySource` Conditional Merge Causes Silent Configuration Drift on Toggle-Off

**Severity:** CRITICAL
**Flagged by:** Terraform Architect (C-2)

**Description:**

The design uses a conditional `merge()` for the Plan action `configuration` block:

```hcl
configuration = merge(
  { ProjectName = module.core.codebuild_project_names["plan-dev"] },
  module.core.configs_enabled ? { PrimarySource = "source_output" } : {}
)
```

When `configs_enabled` transitions from true to false, Terraform omits `PrimarySource` from the configuration map. However, the `aws_codepipeline` resource does not explicitly send `PrimarySource = null` to the AWS API -- it simply omits the key. Whether the API clears the field or retains the previously-set value is AWS API behavior, not Terraform behavior.

**Risk:** If the API retains stale `PrimarySource = "source_output"` server-side after toggle-off, the Plan actions may either:
- Ignore `PrimarySource` (benign -- only one input artifact), or
- Error at runtime because `PrimarySource` references an artifact name that no longer exists in the action's `input_artifacts` list.

**Recommendation:**

1. **Test the toggle-off scenario end-to-end:** enable configs repo, apply, disable configs repo, apply, then trigger the pipeline and verify Plan actions succeed.
2. If the API retains stale `PrimarySource`, consider always setting `PrimarySource = "source_output"` regardless of `configs_enabled`. CodeBuild accepts `PrimarySource` when there is only one input artifact if it matches that artifact's name. This eliminates the conditional entirely and removes the drift risk.

---

### CF-04: Path Traversal and Input Validation Gaps in `configs_repo_path`

**Severity:** HIGH
**Flagged by:** Security Analyst (FINDING-03), Reliability Engineer (Finding 2, Finding 7), Terraform Architect (H-1, H-4)

**Description:**

All three reviewers independently identified that `configs_repo_path` lacks input validation and has multiple path construction edge cases. The variable is passed to CodeBuild as `CONFIGS_PATH` and used in the buildspec to construct a file path:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

The identified issues are:

1. **Path traversal (Security Analyst):** No validation prevents values like `"../../.."`, which could resolve paths outside the configs artifact directory. A malicious `configs_repo_path = "../../../tmp"` causes the buildspec to look for tfvars at unintended filesystem locations. While the CodeBuild filesystem is ephemeral, traversal could read files from the primary source artifact or other mounted locations and use them as Terraform variable input.

2. **Empty string (Reliability Engineer):** The variable has `default = "."` but no validation preventing `""`. An empty string produces `${CONFIGS_DIR}//environments/dev.tfvars` (double-slash), which Linux handles but is fragile and confusing in logs.

3. **Trailing/leading slashes (Reliability Engineer, Terraform Architect):** `configs_repo_path = "projects/my-project/"` produces double-slashes. Leading slashes produce similar issues. No validation prevents these.

4. **Dot-slash path (Reliability Engineer, Terraform Architect):** When `configs_repo_path = "."` (default), the path resolves to `${CONFIGS_DIR}/./environments/dev.tfvars`. While POSIX-valid, this produces confusing log output and relies on OS path normalization rather than explicit handling.

5. **Special characters (Reliability Engineer):** Paths with spaces or special characters are not validated.

**Recommendation:**

1. Add input validation on `configs_repo_path` combining path traversal prevention, empty string rejection, and format enforcement:

```hcl
variable "configs_repo_path" {
  # ...
  validation {
    condition     = var.configs_repo_path == "." || (
      !can(regex("(^/|\\.\\.|\\x00)", var.configs_repo_path)) &&
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_.-]*[a-zA-Z0-9]$", var.configs_repo_path))
    )
    error_message = "configs_repo_path must be '.' or a relative path without path traversal (..), leading/trailing slashes, or special characters."
  }
}
```

2. Add a runtime assertion in the buildspec that the resolved path is within the configs artifact directory:

```bash
RESOLVED_PATH=$(realpath -m "${VARFILE_PATH}")
if [[ "${RESOLVED_PATH}" != "${CONFIGS_DIR}"* ]]; then
  echo "ERROR: Resolved tfvars path is outside configs artifact directory. Aborting."
  exit 1
fi
```

3. Normalize the `"."` case to avoid `/./` in paths. Either normalize in locals (`configs_repo_path_normalized = var.configs_repo_path == "." ? "" : var.configs_repo_path`) and handle empty vs. non-empty in the buildspec, or explicitly handle `"."` in the buildspec branching.

---

### CF-05: Dual-Trigger Race Conditions and CodePipeline V2 Supersession Behavior

**Severity:** HIGH
**Flagged by:** Reliability Engineer (Finding 1, Finding 9), Security Analyst (FINDING-10), Terraform Architect (M-4)

**Description:**

Three reviewers identified overlapping concerns about the dual-trigger architecture where `DetectChanges = "true"` on both source actions.

**Config/Code version mismatch (Reliability Engineer):** When a push to one repo triggers the pipeline, the Source stage fetches the latest commit from both repos at that moment. This creates a window for version skew: an IaC change that adds a new required variable triggers the pipeline before the configs repo has the corresponding value. The benign case is a loud plan failure. The dangerous case is a renamed variable where the old value is silently ignored and the new variable gets a default.

**CodePipeline V2 supersession (Reliability Engineer):** The design does not specify `execution_mode`. The default `SUPERSEDED` mode means a new execution supersedes an in-progress one. With dual triggers, this creates a scenario where:
- Execution A completes DEV deploy with IaC v2 + configs v1.
- Execution B (triggered by configs push) supersedes A at the PROD stage.
- Execution B deploys PROD with IaC v2 + configs v2.
- DEV and PROD now have different configs versions.
- In the `default-dev-destroy` variant, the DEV destroy stage of execution A is superseded and never runs.

**All-pushes trigger all pipelines (Terraform Architect):** When a configs repo serves multiple projects, any push to the tracked branch triggers ALL pipelines referencing that configs repo, regardless of `configs_repo_path`. A push that changes `projects/other-project/environments/dev.tfvars` triggers pipelines for `projects/my-project/` as well. CodePipeline V2 trigger filtering (by file path) is a post-MVP enhancement already acknowledged in the MVP statement.

**Rapid trigger rate-limiting (Security Analyst):** Rapid successive triggers from the configs repo (force-push, CI bot commits) cause pipeline thrashing. The SUPERSEDED mode handles this, but the doubled trigger surface increases probability.

**Recommendation:**

1. Make an explicit design decision on CodePipeline `execution_mode` (`SUPERSEDED` vs. `QUEUED`) and document the tradeoffs. `QUEUED` ensures sequential execution, preventing config version divergence between environments, but increases deployment latency.
2. Document the dual-trigger race condition explicitly in consumer guidance. Recommend coordinated PRs when variable interfaces change.
3. Add a "Known Limitations" section to the design document stating that shared configs repos trigger all pipelines on any push, regardless of `configs_repo_path`.
4. Consider a post-MVP enhancement to include the trigger source (IaC vs. configs) in the PROD approval notification.
5. Consider logging `CONFIGS_COMMIT_SHA` during plan so operators can audit which exact config version was used.

---

### CF-06: Cross-Variable Validation Gaps and Cross-Org Connection Fallback

**Severity:** HIGH
**Flagged by:** Terraform Architect (H-1), Reliability Engineer (Finding 10)

**Description:**

Two reviewers identified that the four new variables lack cross-validation, allowing invalid configurations that fail at runtime rather than plan time.

**Empty branch (Terraform Architect):** `configs_repo_branch` has no validation preventing `""`. An empty string passed to CodePipeline's `BranchName` causes an API error at apply time, not plan time.

**Cross-org connection fallback (Reliability Engineer):** When `configs_repo` is set but `configs_repo_codestar_connection_arn` is not provided, the pipeline falls back to the IaC repo's CodeStar Connection. If the IaC repo and configs repo are in different GitHub organizations, a single CodeStar Connection cannot access both (GitHub App installations are per-org). The pipeline deploys successfully but fails when the Source stage tries to fetch the configs repo -- a runtime failure invisible at plan time.

**Unnecessary connection ARN (Terraform Architect):** `configs_repo = ""` with `configs_repo_codestar_connection_arn = "arn:aws:..."` is accepted, including an unnecessary ARN in the IAM policy. Low risk, but confusing.

**Recommendation:**

1. Add validation on `configs_repo_branch`:
```hcl
validation {
  condition     = var.configs_repo_branch != ""
  error_message = "configs_repo_branch must not be empty."
}
```

2. Add cross-org connection validation to catch misconfiguration at plan time:
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

3. If cross-variable validation is not available in the minimum supported Terraform version, use a `precondition` on the CodePipeline resource.

---

### CF-07: CodeStar Connection IAM Scope Expansion Without Repository Scoping

**Severity:** HIGH
**Flagged by:** Security Analyst (FINDING-02)

**Description:**

The IAM action `codestar-connections:UseConnection` grants the ability to use the connection to access **any repository** that the GitHub App installation can see in the connected organization, not just the specific repos configured in the pipeline.

When the configs repo uses a different connection (`configs_repo_codestar_connection_arn`), both the CodePipeline and CodeBuild service roles gain `UseConnection` on this second connection. This means the CodeBuild service role can access repositories from a second GitHub organization -- an expansion of cross-organization access. The `codestar-connections:UseConnection` permission does not support resource-level conditions that restrict which repository can be accessed through the connection; the only boundary is the GitHub App's installation scope on the GitHub side.

**Attack Scenario:** If the CodeBuild service role is compromised (e.g., through a malicious prebuild script), the attacker gains `UseConnection` on the configs repo's CodeStar Connection. If that connection is installed at the organization level, the attacker can read any repository visible to that GitHub App installation.

**Recommendation:**

1. Document that `configs_repo_codestar_connection_arn` should point to a connection with a narrowly scoped GitHub App installation (repository-level, not organization-level) to limit blast radius.
2. Investigate whether the `codestar-connections:FullRepositoryId` IAM condition key is available for `UseConnection` and implement if supported.
3. Add a note in consumer documentation that granting `UseConnection` on a second connection grants access to all repos visible to that connection's GitHub App, not just the specified `configs_repo`.

---

### CF-08: Configs Artifact Not Integrity-Verified Between Source and Build

**Severity:** HIGH
**Flagged by:** Security Analyst (FINDING-04)

**Description:**

The configs repo artifact uses `CODE_ZIP` format and flows through S3 between stages without integrity verification. The artifact bucket uses SSE-S3 encryption (Amazon-managed keys) and the design skips `CKV_AWS_219` (CMK encryption) as post-MVP.

Anyone with `s3:PutObject` permission on the artifact bucket can replace the configs artifact between stages. The CodeBuild service role has `s3:PutObject` on the artifact bucket (required for outputting plan artifacts). A compromised CodeBuild project (e.g., a malicious prebuild script) could overwrite the `configs_output` artifact in S3 before the Plan stage reads it.

This is a pre-existing architectural risk (the IaC repo artifact has the same exposure), but the configs repo makes it more salient because the configs artifact is a high-value target that directly controls Terraform variable values and uses a simpler format (ZIP vs. CODEBUILD_CLONE_REF).

**Recommendation:**

1. The design document should explicitly acknowledge that artifact integrity between stages relies on S3 bucket policy and IAM controls, not cryptographic verification.
2. Prioritize the post-MVP CMK encryption for the artifact store. KMS key policies can restrict which principals can encrypt/decrypt.
3. Consider adding artifact checksumming in a future iteration -- the Source stage outputs a SHA-256, and the Plan stage verifies before use.

---

### CF-09: Missing Guard for Undefined `CODEBUILD_SRC_DIR_configs_output`

**Severity:** MEDIUM
**Flagged by:** Reliability Engineer (Finding 5), Terraform Architect (M-1)

**Description:**

Both reviewers identified that the buildspec references `CODEBUILD_SRC_DIR_configs_output` inside the `if [ "${CONFIGS_ENABLED}" = "true" ]` branch, which is correct in the normal flow. However, edge cases exist:

1. If someone manually overrides `CONFIGS_ENABLED` to `"true"` in the CodeBuild console while the pipeline does not pass the configs artifact, `CONFIGS_DIR` is set to an empty string. The subsequent path construction resolves to `//./environments/dev.tfvars` -- likely failing the `-f` test and proceeding without tfvars. This is a silent misconfiguration that could deploy with default values.

2. Under `set -u`, referencing `CODEBUILD_SRC_DIR_configs_output` outside the conditional (e.g., future debug logging) would fail with "unbound variable." The current design is safe but fragile for future maintainers.

**Recommendation:**

1. Add an explicit guard after setting `CONFIGS_DIR`:
```bash
if [ "${CONFIGS_ENABLED}" = "true" ]; then
  CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output}"
  if [ -z "${CONFIGS_DIR}" ] || [ ! -d "${CONFIGS_DIR}" ]; then
    echo "ERROR: CONFIGS_ENABLED is true but configs artifact directory is missing or empty: '${CONFIGS_DIR}'"
    exit 1
  fi
```

2. Add a defensive default near the top of the build phase: `CONFIGS_DIR="${CODEBUILD_SRC_DIR_configs_output:-}"` to allow safe reference anywhere in the script.

---

### CF-10: `CONFIGS_ENABLED` String Boolean Comparison Is Fragile

**Severity:** MEDIUM
**Flagged by:** Reliability Engineer (Finding 3)

**Description:**

The design uses `tostring(local.configs_enabled)` to pass the boolean as a CodeBuild environment variable, then checks it in bash with `if [ "${CONFIGS_ENABLED}" = "true" ]`. This works correctly in the normal flow.

The risk is operational: if someone debugging a failed pipeline manually overrides `CONFIGS_ENABLED` in the CodeBuild console, they might set it to `"True"`, `"TRUE"`, `"yes"`, or `"1"` -- all of which silently fall through to the `else` branch, disabling configs repo sourcing without any warning.

**Recommendation:**

1. Add case-insensitive comparison in the buildspec:
```bash
CONFIGS_ENABLED_LOWER=$(echo "${CONFIGS_ENABLED}" | tr '[:upper:]' '[:lower:]')
if [ "${CONFIGS_ENABLED_LOWER}" = "true" ]; then
```

2. Alternatively, log the value explicitly before the branch so operators can see the decision:
```bash
echo "CONFIGS_ENABLED=${CONFIGS_ENABLED}"
```

---

### CF-11: No Validation That Configs Repo Connection ARN Belongs to the Same AWS Account

**Severity:** MEDIUM
**Flagged by:** Security Analyst (FINDING-07)

**Description:**

The `configs_repo_codestar_connection_arn` validation regex accepts any 12-digit account ID. A consumer could provide a CodeStar Connection ARN from a different AWS account. The IAM policy would grant `UseConnection` on this cross-account ARN. Whether this works depends on the connection's resource policy, but the IAM permission is granted regardless, potentially enabling the pipeline to access repositories managed by a different AWS account.

**Recommendation:**

1. Terraform variable validations cannot reference data sources. This would need to be implemented as a `precondition` on a resource or as a local-based check.
2. At minimum, add documentation explicitly stating that the connection must be in the same AWS account as the pipeline.
3. If feasible, implement a `precondition` on the CodePipeline resource comparing the ARN account ID to `data.aws_caller_identity.current.account_id`.

---

### CF-12: Sensitive Values in `.tfvars` Files Traverse the Artifact Bucket in Plaintext

**Severity:** MEDIUM
**Flagged by:** Security Analyst (FINDING-08)

**Description:**

The configs repo artifact (CODE_ZIP) is stored in the S3 artifact bucket with SSE-S3 encryption. The artifact is readable by both the CodePipeline and CodeBuild service roles. While the MVP statement recommends using Secrets Manager references, the design does not enforce this. Many teams put semi-sensitive values in `.tfvars` files (internal IP ranges, account IDs, database identifiers, license keys). If an attacker gains read access to the artifact bucket through the CodeBuild role, they can inspect the configs repo artifact.

This is a pre-existing risk (the IaC repo artifact is equally accessible), but the configs repo amplifies it because configs repos are more likely to contain environment-specific values that teams consider semi-sensitive.

**Recommendation:**

1. Add documentation recommending that configs repos should never contain credentials, API keys, or other high-sensitivity values.
2. Consider a post-MVP Checkov or custom scan that flags common patterns of secrets in tfvars files.

---

### CF-13: `distinct()` on Connection ARNs Obscures IAM Policy Intent

**Severity:** MEDIUM
**Flagged by:** Security Analyst (FINDING-09), Terraform Architect (M-3)

**Description:**

The Security Analyst noted that `distinct()` makes the IAM policy non-deterministic from a review perspective. An auditor seeing one or two connection ARNs may not understand the conditional logic.

The Terraform Architect raised a related concern about plan noise: the change from `[local.codestar_connection_arn]` to `local.all_codestar_connection_arns` could show a spurious plan diff on initial module adoption even without enabling configs repo. On analysis, the Architect concluded this is likely a non-issue because the current code already uses the local reference, and `distinct()` preserves element order. However, verification on an existing deployment is recommended.

**Recommendation:**

1. Add an inline comment in the IAM policy statement explaining the conditional expansion behavior.
2. Consider outputting `all_codestar_connection_arns` from the core module so consumers and auditors can inspect the effective list.
3. Verify zero plan diff on existing deployments after module upgrade without setting `configs_repo`.

---

### CF-14: Destroy BuildSpec Environment Variables Use Inconsistent Pattern

**Severity:** MEDIUM
**Flagged by:** Terraform Architect (M-2)

**Description:**

For Plan CodeBuild projects (managed by core), `CONFIGS_ENABLED` and `CONFIGS_PATH` are set via the `codebuild_projects` map and rendered through the `dynamic "environment_variable"` pattern. For the Destroy CodeBuild project (managed by the variant), the same variables are added as individual `environment_variable` blocks directly in the resource. Both work, but they use different mechanisms -- a gap that already exists in the codebase and is widened by this design.

**Recommendation:**

Accept for MVP as extending the existing pattern. Document as tech debt -- the destroy project's environment variables should be refactored to use a map-based pattern similar to core's `codebuild_projects` in a future cleanup pass.

---

### CF-15: Document Change Summary Ambiguity on Output Changes

**Severity:** MEDIUM
**Flagged by:** Terraform Architect (M-5)

**Description:**

The Change Summary states "No changes to outputs for either variant." This is accurate for variant-level outputs (`modules/default/outputs.tf`, `modules/default-dev-destroy/outputs.tf`). However, the core module's `outputs.tf` is changed (two new outputs added). The statement is ambiguous and could be read as "no output changes anywhere."

**Recommendation:**

Clarify the statement to: "No changes to variant-level outputs (`modules/default/outputs.tf`, `modules/default-dev-destroy/outputs.tf`). Core module gains two new internal-wiring outputs (`configs_enabled`, `configs_repo_connection_arn`)."

---

### CF-16: Manual CodeBuild Trigger Fails on Unbound `CONFIGS_ENABLED`

**Severity:** LOW
**Flagged by:** Reliability Engineer (Finding 12)

**Description:**

If someone manually triggers a CodeBuild build outside of CodePipeline without setting `CONFIGS_ENABLED`, the buildspec fails under `set -u` with "unbound variable." This is correct fail-fast behavior, but the error message is opaque and unhelpful for debugging.

**Recommendation:**

Add a default at the top of the buildspec: `CONFIGS_ENABLED="${CONFIGS_ENABLED:-false}"`. This provides a safe default for manual triggers while preserving intended behavior when the variable is set by the pipeline. Alternatively, document that manual CodeBuild triggers require setting `CONFIGS_ENABLED=false`.

---

### CF-17: Artifact Namespace Not Documented

**Severity:** LOW
**Flagged by:** Reliability Engineer (Finding 8), Terraform Architect (L-3)

**Description:**

The design introduces `configs_output` as a new artifact name alongside `source_output`, `dev_plan_output`, and `prod_plan_output`. There is no collision risk today, but the artifact namespace is not documented, which could cause issues if future features accidentally reuse the name.

The Terraform Architect also noted that the dynamic source action omits the `namespace` attribute, but confirmed this is correct -- `namespace` defaults to the action name, and the two source actions have different names ("GitHub" and "Configs"), so there is no collision.

**Recommendation:**

Add a comment in the variant `main.tf` files documenting the pipeline artifact namespace:
```hcl
# Pipeline artifact namespace:
#   source_output      - IaC repo checkout
#   configs_output     - Configs repo checkout (conditional)
#   dev_plan_output    - Saved DEV terraform plan
#   prod_plan_output   - Saved PROD terraform plan
```

---

## Findings by Severity

| ID | Severity | Title | Flagged By |
|----|----------|-------|------------|
| CF-01 | CRITICAL | Configs repo as unvalidated Terraform input injection vector | Security Analyst |
| CF-02 | CRITICAL | CodePipeline resource force-replacement when toggling `configs_repo` | Terraform Architect, Reliability Engineer |
| CF-03 | CRITICAL | `PrimarySource` conditional merge causes silent config drift on toggle-off | Terraform Architect |
| CF-04 | HIGH | Path traversal and input validation gaps in `configs_repo_path` | Security Analyst, Reliability Engineer, Terraform Architect |
| CF-05 | HIGH | Dual-trigger race conditions and CodePipeline V2 supersession behavior | Reliability Engineer, Security Analyst, Terraform Architect |
| CF-06 | HIGH | Cross-variable validation gaps and cross-org connection fallback | Terraform Architect, Reliability Engineer |
| CF-07 | HIGH | CodeStar Connection IAM scope expansion without repository scoping | Security Analyst |
| CF-08 | HIGH | Configs artifact not integrity-verified between source and build | Security Analyst |
| CF-09 | MEDIUM | Missing guard for undefined `CODEBUILD_SRC_DIR_configs_output` | Reliability Engineer, Terraform Architect |
| CF-10 | MEDIUM | `CONFIGS_ENABLED` string boolean comparison is fragile | Reliability Engineer |
| CF-11 | MEDIUM | No validation that configs repo connection ARN belongs to same AWS account | Security Analyst |
| CF-12 | MEDIUM | Sensitive values in `.tfvars` traverse artifact bucket in plaintext | Security Analyst |
| CF-13 | MEDIUM | `distinct()` on connection ARNs obscures IAM policy intent | Security Analyst, Terraform Architect |
| CF-14 | MEDIUM | Destroy buildspec env vars use inconsistent pattern | Terraform Architect |
| CF-15 | MEDIUM | Document change summary ambiguity on output changes | Terraform Architect |
| CF-16 | LOW | Manual CodeBuild trigger fails on unbound `CONFIGS_ENABLED` | Reliability Engineer |
| CF-17 | LOW | Artifact namespace not documented | Reliability Engineer, Terraform Architect |

---

## Pre-Implementation Blockers

The following findings must be resolved before implementation begins. They represent either concrete attack vectors, data loss risk, or silent misconfiguration paths.

### CRITICAL Blockers

| ID | Title | Required Action |
|----|-------|-----------------|
| ~~CF-01~~ | ~~Configs repo trust boundary~~ | **OUT OF SCOPE** -- Management of repositories is outside the scope of the code module. See Accepted Risks. |
| ~~CF-02~~ | ~~Pipeline force-replacement on toggle~~ | **OUT OF SCOPE** -- Toggle behavior is a consumer-side operational risk. Best practice is to decide single-repo vs. configs+code repos before first deployment. See Accepted Risks. |
| ~~CF-03~~ | ~~`PrimarySource` stale configuration~~ | **OUT OF SCOPE** -- Toggle behavior is a consumer-side operational risk. Best practice is to decide single-repo vs. configs+code repos before first deployment. See Accepted Risks. |

### Blocking HIGH Findings

| ID | Title | Required Action |
|----|-------|-----------------|
| CF-04 | Path traversal in `configs_repo_path` | Add variable validation rejecting `..`, absolute paths, empty strings, trailing/leading slashes, and special characters. Add runtime path assertion in buildspec. Normalize `"."` case. |
| CF-06 | Cross-variable validation gaps | Add validation preventing empty `configs_repo_branch`. Add cross-org connection validation requiring explicit `configs_repo_codestar_connection_arn` when orgs differ. |

---

## Recommendations for Design Revision

The following concrete changes to MVP-DESIGN.md would address all pre-implementation blockers:

### 1. Add a "Known Limitations" Section

Insert after the Security section:
- Shared configs repos trigger all referencing pipelines on any push, regardless of `configs_repo_path`. File-path filtering is post-MVP.
- Dual-trigger architecture means config/code version skew is possible during coordinated changes. Recommend merging IaC changes first, then configs changes.
- The `execution_mode` defaults to `SUPERSEDED`; document implications and whether `QUEUED` is recommended for configs repo users.
- Destroy stage uses configs artifact from the same pipeline execution, which may differ from current configs repo HEAD.

### 2. Add Variable Validations to Design

Update the `configs_repo_path` variable declaration to include validation:

```hcl
variable "configs_repo_path" {
  description = "Path within the configs repo where the environments/ directory is located. Use '.' for repo root."
  type        = string
  default     = "."

  validation {
    condition     = var.configs_repo_path == "." || (
      !can(regex("(^/|\\.\\.|\\x00)", var.configs_repo_path)) &&
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_.-]*[a-zA-Z0-9]$", var.configs_repo_path))
    )
    error_message = "configs_repo_path must be '.' or a relative path without path traversal (..), leading/trailing slashes, or special characters."
  }
}
```

Update `configs_repo_branch` to include empty-string validation.

Add cross-org connection validation (either as variable validation or `precondition`).

### 3. Update Buildspec Design

Update the buildspec section to include:
- `CONFIGS_DIR` existence guard (hard-fail when `CONFIGS_ENABLED=true` but directory is missing).
- Path normalization for `"."` case.
- Runtime path traversal assertion.
- `CONFIGS_ENABLED` default for manual triggers: `CONFIGS_ENABLED="${CONFIGS_ENABLED:-false}"`.

### 4. Clarify Change Summary

Change: "No changes to outputs for either variant" to: "No changes to variant-level outputs. Core module gains two new internal-wiring outputs (`configs_enabled`, `configs_repo_connection_arn`)."

---

## Accepted Risks

The following findings are acknowledged but acceptable for MVP scope. They represent pre-existing risks, operational considerations addressable through documentation, or low-probability edge cases.

| ID | Severity | Title | Justification |
|----|----------|-------|---------------|
| CF-01 | CRITICAL | Configs repo trust boundary | **Out of scope.** Management of repositories (branch protection, access controls, review policies) is outside the scope of the code module. The module creates pipeline infrastructure; repository governance is the consumer's responsibility. |
| CF-02 | CRITICAL | Pipeline force-replacement on toggle | **Out of scope.** Toggling `configs_repo` on/off on an existing pipeline is a consumer-side operational risk. Best practice: the decision to use single-repo vs. configs+code repos is a primary prerequisite that should be made before first deployment. Consumers who toggle after deployment do so at their own risk. |
| CF-03 | CRITICAL | `PrimarySource` stale config on toggle-off | **Out of scope.** Same rationale as CF-02. The single-repo vs. dual-repo decision is a prerequisite, not a runtime toggle. Consumers who change this post-deployment accept the risk of pipeline recreation or stale API-side configuration. |
| CF-05 | HIGH | Dual-trigger race conditions | Inherent to dual-source pipeline architectures. Mitigated by consumer documentation and PROD approval gate. CodePipeline V2 supersession handles concurrent triggers. Post-MVP enhancements (trigger source in approval notification, change filtering) will further reduce risk. |
| CF-07 | HIGH | CodeStar Connection IAM scope expansion | The IAM permission is `UseConnection` only, not `CreateConnection` or administrative access. Mitigated by documentation recommending narrowly-scoped GitHub App installations. The GitHub App installation scope on the GitHub side is the actual security boundary. |
| CF-08 | HIGH | Artifact integrity not cryptographically verified | Pre-existing architectural risk that applies equally to the IaC repo artifact. Mitigated by S3 bucket policy, IAM controls, and CloudTrail logging. CMK encryption is already tracked as post-MVP. |
| CF-09 | MEDIUM | Missing `CODEBUILD_SRC_DIR_configs_output` guard | Should be implemented during build phase as a buildspec hardening item. Not a design-level blocker. |
| CF-10 | MEDIUM | Fragile string boolean comparison | Operational risk from manual overrides. Low probability in normal pipeline flow. Addressable during implementation. |
| CF-11 | MEDIUM | Connection ARN account ID not validated | Cannot be validated in variable blocks (requires data source). Addressable via `precondition` or documentation. Low risk -- cross-account `UseConnection` is unlikely to succeed without explicit resource policies. |
| CF-12 | MEDIUM | Sensitive values in plaintext artifacts | Pre-existing risk. Mitigated by documentation. Configs repos should follow the same secret management practices as IaC repos. |
| CF-13 | MEDIUM | `distinct()` obscures IAM policy intent | Addressable with inline comments. Functionally correct. |
| CF-14 | MEDIUM | Destroy env var pattern inconsistency | Existing tech debt, not introduced by this design. Widened slightly but acceptable for MVP. |
| CF-15 | MEDIUM | Change summary ambiguity | Documentation clarification only. No functional risk. |
| CF-16 | LOW | Unbound variable on manual trigger | Fail-fast behavior is correct. Addressable with a default in the buildspec. |
| CF-17 | LOW | Artifact namespace undocumented | Documentation-only recommendation. No collision risk today. |
