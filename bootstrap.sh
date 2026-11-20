#!/usr/bin/env bash
# ============================================================================
# bootstrap-testing.sh
#
# One-command, fully self-contained setup for the entire testing infrastructure
# on any Go microservice repository. Creates all skills, scripts, workflows,
# CODEOWNERS, composite actions, and installs git hooks.
#
# WHAT IT SETS UP:
#   .claude/skills/go-unit-test/     — Claude Code skill for auto-generating tests
#   .claude/skills/go-test-report/   — Claude Code skill for HTML/PDF reports
#   .claude/skills/pr-description/   — Claude Code skill for PR descriptions
#   .git/hooks/pre-push              — Pre-push hook (11 quality checks)
#   tests/reports/                    — Test reports directory
#
# TEST FILE CONVENTION:
#   Tests are colocated with source files (standard Go convention):
#     internal/config/config.go  →  internal/config/config_test.go
#     models/types.go            →  models/types_test.go
#   Reports go in tests/reports/ (separate folder)
#
# SAFETY:
#   - Will NOT run on main, master, or development branches
#   - Will NOT overwrite existing files (use --force to override)
#   - Will NOT modify any source code
#
# USAGE:
#   bash bootstrap.sh [--force]
#
# ============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
SKIP="${YELLOW}⊘${NC}"

# ── Parse args ───────────────────────────────────────────────────────────────
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)  FORCE=true; shift ;;
        -h|--help)
            echo "Usage: bash bootstrap.sh [--force]"
            echo ""
            echo "Options:"
            echo "  --force              Overwrite existing files"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# ── Detect repo root ────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo -e "${FAIL}  Not inside a git repository. Run this from a git repo."
    exit 1
}

cd "$REPO_ROOT"

echo ""
echo -e "  ${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}  BOOTSTRAP TESTING INFRASTRUCTURE${NC}"
echo -e "  ${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

# ── Branch guard — refuse to run on main, master, or development ────────────
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" || "$CURRENT_BRANCH" == "development" ]]; then
    echo -e "  ${FAIL}  ${RED}Cannot run on '${CURRENT_BRANCH}' branch${NC}"
    echo ""
    echo -e "  This script modifies project infrastructure files and should"
    echo -e "  be run on a feature branch, then merged via PR."
    echo ""
    echo -e "  ${DIM}Create a feature branch first:${NC}"
    echo -e "    git checkout -b feat/add-testing-infra"
    echo ""
    exit 1
fi

echo -e "  ${PASS}  Branch: ${CYAN}${CURRENT_BRANCH}${NC} (not protected)"

# ── Verify this is a Go project ─────────────────────────────────────────────
if [ ! -f "go.mod" ]; then
    echo -e "  ${FAIL}  ${RED}No go.mod found — this doesn't appear to be a Go project${NC}"
    exit 1
fi

MODULE=$(head -1 go.mod | awk '{print $2}')
echo -e "  ${PASS}  Go module: ${CYAN}${MODULE}${NC}"

# ── Helper: write file safely ────────────────────────────────────────────────
FILES_CREATED=0
FILES_SKIPPED=0

write_file() {
    local filepath="$1"

    if [ -f "$filepath" ] && [ "$FORCE" = false ]; then
        echo -e "  ${SKIP}  ${filepath} ${DIM}(exists — use --force to overwrite)${NC}"
        FILES_SKIPPED=$((FILES_SKIPPED + 1))
        return 1
    fi

    mkdir -p "$(dirname "$filepath")"
    FILES_CREATED=$((FILES_CREATED + 1))
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CREATE ALL FILES — fully self-contained
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "  ${BOLD}── Claude Code Skills ──${NC}"

# ── File 1: .claude/skills/go-unit-test/SKILL.md ────────────────────────────
if write_file ".claude/skills/go-unit-test/SKILL.md"; then
    cat > ".claude/skills/go-unit-test/SKILL.md" << 'SKILL_GOTEST_EOF'
---
name: go-unit-test
description: Analyze any Go microservice source code and documentation, auto-discover module path and directory structure, generate colocated unit tests (same directory as source, standard Go convention), detect changes via git diff, run tests, and report results. Fully portable — works on any Go project without modification.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent
version: 4.0.0
compatibility: Claude Opus 4.5+, Claude Code v2.x
updated: 2026-09-21
---

# Go Unit Test — Colocated, Diff-Aware Test Generator

Works on **any Go microservice** without modification. Tests are placed
**in the same directory as the source file** — standard Go convention.
Reports go in `tests/reports/`. Source code is **NEVER modified**.

## CRITICAL RULES

- **Tests live next to source**: `internal/config/config.go` → `internal/config/config_test.go`
- **NEVER create a separate `tests/unit/` directory** for test files.
- **Reports only** go in `tests/reports/` (HTML report, coverage).
- Tests use **external test packages** (e.g., `package config_test`).
- **NEVER modify existing source files** — only create/edit `*_test.go` files.
- Skip `cmd/` entry points — not unit testable.

## When to Apply

- User asks to test new or changed Go code
- User invokes `/go-unit-test`
- After any feature or bugfix commit that lacks corresponding tests
- Called from pre-push hook via `claude -p`

---

## Phase 0 — Auto-Discover Project Context

### Step 0.1 — Read module path from go.mod

```bash
MODULE=$(head -1 go.mod | awk '{print $2}')
```

### Step 0.2 — Discover all Go source directories

```bash
find . -name "*.go" ! -name "*_test.go" ! -path "*/vendor/*" \
  ! -path "*/.git/*" ! -path "*/cmd/*" \
  | sed 's|/[^/]*$||' | sort -u
```

### Step 0.3 — Read project documentation

Read in priority order: README.md, CLAUDE.md, changelog/*.md, docs/*.md
Extract domain knowledge for better test case design.

---

## Phase 1 — Detect Changed Code

### Step 1.1 — Resolve the diff base

```bash
BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || git merge-base HEAD development 2>/dev/null || echo "")
```

If no base found, scan ALL source files.

### Step 1.2 — Extract changed Go files

```bash
git diff --name-only --diff-filter=ACMR "$BASE" HEAD -- '*.go' \
  | grep -v '_test.go$' \
  | grep -v '/vendor/' \
  | grep -v '.pb.go$' \
  | grep -v '^cmd/'
```

### Step 1.3 — Detect ALL change scenarios

#### Scenario A: Source file ADDED — no test exists

```bash
git diff --name-only --diff-filter=A "$BASE" HEAD -- '*.go' \
  | grep -v '_test.go$' | grep -v '^cmd/'
```
**Action**: Create `<same_dir>/<basename>_test.go`.

#### Scenario B: Source file MODIFIED — test not updated

Check if the corresponding `_test.go` in the same dir was also changed.
If NOT → stale. **Action**: Add new test functions for new/changed exports.

#### Scenario C: Test function REMOVED

```bash
git diff "$BASE" HEAD -- '*_test.go' | grep -E '^\-func Test' | grep -v '^\-\-\-'
```
**Action**: Restore removed test functions if source function still exists.

#### Scenario D: Test file DELETED

```bash
git diff --name-only --diff-filter=D "$BASE" HEAD -- '*_test.go'
```
**Action**: Recreate from source.

#### Scenario E: Source file DELETED

**Action**: Flag orphaned test file. Do NOT auto-delete.

---

## Phase 2 — Analyze Source Code

For each source file, read and understand:

1. **Package name** — tests use `package <name>_test` (external black-box).
2. **Exported API** — only exported functions/types/methods are testable.
3. **Function signatures** — input types, return types, error returns.
4. **Dependencies** — classify by testability:

| Category | Test Strategy |
|---|---|
| Pure logic (helpers, validators, parsers) | Direct table-driven tests |
| Exported struct methods (no I/O) | Construct struct, call method |
| Exported constructors | Call constructor, verify result |
| File-based functions | Use `t.TempDir()` with fixture files |
| Heavy I/O (DB, NATS, HTTP, AWS) | Skip, flag for integration test |
| Unexported functions | Cannot test from external package — skip |

---

## Phase 3 — Generate Colocated Tests

### Source-to-test mapping

Tests go in the **same directory** as the source file:

```
Source file                          Test file (same dir)
─────────────────────────────────────────────────────────
models/types.go                   → models/types_test.go
internal/config/config.go         → internal/config/config_test.go
internal/utils/log.go             → internal/utils/log_test.go
internal/services/execution.go    → internal/services/execution_test.go
internal/api/handlers/check.go    → internal/api/handlers/check_test.go
internal/repository/filter.go     → internal/repository/filter_test.go
cmd/server/main.go                → SKIP (entry point)
```

### Package declaration

```go
package <package_name>_test
```

### Import pattern

```go
import (
    "testing"
    "<MODULE>/<package_import_path>"
)
```

Example for `internal/config/config.go` (package `config`):
- Test file: `internal/config/config_test.go`
- Package: `package config_test`
- Import: `"github.com/mydbopsllp/mydbxmysqlqx/internal/config"`

### Test structure — table-driven pattern

```go
func TestFunctionName(t *testing.T) {
    cases := []struct {
        name    string
        // inputs
        // expected outputs
        wantErr bool
    }{
        {"descriptive case name", /* inputs */, /* expected */, false},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got := pkg.FunctionName(tc.input)
            if got != tc.want {
                t.Errorf("FunctionName(%v) = %v, want %v", tc.input, got, tc.want)
            }
        })
    }
}
```

### Edge cases to always cover

- Zero/nil values: empty strings, nil slices, nil maps, zero ints
- Boundary values: max/min, single element slices
- Error paths: invalid input that triggers errors
- Happy path: normal expected usage

---

## Phase 3.5 — Scan Filesystem to Detect All Issues

```bash
MODULE=$(head -1 go.mod | awk '{print $2}')
BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD development 2>/dev/null || echo "")

# All source files (excluding cmd/, vendor, generated)
find . -name "*.go" ! -name "*_test.go" ! -path "*/vendor/*" \
  ! -path "*/.git/*" ! -path "*/cmd/*" ! -name "*.pb.go" | sort

# All existing test files (colocated)
find . -name "*_test.go" ! -path "*/vendor/*" ! -path "*/.git/*" | sort

# Git changes
git diff --name-status "$BASE" HEAD
git diff "$BASE" HEAD -- '*_test.go' | grep -E '^\-func Test' | grep -v '^\-\-\-'
git diff --name-only --diff-filter=D "$BASE" HEAD -- '*_test.go'
```

| Scenario | Detection |
|---|---|
| Source has no test | `source.go` exists but `source_test.go` missing in same dir |
| Test not updated | Source in `git diff`, its `_test.go` NOT in `git diff` |
| Test function removed | `git diff` shows `-func Test*` |
| Test file deleted | `git diff --diff-filter=D` on `*_test.go` |

---

## Phase 4 — Run Tests and Report

```bash
go test -v -count=1 ./...
```

With coverage:
```bash
go test -v -count=1 -coverprofile=tests/reports/coverage.out -covermode=atomic ./...
go tool cover -func=tests/reports/coverage.out
```

---

## Phase 5 — Report

```
## Go Unit Test Report

### Project
- Module: <from go.mod>
- Branch: <current branch>
- Base: <merge-base commit>

### Tests Generated/Updated
| File | Action | Tests | Status |
|---|---|---|---|
| internal/config/config_test.go | CREATED | N | PASS/FAIL |

### Test Results
- Total: N tests
- Passed: N
- Failed: N

### Skipped — Unexported
- <list>

### Skipped — Needs Integration Test
- <list>
```

---

## Rules

1. **Colocated tests** — `foo.go` and `foo_test.go` in the same directory.
2. **NEVER create `tests/unit/`** — reports only in `tests/reports/`.
3. **External test packages** — `package <name>_test`.
4. **Table-driven tests** — `cases := []struct{...}` + `t.Run()`.
5. **No external test frameworks** — stdlib `testing` only.
6. **No mocking heavy I/O** — skip, flag for integration.
7. **Read documentation first** — README.md, CLAUDE.md.
8. **Auto-discover everything** — module path from `go.mod`, dirs from `find`.
9. **Descriptive test case names** — lowercase phrases.
10. **Use `t.Errorf` not `t.Fatalf`** — let all cases run.
11. **Use `t.TempDir()`** for file-based fixtures.
12. **No hardcoded paths** — everything derived at runtime.

---

**Last Updated:** September 21, 2026
**Compatibility:** Claude Opus 4.5+, Claude Code v2.x
**Status:** Production Ready — Colocated Tests
SKILL_GOTEST_EOF
    echo -e "  ${PASS}  .claude/skills/go-unit-test/SKILL.md"
fi

# ── File 2: .claude/skills/go-test-report/SKILL.md ──────────────────────────
if write_file ".claude/skills/go-test-report/SKILL.md"; then
    cat > ".claude/skills/go-test-report/SKILL.md" << 'SKILL_REPORT_EOF'
---
name: go-test-report
description: Run Go unit tests, read test source code to extract actual input values and expected results, generate an incremental HTML report showing raw test data in tests/reports/. Only updates changed packages.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
version: 4.0.0
compatibility: Claude Opus 4.5+, Claude Code v2.x
updated: 2026-09-21
---

# Go Test Report — Raw Test Data Report

Runs Go unit tests (colocated `*_test.go` files), reads the actual test source
code to extract real values, and produces a report in `tests/reports/`.

## When to Apply

- After `/go-unit-test` completes
- User invokes `/go-test-report`
- User asks for a "test report" or "PDF report"

---

## Phase 1 — Determine What Changed

### Step 1.1 — Check if report exists

```bash
ls tests/reports/report.html 2>/dev/null
```

If exists → incremental update (only changed packages). If not → full build.

### Step 1.2 — Find changed test files (colocated)

```bash
find . -name "*_test.go" -newer tests/reports/report.html \
  ! -path "*/vendor/*" ! -path "*/.git/*" 2>/dev/null
```

---

## Phase 2 — Run Tests

```bash
mkdir -p tests/reports
go test -v -count=1 -json ./... 2>&1 | tee tests/reports/test-results.json
```

---

## Phase 3 — Read Test Source Code and Extract Raw Data

For every `*_test.go` file (colocated with source), read and extract from
the `cases := []struct{...}{...}` table-driven structs:

1. **Test name** — subtest name string
2. **Input values** — actual Go values passed to the function
3. **Expected result** — the `want` field value
4. **Pass/Fail** — from the JSON test output

### Example

```go
// internal/config/config_test.go
func TestIsProductionMode(t *testing.T) {
    cases := []struct {
        name     string
        logLevel string
        want     bool
    }{
        {"error level", "error", true},
        {"info level", "info", false},
        {"empty string", "", false},
    }
```

Extract as:

| Test | Case | Input | Expected | Result | Status |
|---|---|---|---|---|---|
| TestIsProductionMode | error level | logLevel="error" | true | true | PASS |
| TestIsProductionMode | info level | logLevel="info" | false | false | PASS |
| TestIsProductionMode | empty string | logLevel="" | false | false | PASS |

### Rules for extraction

- Show the **actual Go values** from source, not descriptions
- Strings in quotes: `"error"`, `""`
- Booleans: `true`, `false`
- Numbers: `5`, `300`, `0`
- Structs: key fields like `Config{LogLevel: "error"}`
- Truncate very long values to 80 chars with `...`

---

## Phase 4 — Generate/Update HTML Report in tests/reports/

### Incremental update

1. If `tests/reports/report.html` exists → read it
2. Find `<div id="pkg-{name}">` for each changed package
3. Replace only those sections
4. Update summary counts and timestamp
5. Leave other sections untouched

### Summary cards structure

```html
<div class="summary-cards">
  <div class="card total"><div class="value">49</div><div class="label">Total Tests</div></div>
  <div class="card pass"><div class="value">49</div><div class="label">Passed</div></div>
  <div class="card fail"><div class="value">0</div><div class="label">Failed</div></div>
</div>
```

### Table structure per package

```html
<div id="pkg-config" class="pkg-section">
  <h3>internal/config (7 tests)</h3>
  <table class="detail-table">
    <thead>
      <tr>
        <th>Test Function</th><th>Case</th><th>Input</th>
        <th>Expected</th><th>Result</th><th>Status</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td rowspan="3"><strong>TestIsProductionMode</strong></td>
        <td>error level</td>
        <td><code>logLevel="error"</code></td>
        <td><code>true</code></td>
        <td><code>true</code></td>
        <td><span class="badge badge-pass">PASS</span></td>
      </tr>
    </tbody>
  </table>
</div>
```

### HTML must include

- Header: project name (from go.mod), branch, commit, timestamp, go version
- Summary cards: total, passed, failed
- Package summary table: package path, test count, status, duration
- Detailed tables per package with Input/Expected/Result columns
- Skipped functions section
- Footer

---

## Rules

1. **Reports go in `tests/reports/`** — never in source directories.
2. **Test files are colocated** — scan `**/*_test.go`, not `tests/unit/`.
3. **HTML only locally** — PDF conversion happens in GitHub Actions.
4. **Incremental updates** — only rebuild changed package sections.
5. **Show raw values** — actual Go values from test source code.
6. **Auto-discover project** — module path from `go.mod`.
7. **Self-contained HTML** — all CSS inline.
8. **ID every package section** — `id="pkg-{name}"` for incremental updates.

---

**Last Updated:** September 21, 2026
**Compatibility:** Claude Opus 4.5+, Claude Code v2.x
**Status:** Production Ready
SKILL_REPORT_EOF
    echo -e "  ${PASS}  .claude/skills/go-test-report/SKILL.md"
fi

# ── File 3: .claude/skills/pr-description/SKILL.md ──────────────────────────
if write_file ".claude/skills/pr-description/SKILL.md"; then
    cat > ".claude/skills/pr-description/SKILL.md" << 'SKILL_PRDESC_EOF'
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
SKILL_PRDESC_EOF
    echo -e "  ${PASS}  .claude/skills/pr-description/SKILL.md"
fi

# ── Files 4-7: PR description reference templates ───────────────────────────
mkdir -p ".claude/skills/pr-description/references"

if write_file ".claude/skills/pr-description/references/default.md"; then
    cat > ".claude/skills/pr-description/references/default.md" << 'EOF'
## Summary
<!-- What does this PR change? 1-2 sentences. -->

## What Changed

**Key changes:**
-
-

**Files modified:**
- `path/to/file.go` — what changed

## Impact

- No breaking changes / API changes / config changes
EOF
    echo -e "  ${PASS}  .claude/skills/pr-description/references/default.md"
fi

if write_file ".claude/skills/pr-description/references/feature.md"; then
    cat > ".claude/skills/pr-description/references/feature.md" << 'EOF'
## Summary
<!-- What new feature is being added? 1-2 sentences. -->

## What Changed

**Key changes:**
-
-

**Files modified:**
- `path/to/file.go` — what changed

## Impact

- No breaking changes / API changes / config changes
EOF
    echo -e "  ${PASS}  .claude/skills/pr-description/references/feature.md"
fi

if write_file ".claude/skills/pr-description/references/bugfix.md"; then
    cat > ".claude/skills/pr-description/references/bugfix.md" << 'EOF'
## Bug Description
<!-- What was the bug? -->

## What Changed

**Root cause:**

**Fix:**
-
-

**Files modified:**
- `path/to/file.go` — what changed

## Impact

- No breaking changes / affects existing behavior
EOF
    echo -e "  ${PASS}  .claude/skills/pr-description/references/bugfix.md"
fi

if write_file ".claude/skills/pr-description/references/hotfix.md"; then
    cat > ".claude/skills/pr-description/references/hotfix.md" << 'EOF'
## Issue
<!-- What production issue is this fixing? -->

## What Changed

**Root cause:**

**Fix:**
-
-

**Urgency:** <!-- Why can't this wait? -->

## Impact

- Affects existing behavior / no side effects
EOF
    echo -e "  ${PASS}  .claude/skills/pr-description/references/hotfix.md"
fi

# ── Git Hook (directly into .git/hooks/pre-push) ────────────────────────────
echo ""
echo -e "  ${BOLD}── Git Pre-Push Hook ──${NC}"

mkdir -p ".git/hooks"
if write_file ".git/hooks/pre-push"; then
    cat > ".git/hooks/pre-push" << 'SCRIPT_PREPUSH_EOF'
#!/usr/bin/env bash
# ============================================================================
# Pre-push hook — quality checks, Claude test generation, go test, PR description
#
# SKIP OPTIONS:
#   git push --no-verify          skip ALL checks
#   SKIP_VET=1                    skip go vet
#   SKIP_FMT=1                    skip gofmt
#   SKIP_STATICCHECK=1            skip staticcheck
#   SKIP_ERRCHECK=1               skip errcheck
#   SKIP_GOSEC=1                  skip gosec
#   SKIP_GOVULNCHECK=1            skip govulncheck
#   SKIP_MODTIDY=1                skip go mod tidy
#   SKIP_MISSPELL=1               skip misspell
#   SKIP_PR_DESC=1                skip PR description generation
#   SKIP_CLAUDE_TEST=1            skip Claude auto test generation
#
# NOTE: go test ALWAYS runs — cannot be skipped.
# ============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
SKIP="${YELLOW}⊘${NC}"

TOTAL_STEPS=11
STEP=0

step() {
    STEP=$((STEP + 1))
    echo -e "  ${BOLD}[${STEP}/${TOTAL_STEPS}]${NC} $1"
}

# ── Sync skip flags to unit-test.yaml ────────────────────────────────────────
WORKFLOW_FILE=".github/workflows/unit-test.yaml"

sync_workflow_var() {
    local var_name="$1"
    local skip_env="$2"
    local value="true"
    if [ "${!skip_env:-0}" = "1" ]; then
        value="false"
    fi
    if [ -f "$WORKFLOW_FILE" ] && grep -q "  ${var_name}:" "$WORKFLOW_FILE" 2>/dev/null; then
        sed -i.bak "s|  ${var_name}: \".*\"|  ${var_name}: \"${value}\"|" "$WORKFLOW_FILE"
        rm -f "${WORKFLOW_FILE}.bak"
    fi
}

sync_workflow_var "VET_CHECK" "SKIP_VET"
sync_workflow_var "FMT_CHECK" "SKIP_FMT"
sync_workflow_var "STATICCHECK" "SKIP_STATICCHECK"
sync_workflow_var "ERRCHECK" "SKIP_ERRCHECK"
sync_workflow_var "GOSEC" "SKIP_GOSEC"
sync_workflow_var "GOVULNCHECK" "SKIP_GOVULNCHECK"
sync_workflow_var "MODTIDY" "SKIP_MODTIDY"
sync_workflow_var "MISSPELL" "SKIP_MISSPELL"
sync_workflow_var "TEST_CHECK" "SKIP_NEVER"
sync_workflow_var "REPORT_GENERATE" "SKIP_REPORT"
sync_workflow_var "PR_DESCRIPTION_UPDATE" "SKIP_PR_DESC"

if ! git diff --quiet "$WORKFLOW_FILE" 2>/dev/null; then
    git add "$WORKFLOW_FILE"
    git commit -m "ci: sync workflow check flags from pre-push" > /dev/null 2>&1
fi

echo ""
echo -e "  ${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}  PRE-PUSH QUALITY CHECKS${NC}"
echo -e "  ${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

run_simple_check() {
    local label="$1"
    local skip_var="$2"
    local cmd="$3"
    local warn_only="${4:-false}"

    step "Running ${CYAN}${label}${NC}..."

    if [ "${!skip_var:-0}" = "1" ]; then
        echo -e "       ${SKIP}  Skipped (${skip_var}=1)"
        return 0
    fi

    local tool_name
    tool_name=$(echo "$cmd" | awk '{print $1}')
    if ! command -v "$tool_name" &>/dev/null; then
        echo -e "       ${WARN}  ${tool_name} not installed — skipping"
        return 0
    fi

    local output
    output=$(eval "$cmd" 2>&1) || true

    if [ -z "$output" ]; then
        echo -e "       ${PASS}  No issues found"
    elif [ "$warn_only" = true ]; then
        local count
        count=$(echo "$output" | wc -l | tr -d ' ')
        echo -e "       ${WARN}  ${count} issues found"
    else
        echo -e "       ${FAIL}  Issues found:"
        echo "$output" | head -10 | while IFS= read -r line; do echo -e "       ${DIM}$line${NC}"; done
        local total
        total=$(echo "$output" | wc -l | tr -d ' ')
        if [ "$total" -gt 10 ]; then
            echo -e "       ${DIM}... and $((total - 10)) more${NC}"
        fi
        echo ""
        echo -e "  ${RED}${BOLD}  PUSH BLOCKED${NC} — fix ${label} errors first"
        echo -e "  ${DIM}  Bypass: ${skip_var}=1 git push${NC}"
        echo ""
        exit 1
    fi
}

# ── Auto-install tools (only if enabled and missing) ─────────────────────────
export PATH=$PATH:$(go env GOPATH)/bin

install_if_enabled() {
    local bin="$1"
    local pkg="$2"
    local enable_var="$3"
    if [ -n "$enable_var" ] && [ "${!enable_var:-0}" != "1" ]; then
        return 0
    fi
    if ! command -v "$bin" &>/dev/null; then
        echo -e "  ${DIM}  Installing ${bin}...${NC}"
        go install "${pkg}" > /dev/null 2>&1 \
            && echo -e "  ${PASS}  ${bin} installed" \
            || echo -e "  ${WARN}  Failed to install ${bin} — will skip"
    fi
}

install_if_enabled "misspell"    "github.com/client9/misspell/cmd/misspell@latest"    ""
install_if_enabled "staticcheck" "honnef.co/go/tools/cmd/staticcheck@latest"          "STATICCHECK"
install_if_enabled "errcheck"    "github.com/kisielk/errcheck@latest"                 "ERRCHECK"
install_if_enabled "gosec"       "github.com/securego/gosec/v2/cmd/gosec@latest"      "GOSEC"
install_if_enabled "govulncheck" "golang.org/x/vuln/cmd/govulncheck@latest"           "GOVULNCHECK"

# ── Helper: opt-in check (off by default, enable with VAR=1) ─────────────────
run_optin_check() {
    local label="$1"
    local enable_var="$2"
    local cmd="$3"

    step "Running ${CYAN}${label}${NC} ${DIM}(opt-in)${NC}..."

    if [ "${!enable_var:-0}" != "1" ]; then
        echo -e "       ${SKIP}  Skipped by default — enable with: ${DIM}${enable_var}=1 git push${NC}"
        return 0
    fi

    local tool_name
    tool_name=$(echo "$cmd" | awk '{print $1}')
    if ! command -v "$tool_name" &>/dev/null; then
        echo -e "       ${WARN}  ${tool_name} not installed — skipping"
        return 0
    fi

    local output
    output=$(eval "$cmd" 2>&1) || true

    if [ -z "$output" ]; then
        echo -e "       ${PASS}  No issues found"
    else
        echo -e "       ${FAIL}  Issues found:"
        echo "$output" | while IFS= read -r line; do echo -e "       ${DIM}$line${NC}"; done
        echo ""
        echo -e "  ${RED}${BOLD}  PUSH BLOCKED${NC} — fix ${label} errors first"
        echo -e "  ${DIM}  Bypass: git push --no-verify${NC}"
        echo ""
        exit 1
    fi
}

# ── Steps 1-8: Static checks ─────────────────────────────────────────────────
# ON  by default: go vet, gofmt, go mod tidy, misspell, go test
# OFF by default: staticcheck, errcheck, gosec, govulncheck (enable with VAR=1)
run_simple_check "go vet"       "SKIP_VET"         "go vet ./..."
run_simple_check "gofmt"        "SKIP_FMT"         "gofmt -d . | grep -v '^vendor/'" warn
run_optin_check  "staticcheck"  "STATICCHECK"      "staticcheck ./..."
run_optin_check  "errcheck"     "ERRCHECK"         "errcheck ./..."
run_optin_check  "gosec"        "GOSEC"            "gosec -quiet ./..."
run_optin_check  "govulncheck"  "GOVULNCHECK"      "govulncheck ./..."

# ── Step 7: go mod tidy ───────────────────────────────────────────────────────
step "Running ${CYAN}go mod tidy${NC}..."

if [ "${SKIP_MODTIDY:-0}" = "1" ]; then
    echo -e "       ${SKIP}  Skipped (SKIP_MODTIDY=1)"
else
    cp go.mod go.mod.bak
    cp go.sum go.sum.bak 2>/dev/null || true
    go mod tidy 2>/dev/null
    if ! diff -q go.mod go.mod.bak &>/dev/null || ! diff -q go.sum go.sum.bak &>/dev/null 2>/dev/null; then
        cp go.mod.bak go.mod
        cp go.sum.bak go.sum 2>/dev/null || true
        rm -f go.mod.bak go.sum.bak
        echo -e "       ${FAIL}  go.mod/go.sum are not tidy — run: go mod tidy"
        echo -e "  ${RED}${BOLD}  PUSH BLOCKED${NC}"
        echo -e "  ${DIM}  Bypass: SKIP_MODTIDY=1 git push${NC}"
        echo ""
        exit 1
    fi
    rm -f go.mod.bak go.sum.bak
    echo -e "       ${PASS}  go.mod/go.sum are tidy"
fi

step "Running ${CYAN}misspell${NC}..."
if [ "${SKIP_MISSPELL:-0}" = "1" ]; then
    echo -e "       ${SKIP}  Skipped (SKIP_MISSPELL=1)"
elif ! command -v misspell &>/dev/null; then
    echo -e "       ${WARN}  misspell not installed — skipping"
else
    MISSPELL_OUT=$(misspell -error . 2>&1) || true
    if [ -z "$MISSPELL_OUT" ]; then
        echo -e "       ${PASS}  No typos found"
    else
        COUNT=$(echo "$MISSPELL_OUT" | wc -l | tr -d ' ')
        echo -e "       ${WARN}  ${COUNT} typos found:"
        echo "$MISSPELL_OUT" | while IFS= read -r line; do echo -e "       ${DIM}$line${NC}"; done
        echo ""
        echo -e "       ${DIM}  Fix all automatically: ${CYAN}misspell -w .${NC}"
        echo ""
    fi
fi

# ── Step 9: Claude Code — colocated test generation + report ─────────────────
step "Analyzing changes with ${CYAN}Claude Code${NC}..."

if [ "${SKIP_CLAUDE_TEST:-0}" = "1" ]; then
    echo -e "       ${SKIP}  Skipped (SKIP_CLAUDE_TEST=1)"
else
    CLAUDE_BIN=$(which claude 2>/dev/null || echo "")

    if [ -z "$CLAUDE_BIN" ]; then
        echo -e "       ${WARN}  Claude Code CLI not found — skipping"
    else
        # Pre-compute what needs attention — pass to Claude so it doesn't scan everything
        _BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD development 2>/dev/null || echo "")
        _CHANGED=$(git diff --name-only --diff-filter=ACMRD "$_BASE" HEAD -- '*.go' 2>/dev/null | grep -v '_test.go$' | grep -v '^vendor/' | grep -v '^cmd/' || echo "")
        _MISSING=$(find . -name '*.go' ! -name '*_test.go' ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/cmd/*' 2>/dev/null | while read -r f; do
            t="${f%.go}_test.go"; [ ! -f "$t" ] && echo "$f"; done || echo "")
        _DELETED_TESTS=$(git diff --name-only --diff-filter=D "$_BASE" HEAD -- '*_test.go' 2>/dev/null || echo "")
        _REMOVED_FUNCS=$(git diff "$_BASE" HEAD -- '*_test.go' 2>/dev/null | grep -E '^\-func Test' | grep -v '^\-\-\-' | sed 's/^-//' || echo "")

        PROMPT="Go unit test generator. Rules: colocated tests (foo.go → foo_test.go same dir), package foo_test, table-driven, stdlib only, never modify source, reports in tests/reports/.

Pre-computed work list (do NOT re-scan everything — only act on these):

CHANGED SOURCE FILES (need test update if test exists, or create if missing):
${_CHANGED:-none}

SOURCE FILES WITH NO TEST YET (create _test.go in same dir):
${_MISSING:-none}

DELETED TEST FILES (recreate from source):
${_DELETED_TESTS:-none}

REMOVED TEST FUNCTIONS (restore if source still exists):
${_REMOVED_FUNCS:-none}

Steps:
1. For each file above: read ONLY that source file, write its _test.go in same directory.
   - Only read README.md if you need domain context for a specific function.
   - Do NOT read files not in the lists above.
2. Run: go test -count=1 ./... to verify.
3. Read .claude/skills/go-test-report/SKILL.md — update tests/reports/report.html (incremental, changed packages only).
4. If nothing to do and report is current, respond with exactly: ALL_TESTS_COVERED"

        echo ""
        echo -e "       ${DIM}─── Claude Code ───${NC}"

        RAW_LOG=$(mktemp)
        (
            "$CLAUDE_BIN" -p "$PROMPT" --dangerously-skip-permissions \
              --allowedTools "Read,Write,Bash,Glob,Grep" \
              --verbose --output-format stream-json 2>/dev/null \
              | tee "$RAW_LOG" \
              | jq -r 'if .type=="assistant" then (.message.content[]? | if .type=="tool_use" then "→ "+.name+" : "+((.input.command//.input.file_path//.input.pattern//.input.description//"")|tostring) elif .type=="text" then "  "+.text else empty end) elif .type=="result" then "✓ done ("+.subtype+")" else empty end' 2>/dev/null
        ) || echo -e "       ${WARN}  Claude Code could not run — skipping"

        echo -e "       ${DIM}─── end ───${NC}"
        echo ""

        CLAUDE_OUTPUT=$(jq -r 'select(.type=="result") | .result // empty' "$RAW_LOG" 2>/dev/null || echo "")
        rm -f "$RAW_LOG"

        if echo "$CLAUDE_OUTPUT" | grep -q "ALL_TESTS_COVERED"; then
            echo -e "       ${PASS}  All tests are up to date"
        else
            # Collect new/modified colocated test files and reports
            NEW_TEST_FILES=$(git status --porcelain 2>/dev/null \
              | grep -E '^\?\?|^ M|^A ' \
              | grep -E '_test\.go$|tests/reports/' || true)

            if [ -n "$NEW_TEST_FILES" ]; then
                echo -e "  ${BOLD}  Generated/updated files:${NC}"
                echo "$NEW_TEST_FILES" | while IFS= read -r line; do
                    echo -e "    ${CYAN}$line${NC}"
                done

                echo ""
                echo -e "  ${BOLD}What would you like to do?${NC}"
                echo -e "    ${GREEN}1)${NC} Commit and push  ${CYAN}(recommended — default)${NC}"
                echo -e "    ${RED}2)${NC} Abort push        ${RED}(review first)${NC}"
                echo ""

                exec < /dev/tty
                # flush any buffered keypresses (e.g. Enter pressed during Claude output)
                read -r -t 1 _discard < /dev/tty 2>/dev/null || true
                read -r -p "  Enter choice [1/2] (default: 1): " CHOICE
                exec <&-

                CHOICE="${CHOICE:-1}"

                if [ "$CHOICE" = "1" ]; then
                    # Stage colocated test files and report
                    git add $(git status --porcelain | grep -E '^\?\?|^ M|^A ' | grep '_test\.go$' | awk '{print $2}') 2>/dev/null || true
                    git add tests/reports/report.html 2>/dev/null || true
                    git commit -m "test: auto-generate unit tests and update report

Generated by pre-push hook via Claude Code /go-unit-test skill." > /dev/null 2>&1
                    echo -e "  ${PASS}  Tests and report committed"
                else
                    echo -e "  ${RED}  Push aborted.${NC}"
                    echo ""
                    exit 1
                fi
            fi
        fi
    fi
fi

# ── Step 10: go test — ALWAYS RUNS ───────────────────────────────────────────
step "Running ${CYAN}go test${NC} (always runs)..."

TEST_OUTPUT=$(go test -count=1 ./... 2>&1) || TEST_FAILED=true
if [ "${TEST_FAILED:-false}" = true ]; then
    echo -e "       ${FAIL}  Tests failed:"
    echo "$TEST_OUTPUT" | grep -E "^(---|\s*FAIL|.*_test\.go)" | while IFS= read -r line; do
        echo -e "       ${DIM}$line${NC}"
    done
    echo ""
    echo -e "  ${RED}${BOLD}  PUSH BLOCKED${NC} — tests failed"
    echo ""
    exit 1
else
    TEST_COUNT=$(echo "$TEST_OUTPUT" | grep -c "^ok" || true)
    echo -e "       ${PASS}  All tests passed (${TEST_COUNT} packages)"
fi

# ── Step 11: Generate PR description ─────────────────────────────────────────
step "Generating ${CYAN}PR description${NC}..."

if [ "${SKIP_PR_DESC:-0}" = "1" ]; then
    echo -e "       ${SKIP}  Skipped (SKIP_PR_DESC=1)"
else
    CLAUDE_BIN=$(which claude 2>/dev/null || echo "")

    if [ -z "$CLAUDE_BIN" ]; then
        echo -e "       ${WARN}  Claude Code CLI not found — skipping"
    else
        PR_PROMPT="Read .claude/skills/pr-description/SKILL.md first.

Then generate a PR description:
1. BASE=\$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD development 2>/dev/null)
2. Run git log, git diff --name-status, git diff --stat to understand changes
3. Read README.md for project context
4. Do NOT run go test, go vet, or gofmt.
5. Write the description to .github/pr-description.md

Must have: Summary, What Changed (key changes + files modified), Impact.
Do NOT include: Testing, Rollback Plan, test file listings. Keep it brief."

        echo ""
        echo -e "       ${DIM}─── Claude Code ───${NC}"

        RAW_LOG=$(mktemp)
        (
            "$CLAUDE_BIN" -p "$PR_PROMPT" --dangerously-skip-permissions \
              --allowedTools "Read,Write,Bash,Glob,Grep" \
              --verbose --output-format stream-json 2>/dev/null \
              | tee "$RAW_LOG" \
              | jq -r 'if .type=="assistant" then (.message.content[]? | if .type=="tool_use" then "→ "+.name+" : "+((.input.command//.input.file_path//.input.pattern//.input.description//"")|tostring) elif .type=="text" then "  "+.text else empty end) elif .type=="result" then "✓ done ("+.subtype+")" else empty end' 2>/dev/null
        ) || echo -e "       ${WARN}  Claude Code could not run — skipping"
        rm -f "$RAW_LOG"

        echo -e "       ${DIM}─── end ───${NC}"

        if [ -f ".github/pr-description.md" ]; then
            git add -f .github/pr-description.md
            git commit -m "docs: auto-generate PR description

Generated by pre-push hook via Claude Code /pr-description skill." > /dev/null 2>&1
            echo -e "       ${PASS}  PR description committed"
        else
            echo -e "       ${WARN}  PR description file not created"
        fi
    fi
fi

echo ""
echo -e "  ${BOLD}──────────────────────────────────────────────────────────${NC}"
echo -e "  ${GREEN}${BOLD}  ALL CHECKS PASSED${NC}"
echo ""
exit 0
SCRIPT_PREPUSH_EOF
    chmod +x ".git/hooks/pre-push"
    echo -e "  ${PASS}  .git/hooks/pre-push"
fi

# ── GitHub Actions ───────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}── GitHub Actions ──${NC}"

# ── .github/workflows/unit-test.yaml ─────────────────────────────────────────
if write_file ".github/workflows/unit-test.yaml"; then
    cat > ".github/workflows/unit-test.yaml" << 'WF_UNITTEST_EOF'
name: Unit Tests

env:
  VET_CHECK: "true"
  FMT_CHECK: "true"
  STATICCHECK: "true"
  ERRCHECK: "true"
  GOSEC: "true"
  GOVULNCHECK: "true"
  MODTIDY: "true"
  MISSPELL: "true"
  TEST_CHECK: "true"
  REPORT_GENERATE: "true"
  PR_DESCRIPTION_UPDATE: "true"

on:
  pull_request:
    branches:
      - main
      - development

permissions:
  contents: read
  pull-requests: write

jobs:

  # ============================================================
  # JOB 1 - GO VET
  # ============================================================
  go_vet_check:
    name: Go Vet Check
    runs-on: ubuntu-latest
    outputs:
      status: ${{ steps.vet.outputs.status }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Common Go setup
        uses: ./.github/actions/go-setup
        with:
          github-token: ${{ secrets.MYDBOPS_GITHUB_TOKEN }}

      - name: go vet
        if: env.VET_CHECK == 'true'
        id: vet
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              execSync('go vet ./...', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
              core.setOutput('status', 'passed');
              console.log('✅ No issues found');
            } catch (e) {
              core.setOutput('status', 'failed');
              core.setFailed('❌ go vet failed:\n' + (e.stderr || e.stdout || e.message).trim());
            }

  # ============================================================
  # JOB 2 - GOFMT
  # ============================================================
  go_fmt_check:
    name: Go Format Check
    runs-on: ubuntu-latest
    outputs:
      status: ${{ steps.fmt.outputs.status }}
      count: ${{ steps.fmt.outputs.count }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Common Go setup
        uses: ./.github/actions/go-setup
        with:
          github-token: ${{ secrets.MYDBOPS_GITHUB_TOKEN }}

      - name: gofmt
        if: env.FMT_CHECK == 'true'
        id: fmt
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            const output = execSync("gofmt -d . | grep -v '^vendor/' || true", { encoding: 'utf8' }).trim();
            if (output) {
              const count = output.split('\n').length;
              core.setOutput('status', 'warning');
              core.setOutput('count', count.toString());
              console.log(`⚠️ ${count} unformatted files:\n${output}`);
            } else {
              core.setOutput('status', 'passed');
              core.setOutput('count', '0');
              console.log('✅ All files formatted');
            }

  # ============================================================
  # JOB 3 - QUALITY CHECKS
  # ============================================================
  go_quality_checks:
    name: Quality Checks
    runs-on: ubuntu-latest
    outputs:
      staticcheck_status: ${{ steps.staticcheck.outputs.status }}
      errcheck_status: ${{ steps.errcheck.outputs.status }}
      gosec_status: ${{ steps.gosec.outputs.status }}
      govulncheck_status: ${{ steps.govulncheck.outputs.status }}
      modtidy_status: ${{ steps.modtidy.outputs.status }}
      misspell_status: ${{ steps.misspell.outputs.status }}
      misspell_count: ${{ steps.misspell.outputs.count }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Common Go setup
        uses: ./.github/actions/go-setup
        with:
          github-token: ${{ secrets.MYDBOPS_GITHUB_TOKEN }}

      - name: Install quality tools
        run: |
          go install honnef.co/go/tools/cmd/staticcheck@latest
          go install github.com/kisielk/errcheck@latest
          go install github.com/securego/gosec/v2/cmd/gosec@latest
          go install golang.org/x/vuln/cmd/govulncheck@latest
          go install github.com/client9/misspell/cmd/misspell@latest

      - name: staticcheck
        if: env.STATICCHECK == 'true'
        id: staticcheck
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              execSync('staticcheck ./...', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
              core.setOutput('status', 'passed');
            } catch (e) {
              core.setOutput('status', 'failed');
              core.setFailed('❌ staticcheck failed:\n' + (e.stderr || e.stdout || e.message).trim());
            }

      - name: errcheck
        if: env.ERRCHECK == 'true'
        id: errcheck
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              execSync('errcheck ./...', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
              core.setOutput('status', 'passed');
            } catch (e) {
              core.setOutput('status', 'failed');
              core.setFailed('❌ errcheck failed:\n' + (e.stderr || e.stdout || e.message).trim());
            }

      - name: gosec
        if: env.GOSEC == 'true'
        id: gosec
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              execSync('gosec -quiet ./...', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
              core.setOutput('status', 'passed');
            } catch (e) {
              core.setOutput('status', 'failed');
              core.setFailed('❌ gosec found issues:\n' + (e.stderr || e.stdout || e.message).trim());
            }

      - name: govulncheck
        if: env.GOVULNCHECK == 'true'
        id: govulncheck
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              execSync('govulncheck ./...', { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
              core.setOutput('status', 'passed');
            } catch (e) {
              core.setOutput('status', 'failed');
              core.setFailed('❌ Vulnerabilities found:\n' + (e.stderr || e.stdout || e.message).trim());
            }

      - name: go mod tidy
        if: env.MODTIDY == 'true'
        id: modtidy
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            const fs = require('fs');
            const modBefore = fs.readFileSync('go.mod', 'utf8');
            const sumBefore = fs.existsSync('go.sum') ? fs.readFileSync('go.sum', 'utf8') : '';
            execSync('go mod tidy', { encoding: 'utf8' });
            const modAfter = fs.readFileSync('go.mod', 'utf8');
            const sumAfter = fs.existsSync('go.sum') ? fs.readFileSync('go.sum', 'utf8') : '';
            if (modBefore !== modAfter || sumBefore !== sumAfter) {
              core.setOutput('status', 'dirty');
              core.setFailed('❌ go.mod/go.sum not tidy — run: go mod tidy');
            } else {
              core.setOutput('status', 'clean');
              console.log('✅ go.mod/go.sum are tidy');
            }

      - name: misspell
        if: env.MISSPELL == 'true'
        id: misspell
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            try {
              const output = execSync('misspell .', { encoding: 'utf8' }).trim();
              if (output) {
                const count = output.split('\n').length;
                core.setOutput('status', 'warning');
                core.setOutput('count', count.toString());
                console.log(`⚠️ ${count} typos:\n${output}`);
              } else {
                core.setOutput('status', 'passed');
                core.setOutput('count', '0');
              }
            } catch (e) {
              core.setOutput('status', 'passed');
              core.setOutput('count', '0');
            }

  # ============================================================
  # JOB 4 - GO TEST (always runs, uses colocated tests)
  # ============================================================
  go_test_check:
    name: Go Test Check
    runs-on: ubuntu-latest
    outputs:
      total: ${{ steps.test.outputs.total }}
      passed: ${{ steps.test.outputs.passed }}
      failed: ${{ steps.test.outputs.failed }}
      pkgs: ${{ steps.test.outputs.pkgs }}
      exit_code: ${{ steps.test.outputs.exit }}
      pkg_results: ${{ steps.test.outputs.pkg_results }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Common Go setup
        uses: ./.github/actions/go-setup
        with:
          github-token: ${{ secrets.MYDBOPS_GITHUB_TOKEN }}

      - name: go test
        id: test
        uses: actions/github-script@v7
        with:
          script: |
            const { execSync } = require('child_process');
            const fs = require('fs');
            execSync('mkdir -p tests/reports');
            let output = '';
            let exitCode = 0;
            try {
              output = execSync('go test -v -count=1 ./... 2>&1', { encoding: 'utf8' });
            } catch (e) {
              output = e.stdout || '';
              exitCode = e.status || 1;
            }
            fs.writeFileSync('tests/reports/test-output.txt', output);
            const total = (output.match(/^--- PASS|^--- FAIL/gm) || []).length;
            const passed = (output.match(/^--- PASS/gm) || []).length;
            const failed = (output.match(/^--- FAIL/gm) || []).length;
            const pkgs = (output.match(/^ok /gm) || []).length;
            const pkgResults = output.split('\n').filter(l => l.startsWith('ok ') || l.startsWith('FAIL')).join('\n');
            core.setOutput('total', total.toString());
            core.setOutput('passed', passed.toString());
            core.setOutput('failed', failed.toString());
            core.setOutput('pkgs', pkgs.toString());
            core.setOutput('exit', exitCode.toString());
            core.setOutput('pkg_results', pkgResults);
            if (failed > 0) {
              core.setFailed(`❌ ${failed}/${total} tests failed`);
            } else {
              console.log(`✅ ${total} tests passed (${pkgs} packages)`);
            }

  # ============================================================
  # JOB 5 - REPORT GENERATION
  # ============================================================
  go_test_report_generation:
    name: Generate Test Report
    runs-on: ubuntu-latest
    needs: go_test_check
    if: always()
    steps:
      - name: Checkout code
        if: env.REPORT_GENERATE == 'true'
        uses: actions/checkout@v4

      - name: Update report test counts
        if: env.REPORT_GENERATE == 'true'
        env:
          CI_TOTAL: ${{ needs.go_test_check.outputs.total }}
          CI_PASSED: ${{ needs.go_test_check.outputs.passed }}
          CI_FAILED: ${{ needs.go_test_check.outputs.failed }}
        run: |
          if [ ! -f tests/reports/report.html ]; then
            echo "⚠️ tests/reports/report.html not found — skipping"
            exit 0
          fi
          python3 << 'PYEOF'
          import re, os
          total = os.environ.get('CI_TOTAL', '0')
          passed = os.environ.get('CI_PASSED', '0')
          failed = os.environ.get('CI_FAILED', '0')
          html = open('tests/reports/report.html').read()
          html = re.sub(r'(<div class="(?:value|number)">)\d+(</div>\s*<div class="label">Total Tests)', rf'\g<1>{total}\2', html)
          html = re.sub(r'(<div class="card pass">\s*<div class="(?:value|number)">)\d+(</div>\s*<div class="label">Passed)', rf'\g<1>{passed}\2', html)
          html = re.sub(r'(<div class="card fail">\s*<div class="(?:value|number)">)\d+(</div>\s*<div class="label">Failed)', rf'\g<1>{failed}\2', html)
          open('tests/reports/report.html', 'w').write(html)
          print(f'Updated: total={total} passed={passed} failed={failed}')
          PYEOF

      - name: Convert HTML to PDF
        if: env.REPORT_GENERATE == 'true'
        run: |
          if [ -f tests/reports/report.html ]; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq wkhtmltopdf > /dev/null 2>&1
            wkhtmltopdf --page-size A4 --margin-top 15 --margin-bottom 15 \
              --margin-left 15 --margin-right 15 \
              tests/reports/report.html tests/reports/report.pdf || true
          fi

      - name: Upload PDF report
        if: env.REPORT_GENERATE == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: unit-test-report
          path: tests/reports/report.pdf
          retention-days: 30
          if-no-files-found: ignore

  # ============================================================
  # JOB 6 - UPDATE PR DESCRIPTION
  # ============================================================
  go_update_pr_description:
    name: Update PR Description
    runs-on: ubuntu-latest
    needs:
      - go_vet_check
      - go_fmt_check
      - go_quality_checks
      - go_test_check
      - go_test_report_generation
    if: always()
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Update PR description
        if: env.PR_DESCRIPTION_UPDATE == 'true'
        uses: actions/github-script@v7
        env:
          VET_STATUS: ${{ needs.go_vet_check.outputs.status }}
          FMT_STATUS: ${{ needs.go_fmt_check.outputs.status }}
          FMT_COUNT: ${{ needs.go_fmt_check.outputs.count }}
          STATICCHECK_STATUS: ${{ needs.go_quality_checks.outputs.staticcheck_status }}
          ERRCHECK_STATUS: ${{ needs.go_quality_checks.outputs.errcheck_status }}
          GOSEC_STATUS: ${{ needs.go_quality_checks.outputs.gosec_status }}
          GOVULNCHECK_STATUS: ${{ needs.go_quality_checks.outputs.govulncheck_status }}
          MODTIDY_STATUS: ${{ needs.go_quality_checks.outputs.modtidy_status }}
          MISSPELL_STATUS: ${{ needs.go_quality_checks.outputs.misspell_status }}
          MISSPELL_COUNT: ${{ needs.go_quality_checks.outputs.misspell_count }}
          TEST_TOTAL: ${{ needs.go_test_check.outputs.total }}
          TEST_PASSED: ${{ needs.go_test_check.outputs.passed }}
          TEST_FAILED: ${{ needs.go_test_check.outputs.failed }}
          TEST_PKGS: ${{ needs.go_test_check.outputs.pkgs }}
          TEST_EXIT: ${{ needs.go_test_check.outputs.exit_code }}
          PKG_RESULTS: ${{ needs.go_test_check.outputs.pkg_results }}
        with:
          script: |
            const fs = require('fs');
            const e = process.env;
            const url = `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
            const ok = e.TEST_FAILED === '0' && e.TEST_EXIT === '0';

            let prDesc = '';
            try {
              prDesc = fs.readFileSync('.github/pr-description.md', 'utf8');
            } catch (err) {
              prDesc = '*No PR description generated.*';
            }

            const checks = [
              { name: 'go vet',       status: e.VET_STATUS,          type: 'pass_fail' },
              { name: 'gofmt',        status: e.FMT_STATUS,          count: e.FMT_COUNT,      type: 'warn_count', unit: 'files' },
              { name: 'staticcheck',  status: e.STATICCHECK_STATUS,  type: 'pass_fail' },
              { name: 'errcheck',     status: e.ERRCHECK_STATUS,     type: 'pass_fail' },
              { name: 'gosec',        status: e.GOSEC_STATUS,        type: 'pass_fail' },
              { name: 'govulncheck',  status: e.GOVULNCHECK_STATUS,  type: 'pass_fail' },
              { name: 'go mod tidy',  status: e.MODTIDY_STATUS,      type: 'clean_dirty' },
              { name: 'misspell',     status: e.MISSPELL_STATUS,     count: e.MISSPELL_COUNT, type: 'warn_count', unit: 'typos' },
            ];

            let body = prDesc + '\n\n---\n\n## CI Results\n\n';
            body += `| Check | Result |\n|---|---|\n`;

            for (const c of checks) {
              if (!c.status) {
                body += `| ${c.name} | ⏭ skipped |\n`;
              } else if (c.type === 'pass_fail') {
                body += `| ${c.name} | ${c.status === 'passed' ? '✅ passed' : '❌ failed'} |\n`;
              } else if (c.type === 'clean_dirty') {
                body += `| ${c.name} | ${c.status === 'clean' ? '✅ clean' : '❌ dirty'} |\n`;
              } else if (c.type === 'warn_count') {
                body += `| ${c.name} | ${c.status === 'passed' ? '✅ passed' : '⚠️ ' + (c.count||'0') + ' ' + c.unit} |\n`;
              }
            }
            body += `| unit tests | ${ok ? '✅' : '❌'} ${e.TEST_PASSED||'0'}/${e.TEST_TOTAL||'0'} passed (${e.TEST_PKGS||'0'} packages) |\n\n`;

            if ((e.TEST_TOTAL||'0') !== '0') {
              body += `### Test Summary\n\n| Metric | Value |\n|---|---|\n`;
              body += `| Total | ${e.TEST_TOTAL} |\n| Passed | ${e.TEST_PASSED} |\n| Failed | ${e.TEST_FAILED} |\n| Packages | ${e.TEST_PKGS} |\n\n`;
            }

            const pkgResults = e.PKG_RESULTS || '';
            if (pkgResults.trim()) {
              body += `<details><summary>Package details</summary>\n\n\`\`\`\n${pkgResults.trim()}\n\`\`\`\n</details>\n\n`;
            }

            body += `📄 [Download test report (PDF)](${url})\n\n`;
            body += `---\n*PR description by Claude Code • CI by unit-test workflow*\n`;

            await github.rest.pulls.update({
              owner: context.repo.owner,
              repo: context.repo.repo,
              pull_number: context.issue.number,
              body: body,
            });
            console.log('✅ PR description updated');
WF_UNITTEST_EOF
    echo -e "  ${PASS}  .github/workflows/unit-test.yaml"
fi

# ── .github/actions/go-setup/action.yml ──────────────────────────────────────
if write_file ".github/actions/go-setup/action.yml"; then
    cat > ".github/actions/go-setup/action.yml" << 'ACTION_GOSETUP_EOF'
name: Common Go Setup
description: Setup Go and configure private repo access

inputs:
  github-token:
    description: GitHub token for private repo access
    required: true

runs:
  using: composite
  steps:
    - name: Setup Go
      uses: actions/setup-go@v5
      with:
        go-version-file: go.mod

    - name: Configure private repo access
      shell: bash
      run: git config --global url."https://${{ inputs.github-token }}@github.com/".insteadOf "https://github.com/"
ACTION_GOSETUP_EOF
    echo -e "  ${PASS}  .github/actions/go-setup/action.yml"
fi

# ── Create directories ───────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}── Directories ──${NC}"

if [ ! -d "tests/reports" ]; then
    mkdir -p "tests/reports"
    echo -e "  ${PASS}  Created tests/reports/"
else
    echo -e "  ${SKIP}  tests/reports/ ${DIM}(exists)${NC}"
fi

# ── Update .gitignore ────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}── Git Ignore ──${NC}"

GITIGNORE_ENTRIES=(
    "tests/reports/test-output.txt"
    "tests/reports/test-results.json"
    "tests/reports/report.pdf"
    "tests/coverage.out"
    "tests/reports/coverage.out"
)

ADDED_ENTRIES=0
for entry in "${GITIGNORE_ENTRIES[@]}"; do
    if ! grep -qF "$entry" .gitignore 2>/dev/null; then
        echo "$entry" >> .gitignore
        ADDED_ENTRIES=$((ADDED_ENTRIES + 1))
    fi
done

if [ "$ADDED_ENTRIES" -gt 0 ]; then
    echo -e "  ${PASS}  Added ${ADDED_ENTRIES} entries to .gitignore"
else
    echo -e "  ${SKIP}  .gitignore ${DIM}(already up to date)${NC}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}${BOLD}  BOOTSTRAP COMPLETE${NC}"
echo ""
echo -e "  ${BOLD}Created:${NC} ${FILES_CREATED} files"
echo -e "  ${BOLD}Skipped:${NC} ${FILES_SKIPPED} files (already exist)"
echo ""
echo -e "  ${BOLD}Test convention:${NC}"
echo -e "    ${CYAN}internal/config/config.go${NC}  →  ${CYAN}internal/config/config_test.go${NC}"
echo -e "    ${DIM}Reports → tests/reports/report.html${NC}"
echo ""
echo -e "  ${BOLD}Pre-push hook behaviour:${NC}"
echo -e "    ${GREEN}ON  by default:${NC}  go vet, gofmt, go mod tidy, misspell,"
echo -e "                      Claude auto test generation, go test, PR description"
echo -e "    ${YELLOW}OFF by default:${NC}  staticcheck, errcheck, gosec, govulncheck"
echo ""
echo -e "  ${BOLD}Usage:${NC}"
echo -e "    git push                          normal push"
echo -e "    GOSEC=1 git push                  + run gosec"
echo -e "    STATICCHECK=1 git push            + run staticcheck"
echo -e "    ERRCHECK=1 git push               + run errcheck"
echo -e "    GOVULNCHECK=1 git push            + run govulncheck"
echo -e "    GOSEC=1 STATICCHECK=1 ERRCHECK=1 GOVULNCHECK=1 git push  run all"
echo -e "    SKIP_CLAUDE_TEST=1 git push       skip Claude test generation"
echo -e "    SKIP_VET=1 git push               skip go vet"
echo -e "    SKIP_PR_DESC=1 git push           skip PR description"
echo -e "    git push --no-verify              skip ALL checks"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. Run ${CYAN}claude /go-unit-test${NC} to generate initial tests"
echo -e "    2. Commit and push — the pre-push hook runs automatically"
echo ""
echo -e "  ${BOLD}Usage on another repo:${NC}"
echo -e "    bash bootstrap.sh"
echo ""
