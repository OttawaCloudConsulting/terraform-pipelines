# PRD: CodeBuild Code Coverage Reporting for Checkov

## Summary

Enhance the `plan.yml` buildspec in the terraform-pipelines module so that Checkov security scan
results are surfaced as structured AWS CodeBuild code coverage reports. Currently, Checkov output
is written only to the build log. After this change, every Plan stage build that runs with
`enable_security_scan = true` will produce a Cobertura XML coverage report that is automatically
uploaded to CodeBuild, where it is visible in the console as a line-coverage percentage with
per-resource and per-check drill-down.

## Goals

- Surface Checkov findings as structured CodeBuild code coverage reports visible in the console
- Produce a line-coverage percentage metric derived from passed vs. failed check ratio
- Preserve all existing hard-fail / soft-fail behaviour of the Checkov gate unchanged
- Require no new module variables or consumer-facing configuration changes
- Implement with a single file change to `modules/core/buildspecs/plan.yml`

## Non-Goals

| Item | Rationale |
|------|-----------|
| `aws_codebuild_report_group` Terraform resource | CodeBuild auto-creates report groups on first upload; explicit lifecycle management deferred to post-MVP |
| S3 export of raw Checkov report data | CodeBuild retains reports internally (30-day default); S3 archival is a post-MVP enhancement |
| KMS CMK encryption of report groups | Consistent with existing module CMK deferral policy (design decision #4 in main arch doc) |
| Coverage threshold gate | Failing the build based on a minimum coverage % is a post-MVP feature |
| Skipped checks in coverage output | Only passed and failed checks are mapped; skipped checks are excluded from MVP |
| JUnit XML test report (parallel) | A separate test report alongside the coverage report is a post-MVP option |
| Checkov in non-plan buildspecs | Only the Plan stage runs Checkov; deploy, test, prebuild, and destroy are unchanged |

## Architecture

```
Plan Stage (plan.yml buildspec)
│
├── [existing] Install phase
│   └── pip3 install checkov  (when ENABLE_SECURITY_SCAN=true)
│
├── [existing] Build phase — terraform init + plan
│
├── [modified] Build phase — security scan block
│   ├── terraform show -json tfplan > tfplan.json
│   ├── checkov ... --output cli --output json --output-file-path /tmp/checkov
│   │   └── writes: /tmp/checkov/results_json.json
│   ├── python3 (inline converter)
│   │   └── reads:  /tmp/checkov/results_json.json
│   │   └── writes: /tmp/checkov/checkov-cobertura.xml
│   └── re-raise CHECKOV_EXIT (preserves hard/soft-fail)
│
└── [new] reports: section (static YAML)
    └── checkov-security → COBERTURAXML → /tmp/checkov/checkov-cobertura.xml
        └── CodeBuild auto-creates report group: {project}-plan-{env}-checkov-security
            └── IAM: CodeBuildReports policy statement (already in iam.tf)
```

**Cobertura mapping:**

| Cobertura Element | Checkov Meaning |
|---|---|
| `<package name="terraform-plan">` | One package per scan (the entire plan) |
| `<class name="aws_s3_bucket.main">` | One Terraform resource |
| `<line hits="1">` | A check that passed on this resource |
| `<line hits="0">` | A check that failed on this resource |
| Line coverage % | `passed / (passed + failed)` across all resources |

## Features

### Feature 1: Checkov JSON Output Capture

Modify the Checkov invocation in `plan.yml` to emit structured JSON alongside the existing CLI
output. Add `--output cli --output json --output-file-path /tmp/checkov` to the Checkov command.
Wrap the Checkov invocation in `set +e / set -e` to capture the exit code without immediately
aborting, so the Cobertura converter can run before the exit code is re-raised.

**Acceptance Criteria:**

- When `ENABLE_SECURITY_SCAN=true`, `/tmp/checkov/results_json.json` is present after Checkov runs
- CLI output (existing build log behaviour) is unchanged
- When Checkov finds failures and `CHECKOV_SOFT_FAIL=false`, the build still fails after the
  converter runs (exit code is re-raised)
- When `CHECKOV_SOFT_FAIL=true`, the build completes successfully even with findings

### Feature 2: Cobertura XML Converter

Add an inline Python script (heredoc in `plan.yml`) that reads `/tmp/checkov/results_json.json`
and produces `/tmp/checkov/checkov-cobertura.xml` in Cobertura v1.0 format. Each unique Terraform
resource becomes a `<class>` element; each check on that resource becomes a `<line>` with
`hits="1"` (passed) or `hits="0"` (failed). The overall `line-rate` reflects passed / total checks.

**Acceptance Criteria:**

- `/tmp/checkov/checkov-cobertura.xml` is valid Cobertura XML with `<coverage>`, `<packages>`,
  `<classes>`, and `<lines>` elements
- `lines-covered` and `lines-valid` attributes on `<coverage>` are accurate
- Each Terraform resource appears as a distinct `<class>` element
- If `results_json.json` does not exist, the script exits cleanly with a warning (no build failure)
- The converter runs whether Checkov passed or failed (exit code is captured before conversion)
- `skipped_checks` are excluded from the coverage calculation — only passed and failed checks contribute to `line-rate`
- When Checkov returns zero checks (e.g., plan has no applicable rules), `line-rate` defaults to `1.0` (100%) rather than dividing by zero

### Feature 3: CodeBuild Reports Section

Add a `reports:` section to the top level of `plan.yml` pointing at the Cobertura XML file with
`file-format: COBERTURAXML`. CodeBuild reads this section at build runtime and uploads the
specified file to the auto-created report group `{codebuild-project-name}-checkov-security`.

**Acceptance Criteria:**

- After a plan build with `ENABLE_SECURITY_SCAN=true`, the CodeBuild console shows a
  **Reports** tab for the `plan-dev` and `plan-prod` projects with a coverage percentage
- The report group is named `{project_name}-plan-{env}-checkov-security`
- Historical trend graphs appear after two or more pipeline runs
- When `ENABLE_SECURITY_SCAN=false`, the Cobertura file is not created; CodeBuild logs a
  warning about the missing file but **does not fail the build**
- When a PROD plan hard-fails (Checkov finds violations, `CHECKOV_SOFT_FAIL=false`), the
  coverage report is still uploaded before the exit code is re-raised — operators can
  inspect findings in the console even for failed builds
- `bash tests/test-terraform.sh` passes for all targets (fmt, validate, tflint, checkov, trivy)

## Configuration

No new module variables are introduced. The feature is activated by the existing flag.

### Relevant Existing Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `enable_security_scan` | `bool` | `true` | Controls whether Checkov runs and the report is generated |
| `checkov_soft_fail` | `bool` | `false` | When `true`, DEV plan continues even if Checkov finds issues |

## Outputs

No new Terraform outputs. The feature produces runtime-only artifacts within CodeBuild.

| Artifact | Type | Description |
|---|---|---|
| CodeBuild coverage report | AWS resource (auto-created) | Report group `{project}-plan-{env}-checkov-security` in CodeBuild console |
| `/tmp/checkov/results_json.json` | Ephemeral build file | Checkov JSON; exists only during the build, not exported as an artifact |
| `/tmp/checkov/checkov-cobertura.xml` | Ephemeral build file | Cobertura XML; uploaded to CodeBuild reports, not exported as a pipeline artifact |

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Checkov JSON output format changes between versions | Low | `results_json.json` structure has been stable; converter uses `.get()` with fallbacks and exits cleanly if keys are missing |
| CodeBuild report upload fails silently | Low | Build log captures the upload attempt; missing file produces a warning, not a silent success |
| `set +e` around Checkov causes hard-fail to be missed | Low | Exit code is captured in `CHECKOV_EXIT` and explicitly re-raised after conversion; `set -e` is restored immediately after Checkov |
| Report group name collision across projects | Low | Names are scoped by `{project_name}` prefix, which is unique per pipeline instance |
| `ET.indent()` requires Python 3.9+ | Low | Amazon Linux 2023 (CodeBuild standard:5.0 image) ships Python 3.11; not a concern for the default image |
| Auto-created report groups use SSE-S3 (not CMK) — flagged by AWS Config rule `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` in CMK-enforcement environments | Medium | Consistent with existing module-wide CMK deferral policy. Consumers enforcing this rule must add `aws_codebuild_report_group` with KMS post-MVP. Document in module README when PR is merged. |
| Truncated or malformed Checkov JSON (e.g., OOM kill mid-write) causes `json.JSONDecodeError` traceback in build log | Low | Build fails safely via `set -e`; traceback is visible in CloudWatch. Acceptable for MVP. Post-MVP: wrap in `try/except json.JSONDecodeError` with a descriptive error message. |
| `tfplan.json` not cleaned up when Checkov hard-fails (pre-existing behaviour — `set -e` aborts before `rm -f`) | Low | CodeBuild containers are ephemeral and destroyed after each build; file does not persist beyond the build. Not a security concern. |
| `aws_codebuild_report_group` auto-created with `type = "TEST"` instead of `type = "CODE_COVERAGE"` | Low | CodeBuild infers report group type from the `file-format` value in the buildspec (`COBERTURAXML` → CODE_COVERAGE). The auto-created group type is set correctly at first upload. No Terraform action needed for MVP; explicit resource post-MVP must set `type = "CODE_COVERAGE"` explicitly. |
| Post-MVP `aws_codebuild_report_group` `s3_destination.encryption_key` is Required, not Optional | Medium | The AWS provider schema requires `encryption_key` when `export_config.type = "S3"`. Post-MVP implementers must provide a KMS key ARN; there is no SSE-S3-only path through the resource. Attempting to set `type = "S3"` without a KMS key will produce a provider-level validation error. Use `type = "NO_EXPORT"` as an intermediate step if KMS is not yet available. |

## External Dependencies

| Dependency | Owner | Status |
|---|---|---|
| `codebuild:*` report IAM permissions | `modules/core/iam.tf` | Already present — `CodeBuildReports` statement covers all 5 required actions |
| Checkov `--output json` flag availability | Checkov PyPI package | Available since Checkov 2.x; installed fresh per build via `pip3 install checkov` |
| CodeBuild Cobertura XML support | AWS | GA feature available in all supported regions |

## Success Criteria

- After deploying a pipeline with `enable_security_scan = true` and running a plan, the
  CodeBuild console shows a populated coverage report with a line coverage percentage
- Running the plan a second time shows a historical trend graph
- Disabling `enable_security_scan` and running the plan produces no report-related errors
- `bash tests/test-terraform.sh` passes all 7 validation steps

## Terraform Implementation Notes

This section documents Terraform-specific implementation guidance for post-MVP features referenced elsewhere in this PRD. It is grounded in the AWS provider documentation retrieved during the PRD review.

### `aws_codebuild_report_group` — Post-MVP Resource Sketch

The MVP relies on CodeBuild's auto-creation behaviour: when a buildspec `reports:` section names a report group that does not yet exist, CodeBuild creates it automatically using SSE-S3 encryption. This is sufficient for the MVP but does not satisfy environments enforcing the `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` AWS Config rule (identifier: `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST`), which flags report groups where `EncryptionDisabled = true` (i.e., not using a KMS CMK).

For post-MVP, an explicit `aws_codebuild_report_group` resource is required. The full argument reference is:

- `name` (Required) — the report group name
- `type` (Required) — must be `"CODE_COVERAGE"` for Cobertura XML coverage reports (not `"TEST"`)
- `export_config` (Required) — must specify `type = "S3"` or `type = "NO_EXPORT"`
  - When `type = "S3"`: the nested `s3_destination` block requires `encryption_key` (KMS key ARN) — this field is **Required** per the provider schema, not optional
- `delete_reports` (Optional, default `false`) — set to `true` if the resource should delete child reports on `terraform destroy`
- `tags` (Optional)

**AWSCC provider note:** The `mcp__awslabs-terraform-mcp-server__SearchAwsccProviderDocs` tool was unavailable during this review. Per project convention (AWSCC-first for Cloud Control API-backed resources), confirm whether `awscc_codebuild_report_group` exists before using the `aws` provider resource. The Future Enhancements table notes this as an open item.

**HCL sketch — compliant `aws_codebuild_report_group` with KMS + S3 export:**

```hcl
# Post-MVP — one resource per plan project per environment (plan-dev, plan-prod)
# Add to modules/core/main.tf alongside aws_codebuild_project.this

resource "aws_codebuild_report_group" "checkov" {
  # checkov:skip=CKV_AWS_147: encryption_key is set; this skip is for the project-level CMK, not report groups
  for_each = var.enable_security_scan ? {
    "plan-dev"  = "dev"
    "plan-prod" = "prod"
  } : {}

  name         = "${var.project_name}-${each.key}-checkov-security"
  type         = "CODE_COVERAGE"
  delete_reports = true

  export_config {
    type = "S3"

    s3_destination {
      bucket              = aws_s3_bucket.artifacts.id
      path                = "/checkov-reports"
      packaging           = "NONE"
      encryption_disabled = false
      encryption_key      = var.kms_key_arn  # post-MVP variable; requires KMS CMK (design decision #4 lifted)
    }
  }

  tags = local.all_tags
}
```

**Key constraints from the provider schema:**

| Argument | Required/Optional | Notes |
|---|---|---|
| `type` | Required | Must be `"CODE_COVERAGE"` — not `"TEST"`. The buildspec `COBERTURAXML` format maps to this type. |
| `export_config.type` | Required | `"S3"` or `"NO_EXPORT"`. `"NO_EXPORT"` retains reports internally for 30 days only (CodeBuild default). |
| `export_config.s3_destination.encryption_key` | Required (when type=S3) | KMS key ARN. There is no SSE-S3-only path through this argument — omitting it is invalid when `type = "S3"`. |
| `export_config.s3_destination.encryption_disabled` | Optional | Must be `false` when `encryption_key` is set. Setting to `true` disables encryption entirely and will trigger the AWS Config rule. |
| `delete_reports` | Optional (default false) | Set to `true` to allow `terraform destroy` to remove the resource without manual report cleanup. |

**Provider version:** `modules/core/versions.tf` constrains `hashicorp/aws ~> 6.0`. The `aws_codebuild_report_group` resource has been available since AWS provider v2.x and is fully supported under the current `~> 6.0` constraint. No version constraint change is needed for this resource.

### `checkov_coverage_threshold` — Proposed Variable Definition

The Future Enhancements section lists a coverage threshold gate as a post-MVP feature. When implemented, add the following variable to `modules/core/variables.tf` and both variant `variables.tf` files:

```hcl
variable "checkov_coverage_threshold" {
  description = "Minimum Checkov line coverage percentage (0–100) required to pass a Plan build. Set to 0 to disable threshold enforcement. Only applies when enable_security_scan = true. PROD plans always hard-fail on any Checkov finding regardless of this setting."
  type        = number
  default     = 0

  validation {
    condition     = var.checkov_coverage_threshold >= 0 && var.checkov_coverage_threshold <= 100
    error_message = "checkov_coverage_threshold must be between 0 and 100 inclusive."
  }
}
```

The buildspec implementation would read this as `CHECKOV_COVERAGE_THRESHOLD` and fail the build when the computed `line-rate * 100` is below the threshold — after the Cobertura XML is written and uploaded, so the report is still visible on failed builds.

### `aws_cloudwatch_metric_alarm` — CloudWatch Alarm for FailedBuilds

The Future Enhancements section references adding a CloudWatch alarm for `FailedBuilds`. The Terraform resource type is `aws_cloudwatch_metric_alarm` (AWS provider). A representative sketch for the plan-dev project:

```hcl
# Post-MVP — add to modules/core/main.tf
resource "aws_cloudwatch_metric_alarm" "plan_failed" {
  for_each = local.codebuild_projects

  alarm_name          = "${var.project_name}-${each.key}-failed-builds"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedBuilds"
  namespace           = "AWS/CodeBuild"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "CodeBuild project ${var.project_name}-${each.key} has a failed build"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ProjectName = aws_codebuild_project.this[each.key].name
  }

  alarm_actions = [aws_sns_topic.approvals.arn]
  tags          = local.all_tags
}
```

This reuses the existing `aws_sns_topic.approvals` resource in `modules/core/storage.tf` to avoid adding a new dependency. It iterates over `local.codebuild_projects` so all seven projects (prebuild, plan-dev, plan-prod, deploy-dev, deploy-prod, test-dev, test-prod) get alarms. If scope should be limited to plan projects only, change the `for_each` to a filtered map.

### IAM `CodeBuildReports` Statement — Correctness Verification

The existing `CodeBuildReports` statement in `modules/core/iam.tf` contains five actions:

```
codebuild:CreateReportGroup
codebuild:CreateReport
codebuild:UpdateReport
codebuild:BatchPutTestCases
codebuild:BatchPutCodeCoverages
```

**Verification findings:**

- All five actions are correct and necessary for the MVP scope.
- `BatchPutCodeCoverages` is the operative action for uploading code coverage report data (Cobertura XML). It is distinct from `BatchPutTestCases`, which handles test case result data (JUnit XML).
- `BatchPutTestCases` is included alongside `BatchPutCodeCoverages`. This is correct: AWS groups these actions together in its documentation examples for report group permissions. Including both future-proofs the IAM policy for the JUnit test report enhancement listed in Future Enhancements, and does not violate least privilege because the resource scope is already narrowed to `{project_name}-*`.
- The wildcard resource pattern `arn:aws:codebuild:{region}:{account}:report-group/{project_name}-*` is the correct least-privilege approach. It allows only report groups whose names begin with the project name, matching the auto-created naming convention `{codebuild-project-name}-{report-group-name-in-buildspec}` described in the AWS CodeBuild documentation.
- When post-MVP adds explicit `aws_codebuild_report_group` resources, their names (`${var.project_name}-plan-dev-checkov-security`, `${var.project_name}-plan-prod-checkov-security`) already match this pattern — no IAM changes required.

### Buildspec `reports:` Format Identifier — Verification

The `file-format: COBERTURAXML` value used in the PRD's Architecture section is confirmed correct per the official AWS CodeBuild buildspec reference (`build-spec-ref.html`). The documentation lists `COBERTURAXML` under "Code coverage reports" as the Cobertura XML format identifier. The value is documented as case-insensitive, but `COBERTURAXML` (uppercase) matches the canonical form shown in AWS examples. No change required.

---

## Future Enhancements

| Enhancement | Description |
|---|---|
| `aws_codebuild_report_group` Terraform resource | Explicit lifecycle management, S3 export config, custom retention beyond 30 days — **required** for environments enforcing the `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` AWS Config rule. Must use `type = "CODE_COVERAGE"`. See Terraform Implementation Notes for the full argument sketch. **Provider note:** per project convention, verify whether `awscc_codebuild_report_group` exists in the AWSCC provider before using `aws_codebuild_report_group`; if the AWSCC resource is available and covers the required arguments, prefer it. |
| KMS CMK encryption for report group | Auto-created report groups use SSE-S3. Consumers requiring CMK encryption must add an explicit `aws_codebuild_report_group` resource with a KMS key ARN. Note: `s3_destination.encryption_key` is **Required** (not optional) in the AWS provider when `export_config.type = "S3"` — a KMS key ARN must be supplied; there is no SSE-S3-only path through this argument. |
| S3 export retention alignment | Configure S3 export on the report group resource; align retention with the existing `artifact_retention_days` variable so reports survive beyond CodeBuild's 30-day default |
| CloudWatch alarm on `FailedBuilds` | Add `aws_cloudwatch_metric_alarm` for `{project_name}-plan-dev` and `{project_name}-plan-prod` CodeBuild projects (module-wide operational gap) |
| `json.JSONDecodeError` handling in converter | Wrap `json.load()` in `try/except` with a descriptive error message to improve CloudWatch diagnosability when Checkov writes a truncated JSON file |
| Coverage threshold gate | New variable `checkov_coverage_threshold` (0–100) fails the plan if coverage drops below the configured threshold |
| Skipped checks in output | Include `skipped_checks` as a third line category in the Cobertura XML |
| JUnit XML test report | Upload `results_junitxml.xml` alongside coverage for per-check test case detail view in the CodeBuild console |
| Checkov baseline file support | Allow a `.checkov.baseline` file to suppress known findings from the coverage calculation |
