# Security Review -- PR #1

**Reviewer:** Security Engineer
**Date:** 2026-02-12
**Focus:** IAM, Encryption, Secrets, Access Control, Cross-Account Trust

---

## Critical Findings

### No critical findings.

---

## High Findings

### H-1: Checkov Security Scan Cannot Fail the Pipeline (`buildspecs/plan.yml`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/plan.yml`, line 52
**Code:**
```yaml
- checkov -f tfplan.json --framework terraform_plan --output junitxml --output-file checkov-report.xml || true
```

**Issue:** The `|| true` suffix means Checkov findings will never stop the pipeline. The architecture document (`ARCHITECTURE_AND_DESIGN.md` line 213, SEC11-BP07 table) states: *"Security tests cannot be bypassed -- Checkov scan runs in Plan stage before any deployment. Non-zero exit stops pipeline."* This is a direct contradiction between documentation and implementation. In practice, an operator who trusts the documentation would believe security gates are enforced when they are not.

**Risk:** A Terraform plan with critical security misconfigurations (public S3 buckets, overly permissive security groups, unencrypted resources) will proceed to deployment without any gate.

**Recommendation:** Remove `|| true` and let Checkov fail the build on findings. If the intent is to allow warnings but block on critical/high findings, use Checkov's `--check` or `--hard-fail-on` flags to fail only on specific severity levels:
```yaml
- checkov -f tfplan.json --framework terraform_plan --output junitxml --output-file checkov-report.xml --hard-fail-on CRITICAL,HIGH
```
If the design intent is truly advisory-only, update the architecture document to reflect that.

---

### H-2: Deployment Role ARNs Passed as PLAINTEXT Environment Variables in Pipeline Configuration (`main.tf`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/main.tf`, lines 352-363, 382-393, 430-441, 460-471

**Code:**
```hcl
EnvironmentVariables = jsonencode([
  {
    name  = "TARGET_ROLE"
    value = var.dev_deployment_role_arn
    type  = "PLAINTEXT"
  }
])
```

**Issue:** Cross-account deployment role ARNs are passed as `PLAINTEXT` type environment variables in the CodePipeline action configuration. While ARNs are not secrets per se, they are sensitive information that reveals the cross-account trust chain. Anyone with `codepipeline:GetPipeline` permission can read these values. More importantly, these ARNs are visible in the CodePipeline console, CloudTrail logs, and any API response that describes the pipeline.

**Risk:** Information disclosure. An attacker who obtains the role ARNs knows exactly which roles to target for privilege escalation across accounts. The ARN also reveals account IDs, role names, and the trust relationship pattern.

**Recommendation:** Consider using AWS Systems Manager Parameter Store references (`PARAMETER_STORE` type) instead of `PLAINTEXT` for the `TARGET_ROLE` values. This keeps the role ARNs out of the pipeline definition itself:
```hcl
{
  name  = "TARGET_ROLE"
  value = "/pipeline/${var.project_name}/dev/deployment-role-arn"
  type  = "PARAMETER_STORE"
}
```
This is a defense-in-depth improvement. The risk is moderate because the ARNs are already present in the Terraform state and IAM policy, but reducing their surface area is worthwhile.

---

### H-3: Provider Version Constraint Too Permissive (`versions.tf`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/versions.tf`, line 7

**Code:**
```hcl
version = ">= 5.0"
```

**Issue:** The `>= 5.0` constraint allows any future major version of the AWS provider (6.0, 7.0, etc.) to be used without explicit opt-in. Major version bumps can introduce breaking changes, new defaults (e.g., encryption settings, resource behaviors), or deprecate security-relevant features. This is a supply chain risk.

**Risk:** A future `terraform init` could pull a provider version with changed IAM policy syntax, different S3 default encryption behavior, or deprecated resource types, potentially introducing security regressions without any code change.

**Recommendation:** Use the pessimistic constraint operator as required by the project's own `terraform-best-practices.md` rule:
```hcl
version = "~> 5.0"
```
This allows 5.x minor/patch updates but blocks 6.0+.

---

## Medium Findings

### M-1: IaC Binary Downloaded Over HTTPS Without Checksum Verification (`buildspecs/plan.yml`, `buildspecs/deploy.yml`)

**Files:**
- `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/plan.yml`, lines 8-25
- `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/deploy.yml`, lines 8-25

**Code (Terraform download):**
```bash
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o terraform.zip
unzip -o terraform.zip -d /usr/local/bin/
```

**Code (OpenTofu download):**
```bash
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone
```

**Issue:** Both the Terraform and OpenTofu installation paths download binaries from the internet without verifying SHA256 checksums or GPG signatures. The OpenTofu path pipes a remote script directly to `sh`, which is a classic supply chain attack vector (compromised CDN, DNS hijack, MITM at egress).

**Risk:** If the download source is compromised, a malicious binary would execute with full CodeBuild service role permissions, including cross-account `sts:AssumeRole` to both DEV and PROD accounts. This is a high-impact supply chain risk.

**Recommendation:**
For Terraform, download and verify the SHA256 checksum:
```bash
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS" -o SHA256SUMS
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS.sig" -o SHA256SUMS.sig
# Verify GPG signature (HashiCorp key)
gpg --verify SHA256SUMS.sig SHA256SUMS
grep "linux_amd64" SHA256SUMS | sha256sum -c -
```
For OpenTofu, use the `--install-method` with checksum verification, or pin to a specific known-good version and verify the hash.

---

### M-2: STS Credentials Stored in Shell Variables, Potentially Logged (`buildspecs/deploy.yml`, `buildspecs/test.yml`)

**Files:**
- `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/deploy.yml`, lines 34-41
- `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/test.yml`, lines 11-18

**Code:**
```bash
CREDENTIALS=$(aws sts assume-role \
  --role-arn "${TARGET_ROLE}" \
  --role-session-name "codebuild-deploy-${TARGET_ENV}" \
  --duration-seconds 3600 \
  --output json)
export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")
```

**Issue:** The full STS response JSON (containing AccessKeyId, SecretAccessKey, and SessionToken) is stored in a shell variable `$CREDENTIALS`. If CodeBuild's `set -x` tracing is enabled (either by a developer's prebuild script or by debugging), these values would appear in CloudWatch logs. Additionally, the `$CREDENTIALS` variable persists in the shell environment for the duration of the build phase.

**Mitigating factors:** The buildspecs do not enable `set -x`, and the credentials are temporary (1 hour). CloudWatch logs are access-controlled.

**Recommendation:** Add explicit safeguards:
1. Add `set +x` before the credential extraction block to ensure tracing is disabled regardless of what prior scripts did.
2. Unset the `CREDENTIALS` variable immediately after extraction: `unset CREDENTIALS`.
3. Consider using `jq` with `--raw-output` instead of piping through `python3`, which avoids loading the full JSON into a second process's command line.

---

### M-3: CodeBuild Service Role Has `s3:DeleteObject` on State Bucket (`iam.tf`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/iam.tf`, lines 131-143

**Code:**
```hcl
{
  Sid    = "S3StateBucketAccess"
  Effect = "Allow"
  Action = [
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",
    "s3:ListBucket"
  ]
  Resource = [
    "arn:aws:s3:::${local.state_bucket_name}",
    "arn:aws:s3:::${local.state_bucket_name}/*"
  ]
}
```

**Issue:** The CodeBuild service role has `s3:DeleteObject` permission on the state bucket. While this may be needed for Terraform's native S3 locking (`.tflock` file cleanup), it also allows deletion of `terraform.tfstate` files themselves.

**Risk:** A compromised build or malicious code in a developer's prebuild/test script could delete state files, causing state loss and potential orphaned resources across both DEV and PROD accounts.

**Recommendation:** Scope `s3:DeleteObject` to only the lock file path pattern if possible:
```hcl
{
  Sid    = "S3StateLockCleanup"
  Effect = "Allow"
  Action = "s3:DeleteObject"
  Resource = "arn:aws:s3:::${local.state_bucket_name}/${local.state_key_prefix}/*/.tflock"
}
```
Alternatively, rely on S3 versioning (which is enabled) as the safety net and document that `s3:DeleteObject` is required for lock file management.

---

### M-4: CloudWatch Log Groups Not Encrypted with KMS

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/main.tf`, lines 8-30

**Issue:** The four CloudWatch log groups do not specify a `kms_key_id`. While CloudWatch Logs encrypts data at rest with AWS-managed encryption by default, build logs may contain sensitive output from `terraform plan` (which can show resource attributes including secrets referenced in Terraform code).

**Risk:** Without customer-managed KMS, there is no ability to revoke access to historical logs via key policy changes, and no independent key rotation control.

**Recommendation:** This is already documented as a post-MVP enhancement in the SecOps report. For production deployments, add an optional `kms_key_arn` variable and apply it to log groups:
```hcl
resource "aws_cloudwatch_log_group" "plan" {
  name              = "/codebuild/${var.project_name}-plan"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null
  tags              = local.all_tags
}
```

---

### M-5: SNS Topic Policy Allows Any CodePipeline Service to Publish (`storage.tf`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/storage.tf`, lines 175-192

**Code:**
```hcl
{
  Sid    = "AllowCodePipelinePublish"
  Effect = "Allow"
  Principal = {
    Service = "codepipeline.amazonaws.com"
  }
  Action   = "SNS:Publish"
  Resource = aws_sns_topic.approvals.arn
}
```

**Issue:** The SNS topic policy grants `SNS:Publish` to the `codepipeline.amazonaws.com` service principal without any condition to scope it to this specific account or pipeline. Any CodePipeline in any AWS account could theoretically publish to this topic (the confused deputy problem).

**Risk:** An attacker with a CodePipeline in another account could send misleading approval notifications to the subscribed email addresses, potentially tricking an operator into approving a malicious deployment (social engineering vector).

**Recommendation:** Add an `aws:SourceAccount` or `aws:SourceArn` condition to the topic policy:
```hcl
Condition = {
  StringEquals = {
    "aws:SourceAccount" = data.aws_caller_identity.current.account_id
  }
}
```

---

### M-6: `codebuild_image` Variable Accepts Any String Without Validation (`variables.tf`)

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/variables.tf`, lines 149-153

**Code:**
```hcl
variable "codebuild_image" {
  description = "CodeBuild managed image for all build projects."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}
```

**Issue:** The `codebuild_image` variable has no validation. A consumer could specify a custom Docker image (e.g., from a public ECR registry or Docker Hub) that contains malicious tooling. The CLAUDE.md states "Standard CodeBuild managed images only (no custom Docker images in MVP)."

**Risk:** A supply chain attack via a compromised or malicious Docker image that would execute with full CodeBuild service role permissions.

**Recommendation:** Add a validation block that enforces AWS-managed images:
```hcl
validation {
  condition     = can(regex("^aws/codebuild/", var.codebuild_image))
  error_message = "codebuild_image must be an AWS-managed CodeBuild image (prefix: aws/codebuild/)."
}
```

---

## Low / Informational

### L-1: S3 Buckets Use SSE-S3 Instead of SSE-KMS with CMK

**Files:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/storage.tf`, lines 20-29, 97-105

**Issue:** Both the state bucket and artifact bucket use `AES256` (SSE-S3) encryption. This provides encryption at rest but without customer-managed key control, independent rotation, or the ability to revoke access via key policy.

**Status:** This is an acknowledged, documented design decision (Architecture Decision #4). SSE-S3 is the AWS default since January 2023. The SecOps assessment classified this as "suppress/ignore" for MVP with a post-MVP roadmap item for CMK encryption.

**Recommendation:** No action needed for MVP. Track the KMS CMK migration in the post-MVP backlog.

---

### L-2: `iac_version` Defaults to `latest` -- Non-Deterministic Builds

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/variables.tf`, lines 86-90

**Issue:** The default value of `iac_version` is `"latest"`, which means the Terraform or OpenTofu version installed in CodeBuild changes over time without any code change. A new IaC release could introduce behavioral changes affecting plan or apply output.

**Risk:** Non-reproducible builds. A pipeline that worked yesterday could behave differently today due to a new Terraform release. This is primarily a reliability concern but has security implications if a new version changes provider credential handling or state locking behavior.

**Recommendation:** Document that production pipelines should always pin `iac_version` to a specific version string (e.g., `"1.11.2"`). Consider changing the default to a specific known-good version.

---

### L-3: Hardcoded Account IDs in E2E Test Configuration

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/tests/e2e/main.tf`

**Issue:** The E2E test module contains real AWS account IDs (389068787156, 914089393341, 264675080489) and role ARNs. If the repository is public or shared beyond the immediate team, this discloses internal account structure.

**Recommendation:** Use environment variables or a `.tfvars` file excluded from version control, or use obviously fake placeholder values in committed code.

---

### L-4: No `prevent_destroy` Lifecycle on State Bucket

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/storage.tf`, lines 5-9

**Issue:** The state bucket resource has no `lifecycle { prevent_destroy = true }` block. A `terraform destroy` on the pipeline module would delete the state bucket and all Terraform state for the managed project.

**Recommendation:** Add a lifecycle rule to prevent accidental state loss:
```hcl
resource "aws_s3_bucket" "state" {
  count  = var.create_state_bucket ? 1 : 0
  bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"
  tags   = local.all_tags

  lifecycle {
    prevent_destroy = true
  }
}
```

---

### L-5: Developer-Controlled Scripts Execute with Full CodeBuild Permissions

**Files:**
- `buildspecs/prebuild.yml` -- runs `cicd/prebuild/main.sh`
- `buildspecs/test.yml` -- runs `cicd/${TARGET_ENV}/smoke-test.sh`

**Issue:** The prebuild and test stages execute arbitrary shell scripts from the consumer's repository. These scripts run with the full permissions of the CodeBuild service role, which includes `sts:AssumeRole` to both DEV and PROD deployment roles, S3 state bucket access, and CloudWatch Logs access.

**Mitigating factors:** This is by design -- the pipeline is a template that supports developer-managed hooks. The scripts come from the same repository that contains the Terraform code being deployed, so they are subject to the same code review process.

**Recommendation:** Document this trust boundary clearly. Consider whether the prebuild stage (which runs before any deployment) actually needs the cross-account `sts:AssumeRole` permission. If not, a separate IAM role with reduced permissions for the prebuild CodeBuild project would limit blast radius.

---

### L-6: Plan Stage State Path Could Accumulate Stale State

**File:** `/Users/christian/git-repos/OCC-github/aws-control-tower-landing-zone/terraform-pipelines/buildspecs/plan.yml`, line 38

**Code:**
```bash
-backend-config="key=${STATE_KEY_PREFIX}/plan/terraform.tfstate"
```

**Issue:** The plan stage writes to a dedicated state path (`<prefix>/plan/terraform.tfstate`). Since plans are environment-agnostic and re-run on every pipeline execution, this state file accumulates and is never cleaned up. It also potentially contains resource metadata from the last plan.

**Recommendation:** Consider whether the plan stage needs a persistent state file at all, or whether it could use a local backend. If remote state is required for provider initialization, document that the `plan/` state path is ephemeral and can be safely deleted.

---

## Positive Observations

### P-1: IAM Policies Follow Least Privilege

The IAM policies are well-scoped throughout:
- **CodePipeline service role** is limited to specific S3 bucket ARNs, specific CodeBuild project ARNs, a single CodeStar connection, and a single SNS topic. No wildcards.
- **CodeBuild service role** has `sts:AssumeRole` scoped to exactly the two deployment role ARNs. No `Resource: "*"` anywhere in IAM policies.
- **No `iam:*`, `organizations:*`, or `sts:*` broad grants.** The CodeBuild role cannot create users, modify roles, or escalate privileges within the automation account.
- All IAM policy statements have explicit `Sid` values for auditability.

### P-2: S3 Security Controls Are Comprehensive

Both S3 buckets have the full complement of security controls:
- Server-side encryption enabled (AES256)
- All four S3 Block Public Access settings enabled
- Bucket policies deny non-SSL requests (`aws:SecureTransport = false`)
- Versioning enabled on both buckets
- Artifact bucket has lifecycle expiration with multipart upload abort
- Optional access logging support via `logging_bucket` variable

### P-3: CodeBuild Privileged Mode Explicitly Disabled

All four CodeBuild projects set `privileged_mode = false` explicitly. This prevents Docker-in-Docker attacks and container escape risks. This satisfies Security Hub control `[CodeBuild.5]`.

### P-4: No Hardcoded Secrets or Credentials

The codebase contains zero hardcoded AWS credentials, API tokens, or secrets. Cross-account access uses STS AssumeRole with temporary credentials. The CodeStar connection uses OAuth (GitHub App), not personal access tokens. No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` appear in any environment variable configuration.

### P-5: SNS Topic Encryption Enabled

The SNS approval topic uses the AWS-managed KMS key (`alias/aws/sns`), which provides encryption at rest for notification messages. This satisfies Security Hub check `CKV_AWS_26`.

### P-6: CloudWatch Log Groups Have Explicit Retention

All four log groups have configurable retention (`var.log_retention_days`, default 30). No log group uses indefinite retention, preventing unbounded log storage costs and ensuring log data has a defined lifecycle.

### P-7: Cross-Account Trust Model Is Sound

The cross-account credential flow uses first-hop `sts:AssumeRole` (no role chaining), which is the recommended pattern for CodeBuild cross-account deployments. The deployment roles are external prerequisites with documented trust policy requirements including `aws:PrincipalOrgID` condition. The CodeBuild service role is scoped to assume only the two specified deployment roles.

### P-8: Input Validation on Security-Sensitive Variables

Variables like `dev_account_id`, `prod_account_id`, `dev_deployment_role_arn`, and `prod_deployment_role_arn` all have regex validation blocks that enforce correct format (12-digit account IDs, valid IAM role ARN patterns). This prevents misconfiguration that could lead to cross-account trust misrouting.

### P-9: Mandatory Production Approval Gate

Stage 7 (Mandatory Approval) is always present in the pipeline -- it is not conditional. This ensures every production deployment requires human approval with SNS notification, providing an audit trail via CloudTrail.

---

## Summary

| Severity | Count | Action Required |
|----------|-------|----------------|
| Critical | 0 | -- |
| High | 3 | Should fix before production use |
| Medium | 6 | Recommended improvements |
| Low/Info | 6 | Track in backlog |

The module demonstrates strong security fundamentals: least-privilege IAM, encryption at rest on all storage, no hardcoded credentials, explicit privileged mode disabling, and a sound cross-account trust model. The high findings relate to the security scan bypass (`|| true`), supply chain hardening (provider pinning, binary verification), and the informational exposure of role ARNs in plaintext pipeline configuration. The medium findings are defense-in-depth improvements that would further harden the module for production use in regulated environments.
