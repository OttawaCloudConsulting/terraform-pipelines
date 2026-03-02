# Red Team Findings: Discrete Configs Repository Support

**Analyst:** Security Analyst -- AWS IAM & Pipeline Security Specialist
**Focus Area:** IAM policy gaps, credential exposure, trust boundary violations, CodeStar Connection abuse vectors, artifact tampering, and privilege escalation paths
**Document Under Review:** [MVP-DESIGN.md](../MVP-DESIGN.md)
**Date:** 2026-02-21

---

## Executive Summary

The proposed design introduces an optional second source repository ("configs repo") to supply `.tfvars` files to the Terraform pipeline. While the design is architecturally sound in its conditional approach and preserves backward compatibility, it introduces several security-relevant changes that expand the pipeline's trust surface. The most significant concerns center on the configs repo functioning as a second ingress point for attacker-controlled input that directly influences Terraform execution, the broadening of CodeStar Connection IAM permissions, and the absence of integrity controls on the configs artifact.

Total findings: 10

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH     | 3 |
| MEDIUM   | 4 |
| LOW      | 2 |

---

## Findings

### FINDING-01: Configs Repo as Unvalidated Terraform Input Injection Vector

**Severity:** CRITICAL

**Description:**

The configs repo provides `.tfvars` files that are passed directly to `terraform plan -var-file=...` and `terraform destroy -var-file=...`. Terraform `.tfvars` files can set any declared variable, including those that control IAM role ARNs, CIDR ranges, resource names, S3 bucket names, and any other infrastructure parameter. A compromised or maliciously modified configs repo can silently alter the infrastructure plan in ways that are not visible from the IaC code review alone.

This is not a new class of vulnerability (the existing pipeline already consumes `.tfvars` from the IaC repo), but the design explicitly separates the trust domain. The IaC repo and configs repo may have different owners, different branch protection policies, different access control lists, and different review cadences. The MVP statement acknowledges this separation is a feature ("different teams own IaC modules vs. environment-specific parameters"), but the security implications are significant:

1. **No code review gate on config changes that trigger PROD deployments.** A push to the configs repo triggers the full pipeline including PROD. While the PROD stage has a mandatory manual approval, the approver sees a Terraform plan that was generated from the configs repo's values. If the approver is not deeply reviewing the plan output for unexpected variable changes, a malicious tfvars change (e.g., widening a security group CIDR, changing an IAM policy ARN, altering a KMS key policy) can pass through.

2. **The configs repo bypasses the IaC repo's PR review process entirely.** The design explicitly enables "a config-only change (e.g., adjusting an instance size) runs the full pipeline without touching the IaC repo." This means the IaC repo's branch protection, CODEOWNERS, required reviewers, and status checks are all irrelevant for config-driven changes.

3. **The `configs_repo_path` variable allows targeting arbitrary subdirectories**, meaning a shared configs repo serving multiple projects could have cross-project impact if path boundaries are misconfigured.

**Attack Scenario:**

An attacker with write access to the configs repo (but not the IaC repo) modifies `environments/prod.tfvars` to set a Terraform variable that controls an IAM policy document, changing it to grant `*:*` permissions. The pipeline triggers, plans with the malicious tfvars, the approver rubber-stamps the approval (or does not notice the policy change buried in a large plan), and the PROD deployment applies an overly permissive IAM policy.

**Recommendation:**

1. Add explicit documentation warning that the configs repo must have **equivalent or stricter branch protection and access controls** compared to the IaC repo, because it has equivalent influence over the deployed infrastructure.
2. Consider a post-MVP validation stage (already noted in the MVP as a potential enhancement) that diffs the tfvars against a baseline and flags unexpected changes to security-sensitive variables.
3. The PROD approval gate's `CustomData` should be enhanced to include a note reminding the approver to review the plan for unexpected variable-driven changes, especially when the pipeline was triggered by a configs repo push.
4. Consider adding a `configs_repo_trusted` or similar acknowledgment flag that forces consumers to explicitly accept the trust implications, rather than silently enabling the feature with just a repo name.

---

### FINDING-02: CodeStar Connection IAM Scope Expansion Without Scoping to Repository

**Severity:** HIGH

**Description:**

The design changes the `CodeStarConnectionAccess` IAM policy statement from a single connection ARN to `local.all_codestar_connection_arns` (potentially two ARNs). The IAM action `codestar-connections:UseConnection` grants the ability to use the connection to access **any repository** that the GitHub App installation can see in the connected organization, not just the specific repos configured in the pipeline.

Currently, the CodePipeline and CodeBuild roles have `UseConnection` on the IaC repo's CodeStar Connection. With the design change:

- If the configs repo uses the **same connection** (default behavior), there is no IAM change. However, the pipeline now fetches from two repos using one connection. The connection's GitHub App installation scope is the security boundary, not IAM.
- If the configs repo uses a **different connection** (`configs_repo_codestar_connection_arn`), both the CodePipeline and CodeBuild service roles gain `UseConnection` on this second connection. This means the CodeBuild service role can now access repositories from a **second GitHub organization** -- an expansion of cross-organization access.

The `codestar-connections:UseConnection` permission does not support resource-level conditions that restrict which repository can be accessed through the connection. The only boundary is the GitHub App's installation scope on the GitHub side.

**Attack Scenario:**

If the CodeBuild service role is compromised (e.g., through a malicious prebuild script in the IaC repo, or a supply-chain attack on a tool installed during the install phase), the attacker gains `UseConnection` on the configs repo's CodeStar Connection. If that connection is installed at the organization level in a different GitHub org, the attacker can read any repository visible to that GitHub App installation -- not just the configs repo.

**Recommendation:**

1. Document that the `configs_repo_codestar_connection_arn` override should point to a connection with a **narrowly scoped GitHub App installation** (repository-level, not organization-level) to limit blast radius.
2. Add an IAM condition key check if AWS supports it for CodeStar Connections (currently limited, but `codestar-connections:FullRepositoryId` condition key may be available for `UseConnection` -- verify and implement if supported).
3. Add a note in the consumer documentation that granting `UseConnection` on a second connection grants access to all repos visible to that connection's GitHub App, not just the specified `configs_repo`.

---

### FINDING-03: Path Traversal in `CONFIGS_PATH` / `configs_repo_path`

**Severity:** HIGH

**Description:**

The `configs_repo_path` variable is passed to CodeBuild as the `CONFIGS_PATH` environment variable, where it is used in the buildspec to construct a file path:

```bash
VARFILE_PATH="${CONFIGS_DIR}/${CONFIGS_PATH}/environments/${TARGET_ENV}.tfvars"
```

The Terraform variable validation only checks that `configs_repo` matches `org/repo` format. There is **no validation on `configs_repo_path`**. A consumer could set:

```hcl
configs_repo_path = "../../.."
```

This would cause the buildspec to resolve a path outside the configs artifact directory. While the CodeBuild filesystem is ephemeral and sandboxed, path traversal could:

1. Read files from the primary source artifact (`CODEBUILD_SRC_DIR`) or other mounted locations, using them as tfvars input to Terraform.
2. In conjunction with CodeBuild's filesystem layout, potentially reference files from other artifacts or the build environment itself.

The `CODE_ZIP` artifact format extracts the configs repo to `CODEBUILD_SRC_DIR_configs_output`. A path traversal from this location could reach `CODEBUILD_SRC_DIR` (the IaC repo) or other system paths.

**Attack Scenario:**

A misconfigured or malicious `configs_repo_path = "../../../tmp"` causes the buildspec to look for tfvars at `/tmp/environments/dev.tfvars`. If an earlier build step (prebuild) or a tool installation wrote a file at that path, it would be consumed as Terraform variable input.

**Recommendation:**

1. Add input validation on `configs_repo_path` that rejects values containing `..`, absolute paths (starting with `/`), or null bytes:

```hcl
variable "configs_repo_path" {
  # ...
  validation {
    condition     = var.configs_repo_path == "." || !can(regex("(^/|\\.\\.|\\x00)", var.configs_repo_path))
    error_message = "configs_repo_path must not contain path traversal sequences (..), absolute paths, or null bytes."
  }
}
```

2. In the buildspec, add a runtime assertion that `VARFILE_PATH` resolves to a location within the configs artifact directory:

```bash
RESOLVED_PATH=$(realpath -m "${VARFILE_PATH}")
if [[ "${RESOLVED_PATH}" != "${CONFIGS_DIR}"* ]]; then
  echo "ERROR: Resolved tfvars path is outside configs artifact directory. Aborting."
  exit 1
fi
```

---

### FINDING-04: Configs Repo Artifact Not Integrity-Verified Between Source and Build

**Severity:** HIGH

**Description:**

The configs repo artifact uses `CODE_ZIP` format (a deliberate and reasonable design choice for simplicity). However, the pipeline does not verify the integrity of the configs artifact between the Source stage and the Build stage. The artifact flows through S3 (the pipeline's artifact bucket) between stages.

The artifact bucket currently uses Amazon S3-managed encryption (SSE-S3) and the design document notes `CKV_AWS_219` is skipped ("Post-MVP -- CMK encryption for CodePipeline artifact store"). Without CMK encryption and without artifact signing:

1. Anyone with `s3:PutObject` permission on the artifact bucket can replace the configs artifact between stages.
2. The CodeBuild service role has `s3:PutObject` on the artifact bucket (required for outputting plan artifacts). This means a compromised CodeBuild project (e.g., a malicious prebuild script) could overwrite the `configs_output` artifact in S3 before the Plan stage reads it.

This is an existing risk for `source_output` as well, but the configs repo makes it more salient because the configs artifact is a high-value target (it directly controls Terraform variable values) and uses a simpler format (ZIP vs. CODEBUILD_CLONE_REF).

**Attack Scenario:**

1. A malicious `prebuild.yml` script (injected through the IaC repo) identifies the S3 key of the `configs_output` artifact in the artifact bucket.
2. It creates a modified ZIP containing a `environments/prod.tfvars` with privilege-escalating variable values.
3. It uploads this modified ZIP to the artifact bucket, replacing the legitimate configs artifact.
4. The Plan-PROD action reads the tampered artifact and generates a plan with the attacker's values.

**Recommendation:**

1. This is a pre-existing architectural risk, not introduced by this feature. However, the design document should explicitly acknowledge that artifact integrity between stages relies on S3 bucket policy and IAM controls, not cryptographic verification.
2. Prioritize the "Post-MVP" CMK encryption for the artifact store. KMS key policies can restrict which principals can encrypt/decrypt, adding a layer of access control.
3. Consider adding artifact checksumming in a future iteration -- the Source stage could output a SHA-256 of the configs artifact, and the Plan stage could verify it before use.

---

### FINDING-05: Dual-Trigger Enables Configs-Only PROD Deployment Without IaC Code Review

**Severity:** MEDIUM

**Description:**

The design enables `DetectChanges = "true"` on both source actions, meaning a push to either repository triggers the full pipeline. This is an explicit MVP requirement, but it creates a control gap:

When the pipeline is triggered by a configs repo push:
- The IaC repo code has not changed, so there is no new PR or code review.
- The configs repo push may or may not have gone through a review process (the pipeline has no visibility into this).
- The pipeline will plan and (upon approval) deploy to PROD using the new config values.

This means the configs repo effectively has a "deploy to PROD" capability that bypasses the IaC repo's governance model. The mandatory PROD approval gate is the only control.

**Context:** The existing pipeline already has this characteristic for IaC repo pushes -- a push triggers the full pipeline with a PROD approval gate. The difference is that the IaC repo is presumably under the same governance framework. The configs repo may not be.

**Recommendation:**

1. Document that the configs repo must be governed with the same rigor as the IaC repo (branch protection, required reviewers, signed commits if applicable).
2. Consider a post-MVP enhancement that includes the trigger source (IaC vs. configs) in the PROD approval notification, so the approver knows which repo triggered the execution.
3. Consider whether the `enable_review_gate` (DEV approval) should be recommended when using a configs repo, to provide an additional checkpoint for config-driven changes.

---

### FINDING-06: `CONFIGS_ENABLED` and `CONFIGS_PATH` Stored as Plaintext CodeBuild Environment Variables

**Severity:** MEDIUM

**Description:**

The design adds `CONFIGS_ENABLED` and `CONFIGS_PATH` as plaintext environment variables in the CodeBuild project configuration. While these values are not secrets, they are attacker-useful metadata:

1. `CONFIGS_PATH` reveals the internal directory structure of the configs repo, which assists in targeting path traversal attacks (see FINDING-03).
2. `CONFIGS_ENABLED = "true"` signals to an attacker that the pipeline consumes a second source, expanding the attack surface they should investigate.

CodeBuild environment variables are visible to anyone with `codebuild:BatchGetProjects` permission on the project, and they appear in the CodeBuild console. They are also logged in CloudTrail `StartBuild` events.

This is low-risk in isolation but contributes to information disclosure that assists other attacks.

**Recommendation:**

1. Accept this risk for MVP. These are non-sensitive operational flags.
2. Ensure that `codebuild:BatchGetProjects` permissions are restricted to pipeline administrators, not broadly granted.

---

### FINDING-07: No Validation That Configs Repo Connection ARN Belongs to the Same AWS Account

**Severity:** MEDIUM

**Description:**

The `configs_repo_codestar_connection_arn` variable validates that the value is a syntactically valid CodeStar Connection ARN, but does not validate that the account ID in the ARN matches the automation account. The validation regex accepts any 12-digit account ID:

```hcl
condition = var.configs_repo_codestar_connection_arn == "" || can(regex("^arn:aws:(codestar-connections|codeconnections):[a-z0-9-]+:[0-9]{12}:connection/.+$", var.configs_repo_codestar_connection_arn))
```

A consumer could (accidentally or intentionally) provide a CodeStar Connection ARN from a different AWS account. The IAM policy would grant `UseConnection` on this cross-account ARN. Whether this actually works depends on the CodeStar Connection's resource policy, but the IAM permission would be granted regardless.

If the cross-account connection has a permissive resource policy (or if AWS CodeStar Connections support cross-account `UseConnection` without explicit resource policies), this could enable the pipeline to access repositories in GitHub organizations managed by a different AWS account.

**Recommendation:**

1. Add a validation that extracts the account ID from the provided ARN and compares it to `data.aws_caller_identity.current.account_id`:

```hcl
validation {
  condition     = var.configs_repo_codestar_connection_arn == "" || can(regex("^arn:aws:(codestar-connections|codeconnections):[a-z0-9-]+:${data.aws_caller_identity.current.account_id}:connection/.+$", var.configs_repo_codestar_connection_arn))
  error_message = "configs_repo_codestar_connection_arn must reference a connection in the current AWS account."
}
```

Note: Terraform variable validations cannot reference data sources. This would need to be implemented as a `precondition` on a resource or as a local with a check, or documented as a consumer responsibility.

2. If validation is not technically feasible in the variable block, add documentation explicitly stating that the connection must be in the same AWS account as the pipeline.

---

### FINDING-08: Sensitive Values in `.tfvars` Files Traverse the Artifact Bucket in Plaintext

**Severity:** MEDIUM

**Description:**

The MVP statement acknowledges that "tfvars files may contain sensitive values" and recommends using Secrets Manager references instead. However, the design does not enforce this. In practice, many teams put semi-sensitive values in `.tfvars` files (internal IP ranges, account IDs, database instance identifiers, license keys, etc.).

With the configs repo feature:
1. The configs repo artifact (CODE_ZIP) is stored in the S3 artifact bucket with SSE-S3 encryption (at-rest only, Amazon-managed keys).
2. The artifact is readable by both the CodePipeline and CodeBuild service roles.
3. The artifact bucket does not have a bucket policy restricting access beyond the IAM roles (it uses IAM-based access control via the role policies).
4. CloudTrail logs S3 access but does not log the artifact contents.

If an attacker gains read access to the artifact bucket (through the CodeBuild role, which has `s3:GetObject` on `${artifact_bucket}/*`), they can download and inspect the configs repo artifact, extracting any sensitive values in the tfvars files.

**Recommendation:**

1. This is a pre-existing risk (the IaC repo artifact is equally accessible), but the configs repo amplifies it because configs repos are more likely to contain environment-specific values that teams consider semi-sensitive.
2. Add documentation recommending that configs repos should never contain credentials, API keys, or other high-sensitivity values.
3. Consider adding a post-MVP Checkov or custom scan that flags common patterns of secrets in tfvars files (e.g., variables named `password`, `secret`, `api_key`, etc.).

---

### FINDING-09: `distinct()` on Connection ARNs Obscures IAM Policy Intent

**Severity:** LOW

**Description:**

The design uses `distinct()` to deduplicate connection ARNs:

```hcl
all_codestar_connection_arns = distinct([
  local.codestar_connection_arn,
  local.configs_repo_connection_arn,
])
```

When the configs repo uses the same connection as the IaC repo (the default), `distinct()` collapses this to a single-element list, producing no IAM change. When a different connection is used, the list expands to two elements.

This is functionally correct but makes the IAM policy non-deterministic from a review perspective. An auditor reading the IAM policy in the Terraform state or in AWS console will see either one or two connection ARNs and may not understand why, because the conditional logic is abstracted away.

**Recommendation:**

1. Add a comment in the IAM policy statement explaining the conditional expansion:

```hcl
# When configs_repo uses a separate CodeStar Connection, this list includes both
# the IaC repo connection and the configs repo connection. When they share a
# connection, distinct() deduplicates to a single ARN.
Resource = local.all_codestar_connection_arns
```

2. Consider outputting `all_codestar_connection_arns` from the core module so that consumers and auditors can inspect the effective connection list.

---

### FINDING-10: No Rate-Limiting or Deduplication on Dual-Trigger Pipeline Execution

**Severity:** LOW

**Description:**

With `DetectChanges = "true"` on both source actions, a simultaneous push to both repos could trigger two pipeline executions. CodePipeline V2 handles concurrent executions via its execution mode (SUPERSEDED by default), but there is no explicit handling in the design for:

1. **Rapid successive triggers** from the configs repo (e.g., a force-push rewriting history, or a CI bot making rapid commits) causing pipeline thrashing.
2. **Race conditions** where a pipeline execution starts with version N of the configs repo and version M of the IaC repo, but by the time the PROD approval happens, both repos have moved to newer versions. The approved plan reflects a stale combination.

This is a pre-existing characteristic of CodePipeline V2's change detection model, not introduced by this design. However, the addition of a second trigger source doubles the probability of such scenarios.

**Recommendation:**

1. Accept this risk for MVP. CodePipeline V2's SUPERSEDED execution mode handles concurrent triggers by canceling in-progress executions when a new trigger arrives.
2. Document that consumers should be aware that rapid commits to the configs repo will cause pipeline restarts, and that the PROD approval should be treated as approving the specific plan output, not the general state of the repos.

---

## Summary Verdict

The design is **well-structured and demonstrates sound architectural judgment** in its conditional approach, backward compatibility preservation, and minimal blast radius when the feature is disabled. The core decision to make the configs repo a drop-in replacement for the `environments/` directory (rather than introducing complex merge logic) is a good simplicity-first choice.

**However, the design underestimates the security implications of introducing a second trust domain into the pipeline.** The existing pipeline treats the IaC repo as the single source of truth for both code and configuration. Adding the configs repo creates a second ingress point with equivalent influence over deployed infrastructure but potentially weaker governance controls. The design's security considerations section (in MVP.md) is brief and does not adequately address this trust boundary expansion.

**The most actionable items before implementation are:**

1. **(CRITICAL) FINDING-01:** Add prominent documentation and consumer guidance that the configs repo must be governed with equivalent rigor to the IaC repo. This is a documentation-only change that costs nothing and prevents a class of operational security failures.

2. **(HIGH) FINDING-03:** Add input validation on `configs_repo_path` to reject path traversal sequences. This is a simple validation rule that prevents a concrete attack vector.

3. **(HIGH) FINDING-02:** Document the implications of `codestar-connections:UseConnection` scope expansion and recommend narrowly-scoped GitHub App installations for the configs repo connection.

4. **(HIGH) FINDING-04:** Acknowledge artifact integrity limitations in the design document. No code change needed for MVP, but the risk should be documented.

**Items acceptable to defer to post-MVP:** FINDING-05 through FINDING-10 represent risks that are either pre-existing, low-probability, or addressable through documentation and operational guidance rather than code changes.

**Overall assessment:** Proceed with implementation, incorporating the CRITICAL and HIGH recommendations. The design does not introduce privilege escalation paths -- the CodeBuild service role's permissions are not broadened beyond CodeStar Connection access, and cross-account deployment role assumption is unchanged. The primary risk is that the configs repo becomes an under-governed input channel, which is a process and documentation problem more than a technical one.
