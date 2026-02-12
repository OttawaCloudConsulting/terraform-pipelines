# Changelog

## [Feature 13] — 2026-02-12

Repository hygiene. Updated `.gitignore` to exclude plan output files (`*.tfplan`, `tfplan.binary`, `tfplan.json`), provider lock files (`.terraform.lock.hcl`), and Claude Code local settings (`.claude/settings.local.json`).

## [Feature 12] — 2026-02-12

Buildspec and code quality improvements. Added `set -euo pipefail` to all 7 multi-line shell blocks across 4 buildspecs. Moved cross-variable `state_bucket` validation from variable block to `precondition` on `data.aws_s3_bucket.existing_state`. Updated `project_name` validation to enforce 3-34 character length and reject consecutive hyphens.

## [Feature 11] — 2026-02-12

PR review security hardening. Converted checkov from advisory-only (`|| true`) to a real security gate with `--hard-fail-on CRITICAL,HIGH` and `checkov_soft_fail` variable. Added inline `#checkov:skip` suppressions for 11 deferred checks (70 skipped instances) with documented rationale. Added `codebuild_image` validation (aws/codebuild/ prefix), SNS `aws:SourceAccount` condition, `prevent_destroy` on state bucket, `s3:GetBucketLocation` IAM permission. Pinned provider to `~> 6.0` (installed v6.32.0).

## [Feature 10] — 2026-02-12

SecOps security hardening based on Checkov + Trivy assessment. Added optional S3 access logging for state and artifact buckets via `logging_bucket` variable. Added `abort_incomplete_multipart_upload` (7-day) to artifact bucket lifecycle. Updated `log_retention_days` description with 365-day compliance recommendation and set `examples/complete/` to 365.

## [Feature 9] — 2026-02-12

End-to-end deployment test of the full pipeline module. Deployed 27 resources to the Automation Account, tested all 9 pipeline stages (Source through Test-PROD) with the terraform-test repo, verified S3 buckets deployed to both DEV and PROD accounts, and completed clean terraform destroy. Fixes applied during E2E: inline buildspecs via `file()`, YAML single-quoted echo commands, `codestar-connections:UseConnection` permission, account ID in bucket names, and permissions boundary updates.

## [Feature 8] — 2026-02-12

Three example root modules demonstrating module usage: minimal (required vars only), complete (all vars with overrides), and opentofu (OpenTofu runtime). All pass `terraform init && terraform validate` and `terraform fmt -check`.

## [Features 1-7] — 2026-02-12

Complete Terraform pipeline module implementation: module skeleton, IAM roles, S3 buckets, SNS topic, CodeStar connection, CodeBuild projects with buildspecs, and CodePipeline V2 with all 9 stages. All resources validated with `terraform validate`, `terraform fmt`, `tflint`, `checkov`, and `trivy`.
