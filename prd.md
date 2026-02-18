# PRD: Provider Override for Cross-Account Credential Flow

## Summary

The pipeline buildspecs need to run Terraform commands that access two different AWS accounts simultaneously: the Automation account (for S3 state bucket) and a target account (for infrastructure resources). This refinement uses Terraform's override file mechanism to inject `assume_role` into the developer's provider block at runtime, so the CodeBuild service role's instance profile credentials handle S3 state access while the provider's `assume_role` handles target account API calls. No `aws sts assume-role` or `export AWS_*` in buildspecs.

## Goals

- **Fix state access** — `terraform init/plan/apply/destroy` must successfully access the S3 state bucket in the Automation account while operating on resources in target accounts
- **Preserve security model** — Target account deployment roles must NOT gain access to the state bucket. State bucket access remains restricted to Automation account roles only
- **Zero developer burden** — Developers write a simple `provider "aws" { region = "..." }` block. The pipeline handles cross-account mechanics transparently
- **All buildspecs consistent** — plan.yml, deploy.yml, and destroy.yml all use the same provider override pattern

## Background

This issue was discovered during out-of-bounds testing of the per-environment plan-apply pipeline (Refinement 1). The full analysis is documented in `docs/REFINEMENT_2.md`.

**Root cause:** All three buildspecs originally assumed the target account role via `aws sts assume-role` + `export AWS_*`, then ran `terraform init` with `-backend-config` pointing to the Automation account's S3 bucket. Terraform attempted S3 operations using the assumed target account credentials, which have no access to the Automation account bucket.

**Failed approaches:**
- Backend `assume_role` / self-assumption — Role chaining failure (target account credentials can't assume back to automation account)
- S3 bucket policy — Rejected (no cross-account bucket access)
- Developer-managed provider `assume_role` — Rejected (too complex for developers)

**Solution:** Terraform override files (`*_override.tf`) merge with existing config. The pipeline generates `_pipeline_override.tf` at runtime containing only `assume_role`, which merges into the developer's provider block. The CodeBuild service role's instance profile credentials (never overwritten by `export AWS_*`) handle S3 backend access natively, while the provider's `assume_role` handles target account API calls.

## Non-Goals

- **Modifying target account deployment roles** — These roles are manual prerequisites outside this module's control
- **Changing the S3 bucket policy** — The CodeBuild service role already has IAM-based access
- **Restructuring pipeline stages** — The 6-stage (default) / 7-8 stage (dev-destroy) pipeline structure is unchanged
- **Changing the CodePipeline artifact flow** — Plan artifact passing to deploy actions is unchanged
- **Creating separate state access roles** — The CodeBuild service role's instance profile credentials provide direct S3 access

## Architecture

### Credential Flow

```
CodeBuild Service Role (Automation Account)
  │
  ├── Instance profile credentials (never overwritten)
  │     └── S3 backend access → ✅ Direct access to state bucket
  │
  ├── Generate _pipeline_override.tf:
  │     provider "aws" {
  │       assume_role {
  │         role_arn     = "<TARGET_ROLE>"
  │         session_name = "codebuild-plan-dev"
  │       }
  │     }
  │
  ├── terraform init -backend-config=/tmp/backend.hcl
  │     State operations → ✅ Instance profile creds → Automation account S3
  │
  └── terraform plan/apply/destroy
        State operations → ✅ Instance profile creds → S3
        Provider operations → ✅ assume_role in provider → target account
```

### How Override Files Work

Terraform override files (`*_override.tf`) merge top-level blocks with identically-named blocks in other files. When the pipeline generates `_pipeline_override.tf` containing `provider "aws" { assume_role { ... } }`, Terraform merges it with the developer's `provider "aws" { region = "..." }` block, producing a combined provider with both `region` and `assume_role`.

### Key Design Decisions

1. **No STS assume-role in buildspecs** — Instance profile credentials are never overwritten. The provider's `assume_role` attribute handles target account access at the Terraform level.
2. **No backend `assume_role`** — The backend config contains only `bucket`, `key`, `region`, and `use_lockfile`. Instance profile credentials provide direct S3 access.
3. **No self-assumption** — The CodeBuild service role trust policy only needs `codebuild.amazonaws.com`. No account root principal or `ArnEquals` condition.
4. **envsubst for variable expansion** — Override files are written with `cat <<'EOF'` (no shell expansion), then `envsubst` expands `${TARGET_ROLE}` and `${TARGET_ENV}`.
5. **Cleanup in post_build** — `rm -f _pipeline_override.tf` ensures the override file doesn't leak into artifacts.

## Input Variables

No new consumer-facing input variables. This is an internal implementation fix.

## Outputs

No output changes.

## Features

### Feature 1: Buildspecs — Replace STS assume-role with provider override

Update all three buildspecs to generate `_pipeline_override.tf` instead of calling `aws sts assume-role`.

**Acceptance criteria:**
- `plan.yml`: Generates `_pipeline_override.tf` with `assume_role { role_arn = "${TARGET_ROLE}", session_name = "codebuild-plan-${TARGET_ENV}" }`
- `deploy.yml`: Same pattern with `session_name = "codebuild-deploy-${TARGET_ENV}"`
- `destroy.yml`: Same pattern with `session_name = "codebuild-destroy-dev"`
- All three use `cat <<'EOF'` + `envsubst` pattern for variable expansion
- Backend config (`/tmp/backend.hcl`) contains only `bucket`, `key`, `region`, `use_lockfile` — no `assume_role`
- `post_build` phase removes `_pipeline_override.tf` in all three buildspecs
- No `aws sts assume-role`, no `export AWS_*` in any buildspec
- `terraform validate` passes for both variants and all examples

### Feature 2: IAM — Remove self-assumption

Remove the self-assumption trust policy and permissions that were added for the previous (failed) approach.

**Acceptance criteria:**
- `AllowSelfAssumption` trust policy statement removed from CodeBuild service role
- Self-ARN removed from `AssumeRole` permission resource list (only dev + prod deployment role ARNs remain)
- `terraform validate` passes for both variants and all examples

### Feature 3: Remove STATE_ACCESS_ROLE_ARN env var

Remove the environment variable that was added for the previous approach (no longer needed since buildspecs don't use backend `role_arn`).

**Acceptance criteria:**
- `STATE_ACCESS_ROLE_ARN` removed from plan-dev, plan-prod, deploy-dev, deploy-prod in `modules/core/locals.tf`
- `STATE_ACCESS_ROLE_ARN` environment_variable block removed from destroy project in `modules/default-dev-destroy/main.tf`
- `terraform validate` passes for both variants and all examples

### Feature 4: Validation and Documentation

Validate the complete credential flow and update documentation.

**Acceptance criteria:**
- Both variant modules pass `terraform validate`
- All examples pass `terraform init -backend=false && terraform validate && terraform fmt -check`
- `CLAUDE.md` updated: credential flow description reflects provider override pattern
- `progress.txt` updated to reflect new approach
- `prd.md` updated to reflect provider override solution
- `docs/REFINEMENT_2.md` updated with solution outcome

## Security Considerations

- **No new cross-account access** — Target account roles gain no new permissions. State bucket access remains Automation-account-only.
- **Simpler IAM** — No self-assumption needed. The CodeBuild service role trust policy is simpler (only `codebuild.amazonaws.com`).
- **State file protection preserved** — S3 encryption (SSE-S3), SSL-only bucket policy, and IAM-based access control are unchanged.
- **Override file cleanup** — `_pipeline_override.tf` is removed in `post_build` to prevent leaking into artifacts or subsequent stages.
- **No long-lived credentials** — Provider `assume_role` uses STS temporary credentials with default session duration.
