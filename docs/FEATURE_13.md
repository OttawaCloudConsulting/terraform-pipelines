# Feature 13 — PR Review: Repo Hygiene

## Summary

Updated `.gitignore` to exclude Terraform plan outputs, provider lock files, and Claude Code local settings that were appearing as untracked files in `git status`.

## Files Changed

| File | Change |
|------|--------|
| `.gitignore` | Added entries for `*.tfplan`, `*.tfplan.*`, `tfplan.binary`, `tfplan.json`, `.terraform.lock.hcl`, `.claude/settings.local.json` |

## Validation

- Plan: 0 to add, 0 to change, 0 to destroy (no infrastructure changes)
- `git status` confirms `.terraform.lock.hcl` files in `examples/` and `tests/e2e/` are no longer shown
- `git status` confirms `tfplan.binary` and `tfplan.json` in `tests/e2e/` are no longer shown

## Verification

```bash
# Verify untracked terraform artifacts no longer appear
git status
# Expected: no .terraform.lock.hcl, tfplan.binary, or tfplan.json in untracked files
```
