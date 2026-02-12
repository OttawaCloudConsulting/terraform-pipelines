# Feature 11 — PR Review: Security Hardening

## Summary

Addresses 7 security findings from the PR #1 review (Security Engineer, Architect, Senior Developer, Copilot). Converts the checkov security scan from advisory-only to a real gate, adds inline suppressions for deferred items, hardens the SNS topic policy, protects the state bucket from accidental deletion, fixes an IAM permission gap, validates the CodeBuild image input, and pins the provider constraint.

## Files Changed

| File | Change |
|------|--------|
| `buildspecs/plan.yml` | Removed `\|\| true`, added `--hard-fail-on CRITICAL,HIGH` and soft-fail conditional |
| `main.tf` | Added `CHECKOV_SOFT_FAIL` env var to plan project; `#checkov:skip` on 4 log groups, 4 CodeBuild projects, 1 CodePipeline |
| `storage.tf` | `#checkov:skip` on 2 S3 buckets; `prevent_destroy` on state bucket; `aws:SourceAccount` on SNS policy |
| `variables.tf` | Added `checkov_soft_fail` variable; added `codebuild_image` validation |
| `iam.tf` | Added `s3:GetBucketLocation` to `S3StateBucketAccess` |
| `versions.tf` | Changed `>= 5.0` to `~> 6.0` |
| `examples/minimal/main.tf` | Changed `>= 5.0` to `~> 6.0` |
| `examples/complete/main.tf` | Changed `>= 5.0` to `~> 6.0` |
| `examples/opentofu/main.tf` | Changed `>= 5.0` to `~> 6.0` |

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `checkov_soft_fail` | `bool` | `false` | When true, checkov findings do not fail the pipeline |

## Checkov Suppressions

| Check ID | Resources | Rationale |
|----------|-----------|-----------|
| CKV_AWS_158 | 4 CloudWatch log groups | Post-MVP: KMS CMK encryption (design decision #4) |
| CKV_AWS_338 | 4 CloudWatch log groups | Consumer-configurable via `log_retention_days`; default 30d |
| CKV_AWS_147 | 4 CodeBuild projects | Post-MVP: CMK encryption (design decision #4) |
| CKV_AWS_219 | 1 CodePipeline | Post-MVP: CMK artifact encryption (design decision #4) |
| CKV_AWS_145 | 2 S3 buckets | Post-MVP: SSE-KMS (design decision #4); SSE-S3 active |
| CKV_AWS_144 | 2 S3 buckets | Single-region design; cross-region replication out of scope |
| CKV2_AWS_62 | 2 S3 buckets | Event notifications not required |
| CKV_AWS_18 | 2 S3 buckets | Conditional via `logging_bucket` variable (Feature 10.1) |
| CKV2_AWS_61 | 1 S3 state bucket | State intentionally retained; no lifecycle expiry |
| CKV_AWS_21 | 1 S3 state bucket | False positive: versioning via separate resource |
| CKV2_AWS_6 | 1 S3 state bucket | False positive: public access block via separate resource |

## Validation

- Checkov: 63 passed, 0 failed, 70 skipped
- Plan: 27 to add, 0 to change, 0 to destroy
- Apply: 27 added, 0 changed, 0 destroyed

## Decisions

- **Provider pinned to `~> 6.0`** (not `~> 5.0`): The installed version is 6.32.0 per `.terraform.lock.hcl`. Pinning to `~> 5.0` would force a downgrade with potential breaking changes. Architecture decision #23.
- **`--hard-fail-on CRITICAL,HIGH`** instead of removing `|| true` entirely: Allows medium/low findings to be reported without blocking the pipeline, while critical/high findings stop deployment. Architecture decision #22.
- **`prevent_destroy` on state bucket**: Prevents catastrophic state loss. Consumers must explicitly remove the lifecycle rule to destroy. Architecture decision #24.

## Verification

```bash
# Verify checkov runs as a real gate (should show 0 failures)
checkov -d . --framework terraform --compact --quiet

# Verify provider constraint
grep 'version' versions.tf
# Expected: version = "~> 6.0"

# Verify prevent_destroy is set
grep -A2 'lifecycle' storage.tf
# Expected: prevent_destroy = true
```
