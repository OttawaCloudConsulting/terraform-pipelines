# MVP Design: Issue #10 — CodeBuild Code Coverage Reporting for Checkov

## References

- [Problem Statement](./PROBLEM-STATEMENT.md)
- [AWS Docs — Create code coverage reports](https://docs.aws.amazon.com/codebuild/latest/userguide/code-coverage-report.html)
- [AWS Docs — Test report permissions](https://docs.aws.amazon.com/codebuild/latest/userguide/test-permissions.html)
- [AWS Docs — Buildspec syntax (`reports:` section)](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
- [Terraform — `aws_codebuild_report_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codebuild_report_group)

---

## Pre-Existing Conditions (No Change Required)

A key finding from codebase analysis: **the IAM permissions are already in place**.

`modules/core/iam.tf` already contains a `CodeBuildReports` statement in the CodeBuild service role policy:

```hcl
{
  Sid    = "CodeBuildReports"
  Effect = "Allow"
  Action = [
    "codebuild:CreateReportGroup",
    "codebuild:CreateReport",
    "codebuild:UpdateReport",
    "codebuild:BatchPutTestCases",
    "codebuild:BatchPutCodeCoverages"
  ]
  Resource = [
    "arn:aws:codebuild:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:report-group/${var.project_name}-*"
  ]
}
```

This covers all five permissions required by AWS for code coverage report upload, scoped to
`${project_name}-*` which will match any auto-created report group for this pipeline.

---

## MVP Scope

**Only one file changes:** `modules/core/buildspecs/plan.yml`

No new Terraform resources are required for MVP. CodeBuild auto-creates a report group on first
upload using the naming convention `{codebuild-project-name}-{report-group-name-in-buildspec}`.

Since the CodeBuild project names are `{project_name}-plan-dev` and `{project_name}-plan-prod`,
and the buildspec report group name will be `checkov-security`, the auto-created report groups
will be named:

- `{project_name}-plan-dev-checkov-security`
- `{project_name}-plan-prod-checkov-security`

Both match the IAM wildcard `{project_name}-*`. No IAM change needed.

### What is out of scope for MVP

- `aws_codebuild_report_group` Terraform resource (auto-creation covers MVP needs)
- S3 export of raw Checkov data (CodeBuild retains reports internally by default)
- Report group retention configuration (CodeBuild default: 30 days)
- Separate report group naming per variant (core module is variant-agnostic)

---

## Design: How CodeBuild Code Coverage Reporting Works

```
plan.yml buildspec
└── reports: section (static YAML)
    └── checkov-security:
        └── file-format: COBERTURAXML
            └── files: ["/tmp/checkov/checkov-cobertura.xml"]

At build time:
  1. Checkov runs → outputs JSON to /tmp/checkov/results_json.json
  2. Python converts JSON → Cobertura XML at /tmp/checkov/checkov-cobertura.xml
  3. CodeBuild reads the reports: section and uploads the Cobertura file
  4. CodeBuild auto-creates report group on first upload (if not existing)
  5. Report appears under Build → Reports tab in CodeBuild console
```

**Cobertura XML semantics applied to Checkov:**

| Cobertura Concept | Checkov Mapping |
|---|---|
| `<package>` | `terraform-plan` (one package per scan) |
| `<class>` | One Terraform resource (e.g., `aws_s3_bucket.main`) |
| `<line hits="1">` | A check that **passed** on this resource |
| `<line hits="0">` | A check that **failed** on this resource |
| Line coverage % | `passed_checks / (passed_checks + failed_checks)` |

---

## Implementation: `modules/core/buildspecs/plan.yml`

### Change 1 — Checkov command: add JSON output

**Before:**
```yaml
CHECKOV_ARGS="-f tfplan.json --framework terraform_plan"
if [ "${CHECKOV_SOFT_FAIL}" = "true" ]; then
  CHECKOV_ARGS="${CHECKOV_ARGS} --soft-fail"
fi
checkov ${CHECKOV_ARGS}
```

**After:**
```yaml
CHECKOV_ARGS="-f tfplan.json --framework terraform_plan"
if [ "${CHECKOV_SOFT_FAIL}" = "true" ]; then
  CHECKOV_ARGS="${CHECKOV_ARGS} --soft-fail"
fi
mkdir -p /tmp/checkov
# Capture exit code manually so we can run the converter before re-raising failure
set +e
checkov ${CHECKOV_ARGS} --output cli --output json --output-file-path /tmp/checkov
CHECKOV_EXIT=$?
set -e
```

> `--output cli --output json` produces CLI output to stdout (unchanged build log) and writes
> `/tmp/checkov/results_json.json` for conversion. `--output-file-path` is the directory prefix.
> `set +e / set -e` captures the exit code without aborting immediately, allowing the converter
> to run even when checks fail.

### Change 2 — Cobertura XML conversion (inline Python)

Appended immediately after the Checkov command block, still within the `ENABLE_SECURITY_SCAN=true`
conditional:

```bash
echo "Converting Checkov results to Cobertura XML for CodeBuild coverage report..."
python3 << 'PYEOF'
import json, sys, os, time
import xml.etree.ElementTree as ET

RESULTS_FILE = "/tmp/checkov/results_json.json"
OUTPUT_FILE  = "/tmp/checkov/checkov-cobertura.xml"

if not os.path.exists(RESULTS_FILE):
    print("No Checkov JSON output found — skipping Cobertura conversion.")
    sys.exit(0)

with open(RESULTS_FILE) as f:
    data = json.load(f)

results  = data.get("results", {})
passed   = results.get("passed_checks", [])
failed   = results.get("failed_checks", [])

# Build resource → { passed: [check_ids], failed: [check_ids] } map
resource_map = {}
for check in passed:
    r = check.get("resource", "unknown")
    resource_map.setdefault(r, {"passed": [], "failed": []})["passed"].append(check["check_id"])
for check in failed:
    r = check.get("resource", "unknown")
    resource_map.setdefault(r, {"passed": [], "failed": []})["failed"].append(check["check_id"])

total_lines   = sum(len(v["passed"]) + len(v["failed"]) for v in resource_map.values())
covered_lines = sum(len(v["passed"]) for v in resource_map.values())
line_rate     = round(covered_lines / total_lines, 4) if total_lines > 0 else 1.0

# Build Cobertura XML
coverage = ET.Element("coverage", {
    "lines-valid":       str(total_lines),
    "lines-covered":     str(covered_lines),
    "line-rate":         str(line_rate),
    "branches-covered":  "0",
    "branches-valid":    "0",
    "branch-rate":       "0",
    "timestamp":         str(int(time.time())),
    "version":           "1.0"
})
sources = ET.SubElement(coverage, "sources")
ET.SubElement(sources, "source").text = "."
packages = ET.SubElement(coverage, "packages")
pkg = ET.SubElement(packages, "package", {
    "name": "terraform-plan", "line-rate": str(line_rate), "branch-rate": "0"
})
classes_el = ET.SubElement(pkg, "classes")

for resource, checks in resource_map.items():
    all_check_ids = checks["passed"] + checks["failed"]
    r_total   = len(all_check_ids)
    r_covered = len(checks["passed"])
    r_rate    = round(r_covered / r_total, 4) if r_total > 0 else 1.0
    cls = ET.SubElement(classes_el, "class", {
        "name":        resource,
        "filename":    resource,
        "line-rate":   str(r_rate),
        "branch-rate": "0"
    })
    lines_el = ET.SubElement(cls, "lines")
    for i, check_id in enumerate(all_check_ids, start=1):
        hits = "1" if check_id in checks["passed"] else "0"
        ET.SubElement(lines_el, "line", {"number": str(i), "hits": hits, "name": check_id})

ET.indent(coverage)
ET.ElementTree(coverage).write(OUTPUT_FILE, encoding="unicode", xml_declaration=True)
print(f"Cobertura report: {OUTPUT_FILE}")
print(f"Coverage: {covered_lines}/{total_lines} checks passed ({line_rate * 100:.1f}%)")
PYEOF

# Re-raise Checkov exit code — preserves hard-fail / soft-fail behaviour
[ "${CHECKOV_EXIT}" -eq 0 ] || exit "${CHECKOV_EXIT}"
```

### Change 3 — Add `reports:` section to buildspec

Append at the top level of `plan.yml` (alongside the existing `artifacts:` section):

```yaml
reports:
  checkov-security:
    files:
      - "/tmp/checkov/checkov-cobertura.xml"
    file-format: COBERTURAXML
```

> CodeBuild auto-creates the report group `{codebuild-project-name}-checkov-security` on first
> upload. The `COBERTURAXML` file-format identifier is the correct CodeBuild constant for
> Cobertura XML coverage reports.
>
> When `ENABLE_SECURITY_SCAN=false`, the file will not be created. CodeBuild logs a warning
> about a missing report file but **does not fail the build** — the report simply shows as
> empty/absent for that run.

---

## Complete Modified Checkov Block (plan.yml)

The full `if [ "${ENABLE_SECURITY_SCAN}" = "true" ]` block after the MVP changes:

```yaml
- |
  set -euo pipefail
  if [ "${ENABLE_SECURITY_SCAN}" = "true" ]; then
    cd "${CODEBUILD_SRC_DIR}/${IAC_WORKING_DIR}"
    echo "Converting plan to JSON for security scan..."
    terraform show -json tfplan > tfplan.json
    echo "Running Checkov security scan..."
    CHECKOV_ARGS="-f tfplan.json --framework terraform_plan"
    if [ "${CHECKOV_SOFT_FAIL}" = "true" ]; then
      CHECKOV_ARGS="${CHECKOV_ARGS} --soft-fail"
    fi
    mkdir -p /tmp/checkov
    set +e
    checkov ${CHECKOV_ARGS} --output cli --output json --output-file-path /tmp/checkov
    CHECKOV_EXIT=$?
    set -e

    echo "Converting Checkov results to Cobertura XML for CodeBuild coverage report..."
    python3 << 'PYEOF'
    ... (converter script as above) ...
    PYEOF

    [ "${CHECKOV_EXIT}" -eq 0 ] || exit "${CHECKOV_EXIT}"
    rm -f tfplan.json
  fi
```

---

## File Change Summary

| File | Change Type | Description |
|---|---|---|
| `modules/core/buildspecs/plan.yml` | Modify | Add JSON output to Checkov, inline Python converter, `reports:` section |
| `modules/core/iam.tf` | None | `CodeBuildReports` statement already present |
| `modules/core/main.tf` | None | No new resources for MVP (auto-creation) |
| `modules/core/variables.tf` | None | Feature follows existing `enable_security_scan` flag |

---

## Verification Steps

1. **Static validation:**
   ```bash
   bash tests/test-terraform.sh --skip-security
   ```
   Must pass `terraform fmt`, `terraform validate` across all modules and examples.

2. **Full validation (with security scan):**
   ```bash
   bash tests/test-terraform.sh
   ```
   Must pass all 7 steps including Checkov and Trivy scans.

3. **End-to-end pipeline test** (requires AWS credentials):
   ```bash
   bash tests/test-terraform.sh --deploy default
   ```
   After the pipeline runs:
   - Open AWS CodeBuild console → project `{project_name}-plan-dev`
   - Select the latest build → **Reports** tab
   - Confirm a coverage report named `{project_name}-plan-dev-checkov-security` appears
   - Confirm line coverage percentage is shown
   - Confirm individual resource classes are listed with per-check pass/fail lines

4. **Soft-fail validation:** Deploy with `checkov_soft_fail = true` in the test tfvars.
   The plan stage must complete successfully even with Checkov findings, and a report must
   still be uploaded.

5. **Security scan disabled validation:** Deploy with `enable_security_scan = false`.
   The plan stage must complete with no report upload errors.

---

## Post-MVP Enhancements (Not in Scope)

| Enhancement | Description |
|---|---|
| `aws_codebuild_report_group` Terraform resource | Explicit lifecycle management, S3 export config, custom retention beyond 30 days, CMK encryption — required for environments enforcing AWS Config rule `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` |
| KMS encryption for report group | Auto-created report groups use SSE-S3 by default. Organisations enforcing CMK encryption via AWS Config must add `aws_codebuild_report_group` with an explicit KMS key (SEC-5) |
| S3 export retention alignment | Add S3 export to the report group resource; align retention with the existing `artifact_retention_days` variable so reports survive beyond the 30-day CodeBuild default (REL-4) |
| CloudWatch alarm on `FailedBuilds` | Add `aws_cloudwatch_metric_alarm` for the `plan-dev` and `plan-prod` CodeBuild projects (module-wide operational gap, OE-3) |
| `json.JSONDecodeError` handling in converter | Wrap `json.load()` in a `try/except` block with a descriptive `print()` to improve CloudWatch diagnosability when Checkov writes a truncated/malformed JSON file (REL-2; build fails safely today but shows a raw Python traceback) |
| Coverage gate | Fail the build if line coverage falls below a configurable threshold (new variable `checkov_coverage_threshold`) |
| Skipped checks in report | Include `skipped_checks` as a third category in the Cobertura output |
| Separate JUnit test report | Upload `results_junitxml.xml` alongside the coverage report for per-check test case view |

> **Well-Architected note (SEC-5 — Implementation):** When merging this PR, add a note to the
> module README that auto-created CodeBuild report groups use SSE-S3 encryption (not CMK).
> Consumers running the `CODEBUILD_REPORT_GROUP_ENCRYPTED_AT_REST` AWS Config rule will see
> these groups flagged as NON_COMPLIANT until the `aws_codebuild_report_group` resource is added
> post-MVP.
