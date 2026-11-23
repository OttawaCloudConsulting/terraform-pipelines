---
name: investigate
description: Run a structured investigation into a failure or unexpected behavior whose cause is not yet known. Use when asked to investigate an issue, find a root cause, or debug a failure, or when the user says "investigate this" or "find the root cause". Skip it for errors with an obvious cause and fix.
---

# investigate

Use this skill to find the root cause of a problem you do not yet understand.
Keep a written record as you go. Separate what you have verified from what you
only suspect, and test competing explanations instead of chasing the first one.

## 1. Define the problem

Get these from the user or from the evidence. Ask only for what you cannot find.

- **Symptom.** The exact error message or behavior.
- **Where.** The file, command, pipeline stage, account, or service.
- **When.** What changed just before it started: a commit, deploy, or config edit.

## 2. Open the investigation directory

Investigations live in `agents/` at the root of the repository being
investigated, one directory per investigation.

1. Look in `agents/` first. Continue an existing investigation only if its
   Status is `Active` or `Unresolved` and both the symptom and the context
   (account, environment, pipeline stage, service) match. If a matching record
   is `Resolved`, read it for context, then start a new investigation that
   links to it.
2. Otherwise pick a short kebab-case slug, such as `plan-artifact-missing` or
   `cross-account-access-denied`. If `agents/<slug>/` is already taken, choose
   another slug.
3. Create `agents/<slug>/investigation.md` from the template below.

Save supporting material in the same directory: log excerpts, command output,
screenshots, scratch scripts. Give each file a name that says what it is, such
as `codebuild-plan-dev.log`. Save scratch Terraform as `.tf.txt`, because the
repository's validation runs `terraform fmt -check -recursive` over everything.

### What not to save

Everything in `agents/<slug>/` can end up in someone's hands, so treat every
file there, including `investigation.md`, as shareable.

- Never save state files, saved plan files (`tfplan`), plan JSON
  (`terraform show -json`), environment dumps, or credentials of any kind.
- Redact secrets, tokens, passwords, and private keys from anything you save,
  including `terraform plan` output, AWS command output, and screenshots. If a
  screenshot cannot be redacted, do not save it. Save excerpts, not whole dumps.
- `agents/` is git-ignored. Commit a record only if the user asks, with
  `git add -f`.

### Template

```markdown
# Investigation: <title>

- **Created:** YYYY-MM-DD
- **Status:** Active
- **Symptom:** <exact error or behavior>
- **Context:** <account, environment, pipeline stage, service, as applicable>

## Facts

Verified observations only. Each one cites its evidence.

- <observation>. Evidence: <file:line, command and output, or file in this directory>

## Hypotheses

Aim for at least three competing explanations. If fewer are plausible, say why.

1. **<name>.** <explanation>
   - For: <evidence that supports it>
   - Against: <evidence that contradicts it>
   - Test: <how to confirm or rule it out>

## Tests

| # | Action | Expected | Actual | Conclusion |
|---|--------|----------|--------|------------|

## Resolution

- **Root cause:**
- **Fix:** <what changed, or the recommended fix if nothing was changed>
- **Prevention:**
```

## 3. Investigate

1. Read the evidence first: error output, logs, source, and recent changes.
2. Prefer read-only checks. Test one hypothesis at a time and change one thing
   per test.
3. Record every test in the table, including the ones that rule something out.
4. Update the file as you learn. Move a confirmed hypothesis into Facts. Mark a
   disproven one as ruled out and name the test that ruled it out.
5. Before you accept the last hypothesis standing, look for alternatives you
   have not considered.

Ask the user before anything that writes to AWS or to a git remote, in any
account including DEV. That covers `terraform apply` or `destroy`;
`terraform plan` against the real backend, which takes the S3 state lock;
`terraform force-unlock` and `terraform state rm`, `mv`, or `push`; starting a
pipeline or CodeBuild run; IAM changes; `git push`; and
`bash tests/test-terraform.sh --deploy`.

## 4. Close

Fill in Resolution and set Status to one of:

- `Resolved`: the root cause is confirmed by evidence.
- `Unresolved`: you stopped without confirming it. Record what you ruled out
  and the next test you would run.

Then tell the user:

```text
INVESTIGATION <RESOLVED|UNRESOLVED>: <title>
Root cause: <one sentence, or "not confirmed">
Fix: <what changed, or the recommended fix; for Unresolved, the next test>
Prevention: <how to avoid it next time, if known>
Record: agents/<slug>/investigation.md
```

If the lesson is likely to recur and is not obvious from the code, suggest a
line for `AGENTS.md`. Do not edit `AGENTS.md` without the user's approval.

## Rules

- A fact needs evidence. "I think" belongs under Hypotheses.
- Keep several hypotheses alive while several remain plausible.
- Ruling something out is progress. Record it.
- Do not guess a root cause. If unsure, say so and name the next test.
- Cite sources: file paths with line numbers, exact error text, command output.
