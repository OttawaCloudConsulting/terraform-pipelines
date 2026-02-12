# Feature 12 — PR Review: Buildspec & Code Quality

## Summary

Addresses code quality findings from PR #1 review. Adds shell safety to all buildspecs, fixes an invalid cross-variable validation, and tightens `project_name` input constraints.

## Files Changed

| File | Change |
|------|--------|
| `buildspecs/prebuild.yml` | Added `set -euo pipefail` to 1 shell block |
| `buildspecs/plan.yml` | Added `set -euo pipefail` to 3 shell blocks |
| `buildspecs/deploy.yml` | Added `set -euo pipefail` to 2 shell blocks |
| `buildspecs/test.yml` | Added `set -euo pipefail` to 1 shell block |
| `variables.tf` | Removed cross-variable `state_bucket` validation; updated `project_name` regex and added consecutive hyphen check |
| `storage.tf` | Added `lifecycle { precondition }` on `data.aws_s3_bucket.existing_state` |

## Decisions

- **`set -euo pipefail` in every `|` block**: CodeBuild YAML `|` blocks run as a single shell script. Without `-e`, intermediate failures are silently swallowed. `-u` catches typos in variable names. `-o pipefail` ensures piped commands propagate failures. All CodeBuild environment variables are guaranteed to be set, so `-u` is safe.
- **Precondition instead of variable validation**: Terraform does not support cross-variable references in `validation` blocks (`var.state_bucket` cannot reference `var.create_state_bucket`). The `precondition` on the data source fires at plan time with a clear error message, achieving the same safety net.
- **Two separate validation blocks for `project_name`**: Splitting the regex check from the consecutive-hyphen check produces clearer error messages — the user knows exactly which constraint they violated.

## Validation

- Checkov: 63 passed, 0 failed, 70 skipped
- Plan: 0 to add, 4 to change, 0 to destroy (buildspec content updates)
- Apply: 0 added, 4 changed, 0 destroyed

## Verification

```bash
# Verify set -euo pipefail is in all shell blocks
grep -c 'set -euo pipefail' buildspecs/*.yml
# Expected: prebuild.yml:1, plan.yml:3, deploy.yml:2, test.yml:1

# Verify project_name validation rejects bad input
terraform plan -var='project_name=AB-test'
# Expected: error (uppercase not allowed)

terraform plan -var='project_name=a--b'
# Expected: error (consecutive hyphens)

terraform plan -var='project_name=abcdefghijklmnopqrstuvwxyz0123456789'
# Expected: error (exceeds 34 chars)

# Verify precondition on data source
terraform plan -var='create_state_bucket=false' -var='state_bucket='
# Expected: error "state_bucket must be provided when create_state_bucket is false."
```
