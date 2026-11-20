---
name: pr-description
description: Auto-generate a PR description by analyzing git diff, commit history, and project docs. Saves to .github/pr-description.md which gets committed and pushed. Used by the pre-push hook.
allowed-tools: Read, Write, Bash, Glob, Grep
version: 2.0.0
compatibility: Claude Opus 4.5+, Claude Code v2.x
updated: 2026-09-21
---

# PR Description Generator

Analyzes the branch changes and generates a concise, human-readable PR
description that explains what changed, why, and what impact it has.

## When to Apply

- Called from pre-push hook via `claude -p`
- User invokes `/pr-description`

---

## Phase 1 — Gather Data

### Step 1.1 — Get branch and diff info

```bash
MODULE=$(head -1 go.mod | awk '{print $2}')
BRANCH=$(git branch --show-current)
BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD development 2>/dev/null)

git log --oneline "$BASE"..HEAD
git diff --name-status "$BASE" HEAD
git diff --stat "$BASE" HEAD | tail -1
git diff --name-only "$BASE" HEAD -- '*.go' | grep -v '_test.go'
```

### Step 1.2 — Read commit messages

```bash
git log --format='%s' "$BASE"..HEAD
```

From commit messages, determine the PR type:
- `feat:` → feature → read `.claude/skills/pr-description/references/feature.md`
- `fix:` → bugfix → read `.claude/skills/pr-description/references/bugfix.md`
- hotfix/urgent → read `.claude/skills/pr-description/references/hotfix.md`
- mixed/default → read `.claude/skills/pr-description/references/default.md`

### Step 1.3 — Read project docs for context

Read README.md to understand the project domain.

---

## Phase 2 — Generate Description

Write the PR description to `.github/pr-description.md`.

### For regular PRs

```markdown
## Summary

<1-2 sentences: what this PR does>

## What Changed

**Key changes:**
- <change 1>
- <change 2>

**Files modified:**
- `path/to/file.go` — <what changed>

## Impact

<Breaking changes, new APIs, config changes, or "No breaking changes.">
```

### What NOT to include

- No Rollback Plan, No Testing section, No test file listings
- No "What reviewers should check", No filler, No CI/workflow mentions

---

## Phase 3 — Save

Write to `.github/pr-description.md`. The pre-push hook commits it.
The GitHub Actions workflow reads it and appends CI results.

---

## Rules

1. **Do NOT run tests** — CI handles that.
2. **Read the actual diff** — don't guess what changed.
3. **Keep it short** — reviewers skim, not read.
4. **Save to `.github/pr-description.md`**.

---

**Last Updated:** September 21, 2026
**Status:** Production Ready
