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
