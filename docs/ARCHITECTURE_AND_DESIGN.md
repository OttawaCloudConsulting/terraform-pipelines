# Architecture and Design: Terraform Pipeline Module

## Overview

This document defines the architecture and implementation design for a reusable Terraform module that provisions AWS CodePipeline V2 + CodeBuild CI/CD pipelines. Each module invocation creates a complete, isolated pipeline instance for one Terraform project, deploying across a three-account Control Tower model (Automation → DEV → PROD).

The authoritative requirements are in `prd.md`. The MVP scope is defined in `docs/codepipeline-mvp-statement.md`.

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        AUTOMATION ACCOUNT (389068787156)                      │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │            AWS CodePipeline V2: <project_name>-pipeline                │  │
│  │                                                                        │  │
│  │  ┌─────────┐   ┌───────────┐   ┌────────────┐   ┌──────────────────┐  │  │
│  │  │ Stage 1  │──►│  Stage 2   │──►│  Stage 3    │──►│  Stage 4         │  │  │
│  │  │ SOURCE   │   │ PRE-BUILD  │   │ PLAN +      │   │ OPTIONAL REVIEW  │  │  │
│  │  │ (GitHub  │   │ (CodeBuild)│   │ SECURITY    │   │ (Manual Approval)│  │  │
│  │  │  via     │   │            │   │ SCAN (CB)   │   │ [conditional]    │  │  │
│  │  │ CodeStar)│   │ cicd/      │   │             │   │                  │  │  │
│  │  │          │   │ prebuild/  │   │ tf plan +   │   │ enable_review_   │  │  │
│  │  │          │   │ main.sh    │   │ checkov     │   │ gate=true/false  │  │  │
│  │  └─────────┘   └───────────┘   └────────────┘   └──────────────────┘  │  │
│  │        │                                                                │  │
│  │        ▼                                                                │  │
│  │  ┌─────────────┐  ┌───────────────┐  ┌──────────────┐  ┌───────────┐  │  │
│  │  │  Stage 5     │  │  Stage 6       │  │  Stage 7      │  │ Stage 8   │  │  │
│  │  │ DEPLOY DEV   │──►│ TEST DEV       │──►│ MANDATORY     │──►│DEPLOY PROD│  │  │
│  │  │ (CodeBuild)  │  │ (CodeBuild)    │  │ APPROVAL      │  │(CodeBuild)│  │  │
│  │  │              │  │                │  │ (SNS + Manual)│  │           │  │  │
│  │  │ tf apply     │  │ cicd/dev/      │  │               │  │ tf apply  │  │  │
│  │  │ via assumed  │  │ smoke-test.sh  │  │ Email → AWS   │  │ via       │  │  │
│  │  │ DEV role     │  │                │  │ Console       │  │ PROD role │  │  │
│  │  └─────────────┘  └───────────────┘  └──────────────┘  └─────┬─────┘  │  │
│  │                                                                │        │  │
│  │                                                         ┌──────┴──────┐ │  │
│  │                                                         │  Stage 9     │ │  │
│  │                                                         │ TEST PROD    │ │  │
│  │                                                         │ (CodeBuild)  │ │  │
│  │                                                         │ cicd/prod/   │ │  │
│  │                                                         │ smoke-test.sh│ │  │
│  │                                                         └─────────────┘ │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────────────┐  │
│  │ S3: State Bucket   │  │ S3: Artifact      │  │ IAM Roles               │  │
│  │ (conditional)      │  │ Bucket            │  │ ┌─────────────────────┐ │  │
│  │ - Versioned        │  │ - Per pipeline    │  │ │ CodePipeline-       │ │  │
│  │ - SSE-S3 (AES256)  │  │ - SSE-S3 (AES256) │  │ │ <project>-SR       │ │  │
│  │ - SSL-only policy  │  │ - SSL-only policy │  │ ├─────────────────────┤ │  │
│  │ - Block Public     │  │ - Block Public    │  │ │ CodeBuild-          │ │  │
│  │   Access (all 4)   │  │   Access (all 4)  │  │ │ <project>-SR       │ │  │
│  │ - Native S3 lock   │  │ - Lifecycle rule  │  │ │ (cross-acct assume)│ │  │
│  │   (use_lockfile)   │  │   (configurable)  │  │ └─────────────────────┘ │  │
│  └───────────────────┘  └───────────────────┘  └─────────────────────────┘  │
│                                                                              │
│  ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────────────┐  │
│  │ SNS Topic:         │  │ CodeStar          │  │ CloudWatch Logs         │  │
│  │ <project>-pipeline │  │ Connection        │  │ Log Groups (x4)         │  │
│  │ -approvals         │  │ (conditional)     │  │ - /codebuild/<project>  │  │
│  │ - AWS-managed KMS  │  │ - GitHub App      │  │   -prebuild, -plan,     │  │
│  │ - Email subs       │  │ - OAuth consent   │  │   -deploy, -test        │  │
│  │   (optional)       │  │   (one-time)      │  │ - Retention: 30d dflt   │  │
│  └───────────────────┘  └───────────────────┘  └─────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
         │                            │                      │
         │ CodeStar Connection        │ sts:AssumeRole       │ sts:AssumeRole
         │ (GitHub App)               │ (first-hop)          │ (first-hop)
         ▼                            ▼                      ▼
    ┌──────────┐            ┌─────────────────┐    ┌─────────────────────┐
    │  GitHub   │            │ DEV TARGET ACCT  │    │ PROD TARGET ACCT     │
    │           │            │ (914089393341)   │    │ (264675080489)       │
    │ OttawaCl- │            │                  │    │                      │
    │ oudCons-  │            │ ┌──────────────┐ │    │ ┌──────────────────┐ │
    │ ulting/   │            │ │ Deployment   │ │    │ │ Deployment       │ │
    │ terraform │            │ │ Role (pre-   │ │    │ │ Role (pre-       │ │
    │ -test     │            │ │ existing)    │ │    │ │ existing)        │ │
    │           │            │ │              │ │    │ │                  │ │
    │ Branch:   │            │ │ Trust:       │ │    │ │ Trust:           │ │
    │ s3-bucket │            │ │ CodeBuild SR │ │    │ │ CodeBuild SR     │ │
    │           │            │ │ + OrgID cond │ │    │ │ + OrgID cond     │ │
    └──────────┘            │ └──────────────┘ │    │ └──────────────────┘ │
                             │                  │    │                      │
                             │ Application      │    │ Application          │
                             │ Secrets (local)  │    │ Secrets (local)      │
                             └─────────────────┘    └─────────────────────┘
```

## Pipeline Data Flow

### Stage-by-Stage Flow

1. **Source** — CodePipeline pulls repo via CodeStar Connection on branch push. Source artifacts stored in artifact bucket.
2. **Pre-Build** — CodeBuild runs `cicd/prebuild/main.sh` from source artifacts. No target account credentials. Developer installs tools inline. Non-zero exit stops pipeline.
3. **Plan + Security Scan** — CodeBuild installs IaC runtime, runs `terraform init` against S3 backend, runs `terraform plan -out=tfplan`. Converts plan to JSON, runs `checkov` scan. Plan file and scan results saved as output artifacts. JUnit XML published to CodeBuild Reports.
4. **Optional Review** — If `enable_review_gate = true`, Manual Approval action pauses pipeline. 7-day timeout.
5. **Deploy DEV** — CodeBuild assumes `dev_deployment_role_arn` via `sts:AssumeRole`, runs `terraform init` + `terraform apply`. If `environments/dev.tfvars` exists, passes `-var-file`; otherwise applies without it.
6. **Test DEV** — CodeBuild assumes DEV role, runs `cicd/dev/smoke-test.sh`. Non-zero exit stops pipeline before PROD approval.
7. **Mandatory Approval** — Manual Approval publishes to SNS topic. Subscribers receive email with console link. 7-day timeout.
8. **Deploy PROD** — Same as Deploy DEV but assumes `prod_deployment_role_arn` and uses `environments/prod.tfvars` if it exists.
9. **Test PROD** — Same as Test DEV but assumes PROD role and runs `cicd/prod/smoke-test.sh`.

### Artifact Flow Between Stages

```
Source Artifact ──► Pre-Build (read-only)
Source Artifact ──► Plan (read, produces plan artifact for review only)
Source Artifact ──► Deploy DEV (re-init + apply from source)
Source Artifact ──► Deploy PROD (re-init + apply from source)
Source Artifact ──► Test DEV / Test PROD (read-only)
```

**Note:** Both Deploy DEV and Deploy PROD re-run `terraform init` and `terraform apply` from source rather than reusing the plan artifact. This is because DEV and PROD use different state files, different backend keys, and potentially different variable values. The Plan stage output is informational — it provides a preview for the optional review gate and produces the checkov security scan report, but is not consumed by the deploy stages.

## Resource Inventory

| # | Resource | Terraform Type | Purpose |
|---|----------|---------------|---------|
| 1 | CodePipeline V2 | `aws_codepipeline` | Pipeline orchestration |
| 2 | CodeBuild: Pre-Build | `aws_codebuild_project` | Developer validation scripts |
| 3 | CodeBuild: Plan | `aws_codebuild_project` | Terraform plan + security scan |
| 4 | CodeBuild: Deploy | `aws_codebuild_project` | Terraform apply (reused for DEV + PROD) |
| 5 | CodeBuild: Test | `aws_codebuild_project` | Developer smoke tests (reused for DEV + PROD) |
| 6 | S3: State Bucket | `aws_s3_bucket` + config | Terraform state storage (conditional) |
| 7 | S3: Artifact Bucket | `aws_s3_bucket` + config | Pipeline artifact storage |
| 8 | IAM: CodePipeline Role | `aws_iam_role` + `aws_iam_role_policy` | Pipeline service role |
| 9 | IAM: CodeBuild Role | `aws_iam_role` + `aws_iam_role_policy` | Build service role with cross-account access |
| 10 | SNS: Approval Topic | `aws_sns_topic` + subscriptions | Approval notifications |
| 11 | CodeStar Connection | `aws_codestarconnections_connection` | GitHub integration (conditional) |
| 12 | CloudWatch: Log Groups (x4) | `aws_cloudwatch_log_group` | Build log retention |
| 13 | S3: State Bucket (data) | `data.aws_s3_bucket` | Validate existing bucket (when not creating) |

## Cost Estimate

Pricing is based on `ca-central-1` region rates. All prices in USD.

### Per-Pipeline Monthly Cost (Moderate Use: ~20 pipeline executions/month)

A single pipeline execution triggers approximately 6 CodeBuild actions (prebuild, plan, deploy-dev, test-dev, deploy-prod, test-prod) and 2 approval actions. Estimated durations per stage: prebuild ~2 min, plan ~3 min, deploy ~5 min each, test ~2 min each.

| Component | Unit Price | Usage Assumption | Monthly Cost |
|-----------|-----------|-----------------|-------------|
| **CodePipeline V2** | $0.002/action-execution-minute | 20 runs × 6 actions × ~3 min avg = 360 action-min | ~$0.72 |
| **CodeBuild** (general1.small, Linux) | $0.005/build-minute | 20 runs × 6 builds × ~3 min avg = 360 build-min | ~$1.80 |
| **S3 State Bucket** | $0.025/GB/month + requests | < 100 MB state files, ~2,000 requests | ~$0.01 |
| **S3 Artifact Bucket** | $0.025/GB/month + requests | ~500 MB artifacts (30-day lifecycle), ~4,000 requests | ~$0.02 |
| **CloudWatch Logs** | $0.50/GB ingested | ~200 MB logs/month | ~$0.10 |
| **SNS** (email) | First 1,000 notifications free | < 50 notifications | $0.00 |
| **KMS** (SNS AWS-managed key) | No charge for AWS-managed keys | — | $0.00 |
| **CodeStar Connection** | No charge | — | $0.00 |
| **Total (per pipeline)** | | | **~$2.65/month** |

### Free Tier Impact (First 12 Months)

| Component | Free Tier Allowance | Impact |
|-----------|-------------------|--------|
| CodePipeline V2 | 1 free active pipeline/month | First pipeline is free; saves ~$0.72/month |
| CodeBuild | 100 free build-minutes/month (general1.small) | Covers ~5 pipeline runs; saves up to ~$0.50/month |
| S3 | 5 GB storage, 20,000 GET, 2,000 PUT | Covers state + artifact storage entirely |
| CloudWatch Logs | 5 GB ingestion, 5 GB storage | Covers all pipeline logging |
| SNS | 1,000 email notifications | Covers all approval notifications |

### Scaling Estimates

| Pipeline Count | Monthly Cost (no free tier) | Monthly Cost (with free tier) |
|---------------|---------------------------|------------------------------|
| 1 pipeline | ~$2.65 | ~$0.00 (fully within free tier) |
| 5 pipelines | ~$13.25 | ~$11.50 |
| 10 pipelines | ~$26.50 | ~$24.75 |
| 20 pipelines | ~$53.00 | ~$51.25 |

### Cost Drivers to Monitor

- **Large Terraform applies** (10+ minutes) significantly increase CodeBuild costs. Consider `BUILD_GENERAL1_MEDIUM` ($0.01/min) only if small instances are too slow.
- **Frequent pushes** to the trigger branch cause full pipeline runs. Feature branch filtering is post-MVP.
- **No DynamoDB costs** — native S3 locking eliminates the DynamoDB line item entirely.
- **No per-user or per-seat fees** — all pipeline costs are consumption-based.

## Security Model

### AWS Security Best Practices Compliance

The following security controls are implemented based on [AWS CodePipeline Security Best Practices](https://docs.aws.amazon.com/codepipeline/latest/userguide/security-best-practices.html), [AWS Security Hub CodeBuild Controls](https://docs.aws.amazon.com/securityhub/latest/userguide/codebuild-controls.html), and [AWS Well-Architected Security Pillar SEC11-BP07](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_appsec_regularly_assess_security_properties_of_pipelines.html).

#### Security Hub Controls Alignment

| Control | Requirement | Implementation |
|---------|------------|----------------|
| **[CodeBuild.1]** | No sensitive credentials in source URLs | CodeStar Connection uses OAuth (GitHub App), no tokens in URLs |
| **[CodeBuild.2]** | No cleartext credentials in env vars | Cross-account credentials obtained via `sts:AssumeRole` at runtime, never stored in env vars. No `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in project configuration |
| **[CodeBuild.3]** | S3 logs encrypted | S3 artifact bucket uses SSE-S3 encryption |
| **[CodeBuild.4]** | Logging enabled | All CodeBuild projects configured with CloudWatch log groups |
| **[CodeBuild.5]** | Privileged mode disabled | No CodeBuild project enables `privilegedMode` (no Docker-in-Docker needed) |

#### CodePipeline Security Best Practices

| Best Practice | Implementation |
|--------------|----------------|
| **No secrets in action configuration** | Secrets referenced via `sts:AssumeRole` or `secrets-manager` buildspec integration, never hardcoded |
| **Server-side encryption for artifacts** | Artifact bucket uses SSE-S3. CodePipeline default encryption applies via AWS-managed `aws/s3` KMS key |
| **Least-privilege service roles** | CodeBuild role scoped to exactly two deployment role ARNs for `sts:AssumeRole`. No wildcards |
| **CloudTrail logging** | All IAM, STS, CodePipeline, and CodeBuild API calls logged via CloudTrail (org-level trail assumed) |

#### Well-Architected Pipeline Security (SEC11-BP07)

| Principle | Implementation |
|-----------|----------------|
| **Security tests cannot be bypassed** | Checkov scan runs in Plan stage before any deployment. Non-zero exit stops pipeline |
| **Limited permissions** | CodeBuild role has no admin access. Scoped to specific S3 paths, log groups, and target role ARNs |
| **Safeguards against wrong environment** | TARGET_ENV and TARGET_ROLE set per-stage by CodePipeline, not by developer scripts |
| **No long-lived credentials** | All credentials are temporary (STS sessions). No IAM access keys anywhere |
| **Human approval before production** | Mandatory approval stage (Stage 7) blocks PROD deployment. Decision logged in CloudTrail |

### Encryption

| Resource | Encryption | Key | Notes |
|----------|-----------|-----|-------|
| S3 State Bucket | SSE-S3 (AES256) | AWS-managed | All S3 objects auto-encrypted since Jan 2023 |
| S3 Artifact Bucket | SSE-S3 (AES256) | AWS-managed | CodePipeline also applies `aws/s3` KMS key by default |
| SNS Topic | SSE-KMS | AWS-managed SNS key (`alias/aws/sns`) | Zero key management overhead |
| CloudWatch Logs | Encrypted by default | AWS-managed | CloudWatch Logs encrypts all log data |
| CodeBuild build logs | Encrypted in transit | TLS | All API calls use HTTPS/TLS |

### Access Control

- **S3 Bucket Policies:** Both buckets deny non-SSL requests (`aws:SecureTransport = false`) and have S3 Block Public Access enabled (all four settings). Follows [AWS Prescriptive Guidance: S3 Encryption Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/encryption-best-practices/s3.html).
- **IAM Least Privilege:** CodeBuild service role has `sts:AssumeRole` scoped to exactly the two deployment role ARNs. No wildcards. Follows [AWS IAM Best Practices](https://aws.amazon.com/iam/resources/best-practices/).
- **State Bucket Access:** Only the CodeBuild service role has read/write access to state files and `.tflock` files. Target account deployment roles do NOT access the state bucket.
- **Deployment Role Trust:** Handled outside this module. Trust policy must reference the CodeBuild service role ARN with `aws:PrincipalOrgID` condition for defense-in-depth.
- **No Privileged Mode:** CodeBuild projects do not enable Docker privileged mode. No Docker-in-Docker is needed for Terraform operations.

### SCP Compatibility

All principals are within the AWS Organization. No external OIDC trust. No role chaining. Region-deny SCPs respected — pipeline targets `ca-central-1` by default.

### Security Requirements Checklist

The following must be verified during implementation and testing:

- [ ] CodeBuild projects have `privileged_mode = false` (explicit)
- [ ] No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` in any CodeBuild environment variable
- [ ] S3 bucket policies deny `aws:SecureTransport = false`
- [ ] S3 Block Public Access enabled on all buckets (all four settings)
- [ ] IAM policies use specific resource ARNs, not `*`, for `sts:AssumeRole`
- [ ] SNS topic has encryption enabled (AWS-managed KMS key)
- [ ] CloudWatch log groups have explicit retention periods (no indefinite retention)
- [ ] CodeStar Connection uses OAuth/GitHub App (no personal access tokens)
- [ ] Buildspec files do not echo or log secret values
- [ ] CodeBuild service role cannot create IAM users, access keys, or modify organization settings
- [ ] Deployment role trust policies include `aws:PrincipalOrgID` condition

## Terraform Best Practices

The following practices are implemented based on [AWS Prescriptive Guidance: Best Practices for Using the Terraform AWS Provider](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/introduction.html).

### Code Structure (per AWS Prescriptive Guidance)

| Practice | Implementation |
|----------|----------------|
| **Standard repository structure** | Root module with `main.tf`, `variables.tf`, `outputs.tf`, `locals.tf`, `versions.tf` |
| **Separate providers from resources** | `versions.tf` contains `terraform {}` and `required_providers` blocks only |
| **Variables have types and descriptions** | All variables include `type`, `description`, and `default` (where optional) |
| **Validation blocks** | `iac_runtime` validated to `["terraform", "opentofu"]`. Account IDs validated as 12-digit strings. ARNs validated with regex |
| **Use locals for computed values** | `locals.tf` computes `state_bucket_name`, `codestar_connection_arn`, merged tags |
| **Use attachment resources** | IAM policies attached via `aws_iam_role_policy` (inline) rather than embedded in role definitions |
| **Default tags on all resources** | `local.all_tags` merges module-managed tags with consumer `var.tags`. Applied to all taggable resources |
| **Snake case naming** | All Terraform resource names and variables use `snake_case` |
| **No hardcoded values** | All configurable values exposed as variables with sensible defaults |

### Backend Best Practices (per AWS Prescriptive Guidance)

| Practice | Implementation |
|----------|----------------|
| **S3 for remote state** | S3 backend in Automation Account. 99.999999999% durability |
| **Native S3 state locking** | `use_lockfile = true` — recommended over deprecated DynamoDB locking |
| **Versioning enabled** | S3 versioning on state bucket for point-in-time recovery |
| **Separate state per environment** | Key pattern: `<project>/<env>/terraform.tfstate`. DEV and PROD never share state |
| **Encryption at rest** | SSE-S3 on state bucket |
| **CloudTrail integration** | S3 API calls (PutObject, DeleteObject) logged for accountability |

### Module Design Best Practices

| Practice | Implementation |
|----------|----------------|
| **Don't configure providers in modules** | Module does not contain `provider` blocks. Consumer configures the AWS provider |
| **Declare required_providers** | `versions.tf` declares `aws` provider with version constraint |
| **Use count for conditional resources** | State bucket and CodeStar Connection use `count` pattern |
| **Reference resources in outputs** | Outputs reference resource attributes, not input variables |
| **Encapsulate logical relationships** | Related resources grouped in files (`storage.tf` = S3 + SNS, `iam.tf` = roles + policies) |
| **Examples directory** | `examples/minimal/`, `examples/complete/`, `examples/opentofu/` demonstrate usage |

## File Organization

```
terraform-pipelines/               # Module root
├── main.tf                         # CodePipeline + CodeBuild projects
├── iam.tf                          # IAM roles and policies
├── storage.tf                      # S3 buckets (state + artifacts) + SNS topic
├── codestar.tf                     # CodeStar Connection (conditional)
├── variables.tf                    # All input variables with validation
├── outputs.tf                      # All module outputs
├── locals.tf                       # Computed values (bucket names, tags, etc.)
├── versions.tf                     # required_version, required_providers
├── buildspecs/                     # CodeBuild buildspec files
│   ├── prebuild.yml
│   ├── plan.yml
│   ├── deploy.yml
│   └── test.yml
├── examples/
│   ├── minimal/                    # Required variables only
│   │   ├── main.tf
│   │   └── variables.tf
│   ├── complete/                   # All variables populated
│   │   ├── main.tf
│   │   └── variables.tf
│   └── opentofu/                   # OpenTofu runtime example
│       ├── main.tf
│       └── variables.tf
├── docs/
│   ├── codepipeline-mvp-statement.md
│   └── ARCHITECTURE_AND_DESIGN.md
├── prd.md
├── progress.txt
├── CLAUDE.md
└── README.md
```

### File Responsibilities

| File | Contents |
|------|----------|
| `main.tf` | `aws_codepipeline`, `aws_codebuild_project` (x4), `aws_cloudwatch_log_group` (x4) |
| `iam.tf` | `aws_iam_role` (x2), `aws_iam_role_policy` (x2) |
| `storage.tf` | `aws_s3_bucket` (x2, state conditional), bucket configs, `aws_sns_topic`, `aws_sns_topic_subscription`, `data.aws_s3_bucket` |
| `codestar.tf` | `aws_codestarconnections_connection` (conditional) |
| `variables.tf` | All `variable` blocks with types, descriptions, defaults, validation |
| `outputs.tf` | All `output` blocks |
| `locals.tf` | Computed values: `state_bucket_name`, `codestar_connection_arn`, merged tags |
| `versions.tf` | `terraform { required_version }`, `required_providers` |

## Conditional Resource Logic

| Resource | Condition | Pattern |
|----------|-----------|---------|
| S3 State Bucket | `var.create_state_bucket` | `count = var.create_state_bucket ? 1 : 0` |
| State Bucket data source | `!var.create_state_bucket` | `count = var.create_state_bucket ? 0 : 1` |
| CodeStar Connection | `var.codestar_connection_arn == ""` | `count = var.codestar_connection_arn == "" ? 1 : 0` |
| Optional Review Stage | `var.enable_review_gate` | `dynamic "stage"` block in CodePipeline |
| SNS Subscriptions | `length(var.sns_subscribers) > 0` | `for_each = toset(var.sns_subscribers)` |

### Locals for Conditional References

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

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Reusable Terraform module (not root module) | Consumers invoke via `module {}` block. Supports multiple pipeline instances from one codebase. |
| 2 | 4 CodeBuild projects, reused with env vars | Deploy and Test projects are parameterized per stage (TARGET_ENV, TARGET_ROLE). Reduces resource count from 6 to 4. |
| 3 | Buildspec files in `buildspecs/` directory | Separate YAML files rather than inline in Terraform. Easier to read, lint, and modify independently. |
| 4 | SSE-S3 encryption (not KMS) | Simpler — no KMS key lifecycle to manage. Sufficient for state and artifacts in MVP. Post-MVP: customer-managed KMS keys for cross-account artifact sharing. |
| 5 | SNS uses AWS-managed KMS key | Encryption at rest with zero key management overhead. |
| 6 | `count` for conditional resources | Standard Terraform pattern for single conditional resources (state bucket, CodeStar connection). |
| 7 | Data source for existing state bucket | When `create_state_bucket = false`, a `data.aws_s3_bucket` validates the bucket exists and provides attributes. |
| 8 | Validation blocks on input variables | Fail fast with clear errors for `iac_runtime`, account ID format, ARN format. Per AWS Prescriptive Guidance. |
| 9 | Fixed + custom tags | Module always applies `project_name` and `managed-by` tags. Consumer merges additional tags. Per AWS Prescriptive Guidance `default_tags` pattern. |
| 10 | Artifact bucket per pipeline | Each pipeline gets its own artifact bucket. Clean isolation. No cross-pipeline artifact collision. |
| 11 | Explicit CloudWatch log groups | Module creates and manages log groups with configurable retention. Prevents unbounded log growth. Required by Security Hub [CodeBuild.4]. |
| 12 | Configurable build timeout | `codebuild_timeout_minutes` variable (default 60) gives consumers control over long-running applies. |
| 13 | `required_version >= 1.11` | Enforced because native S3 locking (`use_lockfile`) requires Terraform 1.11+. |
| 14 | Fewer, grouped .tf files | `main.tf` (pipeline + CodeBuild), `iam.tf`, `storage.tf` (S3 + SNS). Balanced readability without excessive file count. |
| 15 | `dynamic "stage"` for optional review gate | Boolean variable `enable_review_gate` controls whether Stage 4 is included. Uses Terraform `dynamic` block. |
| 16 | Graceful var-file handling in buildspecs | Plan and deploy buildspecs check if `environments/${TARGET_ENV}.tfvars` exists before passing `-var-file`. Supports simple projects without tfvars. |
| 17 | Privileged mode explicitly disabled | CodeBuild projects set `privileged_mode = false`. No Docker-in-Docker needed. Required by Security Hub [CodeBuild.5]. |
| 18 | No provider block in module | Module does not configure the AWS provider. Consumer manages provider configuration. Per AWS Prescriptive Guidance and Terraform module best practices. |

## Deployment Workflow

The module itself is deployed by a consumer writing a root module that invokes it:

```hcl
module "my_project_pipeline" {
  source = "path/to/terraform-pipelines"

  project_name             = "my-project"
  github_repo              = "my-org/my-project"
  dev_account_id           = "111111111111"
  dev_deployment_role_arn  = "arn:aws:iam::111111111111:role/TerraformDeploy-my-project-dev"
  prod_account_id          = "222222222222"
  prod_deployment_role_arn = "arn:aws:iam::222222222222:role/TerraformDeploy-my-project-prod"

  # Optional overrides
  enable_review_gate = true
  sns_subscribers    = ["team@example.com"]
  tags = {
    team        = "platform"
    cost-center = "12345"
  }
}
```

The consumer runs `terraform init && terraform apply` in the Automation Account. This creates all pipeline resources. The pipeline then operates autonomously on code pushes.

## Out of Scope

| Item | Rationale |
|------|-----------|
| Deployment roles in target accounts | Prerequisite. Trust and permission policies documented in MVP statement. |
| Custom Docker images | Adds build/maintain/patch lifecycle. MVP uses standard images + inline install. |
| Automated approval | Lambda + PutApprovalResult is post-MVP. |
| Multi-environment beyond DEV/PROD | Template extension. Each pipeline deploys to exactly two accounts. |
| Terraform state bucket for the pipeline module itself | The pipeline module's own state management is the consumer's responsibility. |
| Customer-managed KMS keys for artifact encryption | Post-MVP enhancement. Required for cross-account artifact sharing per [AWS CodePipeline cross-account docs](https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-create-cross-account.html). MVP uses SSE-S3 since artifacts stay within the Automation Account. |
| VPC endpoints for CodeBuild | Post-MVP. Would eliminate internet access for CodeBuild, enhancing data residency. |

## Test Environment

The following accounts and repository are used for end-to-end validation of the pipeline module.

| Account | Account ID | CLI Profile | Role |
|---------|-----------|-------------|------|
| Automation | 389068787156 | `aft-automation` | Pipeline host — all pipeline resources deployed here |
| DEV Target | 914089393341 | `developer-account` | DEV deployment target |
| PROD Target | 264675080489 | `network` | PROD deployment target |

**Test Repository:** `OttawaCloudConsulting/terraform-test`, branch `s3-bucket`
- Deploys a simple S3 bucket without customization or tfvars
- Validates that the pipeline works with projects that have no `environments/*.tfvars` files

**Manual Prerequisites Before E2E Test:**
1. Create deployment roles in DEV (914089393341) and PROD (264675080489) accounts
2. Deployment roles must trust `CodeBuild-<project>-ServiceRole` in Automation Account (389068787156)
3. Trust policy must include `aws:PrincipalOrgID` condition
4. See `docs/codepipeline-mvp-statement.md` § Target Account Deployment Role Requirements for full details

## Dependency Graph

```
versions.tf (providers, version constraints)
    │
    ▼
variables.tf + locals.tf (inputs, computed values)
    │
    ├──► iam.tf
    │    ├── CodePipeline Service Role
    │    └── CodeBuild Service Role
    │         (depends on: state bucket name, artifact bucket name,
    │          deployment role ARNs, log group ARNs)
    │
    ├──► storage.tf
    │    ├── S3 State Bucket (conditional)
    │    ├── S3 State Bucket data source (conditional, inverse)
    │    ├── S3 Artifact Bucket
    │    ├── SNS Approval Topic
    │    └── SNS Subscriptions
    │
    ├──► codestar.tf
    │    └── CodeStar Connection (conditional)
    │
    └──► main.tf
         ├── CloudWatch Log Groups (x4)
         ├── CodeBuild Projects (x4)
         │    (depends on: CodeBuild role, log groups, artifact bucket)
         └── CodePipeline
              (depends on: CodePipeline role, artifact bucket,
               CodeStar connection, CodeBuild projects, SNS topic)
```

### Creation Order (Terraform resolves automatically)

1. S3 buckets, SNS topic, CodeStar Connection, CloudWatch log groups — independent, created in parallel
2. IAM roles and policies — depend on bucket ARNs and log group ARNs
3. CodeBuild projects — depend on IAM role and log groups
4. CodePipeline — depends on everything above

## References

- [AWS CodePipeline Security Best Practices](https://docs.aws.amazon.com/codepipeline/latest/userguide/security-best-practices.html)
- [AWS Security Hub CodeBuild Controls](https://docs.aws.amazon.com/securityhub/latest/userguide/codebuild-controls.html)
- [AWS Well-Architected SEC11-BP07: Pipeline Security](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_appsec_regularly_assess_security_properties_of_pipelines.html)
- [AWS Prescriptive Guidance: Terraform AWS Provider Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/introduction.html)
- [AWS Prescriptive Guidance: Terraform Code Structure](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/structure.html)
- [AWS Prescriptive Guidance: Terraform Backend Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html)
- [AWS Prescriptive Guidance: Terraform Security](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/security.html)
- [AWS Prescriptive Guidance: S3 Encryption Best Practices](https://docs.aws.amazon.com/prescriptive-guidance/latest/encryption-best-practices/s3.html)
- [AWS CodePipeline Artifact Encryption](https://docs.aws.amazon.com/codepipeline/latest/userguide/S3-artifact-encryption.html)
- [AWS CodePipeline Cross-Account Pipelines](https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-create-cross-account.html)
- [AWS IAM Best Practices](https://aws.amazon.com/iam/resources/best-practices/)
- [Implementing Defense-in-Depth Security for CodeBuild Pipelines](https://aws.amazon.com/blogs/security/implementing-defense-security-for-aws-codebuild-pipelines/)
