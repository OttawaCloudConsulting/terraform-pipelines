# Changelog

## [Feature 8] — 2026-02-12

Three example root modules demonstrating module usage: minimal (required vars only), complete (all vars with overrides), and opentofu (OpenTofu runtime). All pass `terraform init && terraform validate` and `terraform fmt -check`.

## [Features 1-7] — 2026-02-12

Complete Terraform pipeline module implementation: module skeleton, IAM roles, S3 buckets, SNS topic, CodeStar connection, CodeBuild projects with buildspecs, and CodePipeline V2 with all 9 stages. All resources validated with `terraform validate`, `terraform fmt`, `tflint`, `checkov`, and `trivy`.
