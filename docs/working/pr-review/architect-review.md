# Architecture Review -- PR #1

**Reviewer:** Cloud Solutions Architect
**Date:** 2026-02-12
**Focus:** Architecture, Scalability, Operational Readiness, Well-Architected Alignment

---

## Architectural Concerns

### AC-1: Deploy Stage Performs `terraform apply` Without a Saved Plan (Medium-High)

The Plan stage (Stage 3) generates `tfplan` and exports it as an artifact, but neither the Deploy-DEV nor Deploy-PROD stages consume this artifact. Instead, each deploy stage re-runs `terraform init` and `terraform apply` from source. This means the infrastructure being applied may differ from what was reviewed:

- Time passes between Plan and Deploy (especially with approval gates). During this window, the provider APIs, data sources, or external state could change.
- The Plan stage runs without environment-specific var-files (`-var-file` is not used), while Deploy stages conditionally include `environments/${TARGET_ENV}.tfvars`. The plan artifact that a reviewer examines does not reflect the actual apply.
- The architecture document acknowledges this ("Plan stage output is informational") but this creates a gap between what is reviewed and what is deployed.

**Recommendation:** This is an acceptable MVP trade-off given that DEV and PROD use different state and variables. However, the documentation should clearly warn consumers that the Plan stage is a preview only, and a future enhancement should generate per-environment plans that are consumed by the corresponding deploy stages. Consider adding a plan step within each deploy buildspec (plan + apply with `-auto-approve` on the saved plan) so the apply is deterministic.

### AC-2: State Backend Initialized with Assumed Role Credentials (Medium)

In `deploy.yml`, the STS `AssumeRole` call exports target-account credentials *before* `terraform init`. This means `terraform init` runs with the target account's credentials, but the S3 state backend resides in the Automation Account. The target account role would need `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` on the Automation Account's state bucket.

This creates an architectural tension: either the deployment roles in target accounts need cross-account S3 permissions on the Automation Account bucket (expanding their blast radius beyond the target account), or the init must run with the CodeBuild service role's credentials and only the apply uses assumed credentials.

**Recommendation:** Separate the credential flow: run `terraform init` with the CodeBuild service role's native credentials (which already have state bucket access per `iam.tf`), then export the assumed role credentials and run `terraform apply`. This keeps the deployment role scoped to its own account and avoids granting it access to the Automation Account's state bucket.

### AC-3: `|| true` on Checkov Contradicts Security Gate Intent (Medium)

The architecture document states "Checkov scan runs in Plan stage before any deployment. Non-zero exit stops pipeline" and the Well-Architected alignment table asserts "Security tests cannot be bypassed." However, `buildspecs/plan.yml` line 52 runs Checkov with `|| true`, meaning findings never fail the build. The Copilot review (C-8) also flagged this.

This is a genuine architectural gap: the security scanning stage is currently advisory-only, not a gate. Any consumer reading the architecture document would reasonably assume Checkov failures block deployment.

**Recommendation:** Remove `|| true` and let Checkov fail the build. Add a variable `checkov_soft_fail` (default: `false`) that consumers can set to `true` during initial adoption. When soft-fail is enabled, use `|| true`; otherwise, let failures propagate. Update documentation to match the actual behavior.

### AC-4: Single CodeStar Connection Per Pipeline Instance (Low-Medium)

When `codestar_connection_arn` is empty, each pipeline creates its own CodeStar Connection. CodeStar Connections have a default service quota of 50 per account per region. At scale (20+ pipelines sharing a GitHub org), this wastes quota and creates a management burden (each connection requires manual OAuth authorization).

**Recommendation:** The existing `codestar_connection_arn` variable already supports connection sharing, so the module is architecturally sound. Document the best practice of creating one shared CodeStar Connection and passing its ARN to all pipeline instances. Consider making the default behavior require an existing connection (i.e., make `codestar_connection_arn` required) and move connection creation to a separate, one-time setup module.

### AC-5: IAM Role Name Length Limits at Scale (Low)

IAM role names have a 64-character limit. The naming pattern `CodeBuild-${project_name}-ServiceRole` and `CodePipeline-${project_name}-ServiceRole` consume 27-30 characters before the project name. A `project_name` longer than 34 characters will cause a deployment failure with a cryptic AWS API error.

**Recommendation:** Add a validation rule on `project_name` limiting it to 34 characters, or truncate with a hash suffix for long names. The existing regex validation enforces format but not length.

---

## Operational Readiness Gaps

### OR-1: No Pipeline Failure Notifications

The module creates SNS infrastructure for approval notifications but has no mechanism to notify operators when pipeline stages fail. A Deploy-DEV failure at 2 AM goes unnoticed until someone checks the console. This is a significant day-2 operations gap.

**Recommendation:** Add a CloudWatch Event Rule (or EventBridge rule) that captures `codepipeline-pipeline-stage-execution` state changes for `FAILED` status and publishes to either the existing SNS topic or a separate failure notification topic. This is a low-effort, high-value addition.

### OR-2: No Terraform State Lock Monitoring

Native S3 locking (`use_lockfile = true`) is used for state management, but there is no mechanism to detect or alert on stale locks. If a CodeBuild job crashes mid-apply, the `.tflock` file may persist, blocking all subsequent deployments. The only remediation is manual lock file deletion from S3.

**Recommendation:** Document the lock recovery procedure. Consider a CloudWatch alarm on deploy stage build duration that alerts when builds exceed a threshold (indicating possible lock contention). Post-MVP, add a Lambda that detects `.tflock` files older than the build timeout and alerts.

### OR-3: No Build Caching

Each pipeline execution reinstalls the IaC runtime (Terraform/OpenTofu), providers, and tools (checkov) from the internet. For a module with many providers, `terraform init` can take 2-5 minutes. At 20 pipeline executions per month, this is 40-100 minutes of redundant downloads.

**Recommendation:** Post-MVP, configure CodeBuild `cache` blocks with S3-backed caching for the `.terraform/providers` directory and pip cache. This reduces build times by 30-60% and improves reliability (insulates from upstream download failures).

### OR-4: No Rollback or Failure Recovery Guidance

When a Deploy-PROD stage fails mid-apply, the state may be partially applied. The module provides no guidance on recovery. Terraform does not have native rollback, so the operator must manually assess state and either re-apply or import/taint resources.

**Recommendation:** Add operational runbook documentation covering: (1) how to inspect state after a failed apply, (2) how to manually re-trigger a single pipeline stage, (3) how to remove a stale state lock, (4) how to roll back by reverting the Git commit and re-running the pipeline.

### OR-5: Approval Timeout Behavior Not Documented

Both approval stages have a 7-day timeout (CodePipeline default). When an approval times out, the entire pipeline execution fails and must be re-triggered from source. This is surprising to operators who may expect the pipeline to simply wait.

**Recommendation:** Document the 7-day timeout behavior. Consider exposing the approval timeout as a variable for consumers with long approval workflows (e.g., change advisory boards).

---

## Design Recommendations

### DR-1: Shared State Bucket Across Multiple Pipelines

The current design creates a state bucket per pipeline when `create_state_bucket = true`. In a mature organization with 20+ pipelines, this means 20+ S3 buckets, each requiring independent backup verification, access logging configuration, and policy management.

**Recommendation:** Document the expected operational model: create one shared state bucket (either outside the module or via the first pipeline invocation) and pass it via `state_bucket` + `create_state_bucket = false` to all subsequent pipelines. The key prefix pattern (`<project>/<env>/terraform.tfstate`) already supports multi-tenancy within a single bucket. Add an example demonstrating this pattern.

### DR-2: Consider `for_each` Over `count` for Conditional Resources

The module uses `count` for conditional resources (state bucket, CodeStar connection). While functional, `count` creates resources addressed by index (`[0]`), which means removing or reordering conditions can force resource recreation. For the state bucket specifically, an inadvertent `count` change could destroy and recreate the bucket, losing all state.

**Recommendation:** This is acceptable for MVP since the conditions are straightforward booleans. For the state bucket, add `lifecycle { prevent_destroy = true }` as a safety net against accidental deletion. This is critical given that the state bucket contains all downstream project state.

### DR-3: Pin Terraform/OpenTofu Version by Default

The `iac_version` variable defaults to `"latest"`, which means every pipeline execution may install a different IaC version. A Terraform minor version bump could change plan output, introduce new deprecation warnings, or (rarely) introduce bugs. This creates non-deterministic builds.

**Recommendation:** Change the default to a specific version (e.g., `"1.11.0"`) and document that `"latest"` is available but not recommended for production. This aligns with the Terraform best practice of pinning CLI versions.

### DR-4: Artifact Bucket Naming and Global Uniqueness

S3 bucket names are globally unique. The naming pattern `${project_name}-pipeline-artifacts-${account_id}` and `${project_name}-terraform-state-${account_id}` is good (includes account ID for uniqueness), but common `project_name` values could collide with other AWS accounts using this module.

**Recommendation:** The current pattern is reasonable for an internal module. If this module is published externally, consider adding a random suffix or organization prefix option. No immediate action needed.

### DR-5: Buildspec Terraform Installation is a Supply Chain Risk

Both `plan.yml` and `deploy.yml` download Terraform binaries from `releases.hashicorp.com` and OpenTofu from `get.opentofu.org` at build time without checksum verification. A compromised download endpoint could inject a malicious binary that has full access to the assumed deployment role.

**Recommendation:** Add SHA256 checksum verification after downloading Terraform/OpenTofu binaries. HashiCorp publishes checksums and GPG signatures for all releases. This is a defense-in-depth measure that prevents supply chain attacks through compromised CDN or DNS.

---

## Well-Architected Assessment

### Security Pillar -- STRONG

The module demonstrates mature security thinking:

- **Least privilege IAM:** CodeBuild role scoped to exactly two deployment role ARNs. No wildcards. CodePipeline role scoped to specific artifact bucket, CodeBuild projects, and SNS topic.
- **No long-lived credentials:** All cross-account access uses STS temporary credentials with 1-hour sessions.
- **Encryption at rest:** All S3 buckets (SSE-S3), SNS topic (AWS-managed KMS), CloudWatch Logs (AWS-managed). The SSE-S3 vs. CMK trade-off is well-documented and appropriate for MVP.
- **Network security:** No privileged mode, no Docker-in-Docker, no custom images that could introduce vulnerabilities.
- **Separation of concerns:** Automation secrets stay in the Automation Account. Application secrets stay in target accounts. No cross-boundary secret sharing.

**Gap:** The Checkov `|| true` issue (AC-3) undermines the security gate promise. The lack of binary checksum verification (DR-5) is a supply chain concern. These are addressable without architectural changes.

### Reliability Pillar -- MODERATE

- **Positive:** S3 versioning on state bucket enables point-in-time recovery. Separate state per environment prevents cross-environment blast radius. Artifact lifecycle prevents unbounded storage growth.
- **Gap:** No automated failure notifications (OR-1). No stale lock detection (OR-2). No build caching reduces reliability by depending on external download endpoints (OR-3). No guidance on partial apply recovery (OR-4). Single-region design with no cross-region replication (acknowledged as intentional).

### Operational Excellence Pillar -- MODERATE

- **Positive:** Comprehensive CloudWatch logging with configurable retention. Explicit log groups prevent unbounded growth. Tagging strategy enables cost attribution. Pipeline URL output enables quick navigation. Detailed architecture documentation.
- **Gap:** No failure alerting. No operational runbooks. No build metrics or dashboards. No drift detection. Approval timeout behavior undocumented.

### Cost Optimization Pillar -- STRONG

- **Positive:** Excellent cost analysis in the architecture document. `BUILD_GENERAL1_SMALL` default is appropriate for most Terraform operations. Artifact lifecycle prevents unbounded storage. No DynamoDB eliminates a per-request cost line item. Per-pipeline isolation means costs scale linearly and predictably.
- **Gap:** No build caching increases build minutes (and costs) by 30-60%. The `"latest"` default for `iac_version` means unnecessary downloads of the same version. These are minor at low scale but compound at 20+ pipelines.

### Performance Pillar -- ADEQUATE

- **Positive:** CodePipeline V2 with parallel-capable stages. Reuse of Deploy and Test CodeBuild projects across environments reduces resource count.
- **Gap:** No build caching. Each build reinstalls tools. At scale, this adds 2-5 minutes per stage. The `queued_timeout = 480` (8 hours) is reasonable but not configurable.

---

## Positive Observations

### P-1: Clean Three-Account Separation

The cross-account model is well-implemented. First-hop role assumption (no chaining) avoids the STS session duration limits that plague chained-role architectures. The CodeBuild service role is the single trust anchor, and deployment roles in target accounts can independently scope their permissions without coordination.

### P-2: Reusable Project Parameterization

The 4-CodeBuild-project design (prebuild, plan, deploy, test) with per-stage environment variable injection is elegant. Reusing the deploy and test projects for both DEV and PROD via `EnvironmentVariables` in the pipeline action configuration reduces resource count from 8 to 4 while maintaining clean environment separation. This is a well-considered design decision.

### P-3: Graceful Var-File Handling

The buildspec pattern of checking for `environments/${TARGET_ENV}.tfvars` existence before passing `-var-file` is a practical detail that supports both simple projects (no tfvars) and complex multi-environment projects. This removes a common friction point.

### P-4: Thorough Input Validation

The validation blocks on `project_name` (regex format), `dev_account_id` / `prod_account_id` (12-digit format), deployment role ARNs (IAM ARN format), `iac_runtime` (enum), `codebuild_compute_type` (enum), and `log_retention_days` (CloudWatch-valid values) provide excellent fail-fast behavior. Consumers get clear error messages at plan time rather than cryptic AWS API errors at apply time.

### P-5: Well-Documented Design Decisions

The 21-item design decision table in `ARCHITECTURE_AND_DESIGN.md` is exemplary. Each decision includes a rationale, and security trade-offs (SSE-S3 vs. KMS, CloudWatch default encryption vs. CMK) are explicitly acknowledged as post-MVP enhancements. This is rare and valuable for long-term maintainability.

### P-6: Conditional Resource Pattern is Clean

The `count`-based conditional creation of the state bucket and CodeStar connection, with matching data sources and locals for reference resolution, is a well-established Terraform pattern applied correctly. The `locals.tf` file cleanly abstracts the conditional references so downstream resources don't need to know which path was taken.

### P-7: Security Posture Exceeds Typical MVP

The combination of S3 Block Public Access (all four settings), SSL-only bucket policies, explicit `privileged_mode = false`, no hardcoded credentials, scoped IAM policies, and encrypted SNS represents a security posture that many production modules lack. The SecOps assessment confirming zero critical/high findings validates this.

### P-8: Cost-Conscious Design

The absence of DynamoDB (replaced by native S3 locking), use of `BUILD_GENERAL1_SMALL` as default, artifact lifecycle policies, and the detailed cost estimate in the architecture document show genuine attention to cost efficiency. The module operates within AWS Free Tier for a single pipeline, which is excellent for adoption.

---

## Summary of Recommended Actions

| Priority | Item | Category | Effort |
|----------|------|----------|--------|
| **High** | AC-3: Fix Checkov `\|\| true` or align documentation | Security | Low |
| **High** | AC-2: Separate init credentials from apply credentials in deploy buildspec | Architecture | Medium |
| **High** | OR-1: Add pipeline failure notifications via EventBridge | Operations | Medium |
| **Medium** | DR-2: Add `prevent_destroy` lifecycle to state bucket | Safety | Low |
| **Medium** | AC-5: Add `project_name` length validation | Reliability | Low |
| **Medium** | DR-3: Pin default `iac_version` to a specific release | Reliability | Low |
| **Medium** | DR-5: Add checksum verification for binary downloads | Security | Medium |
| **Low** | OR-3: Add CodeBuild S3 caching for providers and tools | Performance | Medium |
| **Low** | AC-1: Document plan-vs-apply divergence risk clearly | Documentation | Low |
| **Low** | DR-1: Add shared state bucket usage example | Documentation | Low |
| **Low** | OR-4: Create operational runbook for failure recovery | Documentation | Medium |
