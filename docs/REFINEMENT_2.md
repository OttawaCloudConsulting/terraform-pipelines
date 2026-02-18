# Refinement 2: Cross-Account Credential Flow — State Access vs. Provider Operations

## Problem Statement

The buildspecs (plan, deploy, destroy) assume the target account's cross-account deployment role **before** running `terraform init`. Terraform's S3 backend then attempts to read/write state using those assumed credentials. The state bucket lives in the Automation account (aft-automation, 389068787156), but the assumed credentials belong to the target account deployment role (e.g., `org-default-deployment-role` in DEV 914089393341 or PROD 264675080489). That role has no permissions to the Automation account's S3 state bucket — and it should not.

### Current Behavior (Before Fix)

All three buildspecs (plan.yml, deploy.yml, destroy.yml) followed the same sequence:

```
1. Assume cross-account role → export AWS_ACCESS_KEY_ID/SECRET/TOKEN
2. terraform init -backend-config="bucket=<automation-account-bucket>" ...
3. terraform plan/apply/destroy (operates on target account resources)
```

At step 2, `terraform init` connects to the S3 backend using the **target account role credentials**. The state bucket's policy and IAM permissions only allow access from roles in the Automation account (the CodeBuild service role). The init fails with an S3 access denied error.

At step 3, `terraform plan/apply/destroy` needs the **target account role credentials** to call AWS APIs in the target account. But Terraform also reads and writes state during plan/apply/destroy, which requires access to the Automation account's S3 bucket.

### Credential Requirements Per Operation

| Operation | S3 State Bucket (Automation Account) | AWS Provider APIs (Target Account) |
|-----------|--------------------------------------|-------------------------------------|
| `terraform init` | Needs access (downloads state, locks) | No provider calls |
| `terraform plan` | Reads state (refresh) | Reads target account resources |
| `terraform apply` | Reads and writes state | Modifies target account resources |
| `terraform destroy` | Reads and writes state | Deletes target account resources |

The conflict: `init` needs Automation account credentials for S3, while provider operations need target account credentials. The original buildspecs set assumed role credentials globally via environment variables before either operation runs.

### Why the Target Account Role Should NOT Have State Bucket Access

This is the correct security design:

1. **Least privilege** — Target account deployment roles should only have permissions to manage resources within their own account. Granting cross-account S3 access to every target account role widens the blast radius.

2. **State file sensitivity** — Terraform state files contain sensitive resource attributes (ARNs, IPs, sometimes secrets). Access should be restricted to the Automation account's service roles, not distributed to deployment roles across the organization.

3. **Single point of control** — The Automation account owns the state bucket, its bucket policy, and the IAM roles that access it. This makes access auditable and revocable from one place.

### Affected Buildspecs

| Buildspec | Location | Operations |
|-----------|----------|------------|
| `plan.yml` | `modules/core/buildspecs/plan.yml` | `terraform init` + `terraform plan` |
| `deploy.yml` | `modules/core/buildspecs/deploy.yml` | `terraform init` + `terraform apply tfplan` |
| `destroy.yml` | `modules/default-dev-destroy/buildspecs/destroy.yml` | `terraform init` + `terraform destroy` |

### Original Credential Flow (Broken)

```
CodeBuild Service Role (Automation Account)
  │
  ├── sts:AssumeRole → Target Account Deployment Role
  │     │
  │     ├── export AWS_ACCESS_KEY_ID=<target-account-creds>
  │     ├── export AWS_SECRET_ACCESS_KEY=<target-account-creds>
  │     └── export AWS_SESSION_TOKEN=<target-account-creds>
  │
  ├── terraform init (S3 backend) → ❌ Access Denied
  │     Uses target account creds → cannot access Automation account S3 bucket
  │
  └── terraform plan/apply/destroy → ✅ Would work
        Uses target account creds → can manage target account resources
        But also reads/writes state → ❌ Access Denied on S3
```

## Solution Space

### Option A: S3 Backend `role_arn` Parameter (ATTEMPTED — FAILED)

Configure `terraform init` to pass the CodeBuild service role ARN as the backend's `role_arn`. Terraform would assume that role for state operations while using the exported `AWS_*` credentials for provider calls.

**Why it failed:** The S3 backend `role_arn` performs an `sts:AssumeRole` call. When the exported `AWS_*` credentials (target account role) are active, the assume-role call becomes a **role chain**: target account role → CodeBuild service role. This fails because:
1. The target account role is not trusted by the CodeBuild service role's trust policy
2. Even with self-assumption trust added, the active credentials are the target account's — not the CodeBuild role's own credentials

The self-assumption pattern only works when the role assumes itself using its own credentials, not when a different role tries to assume it.

### Option B: Init Before Assume, Re-init After (NOT VIABLE)

Run `terraform init` with the default CodeBuild service role credentials (before assuming the target role), then assume the target role and run plan/apply. However, Terraform re-reads state during plan/apply, so the assumed credentials would still fail on state access during those operations.

### Option C: Provider Override File (IMPLEMENTED — WORKS)

Instead of assuming the target role at the shell level (`aws sts assume-role` + `export AWS_*`), let Terraform handle role assumption through the provider's `assume_role` attribute. Generate a `_pipeline_override.tf` file that merges `assume_role` into the developer's provider block.

**Why it works:**
- CodeBuild instance profile credentials are **never overwritten** by `export AWS_*`
- S3 backend uses the instance profile credentials directly → Automation account S3 access ✅
- Provider `assume_role` tells Terraform to assume the target role for API calls → target account access ✅
- No role chaining — each credential path is a single hop

### Option D: Dual Credential Wrapper (REJECTED)

Create a credential helper that intercepts S3 calls for state and routes them through the CodeBuild service role. Overly complex and fragile.

### Option E: S3 Bucket Policy (REJECTED)

Grant target account roles access to the state bucket. Violates the security principle of restricting state access to the Automation account.

### Option F: Developer-Managed Provider assume_role (REJECTED)

Require developers to add `assume_role` to their provider blocks. Too much burden on consumers; defeats the purpose of a transparent pipeline template.

## Implemented Solution: Provider Override File

### How It Works

Terraform override files (`*_override.tf`) merge top-level blocks with identically-named blocks in other configuration files. The pipeline generates `_pipeline_override.tf` at runtime:

**Developer writes:**
```hcl
provider "aws" {
  region = "ca-central-1"
  default_tags { tags = { ... } }
}
```

**Pipeline generates at runtime:**
```hcl
provider "aws" {
  assume_role {
    role_arn     = "arn:aws:iam::914089393341:role/org/org-default-deployment-role"
    session_name = "codebuild-plan-dev"
  }
}
```

**Terraform merges them** → provider has `region` + `default_tags` + `assume_role`.

### Fixed Credential Flow

```
CodeBuild Service Role (Automation Account)
  │
  ├── Instance profile credentials (never overwritten)
  │     └── S3 backend access → ✅ Direct access to state bucket
  │
  ├── Generate _pipeline_override.tf with assume_role block
  │
  ├── terraform init -backend-config=/tmp/backend.hcl
  │     State operations → ✅ Instance profile creds → Automation account S3
  │
  └── terraform plan/apply/destroy
        State operations → ✅ Instance profile creds → S3
        Provider operations → ✅ assume_role in provider → target account
```

### Buildspec Pattern

All three buildspecs follow this pattern:

```bash
# Build phase
cd "${CODEBUILD_SRC_DIR}/${IAC_WORKING_DIR}"

# Generate provider override (no shell expansion in heredoc, envsubst after)
cat > _pipeline_override.tf <<'OVERRIDE_EOF'
provider "aws" {
  assume_role {
    role_arn     = "${TARGET_ROLE}"
    session_name = "codebuild-<action>-${TARGET_ENV}"
  }
}
OVERRIDE_EOF
envsubst < _pipeline_override.tf > _pipeline_override.tf.tmp
mv _pipeline_override.tf.tmp _pipeline_override.tf

# Backend config — no assume_role, instance profile creds handle S3
cat > /tmp/backend.hcl <<BACKEND_EOF
bucket       = "${STATE_BUCKET}"
key          = "${STATE_KEY_PREFIX}/${TARGET_ENV}/terraform.tfstate"
region       = "${AWS_DEFAULT_REGION}"
use_lockfile = true
BACKEND_EOF

terraform init -backend-config=/tmp/backend.hcl -input=false
terraform plan/apply/destroy ...

# Post-build phase
rm -f _pipeline_override.tf
```

## Implementation Changes

### Changes Made

1. **Buildspecs (plan.yml, deploy.yml, destroy.yml)** — Replaced `aws sts assume-role` + `export AWS_*` with `_pipeline_override.tf` generation. Removed `assume_role` from backend.hcl. Added cleanup in post_build.
2. **IAM (modules/core/iam.tf)** — Removed `AllowSelfAssumption` trust policy statement and self-ARN from AssumeRole permissions (added during failed Option A attempt).
3. **Env vars (modules/core/locals.tf)** — Removed `STATE_ACCESS_ROLE_ARN` from plan-dev, plan-prod, deploy-dev, deploy-prod.
4. **Env vars (modules/default-dev-destroy/main.tf)** — Removed `STATE_ACCESS_ROLE_ARN` from destroy project.

### Not Changed

- Target account deployment roles — no new permissions needed
- S3 bucket policy — CodeBuild service role already has IAM-based access
- CodePipeline stages and artifact flow — unchanged
- Test buildspecs (test.yml) — shell scripts, not Terraform; they use STS assume-role directly
- `TARGET_ROLE` env var — still present (now used by override file instead of `aws sts assume-role`)
- Consumer-facing variables and outputs — unchanged
