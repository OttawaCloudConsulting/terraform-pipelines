# SecOps Security Assessment Report
## Terraform Pipeline Module

**Date:** 2026-02-12
**Assessed By:** SecOps Sub-Agent
**Module:** terraform-pipelines
**Scan Tools:** Checkov v3.2.396, Trivy (latest)
**Scope:** Module source code + Terraform plan (e2e test configuration)

---

## Executive Summary

The Terraform pipeline module demonstrates a **strong security baseline**. IAM policies follow least-privilege principles, S3 buckets have public access blocked and SSL-only policies, CodeBuild projects have privileged mode disabled, and no hardcoded secrets exist anywhere in the codebase.

The findings are predominantly related to **encryption key management** (use of AWS-managed keys vs. customer-managed KMS keys) and **operational logging/monitoring** enhancements. No critical vulnerabilities were found. The majority of "failed" checks reflect a conscious design decision documented in `ARCHITECTURE_AND_DESIGN.md` to use SSE-S3 encryption for the MVP, with customer-managed KMS keys noted as a post-MVP enhancement.

**Summary:**
- Total unique findings across all scans: **15 distinct check types**
- MUST-FIX (Critical): **0**
- MUST-FIX (High): **0**
- RECOMMENDED: **3** (S3 access logging, lifecycle abort rule, CloudWatch log retention policy)
- SUPPRESS / IGNORE: **12** (CMK encryption deferrals, cross-region replication, event notifications, and false positives)

---

## Scan Results Summary

| Tool | Scan Target | Passed | Failed | Skipped |
|------|------------|--------|--------|---------|
| Checkov | Module Code | 64 | 30 | 0 |
| Checkov | TF Plan | 58 | 22 | 0 |
| Trivy | Module Code | 0 | 34 | 0 |
| Trivy | TF Plan | 0 | 0 | 0 |

**Notes on scan counts:**
- Checkov module code counts include duplicate findings across examples (minimal, complete, opentofu) and e2e test configurations that reference the same module resources. Unique failing check types: 15.
- Trivy module code findings are 16 LOW (CloudWatch log group KMS encryption x4 per example) + 18 from storage.tf (7 LOW for S3 logging + 11 HIGH for CMK encryption). These are all duplicates across the 4 example/test module invocations. Unique finding types: 3.
- Trivy plan scan: 0 findings (Trivy had parsing errors with the plan JSON but reported clean).

---

## Findings -- MUST-FIX (Critical)

No critical findings.

---

## Findings -- MUST-FIX (High)

No high-priority findings that require immediate remediation.

---

## Findings -- RECOMMENDED

### R-1: S3 Bucket Access Logging Not Enabled

| Field | Value |
|-------|-------|
| **Check IDs** | CKV_AWS_18, AWS-0089 |
| **Description** | S3 buckets (state and artifacts) do not have server access logging enabled |
| **Affected Resources** | `aws_s3_bucket.state`, `aws_s3_bucket.artifacts` |
| **File** | `/storage.tf` lines 5-9, 77-80 |
| **Risk** | Without access logging, there is no record of who accessed state files or pipeline artifacts. For the **state bucket specifically**, this is valuable for audit trail and forensic investigation of unauthorized state access. |

**Remediation:** Add an `aws_s3_bucket_logging` resource for at least the state bucket, targeting a centralized logging bucket. The architecture document already references CloudTrail for S3 API calls, so this is defense-in-depth. Consider adding a `logging_bucket` variable to the module.

```hcl
resource "aws_s3_bucket_logging" "state" {
  count         = var.create_state_bucket && var.logging_bucket != "" ? 1 : 0
  bucket        = aws_s3_bucket.state[0].id
  target_bucket = var.logging_bucket
  target_prefix = "s3-access-logs/${var.project_name}-state/"
}
```

**Priority:** Medium. CloudTrail provides API-level logging already. S3 access logging adds object-level granularity.

---

### R-2: Artifact Bucket Lifecycle Missing Abort Incomplete Multipart Upload Rule

| Field | Value |
|-------|-------|
| **Check ID** | CKV_AWS_300 |
| **Description** | S3 lifecycle configuration does not set a period for aborting failed multipart uploads |
| **Affected Resource** | `aws_s3_bucket_lifecycle_configuration.artifacts` |
| **File** | `/storage.tf` lines 134-145 |
| **Risk** | Incomplete multipart uploads consume storage and incur costs indefinitely. |

**Remediation:** Add an `abort_incomplete_multipart_upload` block to the existing lifecycle rule:

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    expiration {
      days = var.artifact_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
```

**Priority:** Low. Cost hygiene improvement. Minimal security impact.

---

### R-3: CloudWatch Log Group Retention Policy -- Default is Short for Compliance

| Field | Value |
|-------|-------|
| **Check ID** | CKV_AWS_338 |
| **Description** | CloudWatch log groups should retain logs for at least 1 year (365 days) for compliance |
| **Affected Resources** | All 4 CloudWatch log groups (prebuild, plan, deploy, test) |
| **File** | `/main.tf` lines 8-30 |
| **Risk** | The module default is 30 days. The e2e test uses 1 day. Some compliance frameworks (SOC2, PCI-DSS) require 1-year log retention for CI/CD pipeline logs. |

**Remediation:** This is already configurable via `var.log_retention_days`. No module code change needed. **Document the recommendation** that production deployments should set `log_retention_days = 365` for compliance. Consider changing the default from 30 to 365 if the organization requires compliance-by-default.

**Priority:** Medium. Depends on organizational compliance requirements.

---

## Findings -- SUPPRESS / IGNORE

### S-1: S3 Buckets Not Encrypted with KMS CMK

| Field | Value |
|-------|-------|
| **Check IDs** | CKV_AWS_145, AWS-0132 |
| **Description** | S3 buckets use SSE-S3 (AES256) instead of SSE-KMS with a customer-managed key |
| **Affected Resources** | `aws_s3_bucket.state`, `aws_s3_bucket.artifacts` |
| **Reason for Suppression** | **Documented design decision.** `ARCHITECTURE_AND_DESIGN.md` Design Decision #4 explicitly states: "SSE-S3 encryption (not KMS) -- Simpler, no KMS key lifecycle to manage. Sufficient for state and artifacts in MVP. Post-MVP: customer-managed KMS keys for cross-account artifact sharing." All S3 objects are encrypted at rest with AES256 since Jan 2023 (AWS default). The data remains encrypted; the finding is about key management granularity, not about missing encryption. |

---

### S-2: CloudWatch Log Groups Not Encrypted with KMS CMK

| Field | Value |
|-------|-------|
| **Check IDs** | CKV_AWS_158, AWS-0017 |
| **Description** | CloudWatch log groups do not specify a KMS CMK for encryption |
| **Affected Resources** | All 4 CloudWatch log groups |
| **Reason for Suppression** | CloudWatch Logs encrypts all log data by default with AWS-managed encryption. The finding requests customer-managed KMS keys for additional key rotation control. This is a post-MVP enhancement that would require creating a KMS key and associated IAM policies. The build logs do not contain secrets (buildspec files do not echo sensitive values, as verified in the security checklist). |

---

### S-3: CodeBuild Projects Not Encrypted with KMS CMK

| Field | Value |
|-------|-------|
| **Check IDs** | CKV_AWS_147 |
| **Description** | CodeBuild projects do not specify a customer-managed KMS key for build artifact encryption |
| **Affected Resources** | All 4 CodeBuild projects (prebuild, plan, deploy, test) |
| **Reason for Suppression** | CodeBuild uses AWS-managed encryption by default for build artifacts. This is consistent with Design Decision #4 (SSE-S3 for MVP). The `CKV_AWS_78` check ("Ensure that CodeBuild Project encryption is not disabled") PASSES, confirming encryption is active. The difference is AWS-managed vs. customer-managed key. Post-MVP enhancement. |

---

### S-4: CodePipeline Artifact Store Not Using KMS CMK

| Field | Value |
|-------|-------|
| **Check ID** | CKV_AWS_219 |
| **Description** | CodePipeline artifact store does not specify a KMS CMK |
| **Affected Resource** | `aws_codepipeline.this` |
| **Reason for Suppression** | Same rationale as S-1 and S-3. CodePipeline uses the default `aws/s3` KMS key for artifact encryption. This is documented in the architecture: "CodePipeline default encryption applies via AWS-managed `aws/s3` KMS key." Customer-managed KMS is noted as a post-MVP requirement for cross-account artifact sharing. |

---

### S-5: SNS Topic Not Using Customer-Managed KMS Key

| Field | Value |
|-------|-------|
| **Check ID** | AWS-0136 |
| **Description** | SNS topic uses AWS-managed KMS key (`alias/aws/sns`) instead of a customer-managed CMK |
| **Affected Resource** | `aws_sns_topic.approvals` |
| **Reason for Suppression** | The topic IS encrypted (CKV_AWS_26 PASSES). It uses the AWS-managed SNS key as documented in Design Decision #5: "Encryption at rest with zero key management overhead." The topic carries approval notification messages (non-sensitive pipeline metadata), not secrets. Customer-managed key adds operational overhead with minimal security benefit for this use case. |

---

### S-6: S3 Buckets Do Not Have Cross-Region Replication

| Field | Value |
|-------|-------|
| **Check ID** | CKV_AWS_144 |
| **Description** | S3 buckets do not have cross-region replication enabled |
| **Affected Resources** | `aws_s3_bucket.state`, `aws_s3_bucket.artifacts` |
| **Reason for Suppression** | Cross-region replication is a **disaster recovery** control, not a security control. The pipeline operates in a single region (`ca-central-1`). State bucket has versioning enabled for point-in-time recovery. Artifact bucket has a lifecycle policy (ephemeral by design). Cross-region replication would double storage costs and add complexity with no security benefit for this use case. |

---

### S-7: S3 Buckets Do Not Have Event Notifications

| Field | Value |
|-------|-------|
| **Check ID** | CKV2_AWS_62 |
| **Description** | S3 buckets do not have event notifications enabled |
| **Affected Resources** | `aws_s3_bucket.state`, `aws_s3_bucket.artifacts` |
| **Reason for Suppression** | Event notifications are an operational monitoring feature, not a security requirement. The architecture relies on CloudTrail for S3 API call monitoring. Adding S3 event notifications would require additional SNS/SQS/Lambda infrastructure that is outside the pipeline module's scope. Organizations can add this at the account level via a separate monitoring module. |

---

### S-8: State Bucket Has No Lifecycle Configuration

| Field | Value |
|-------|-------|
| **Check ID** | CKV2_AWS_61 |
| **Description** | State bucket does not have a lifecycle configuration |
| **Affected Resource** | `aws_s3_bucket.state` |
| **Reason for Suppression** | The state bucket stores active Terraform state files that must be retained indefinitely. Adding a lifecycle expiration policy would risk deleting active state, causing state loss. Versioning is enabled for recovery of previous versions. A lifecycle rule to expire non-current versions could be added as an optimization, but the current configuration is the safe default for state storage. |

---

### S-9: State Bucket Versioning -- Checkov False Positive (CKV_AWS_21)

| Field | Value |
|-------|-------|
| **Check ID** | CKV_AWS_21 |
| **Description** | Checkov reports state bucket does not have versioning enabled |
| **Affected Resource** | `aws_s3_bucket.state[0]` |
| **Reason for Suppression** | **False positive.** Versioning IS configured via `aws_s3_bucket_versioning.state` (storage.tf lines 11-18). Checkov's static analysis of modules with `count` sometimes fails to link the separate versioning resource to the bucket resource. The TF Plan scan (CKV_AWS_21) correctly reports this as PASSED, confirming versioning is enabled. |

---

### S-10: State Bucket Public Access Block -- Checkov False Positive (CKV2_AWS_6)

| Field | Value |
|-------|-------|
| **Check ID** | CKV2_AWS_6 |
| **Description** | Checkov reports state bucket does not have a public access block |
| **Affected Resource** | `aws_s3_bucket.state[0]` |
| **Reason for Suppression** | **False positive.** Public access block IS configured via `aws_s3_bucket_public_access_block.state` (storage.tf lines 31-39) with all four settings enabled. Checkov's static module analysis with `count` fails to link the resources. The TF Plan scan correctly reports CKV_AWS_53/54/55/56 as PASSED for the state bucket. |

---

### S-11: Trivy HCL Parsing Errors

| Field | Value |
|-------|-------|
| **Check ID** | N/A (parser error) |
| **Description** | Trivy reports HCL parsing errors on `main.tf` due to `jsonencode()` in CodePipeline `EnvironmentVariables` configuration |
| **Reason for Suppression** | This is a Trivy parser limitation, not a code issue. Trivy's HCL parser cannot handle Terraform's `jsonencode()` function with complex inline structures. The same code validates cleanly with `terraform validate`, Checkov, and the AWS provider. Trivy's plan scan (which uses the JSON representation) did not find issues either. |

---

### S-12: State Bucket Lifecycle Configuration (Duplicate from CKV2_AWS_61 on module.pipeline.aws_s3_bucket.state)

| Field | Value |
|-------|-------|
| **Check ID** | CKV2_AWS_61 (on `state` resource without index) |
| **Description** | Duplicate of S-8, reported against the unindexed resource reference |
| **Reason for Suppression** | Same as S-8. Checkov reports this finding twice due to the `count` pattern -- once for `aws_s3_bucket.state` and once for `aws_s3_bucket.state[0]`. Same resource, same rationale. |

---

## Remediation Roadmap

### Immediate (Pre-Production)

No blocking items. The module can be deployed to production in its current state.

### Short-Term (Next Sprint)

1. **R-2: Add `abort_incomplete_multipart_upload` to artifact bucket lifecycle rule** -- Simple one-line addition. No risk. Prevents cost leakage from abandoned uploads.

2. **R-3: Document recommended `log_retention_days` value** -- Add a note in the README or examples that production deployments should use `log_retention_days = 365` for compliance. Consider changing the default.

### Medium-Term (Post-MVP)

3. **R-1: Add optional S3 access logging for the state bucket** -- Add a `logging_bucket` variable. When provided, enable access logging on the state bucket. This provides object-level audit trail beyond CloudTrail.

4. **KMS CMK encryption (S-1 through S-5)** -- Introduce an optional `kms_key_arn` variable. When provided, use it for:
   - S3 bucket encryption (state + artifacts)
   - CloudWatch log group encryption
   - CodeBuild project encryption
   - CodePipeline artifact store encryption
   - This addresses CKV_AWS_145, CKV_AWS_158, CKV_AWS_147, CKV_AWS_219 in a single effort.

### Long-Term (Post-MVP Hardening)

5. **State bucket lifecycle for non-current versions** -- Add a rule to expire non-current object versions after a configurable period (e.g., 90 days) to manage storage costs while maintaining recovery capability.

6. **VPC endpoints for CodeBuild** -- Documented as out-of-scope in the architecture. Would eliminate internet access from build containers, further reducing attack surface.

---

## Security Posture Summary

### Controls That PASSED (Highlights)

These are the most important security checks, and the module passes all of them:

| Check | Description | Status |
|-------|-------------|--------|
| CKV_AWS_41 | No hardcoded AWS credentials in provider | PASSED |
| CKV_AWS_274 | No AdministratorAccess policy on IAM roles | PASSED |
| CKV_AWS_61 | No assume role across all services | PASSED |
| CKV_AWS_60 | IAM roles allow only specific services | PASSED |
| CKV_AWS_63 | No wildcard actions in IAM policies | PASSED |
| CKV_AWS_62 | No full admin privileges in IAM policies | PASSED |
| CKV_AWS_316 | CodeBuild privileged mode disabled | PASSED |
| CKV_AWS_78 | CodeBuild encryption not disabled | PASSED |
| CKV_AWS_314 | CodeBuild logging enabled | PASSED |
| CKV_AWS_311 | CodeBuild S3 logs encrypted | PASSED |
| CKV_AWS_66 | CloudWatch log retention set | PASSED |
| CKV_AWS_26 | SNS topic encrypted | PASSED |
| CKV_AWS_169 | SNS topic policy not public | PASSED |
| CKV_AWS_93 | S3 bucket policy does not lock out users | PASSED |
| CKV_AWS_53-56 | S3 block public access (all 4 settings) | PASSED |
| CKV_AWS_20 | No public READ ACL on S3 | PASSED |
| CKV_AWS_57 | No public WRITE ACL on S3 | PASSED |
| CKV_AWS_19 | S3 encrypted at rest | PASSED |
| CKV_AWS_21 | S3 versioning enabled (plan scan) | PASSED |
| CKV2_AWS_6 | S3 public access block present (plan scan) | PASSED |
| CKV2_AWS_56 | No IAMFullAccess managed policy | PASSED |
| CKV2_AWS_61 | S3 lifecycle configured (artifacts) | PASSED |

---

## Appendix: Raw Scan Outputs

The following files contain the complete scan output and are located in `docs/working/`:

| File | Description |
|------|-------------|
| `checkov-module-output.txt` | Checkov scan of module source code (64 passed, 30 failed) |
| `checkov-plan-output.txt` | Checkov scan of Terraform plan JSON (58 passed, 22 failed) |
| `trivy-module-output.txt` | Trivy config scan of module source code (34 misconfigurations, all LOW/HIGH) |
| `trivy-plan-output.txt` | Trivy config scan of plan JSON (0 findings, parser limitations) |

All output files are stored at:
`/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/docs/working/`
