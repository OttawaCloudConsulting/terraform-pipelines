# Feature 10 — SecOps Security Hardening

## Summary

Addresses three recommendations from the SecOps security assessment (Checkov + Trivy, 2026-02-12). Adds optional S3 access logging, incomplete multipart upload cleanup, and compliance documentation for log retention. No critical or high-severity findings existed — these are defense-in-depth improvements.

## Files Changed

| File | Change |
|------|--------|
| `storage.tf` | Added `aws_s3_bucket_logging.state` (conditional), `aws_s3_bucket_logging.artifacts` (conditional), `abort_incomplete_multipart_upload` block on artifact lifecycle |
| `variables.tf` | Added `logging_bucket` and `logging_prefix` variables; updated `log_retention_days` description |
| `examples/complete/main.tf` | Changed `log_retention_days` from 90 to 365 |
| `docs/ARCHITECTURE_AND_DESIGN.md` | Added design decisions #19-21, resources #14-15, conditional resource entries |
| `prd.md` | Added Feature 10 with acceptance criteria, added new variables to input table |
| `progress.txt` | Added and completed Feature 10 |

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `logging_bucket` | `string` | `""` | Existing S3 bucket name for access logs. When provided, enables server access logging on state and artifact buckets. Leave empty to disable. |
| `logging_prefix` | `string` | `""` | S3 key prefix for access logs. When empty, defaults to `s3-access-logs/<project_name>-<bucket_type>/`. |

## Validation

Plan output (e2e config, `logging_bucket` not set): **27 to add, 0 to change, 0 to destroy** — unchanged from pre-feature baseline. Logging resources correctly excluded when `logging_bucket == ""`.

## Decisions

| Decision | Rationale |
|----------|-----------|
| Logging opt-in, not default | No breaking change for existing consumers. CloudTrail already provides API-level audit. S3 access logging adds object-level granularity as defense-in-depth. |
| 7-day multipart upload abort | Conservative threshold — pipeline artifacts are small and upload quickly. 7 days gives ample margin before cleanup. |
| Default `log_retention_days` stays at 30 | Changing the default would be a breaking change for existing consumers. Compliance recommendation documented in variable description and `examples/complete/`. |
| Both buckets get logging | State bucket (sensitive) and artifact bucket (ephemeral but auditable) both benefit from access logging when the consumer provides a logging bucket. |

## Verification

When deployed with `logging_bucket` set:

```bash
# Verify access logging is enabled on state bucket
aws s3api get-bucket-logging --bucket <project>-terraform-state-<account_id> --profile aft-automation

# Verify access logging is enabled on artifact bucket
aws s3api get-bucket-logging --bucket <project>-pipeline-artifacts-<account_id> --profile aft-automation

# Verify abort_incomplete_multipart_upload on artifact bucket
aws s3api get-bucket-lifecycle-configuration --bucket <project>-pipeline-artifacts-<account_id> --profile aft-automation
```
