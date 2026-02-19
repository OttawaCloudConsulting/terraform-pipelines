# Investigation: Source Stage Failure — Both E2E Pipelines

**Created:** 2026-02-13
**Status:** Resolved
**Symptom:** Both `test-default-pipeline` and `test-dev-destroy-pipeline` fail at the Source stage with: `[GitHub] No Branch [main] found for FullRepositoryName [OttawaCloudConsulting/terraform-test]`

## Facts

- FACT: Error message is `No Branch [main] found for FullRepositoryName [OttawaCloudConsulting/terraform-test]` — verified by `aws codepipeline list-action-executions` on execution IDs `2047e733` and `b552710c`
- FACT: The `OttawaCloudConsulting/terraform-test` repo has branches `master` and `s3-bucket` only — verified by `gh api repos/OttawaCloudConsulting/terraform-test/branches`
- FACT: There is no `main` branch on that repo — verified by the branch listing
- FACT: CLAUDE.md specifies the test repo branch as `s3-bucket` — verified at CLAUDE.md:143
- FACT: Both test configs (`tests/default/main.tf`, `tests/default-dev-destroy/main.tf`) do not set `github_branch`, so it defaults to `"main"` — verified by reading both files
- FACT: The `github_branch` variable in `modules/core/variables.tf` defaults to `"main"` — verified from Feature 1 implementation
- FACT: CodeStar connections are AVAILABLE — verified by `aws codestar-connections list-connections`
- FACT: All 3 executions per pipeline (CreatePipeline auto-trigger + 2 manual StartPipelineExecution) failed with the same error

## Theories

1. **Wrong branch default:** Test configs rely on the `github_branch` default of `"main"`, but the test repo uses `master`/`s3-bucket`.
   - Evidence for: Error says "No Branch [main]", repo has no `main` branch
   - Evidence against: None
   - Test: Set `github_branch = "s3-bucket"` in test configs and re-apply
   - **CONFIRMED**

## Tests Performed

| # | Action | Expected | Actual | Conclusion |
|---|--------|----------|--------|------------|
| 1 | `list-action-executions` on both pipelines | Error details | `No Branch [main] found` | Branch mismatch confirmed |
| 2 | `gh api repos/.../branches` | See available branches | `master`, `s3-bucket` | No `main` branch exists |
| 3 | Read test configs | Find `github_branch` setting | Not set, defaults to `"main"` | Root cause confirmed |

## Resolution

- **Root cause:** Test configurations omit `github_branch`, inheriting the default value `"main"`. The test repo `OttawaCloudConsulting/terraform-test` has no `main` branch — only `master` and `s3-bucket`. CLAUDE.md documents the correct branch as `s3-bucket`.
- **Fix:** Add `github_branch = "s3-bucket"` to both `tests/default/main.tf` and `tests/default-dev-destroy/main.tf`, then re-apply and re-trigger.
- **Prevention:** Test configs should always explicitly set `github_branch` rather than relying on the default, since the test repo branch differs from the module default.
