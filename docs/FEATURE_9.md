# Feature 9 — End-to-End Deployment Test

## Summary

Full end-to-end deployment test of the pipeline module. Deployed to the Automation Account, ran all 9 pipeline stages successfully, verified deployed resources in target accounts, and completed clean terraform destroy.

## Files Changed

| File | Change |
|------|--------|
| `storage.tf` | Added account ID to S3 bucket names for global uniqueness |
| `iam.tf` | Added `codestar-connections:UseConnection` permission to CodeBuild role |
| `main.tf` | Changed buildspec references from file paths to `file()` inline |
| `buildspecs/prebuild.yml` | YAML single-quoted echo commands with colon-space |
| `buildspecs/deploy.yml` | Same YAML fix for colon-space in echo commands |
| `buildspecs/test.yml` | Same YAML fix for colon-space in echo commands |
| `outputs.tf` | Added `dev_account_id` and `prod_account_id` outputs |
| `tests/e2e/main.tf` | E2E test root module |
| `tests/test-terraform.sh` | Fixed to use E2E dir for plan/apply, correct AWS profile |
| `docs/working/CROSS_ACCOUNT_ROLES.md` | Cross-account role documentation (v1.2) |
| `docs/working/deployment-role-trust-policy.json` | Trust policy with dual trust pattern |
| `docs/working/boundary-policy-dev.json` | Updated boundary policy for DEV account |
| `docs/working/boundary-policy-prod.json` | Updated boundary policy for PROD account |

## Decisions

1. **Inline buildspecs via `file()`**: Buildspecs are module-managed files, not consumer repo files. Using `file("${path.module}/buildspecs/...")` embeds them in the CodeBuild project configuration, eliminating dependency on the source repo containing them.

2. **YAML single-quoted echo commands**: CodeBuild's YAML parser interprets `: ` (colon-space) inside standalone echo commands as key-value mappings. Wrapping in YAML single quotes (`'echo "Key: $VAR"'`) prevents this.

3. **Account ID in bucket names**: S3 bucket names are globally unique. Appending `${data.aws_caller_identity.current.account_id}` prevents collisions across AWS accounts.

4. **Dual trust pattern for deployment roles**: Deployment roles trust both the broker role (`org-automation-broker-role`) for interactive use and CodeBuild service roles (`CodeBuild-*-ServiceRole`) for pipeline use via `StringLike` condition.

5. **Boundary policy as deny-list**: The `Boundary-Boundary-Default` permissions boundary was updated from an allow-list (only organizations read actions) to a deny-list pattern (allow all, deny specific protected operations). Without the broad Allow, even `AdministratorAccess` on the role was ineffective.

## Verification

Pipeline deployment and full flow were verified:

```bash
# Deploy pipeline (27 resources)
cd tests/e2e && terraform init && terraform apply

# Verify pipeline execution (all 9 stages passed)
aws codepipeline get-pipeline-state --name e2e-test-pipeline --profile aft-automation

# Verify S3 buckets in target accounts
aws s3api head-bucket --bucket <bucket-name> --profile developer-account
aws s3api head-bucket --bucket <bucket-name> --profile network

# Clean destroy
terraform destroy
```

## Prerequisites (Manual)

The following were created manually in target accounts before testing:

1. **Deployment roles** (`org-default-deployment-role`) in DEV and PROD with:
   - `AdministratorAccess` policy
   - Trust policy allowing both broker role and `CodeBuild-*-ServiceRole`
   - Permissions boundary: `Boundary-Boundary-Default`

2. **Boundary policy update** (v2) adding `AllowAllServices` statement

See `docs/working/CROSS_ACCOUNT_ROLES.md` for full documentation.
