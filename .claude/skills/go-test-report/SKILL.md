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
