# Problem Statement: Issue #10 — CodeBuild Code Coverage Reporting for Checkov

## Issue Reference

- **Issue:** [#10 — Code Coverage](https://github.com/OttawaCloudConsulting/aws-control-tower-landing-zone/issues/10)
- **Branch:** `development/codecoverage`
- **Reported by:** OttawaCloudConsulting

> Plan phases include a security scanning using Checkov.
> AWS CodeBuild includes Code Coverage reporting.
> CodeBuild stages that run Checkov scans must populate CodeBuild code coverage reports with the output.

---

## Background

The terraform-pipelines module orchestrates Terraform deployments through AWS CodePipeline V2. Each
pipeline includes Plan stages for both DEV and PROD environments. When `enable_security_scan = true`,
the Plan stage installs Checkov and scans the Terraform plan file (`tfplan.json`) for security
misconfigurations before deployment proceeds.

AWS CodeBuild natively supports two structured report types that appear in the CodeBuild console
with historical trends and per-run drill-down:

| Report Type | Formats Supported |
|---|---|
| Test Reports | JUnit XML, NUnit XML, TestNG XML, Cucumber JSON, Visual Studio TRX |
| Code Coverage Reports | Clover XML, Cobertura XML, JaCoCo XML, Simplecov JSON, LCOV |

These reports are uploaded automatically when a buildspec includes a `reports:` section and the
CodeBuild service role has the required IAM permissions.

---

## Current State

### Checkov execution in `modules/core/buildspecs/plan.yml`

1. **Install phase:** Checkov is installed via `pip3 install checkov` when `ENABLE_SECURITY_SCAN=true`
2. **Build phase:**
   - The saved Terraform plan is exported to JSON: `terraform show -json tfplan > tfplan.json`
   - Checkov runs against the plan JSON:
     ```bash
     checkov -f tfplan.json --framework terraform_plan [--soft-fail]
     ```
   - Results are written only to stdout (the build log)
   - `tfplan.json` is deleted immediately after the scan: `rm -f tfplan.json`
3. **No `reports:` section** exists in the buildspec — CodeBuild never uploads any structured report
4. **No report group** is provisioned in Terraform for these CodeBuild projects

### What this means operationally

- Checkov findings are only visible by manually opening the build log in CloudWatch or CodeBuild
- There is no historical trending of pass/fail rates across pipeline runs
- Stakeholders have no consolidated security posture view in the CodeBuild console
- The pipeline enforces hard/soft-fail behaviour (correct), but provides no audit trail of findings

---

## Problem Statement

Checkov security scan results from Plan stages are not surfaced as structured AWS CodeBuild reports.
Developers and security reviewers must inspect raw build logs to see which checks passed or failed.
There is no historical trending, no per-check drill-down in the console, and no machine-readable
artifact from the security scan. The CodeBuild code coverage reporting feature — designed exactly
for this kind of structured pass/fail metric — is not being used.

---

## Proposed Solution

### Recommended approach: Code Coverage Reports via Cobertura XML

Map Checkov check results to the Cobertura XML coverage format, where:

- Each Terraform resource in the plan = a "class" (coverage unit)
- Each Checkov check against that resource = a "line"
- **Passed check** → `hits="1"` (covered)
- **Failed check** → `hits="0"` (not covered)

This produces a percentage metric ("X% of checks passed") that CodeBuild renders as a coverage
trend graph, with per-resource and per-check drill-down.

**Why Cobertura over JUnit XML:**
JUnit XML maps to CodeBuild _Test Reports_, which show pass/fail counts but no coverage percentage.
Cobertura maps to CodeBuild _Code Coverage Reports_, which provide a line-coverage percentage metric
and trend chart — better suited to expressing "what fraction of your infrastructure passes security
checks."

**Implementation overview:**

1. Run Checkov with `--output json --output-file-path /tmp/checkov-report` to produce a structured
   JSON artifact alongside the existing CLI output
2. Execute a post-scan Python script to convert the Checkov JSON to Cobertura XML format
3. Add a `reports:` section to `plan.yml` pointing at the Cobertura XML file
4. Grant the CodeBuild service role the IAM permissions required to upload coverage reports
5. Optionally provision a named CodeBuild Report Group in Terraform for consistent naming and
   retention configuration

### Alternative: Test Reports via JUnit XML (simpler, less visual)

Checkov natively outputs JUnit XML with `--output junitxml`. This can be uploaded directly as a
CodeBuild Test Report with minimal change:

```bash
checkov -f tfplan.json --framework terraform_plan --output junitxml \
  --output-file-path /tmp/checkov-report
```

Buildspec addition:
```yaml
reports:
  checkov-test-report:
    files:
      - "/tmp/checkov-report/results_junitxml.xml"
    file-format: JUNITXML
```

**Trade-off:** JUnit reports show pass/fail counts per check but do not produce a coverage
percentage metric or coverage trend graph. The issue specifically requests "code coverage reports,"
which implies the Cobertura approach.

---

## Implementation Touch Points

| File | Change Required |
|---|---|
| `modules/core/buildspecs/plan.yml` | Add `--output json --output-file-path` to Checkov command; add conversion script invocation; add `reports:` section |
| `modules/core/iam.tf` | Add CodeBuild report IAM actions to the CodeBuild service role policy |
| `modules/core/main.tf` | Optionally add `aws_codebuild_report_group` resource(s) for plan-dev and plan-prod projects |
| `modules/core/variables.tf` | No new variables expected — feature follows `enable_security_scan` flag |
| `modules/core/outputs.tf` | Optionally expose report group ARNs |

### Required IAM permissions (additions to CodeBuild service role)

```
codebuild:CreateReportGroup
codebuild:CreateReport
codebuild:UpdateReport
codebuild:BatchPutCodeCoverages
```

These must be scoped to the report group ARN(s) for least-privilege compliance.

### Checkov JSON → Cobertura XML conversion

A small inline Python script (embedded in the buildspec or stored as `modules/core/buildspecs/checkov-to-cobertura.py`)
transforms Checkov's JSON output:

```python
# Checkov JSON structure:
# {
#   "results": {
#     "passed_checks": [{ "check_id": "CKV_AWS_...", "resource": "aws_s3_bucket.main", ... }],
#     "failed_checks": [{ "check_id": "CKV_AWS_...", "resource": "aws_s3_bucket.main", ... }]
#   }
# }
```

Each unique resource becomes a `<class>` element. Each check becomes a `<line>`. Line hits are
set to `1` (passed) or `0` (failed). The overall coverage rate is derived from total passed /
total checks.

---

## Acceptance Criteria

1. When a Plan stage runs with `ENABLE_SECURITY_SCAN=true`, a structured Cobertura XML report is
   generated and uploaded to CodeBuild
2. The CodeBuild console shows a "Code Coverage" tab for `plan-dev` and `plan-prod` build projects
   with a coverage percentage reflecting the ratio of passed Checkov checks
3. Consecutive pipeline runs produce a historical trend graph in the CodeBuild console
4. When `ENABLE_SECURITY_SCAN=false`, no report is generated and the build does not fail due to
   missing report files
5. The Checkov hard-fail / soft-fail behaviour (`CHECKOV_SOFT_FAIL`, PROD always hard-fails) is
   unchanged — reporting is additive, not a gate change
6. The CodeBuild service role policy grants report upload permissions scoped to the correct report
   group ARN(s)
7. `bash tests/test-terraform.sh` continues to pass for all targets

---

## Out of Scope

- Changing the hard-fail / soft-fail behaviour of the security scan
- Adding Checkov to buildspecs other than `plan.yml` (deploy, test, prebuild)
- Surfacing Checkov results in the CodePipeline execution history (CodePipeline does not support
  custom report types natively)
- Alerting or SNS notifications triggered by coverage thresholds
- Custom Checkov policies or check suppressions
