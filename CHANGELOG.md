# Changelog

## [Feature 9] — 2026-02-12

End-to-end deployment test of the full pipeline module. Deployed 27 resources to the Automation Account, tested all 9 pipeline stages (Source through Test-PROD) with the terraform-test repo, verified S3 buckets deployed to both DEV and PROD accounts, and completed clean terraform destroy. Fixes applied during E2E: inline buildspecs via `file()`, YAML single-quoted echo commands, `codestar-connections:UseConnection` permission, account ID in bucket names, and permissions boundary updates.

## [Feature 8] — 2026-02-12

Three example root modules demonstrating module usage: minimal (required vars only), complete (all vars with overrides), and opentofu (OpenTofu runtime). All pass `terraform init && terraform validate` and `terraform fmt -check`.

## [Features 1-7] — 2026-02-12

Complete Terraform pipeline module implementation: module skeleton, IAM roles, S3 buckets, SNS topic, CodeStar connection, CodeBuild projects with buildspecs, and CodePipeline V2 with all 9 stages. All resources validated with `terraform validate`, `terraform fmt`, `tflint`, `checkov`, and `trivy`.
