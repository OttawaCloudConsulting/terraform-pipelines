# Code Review: Terraform Pipeline Module (Feature 1-7)

**Date:** 2026-02-12
**Reviewer:** Claude Code (automated review)
**Branch:** `development/mvp`
**Scope:** All Terraform files, buildspecs, compared against best practices, architecture doc, and PRD

---

## 1. Terraform Best Practices Compliance

### 1.1 File Structure

**Status: PASS**

The module follows the standard layout documented in the architecture doc:

| Expected File | Present | Contents Match |
|---------------|---------|----------------|
| `main.tf` | Yes | CodePipeline, CodeBuild projects, CloudWatch log groups |
| `variables.tf` | Yes | All input variables |
| `outputs.tf` | Yes | All outputs |
| `locals.tf` | Yes | Computed values and tags |
| `versions.tf` | Yes | `required_version`, `required_providers` |
| `iam.tf` | Yes | IAM roles and policies |
| `storage.tf` | Yes | S3 buckets, SNS topic, SNS subscriptions |
| `codestar.tf` | Yes | Conditional CodeStar Connection |
| `buildspecs/` | Yes | 4 YAML buildspec files |

**Missing from architecture doc's file tree:**
- `examples/` directory (minimal, complete, opentofu) -- not yet created (Feature 8 scope)
- `README.md` -- not yet created (Feature 8 scope)

### 1.2 Naming Conventions

**Status: PASS with INFO items**

- All Terraform resource names use `snake_case`: `codepipeline`, `codebuild`, `prebuild`, `plan`, `deploy`, `test`, `artifacts`, `state`, `approvals` -- PASS
- Resource names describe purpose, not type (e.g., `aws_iam_role.codepipeline` not `aws_iam_role.codepipeline_role`) -- PASS
- Singular nouns used throughout -- PASS
- Variables use `snake_case` -- PASS
- Boolean variable uses positive name: `enable_review_gate`, `create_state_bucket` -- PASS

**[INFO-01]** `locals.tf:8` -- The tag key `managed-by` uses a hyphen rather than an underscore. This is inconsistent with the `project_name` tag key on the line above it. While tag keys are not Terraform identifiers and hyphens are common in AWS tags, the inconsistency is worth noting.

```hcl
default_tags = {
  project_name = var.project_name
  managed-by   = "terraform"    # hyphen vs underscore
}
```

### 1.3 Variable Definitions

**Status: PASS**

All variables have:
- `type` -- PASS (all 16 variables have explicit types)
- `description` -- PASS (all 16 variables have descriptions)
- `default` for optional variables -- PASS (all 10 optional variables have defaults)
- No default for required variables -- PASS (all 6 required variables omit default)

Validation blocks present on:
- `project_name` (regex) -- PASS
- `github_repo` (regex) -- PASS
- `dev_account_id` / `prod_account_id` (12-digit regex) -- PASS
- `dev_deployment_role_arn` / `prod_deployment_role_arn` (ARN regex) -- PASS
- `iac_runtime` (enum) -- PASS
- `codestar_connection_arn` (empty or ARN regex) -- PASS
- `codebuild_compute_type` (enum) -- PASS
- `codebuild_timeout_minutes` (range) -- PASS
- `log_retention_days` (valid CW values) -- PASS
- `artifact_retention_days` (range) -- PASS

**[INFO-02]** `variables.tf:10` -- The `project_name` regex `^[a-z0-9][a-z0-9-]*[a-z0-9]$` requires minimum 2 characters. A single-character project name like `"x"` would fail. This is likely intentional but worth documenting.

**[WARNING-01]** `variables.tf:109-113` -- No cross-validation between `create_state_bucket` and `state_bucket`. When `create_state_bucket = false` and `state_bucket = ""` (default), the `data.aws_s3_bucket.existing_state[0]` will fail with a confusing error about an empty bucket name. Consider adding a validation block or precondition.

### 1.4 Outputs

**Status: PASS**

All outputs have:
- `description` -- PASS (all 9 outputs)
- Reference resource attributes, not input variables -- PASS

| Output | References |
|--------|-----------|
| `pipeline_arn` | `aws_codepipeline.this.arn` |
| `pipeline_url` | `data.aws_region.current.id` + `aws_codepipeline.this.name` |
| `codebuild_project_names` | `aws_codebuild_project.*.name` (x4) |
| `codebuild_service_role_arn` | `aws_iam_role.codebuild.arn` |
| `codepipeline_service_role_arn` | `aws_iam_role.codepipeline.arn` |
| `sns_topic_arn` | `aws_sns_topic.approvals.arn` |
| `artifact_bucket_name` | `aws_s3_bucket.artifacts.id` |
| `state_bucket_name` | `local.state_bucket_name` (resolves to resource attribute) |
| `codestar_connection_arn` | `local.codestar_connection_arn` (resolves to resource attribute or input) |

**[INFO-03]** `outputs.tf:48` -- `codestar_connection_arn` output references a local that may resolve to `var.codestar_connection_arn` (an input variable) when a pre-existing connection is provided. This is a minor deviation from the "reference resource attributes not inputs" rule, but is the correct pattern for conditional resources.

### 1.5 Module Design

**Status: PASS**

- No `provider` blocks in module -- PASS
- `required_providers` declared in `versions.tf` -- PASS
- `count` used for conditional resources (state bucket, CodeStar connection) -- PASS
- `dynamic` block for optional pipeline stage -- PASS
- `for_each` for SNS subscriptions -- PASS

### 1.6 Security

**Status: PASS with WARNING items**

- No hardcoded secrets -- PASS
- No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` in environment variables -- PASS
- `privileged_mode = false` on all 4 CodeBuild projects -- PASS
- IAM policies scoped to specific resources (no `*` for `sts:AssumeRole`) -- PASS
- S3 encryption enabled (AES256) on both buckets -- PASS
- S3 Block Public Access enabled on both buckets -- PASS
- S3 bucket policies deny non-SSL -- PASS
- SNS topic encrypted with `alias/aws/sns` -- PASS
- CloudWatch log groups have explicit retention -- PASS

**[WARNING-02]** `iam.tf:39` -- The CodePipeline role includes `s3:PutObjectAcl` permission. ACLs are a legacy access control mechanism. With S3 Block Public Access enabled and bucket ownership controls, this permission is unnecessary and could be removed for tighter least privilege.

```hcl
# iam.tf:34-40
Action = [
  "s3:GetObject",
  "s3:GetObjectVersion",
  "s3:GetBucketVersioning",
  "s3:PutObject",
  "s3:PutObjectAcl"    # <-- unnecessary with Block Public Access
]
```

### 1.7 Version Pinning

**Status: PASS with INFO item**

- `required_version = ">= 1.11"` -- PASS (enforces native S3 locking support)
- `aws` provider `version = ">= 5.0"` -- present

**[INFO-04]** `versions.tf:6` -- The provider version constraint uses `>= 5.0` instead of the recommended `~> 5.0` (pessimistic constraint). The `>=` operator allows major version jumps (e.g., 6.0) which could introduce breaking changes. The architecture doc acknowledges this as a module (`~>` recommended for shared modules), but the implementation uses `>=`.

```hcl
# versions.tf:5-8
aws = {
  source  = "hashicorp/aws"
  version = ">= 5.0"    # Consider: "~> 5.0"
}
```

### 1.8 Bad Practices Check

**Status: PASS**

| Bad Practice | Found? |
|-------------|--------|
| Local state files | No (S3 backend in buildspecs) |
| Hardcoded access keys | No |
| Secrets in tfvars/HCL | No |
| Unpinned provider versions | No (pinned, see INFO-04) |
| `actions: ["*"]` in IAM | No |
| Provisioners | No |
| Overcomplex `for_each`/`dynamic` | No (used appropriately) |

---

## 2. Architecture Document Compliance

### 2.1 Resource Inventory

Comparing the architecture doc's Resource Inventory table against actual implementation:

| # | Resource | Expected Type | Implemented? | Notes |
|---|----------|--------------|-------------|-------|
| 1 | CodePipeline V2 | `aws_codepipeline` | PASS | `main.tf:248` with `pipeline_type = "V2"` |
| 2 | CodeBuild: Pre-Build | `aws_codebuild_project` | PASS | `main.tf:36` |
| 3 | CodeBuild: Plan | `aws_codebuild_project` | PASS | `main.tf:83` |
| 4 | CodeBuild: Deploy | `aws_codebuild_project` | PASS | `main.tf:140` |
| 5 | CodeBuild: Test | `aws_codebuild_project` | PASS | `main.tf:197` |
| 6 | S3: State Bucket | `aws_s3_bucket` + config | PASS | `storage.tf:5` conditional |
| 7 | S3: Artifact Bucket | `aws_s3_bucket` + config | PASS | `storage.tf:77` |
| 8 | IAM: CodePipeline Role | `aws_iam_role` + `aws_iam_role_policy` | PASS | `iam.tf:5,24` |
| 9 | IAM: CodeBuild Role | `aws_iam_role` + `aws_iam_role_policy` | PASS | `iam.tf:88,107` |
| 10 | SNS: Approval Topic | `aws_sns_topic` + subscriptions | PASS | `storage.tf:151,176` |
| 11 | CodeStar Connection | `aws_codestarconnections_connection` | PASS | `codestar.tf:7` |
| 12 | CloudWatch: Log Groups (x4) | `aws_cloudwatch_log_group` | PASS | `main.tf:8-30` |
| 13 | S3: State Bucket (data) | `data.aws_s3_bucket` | PASS | `storage.tf:68` |

All 13 resource entries accounted for. No extra unexpected resources.

### 2.2 File Organization

**Status: PASS**

The architecture doc's File Responsibilities table matches the implementation exactly:

| File | Expected Contents | Match? |
|------|-------------------|--------|
| `main.tf` | `aws_codepipeline`, `aws_codebuild_project` (x4), `aws_cloudwatch_log_group` (x4) | PASS |
| `iam.tf` | `aws_iam_role` (x2), `aws_iam_role_policy` (x2) | PASS |
| `storage.tf` | `aws_s3_bucket` (x2), configs, `aws_sns_topic`, subscriptions, `data.aws_s3_bucket` | PASS |
| `codestar.tf` | `aws_codestarconnections_connection` (conditional) | PASS |
| `variables.tf` | All variable blocks | PASS |
| `outputs.tf` | All output blocks | PASS |
| `locals.tf` | Computed values | PASS |
| `versions.tf` | `terraform {}`, `required_providers` | PASS |

### 2.3 Conditional Resource Logic

**Status: PASS**

| Resource | Expected Condition | Implemented? |
|----------|--------------------|-------------|
| S3 State Bucket | `count = var.create_state_bucket ? 1 : 0` | PASS (`storage.tf:6`) |
| State Bucket data source | `count = var.create_state_bucket ? 0 : 1` | PASS (`storage.tf:69`) |
| CodeStar Connection | `count = var.codestar_connection_arn == "" ? 1 : 0` | PASS (`codestar.tf:8`) |
| Optional Review Stage | `dynamic "stage"` | PASS (`main.tf:317-335`) |
| SNS Subscriptions | `for_each = toset(var.sns_subscribers)` | PASS (`storage.tf:177`) |

### 2.4 Locals

**Status: PASS**

The architecture doc specifies these locals:

```hcl
locals {
  state_bucket_name       = var.create_state_bucket ? aws_s3_bucket.state[0].id : data.aws_s3_bucket.existing_state[0].id
  codestar_connection_arn = var.codestar_connection_arn != "" ? var.codestar_connection_arn : aws_codestarconnections_connection.github[0].arn
  default_tags = {
    project_name = var.project_name
    managed-by   = "terraform"
  }
  all_tags = merge(local.default_tags, var.tags)
}
```

Implementation at `locals.tf:1-11` matches exactly, with the addition of `state_key_prefix` which is a valid addition not in the architecture doc's locals snippet but referenced throughout the codebase.

**[INFO-05]** `locals.tf:4` -- `state_key_prefix` local is not listed in the architecture doc's Locals for Conditional References section but is present and used correctly. The architecture doc should be updated to include it.

### 2.5 Design Decisions Compliance

| # | Decision | Compliance |
|---|----------|-----------|
| 1 | Reusable module (not root) | PASS -- no `provider` or `backend` blocks |
| 2 | 4 CodeBuild projects reused with env vars | PASS -- deploy and test reused for DEV/PROD |
| 3 | Buildspec files in `buildspecs/` | PASS |
| 4 | SSE-S3 (not KMS) | PASS -- `sse_algorithm = "AES256"` |
| 5 | SNS AWS-managed KMS key | PASS -- `kms_master_key_id = "alias/aws/sns"` |
| 6 | `count` for conditionals | PASS |
| 7 | Data source for existing bucket | PASS |
| 8 | Validation blocks | PASS |
| 9 | Fixed + custom tags | PASS |
| 10 | Artifact bucket per pipeline | PASS |
| 11 | Explicit CloudWatch log groups | PASS |
| 12 | Configurable build timeout | PASS |
| 13 | `required_version >= 1.11` | PASS |
| 14 | Fewer, grouped .tf files | PASS |
| 15 | `dynamic "stage"` for review gate | PASS |
| 16 | Graceful var-file handling | PASS (verified in buildspecs) |
| 17 | `privileged_mode = false` | PASS (all 4 projects) |
| 18 | No provider block in module | PASS |

### 2.6 Security Requirements Checklist

| Requirement | Status | Location |
|-------------|--------|----------|
| `privileged_mode = false` (explicit) | PASS | `main.tf:51,98,155,212` |
| No `AWS_ACCESS_KEY_ID`/`SECRET_ACCESS_KEY` in env vars | PASS | All CodeBuild env blocks checked |
| S3 policies deny `aws:SecureTransport = false` | PASS | `storage.tf:41-65,109-132` |
| S3 Block Public Access (all 4 settings) | PASS | `storage.tf:31-39,100-107` |
| IAM specific ARNs for `sts:AssumeRole` (not `*`) | PASS | `iam.tf:118-121` |
| SNS encryption (AWS-managed KMS) | PASS | `storage.tf:153` |
| CloudWatch log groups have retention | PASS | `main.tf:10,16,22,28` |
| CodeStar uses OAuth (no PATs) | PASS | `codestar.tf:10` (`provider_type = "GitHub"`) |
| Buildspecs don't echo secrets | PASS | See Section 5 |
| CodeBuild role cannot create IAM users/keys | PASS | `iam.tf:107-179` (no `iam:*` actions) |
| Deployment role trust includes `aws:PrincipalOrgID` | N/A | Outside module scope (prerequisite) |

---

## 3. PRD Compliance

### 3.1 Feature 1: Project Foundation and Module Structure

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| `required_version >= 1.11` in `versions.tf` | PASS | `versions.tf:2` |
| AWS provider configured for `ca-central-1` | N/A | Module does not configure provider (correct -- consumer's responsibility) |
| All input variables in `variables.tf` | PASS | All 16 variables present |
| All outputs in `outputs.tf` | PASS | All 9 outputs present |
| `locals.tf` with computed values | PASS | `state_bucket_name`, `codestar_connection_arn`, merged tags |
| Module file structure | PASS | All 8 files present |
| Buildspec files in `buildspecs/` | PASS | All 4 YAML files present |
| `terraform validate` passes | NOT TESTED | Requires `terraform init` with provider |

### 3.2 Feature 2: IAM Roles and Policies

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| `CodePipeline-<project>-ServiceRole` | PASS | `iam.tf:6` |
| `CodeBuild-<project>-ServiceRole` | PASS | `iam.tf:89` |
| CodeBuild `sts:AssumeRole` scoped to DEV+PROD ARNs | PASS | `iam.tf:115-121` |
| CodeBuild S3 access for state+artifact buckets | PASS | `iam.tf:123-148` |
| CodeBuild CloudWatch Logs scoped to pipeline log groups | PASS | `iam.tf:150-162` |
| CodePipeline perms: S3, CodeBuild, CodeStar, SNS | PASS | `iam.tf:28-81` |
| Tags applied to IAM resources | PASS | `iam.tf:21,104` |

### 3.3 Feature 3: S3 Buckets

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| State bucket conditional via `create_state_bucket` | PASS | `storage.tf:6` |
| State bucket SSE-S3 (AES256) | PASS | `storage.tf:20-29` |
| State bucket versioning | PASS | `storage.tf:11-18` |
| State bucket SSL-only policy | PASS | `storage.tf:41-65` |
| State bucket Block Public Access (all 4) | PASS | `storage.tf:31-39` |
| Artifact bucket named `<project>-pipeline-artifacts` | PASS | `storage.tf:78` |
| Artifact bucket SSE-S3, versioning | PASS | `storage.tf:82-98` |
| Artifact bucket SSL-only + Block Public Access | PASS | `storage.tf:100-132` |
| Artifact lifecycle rule | PASS | `storage.tf:134-145` |
| Existing bucket validated via `data.aws_s3_bucket` | PASS | `storage.tf:68-71` |
| `count` pattern for conditional creation | PASS | |

### 3.4 Feature 4: SNS Topic and Subscriptions

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| Topic named `<project>-pipeline-approvals` | PASS | `storage.tf:152` |
| Encrypted with `alias/aws/sns` | PASS | `storage.tf:153` |
| Optional email subscriptions | PASS | `storage.tf:176-181` |
| Topic policy allows CodePipeline publish | PASS | `storage.tf:157-174` |
| Topic ARN as output | PASS | `outputs.tf:31-34` |

### 3.5 Feature 5: CodeStar Connection

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| References existing when provided | PASS | `locals.tf:3` |
| Creates new when empty | PASS | `codestar.tf:8` |
| Name: `<project>-github` | PASS | `codestar.tf:9` |
| ARN as output | PASS | `outputs.tf:46-49` |
| Documentation about manual OAuth | PASS | `codestar.tf:4` (comment) |

### 3.6 Feature 6: CodeBuild Projects and Buildspecs

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| 4 projects created | PASS | `main.tf:36,83,140,197` |
| Configurable compute/image | PASS | All 4 projects |
| Reference CodeBuild role | PASS | All 4 projects |
| CloudWatch log groups with retention | PASS | `main.tf:8-30` |
| Configurable timeout | PASS | `build_timeout` on all 4 |
| 4 buildspec files | PASS | `buildspecs/` directory |
| IaC runtime handling | PASS | See Section 5 |
| Graceful var-file handling | PASS | See Section 5 |
| Checkov in plan buildspec | PASS | `buildspecs/plan.yml:55` |
| Cross-account role in deploy | PASS | `buildspecs/deploy.yml:31-39` |
| Cross-account role in test | PASS | `buildspecs/test.yml:9-16` |
| Project names as output | PASS | `outputs.tf:11-19` |

### 3.7 Feature 7: CodePipeline

| Acceptance Criterion | Status | Notes |
|---------------------|--------|-------|
| Pipeline V2: `<project>-pipeline` | PASS | `main.tf:248-251` |
| Stage 1 Source: CodeStar | PASS | `main.tf:259-277` |
| Stage 2 Pre-Build | PASS | `main.tf:280-295` |
| Stage 3 Plan with output artifact | PASS | `main.tf:298-314` |
| Stage 4 Optional Review | PASS | `main.tf:317-335` |
| Stage 5 Deploy DEV with env vars | PASS | `main.tf:338-365` |
| Stage 6 Test DEV with env vars | PASS | `main.tf:368-395` |
| Stage 7 Mandatory Approval with SNS | PASS | `main.tf:398-413` |
| Stage 8 Deploy PROD with env vars | PASS | `main.tf:416-443` |
| Stage 9 Test PROD with env vars | PASS | `main.tf:446-473` |
| Uses artifact bucket | PASS | `main.tf:253-256` |
| Pipeline ARN + URL as outputs | PASS | `outputs.tf:1-9` |

**[WARNING-03]** `main.tf:274` -- The Source stage configuration includes `DetectChanges = "true"` but does **not** include `OutputArtifactFormat = "CODE_ZIP"`. The PRD mentions "full clone" for the source stage. CodeStarSourceConnection defaults to `CODE_ZIP` which is a zip archive, not a full git clone. For a full clone (with git history), `OutputArtifactFormat = "CODEBUILD_CLONE_REF"` would be needed. However, a full clone is not required for any of the buildspec operations (plan, apply, test), so this may be intentional simplification.

**[WARNING-04]** `main.tf:280-295` -- The Pre-Build stage does not pass `output_artifacts`. This means the Pre-Build stage consumes `source_output` but produces nothing. Subsequent stages also consume `source_output` directly (not a pre-build output). This is correct behavior since pre-build is for validation only, but differs from the architecture doc's artifact flow which shows "Source Artifact -> Pre-Build (read-only)" -- confirming read-only is the intent.

**[CRITICAL-01]** `main.tf:347` -- Deploy DEV uses `input_artifacts = ["source_output"]` instead of `["plan_output"]`. The architecture doc's "Artifact Flow Between Stages" section states: "Plan Artifact -> Deploy DEV (consumes tfplan)". However, the deploy buildspec (`buildspecs/deploy.yml`) runs `terraform init` + `terraform apply` from scratch (not consuming a saved plan file). The buildspec does NOT reference `tfplan` from the plan stage. This means **DEV deploy re-plans and applies rather than applying the reviewed plan**. The architecture doc also says "Deploy PROD re-runs terraform init and terraform apply" but says DEV should consume the plan artifact. This is an inconsistency that should be resolved -- either:
  - (a) Update the deploy buildspec to consume the plan artifact for DEV, or
  - (b) Update the architecture doc to clarify that both DEV and PROD re-plan and apply from source

**Note on CRITICAL-01 severity:** While this works functionally (deploy will succeed), it means the plan reviewed in Stage 3 is not the same plan applied in Stage 5. Infrastructure changes could occur between plan and apply if the underlying cloud state changes. This is a design decision worth explicitly documenting either way.

### 3.8 Feature 8: Examples and Validation

**Status: NOT IMPLEMENTED** (expected -- Feature 8 is separate scope)

- `examples/` directory does not exist yet
- This is tracked as a separate feature and not a blocker for Features 1-7

### 3.9 Input Variables -- PRD Cross-Check

Comparing PRD's variable table against `variables.tf`:

| PRD Variable | Type Match | Default Match | Present |
|-------------|-----------|--------------|---------|
| `project_name` | `string` | (no default) | PASS |
| `github_repo` | `string` | (no default) | PASS |
| `dev_account_id` | `string` | (no default) | PASS |
| `dev_deployment_role_arn` | `string` | (no default) | PASS |
| `prod_account_id` | `string` | (no default) | PASS |
| `prod_deployment_role_arn` | `string` | (no default) | PASS |
| `github_branch` | `string` | `"main"` | PASS |
| `iac_runtime` | `string` | `"terraform"` | PASS |
| `iac_version` | `string` | `"latest"` | PASS |
| `codestar_connection_arn` | `string` | `""` | PASS |
| `state_bucket` | `string` | `""` | PASS |
| `create_state_bucket` | `bool` | `true` | PASS |
| `state_key_prefix` | `string` | `""` | Note below |
| `sns_subscribers` | `list(string)` | `[]` | PASS |
| `enable_review_gate` | `bool` | `false` | PASS |
| `codebuild_compute_type` | `string` | `"BUILD_GENERAL1_SMALL"` | PASS |
| `codebuild_image` | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | PASS |
| `codebuild_timeout_minutes` | `number` | `60` | PASS |
| `log_retention_days` | `number` | `30` | PASS |
| `artifact_retention_days` | `number` | `30` | PASS |
| `tags` | `map(string)` | `{}` | PASS |

**[INFO-06]** PRD says `state_key_prefix` defaults to `project_name`, but the variable's actual default is `""` with the local computing the effective value. This is functionally equivalent since `locals.tf:4` handles the fallback: `var.state_key_prefix != "" ? var.state_key_prefix : var.project_name`. Correct implementation.

### 3.10 Outputs -- PRD Cross-Check

| PRD Output | Present | Correct Reference |
|-----------|---------|-------------------|
| `pipeline_arn` | PASS | Resource attribute |
| `pipeline_url` | PASS | Computed from region + name |
| `codebuild_project_names` | PASS | Map of 4 project names |
| `codebuild_service_role_arn` | PASS | Resource attribute |
| `codepipeline_service_role_arn` | PASS | Resource attribute |
| `sns_topic_arn` | PASS | Resource attribute |
| `artifact_bucket_name` | PASS | Resource attribute |
| `state_bucket_name` | PASS | Local (resolves to resource) |
| `codestar_connection_arn` | PASS | Local (resolves to resource or input) |

All 9 PRD outputs accounted for.

---

## 4. Issues and Discrepancies

### CRITICAL

| ID | Issue | File:Line | Description |
|----|-------|-----------|-------------|
| CRITICAL-01 | Plan artifact not consumed by Deploy DEV | `main.tf:347` | Deploy DEV uses `source_output` instead of `plan_output`. The architecture doc says Deploy DEV should consume the plan artifact. The deploy buildspec re-plans from source rather than applying the saved plan. See Section 3.7 for details. |

### WARNING

| ID | Issue | File:Line | Description |
|----|-------|-----------|-------------|
| WARNING-01 | No cross-validation for `state_bucket` | `variables.tf:109-113` | When `create_state_bucket = false` and `state_bucket = ""`, the data source will fail with a confusing error. Add a validation or precondition. |
| WARNING-02 | Unnecessary `s3:PutObjectAcl` | `iam.tf:39` | CodePipeline role includes ACL permission that is unnecessary with Block Public Access enabled. |
| WARNING-03 | Source artifact format vs full clone | `main.tf:270-275` | PRD mentions "full clone" but configuration uses default `CODE_ZIP`. If git history is not needed (and it is not for plan/apply), this is acceptable but should be explicitly documented. |
| WARNING-04 | Pre-Build produces no output artifact | `main.tf:280-295` | Pre-Build stage has no `output_artifacts`. This is correct for read-only validation but worth confirming is intentional. |
| WARNING-05 | Plan buildspec `TARGET_ENV` not set | `buildspecs/plan.yml:45` | The plan buildspec references `${TARGET_ENV}` for var-file handling, but the Plan CodeBuild project (`main.tf:83-138`) does not pass a `TARGET_ENV` environment variable. This means `${TARGET_ENV}` will be empty/unset during the plan stage. The plan will run without a var-file regardless of whether one exists. |
| WARNING-06 | Deploy buildspec credential scoping | `buildspecs/deploy.yml:30-39` | The STS assume-role credentials are exported as environment variables in the `pre_build` phase. However, each CodeBuild phase runs in a separate shell process by default. The exported credentials may not persist to the `build` phase. AWS CodeBuild documentation states that environment variables set in one phase ARE available in subsequent phases only within the same `commands` block. Since these are separate phases (`pre_build` vs `build`), the assumed-role credentials may be lost. This needs E2E testing to confirm. |

### INFO

| ID | Issue | File:Line | Description |
|----|-------|-----------|-------------|
| INFO-01 | Tag key inconsistency | `locals.tf:8` | `managed-by` uses hyphen, `project_name` uses underscore |
| INFO-02 | `project_name` min length | `variables.tf:10` | Regex requires minimum 2 characters |
| INFO-03 | Output may reference input | `outputs.tf:48` | `codestar_connection_arn` may resolve to input var |
| INFO-04 | Provider version constraint | `versions.tf:6` | Uses `>=` instead of recommended `~>` |
| INFO-05 | Undocumented local | `locals.tf:4` | `state_key_prefix` not in architecture doc's locals section |
| INFO-06 | Default value technique | `variables.tf:118` | `state_key_prefix` default is `""` with local fallback; PRD says default is `project_name` |
| INFO-07 | `state_bucket` in CLAUDE.md | `CLAUDE.md` | CLAUDE.md lists `state_bucket` as both required and optional. The PRD and implementation correctly list it as optional. |
| INFO-08 | Checkov `\|\| true` suppression | `buildspecs/plan.yml:55` | Checkov failures are suppressed with `\|\| true`. This means security scan failures will NOT stop the pipeline. The architecture doc says "Non-zero exit stops pipeline" for checkov, but the `\|\| true` overrides this. This may be intentional for MVP (advisory-only scanning) but should be explicitly documented. |

---

## 5. Buildspec Review

### 5.1 IaC Runtime Install Logic

**File: `buildspecs/plan.yml:8-26`, `buildspecs/deploy.yml:8-26`**

Both plan and deploy buildspecs contain identical install logic:

```yaml
if [ "${IAC_RUNTIME}" = "opentofu" ]; then
  # OpenTofu install (standalone method)
  # Symlinks tofu -> terraform for command compatibility
else
  # Terraform install from HashiCorp releases
fi
```

**Status: PASS**

- OpenTofu: uses official install script, supports `latest` and specific versions -- PASS
- Terraform: uses HashiCorp checkpoint API for latest, direct download for specific versions -- PASS
- Symlink `tofu -> terraform` ensures buildspec commands work with either runtime -- PASS
- Pre-build buildspec (`prebuild.yml`) does NOT install IaC runtime -- correct, pre-build is for developer scripts
- Test buildspec (`test.yml`) does NOT install IaC runtime -- correct, tests are developer shell scripts

**[INFO-09]** The install logic is duplicated between `plan.yml` and `deploy.yml`. If a bug is found in the install logic, it must be fixed in both files. Consider extracting to a shared script, though this adds complexity. Acceptable for MVP.

### 5.2 Graceful Var-File Handling

**File: `buildspecs/plan.yml:44-51`, `buildspecs/deploy.yml:53-60`**

```bash
if [ -f "environments/${TARGET_ENV}.tfvars" ]; then
  PLAN_ARGS="${PLAN_ARGS} -var-file=environments/${TARGET_ENV}.tfvars"
else
  echo "No environments/${TARGET_ENV}.tfvars found, proceeding without var-file."
fi
```

**Status: PASS** -- Both plan and deploy buildspecs check for var-file existence before passing `-var-file`.

See WARNING-05 above regarding `TARGET_ENV` not being set in the plan stage.

### 5.3 Cross-Account Role Assumption

**File: `buildspecs/deploy.yml:30-39`, `buildspecs/test.yml:8-16`**

Both buildspecs use the same pattern:

```bash
CREDENTIALS=$(aws sts assume-role \
  --role-arn "${TARGET_ROLE}" \
  --role-session-name "codebuild-deploy-${TARGET_ENV}" \
  --duration-seconds 3600 \
  --output json)
export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | python3 -c "...")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | python3 -c "...")
export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | python3 -c "...")
```

**Status: PASS with WARNING**

- Uses `sts:AssumeRole` (first-hop, not role chaining) -- PASS
- Session duration 3600s (1 hour) -- reasonable for builds -- PASS
- Session name includes environment for CloudTrail tracing -- PASS
- Uses `python3` for JSON parsing (available in standard CodeBuild images) -- PASS

See WARNING-06 regarding credential persistence across CodeBuild phases.

### 5.4 Checkov Integration

**File: `buildspecs/plan.yml:27,53-55`**

```yaml
- pip3 install checkov
# ...
- checkov -f tfplan.json --framework terraform_plan --output junitxml --output-file checkov-report.xml || true
```

**Status: PASS with INFO**

- Installs checkov via pip3 -- PASS
- Scans the plan JSON (not raw HCL) -- PASS (more comprehensive)
- Outputs JUnit XML for CodeBuild Reports -- PASS
- Report published via `reports:` section -- PASS
- Plan file and report saved as artifacts -- PASS

See INFO-08 regarding `|| true` suppressing checkov failures.

### 5.5 Security Review of Buildspecs

| Check | Status | Notes |
|-------|--------|-------|
| No secrets echoed | PASS | Only project name, runtime, and env labels echoed |
| No hardcoded credentials | PASS | Credentials obtained via STS at runtime |
| No sensitive env vars logged | PASS | `TARGET_ROLE` ARN is echoed (this is not a secret) |
| Credentials not written to files | PASS | Exported as env vars only |
| `CREDENTIALS` variable scope | PASS | Shell variable, not persisted |

### 5.6 Plan Buildspec -- Backend Key Path

**File: `buildspecs/plan.yml:35`**

```yaml
-backend-config="key=${STATE_KEY_PREFIX}/plan/terraform.tfstate"
```

**[WARNING-07]** The plan stage uses `${STATE_KEY_PREFIX}/plan/terraform.tfstate` as the state key. This creates a **third** state file separate from DEV and PROD. The architecture doc specifies the pattern `<project>/<env>/terraform.tfstate` with DEV and PROD as the two environments. Having a `/plan/` state file means the plan stage creates its own state, which will diverge from DEV and PROD state. This is likely intentional (plan runs without assuming a target role, so it cannot write to target-account state), but it means:
- The plan output may differ from what deploy actually applies (different state context)
- There is a state file (`plan/terraform.tfstate`) that serves no production purpose
- This state file will accumulate stale resources if the plan stage ever creates resources

This should be explicitly documented as a design decision. If the plan is intended to be informational only (and the deploy re-initializes with the correct env-specific state), then the plan state is effectively a throwaway workspace.

---

## 6. Summary

### Overall Assessment

The implementation is **well-structured and closely follows** both the architecture document and PRD. The code is clean, well-organized, and follows Terraform best practices. Security controls are comprehensive and match the documented requirements.

### Issue Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| WARNING | 7 |
| INFO | 9 |

### Priority Items Before E2E Testing

1. **CRITICAL-01**: Resolve the plan artifact vs source artifact inconsistency for Deploy DEV. Either update the deploy buildspec to consume the saved plan, or update the architecture doc to reflect that all deploys re-plan from source.

2. **WARNING-05**: The plan stage does not receive `TARGET_ENV`, so var-file handling in the plan buildspec is non-functional. Either add `TARGET_ENV` to the plan CodeBuild project's environment variables (but which env -- dev or prod?), or remove the var-file logic from the plan buildspec since plan runs against a separate state.

3. **WARNING-06**: Verify that STS credentials exported in `pre_build` phase persist to the `build` phase in CodeBuild. This is a runtime behavior that must be validated during E2E testing.

4. **WARNING-07**: Clarify the plan stage's state key path (`/plan/terraform.tfstate`) design intent. Is this a throwaway workspace or should it share state with DEV?

5. **WARNING-01**: Add cross-validation for `state_bucket` when `create_state_bucket = false`.

### Items That Are Correct But Worth Documenting

- Checkov runs in advisory mode (`|| true`) and does not block the pipeline
- Pre-Build stage is read-only (no output artifacts)
- Both DEV and PROD deploys re-initialize and re-plan from source
- The plan stage state file is separate from DEV/PROD state files
