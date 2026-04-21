---
name: super-smoke-test
description: >
  Post-execution QA gate for phased AI development workflows (GSD, Superpowers,
  any phased build). Orchestrates: (1) /codex:review — always runs, no install
  check, (2) apply fixes + regression gate (tsc + build + lint, blocks on
  regression), (3) parse GSD phase artifacts (PLAN.md / SUMMARY.md) to derive
  UAT scenarios per requirement, (4) wire auth bypass via smoke-test-auth-bypass
  skill, (5) generate + run a Playwright spec file headlessly with click-through
  flows + DOM dimension asserts + console/network checks, (6) DB assertions via
  Supabase MCP after mutations, (7) auto-invoke /gsd-verify-work on pass.
  Trigger on: "smoke test", "run tests", "QA this", "verify the build", phase
  completion. A build is not done until this gate passes. Invoke manually after
  any execution phase that produced frontend or API changes.
---

# Super Smoke Test — Post-Execution QA Gate

Automated UAT-level QA pipeline. Exercises what was built, not just "does the
page load". Catches CSS collapses, missing hrefs, broken Server Actions, RLS
issues, and regressions introduced by auto-fixes.

**The phase is not complete until this gate passes.**

## Pipeline

```
Execution phase complete
  │
  ▼
  Step 0: should-trigger.sh → SKIP or TRIGGER
  │ (scans full phase diff, not HEAD~1)
  ▼
  Step 1: /codex:review  ← ALWAYS runs (no install check)
  ▼
  Step 2: Apply fixes → regression-gate.sh
  │ (tsc + build + lint; BLOCK on regression, no auto-revert)
  ▼
  Step 3: parse-gsd-artifacts.sh → UAT scenarios per requirement ID
  ▼
  Step 4: Wire auth bypass via smoke-test-auth-bypass skill
  ▼
  Step 5: generate-spec.sh → npx playwright test (headless)
  │ DOM + dimension + console + network asserts, screenshots
  ▼
  Step 6: DB assertions for mutation scenarios via mcp__supabase__execute_sql
  ▼
  Step 7: Auto-fix failures (max 3) → re-run regression gate → re-run spec
  ▼
  Step 8: Report → auto-invoke /gsd-verify-work
```

## Prerequisites

- `@playwright/test` installed in the project (`npm i -D @playwright/test` + `npx playwright install chromium`)
- Git available
- Dev server startable (`detect-server.sh` handles this)
- Supabase MCP available if the project uses Supabase (for DB assertions)

---

## Step 0: Should this run?

```bash
bash <skill_dir>/scripts/should-trigger.sh
```

Scans the **full phase diff** — merge-base with main/master, falling back to
HEAD~10. No longer limited to HEAD~1 (which silently skipped multi-commit
phases).

If SKIP → tell user "No frontend or API impact — QA gate skipped." Exit.
If TRIGGER → proceed.

---

## Step 1: /codex:review (always)

Run unconditionally. No `which codex` gate.

```
/codex:review --wait
```

Wait for results. Read every finding. Categorize by severity.

---

## Step 2: Apply fixes + regression gate

Fix Critical and High findings. Fix Medium where straightforward. Note Low in
the report.

After fixes:

```bash
bash <skill_dir>/scripts/regression-gate.sh "$(pwd)"
```

Runs `tsc --noEmit` (or `npm run typecheck`), `npm run lint`, `npm run build`.

- Pass → proceed.
- Fail → **BLOCK**. Report the regression. Do NOT auto-revert. User decides.

Set `SKIP_BUILD_GATE=1` to skip the build step (slow on some projects).

Single pass — no codex re-review loop. Move on to smoke tests.

---

## Step 3: Parse GSD phase artifacts

```bash
bash <skill_dir>/scripts/parse-gsd-artifacts.sh "$(pwd)"
```

Reads `.planning/current/SUMMARY.md` and `PLAN.md`. Extracts requirement IDs
from frontmatter (`requirements-completed: [LEAG-01, PICK-01, ...]`) or by
scanning for patterns like `ABCD-NN`.

Returns JSON with `{id, description, acceptance}` per requirement.

**If no GSD artifacts found:** fall back to `derive-routes.sh` (git-diff-based
route derivation) and run page-load smoke tests on derived routes.

**For each requirement**, derive a concrete scenario:
- Primary route (from description / acceptance criteria)
- Primary user action (create/update/delete/view)
- Happy-path click-through that fulfills acceptance criteria
- `min_dimensions` on the primary visual container
- `db_assert` if action contains mutation keyword (see config)

See `references/playwright-scenarios.md` for the scenario shape and action
vocabulary. Write the derived scenarios JSON to `.playwright-cli/scenarios.json`.

---

## Step 4: Wire auth bypass

Detect auth provider from `package.json` + middleware files (Clerk, NextAuth,
Supabase Auth). If detected, invoke the `smoke-test-auth-bypass` skill:

```
Skill({ skill: "smoke-test-auth-bypass" })
```

Verify after invocation:
1. Middleware has `SMOKE_TEST_BYPASS` env-gated bypass
2. Auth helper returns mock user when bypass cookie is set
3. API routes use the bypass-aware helper (no raw `auth()` calls)

Read the files to confirm — don't assume the skill succeeded.

**If Supabase with RLS:** ensure a dev user row exists in `bc_profiles` (or
equivalent) seeded via a SQL migration or a `seed_profile_sql` entry in config.
Without it, protected reads return zero rows even with bypass wired.

Set `SMOKE_TEST_BYPASS=true` before starting the dev server.

---

## Step 5: Generate spec + run headless

### 5a: Ensure dev server running

```bash
bash <skill_dir>/scripts/detect-server.sh "$(pwd)" "${PORT:-}"
```

Must have `SMOKE_TEST_BYPASS=true` in its env. If the server was already
running without the env var, restart it.

### 5b: Generate Playwright spec

```bash
bash <skill_dir>/scripts/generate-spec.sh \
  .playwright-cli/scenarios.json \
  "http://localhost:${PORT}" \
  tests/smoke/super-smoke.spec.ts
```

### 5c: Run headless

```bash
npx playwright test tests/smoke/super-smoke.spec.ts --reporter=line
```

Spec runs serial in a persistent browser context, auth cookie set per
scenario. Asserts:
- Response < 400
- Primary container matches `min_dimensions` (catches CSS collapse bugs)
- Each step completes (fill/click/waitFor/expectVisible/expectText)
- Console clean of errors (after `ignore_console` filter)
- Screenshot saved to `test-results/smoke/{id}.png`

---

## Step 6: DB assertions

For scenarios with `db_assert.enabled = true`:

```
mcp__supabase__execute_sql with:
  SELECT count(*) FROM <table> WHERE <where clause from db_assert>
```

Assert row count ≥ `expect_row_count_gte`. If the spec passed but DB is empty,
that's a regression (commonly: Server Action silently failing, RLS blocking,
or trigger race on dependent row).

---

## Step 7: Auto-fix loop

For every failure — Playwright or DB assertion:

| Failure | Fix |
|---|---|
| 401/500 on API route | Auth helper not using bypass — patch it |
| Dimension check fails | CSS bug — inspect the element, fix tailwind/style |
| `Cannot find module` | `rm -rf .next` + restart |
| Redirect to /sign-in | Bypass not wired for this route group |
| Hydration mismatch | Client/server divergence in the component |
| `crypto.randomUUID` error | Non-HTTPS dev context; add fallback |
| DB row missing | Inspect Server Action + RLS + trigger chain |

Apply fix → re-run regression gate (Step 2) → re-run failed scenarios only.
Max `max_fix_attempts` (default 3).

See `references/common-failures.md` for extended diagnostics.

---

## Step 8: Report + hand off to verify-work

```
## QA Gate Results — {phase name}

### Code Review (Codex)
Status: PASS (N findings fixed)
Findings fixed:
- [summary per finding]

### Regression Gate
tsc: ✅   lint: ✅   build: ✅

### Smoke Test
Phase: {phase_dir}
Requirements exercised: LEAG-01, LEAG-02, PICK-01, ...
Scenarios: X/Y passed

| ID | Scenario | Status | DB Assert | Fix Applied |
|----|----------|--------|-----------|-------------|
| LEAG-01 | create league | ✅ | ✅ row in bc_leagues | — |
| PICK-01 | submit pick | ✅ | ✅ row in bc_picks | auth helper |

Screenshots: test-results/smoke/
```

**Then auto-invoke `/gsd-verify-work`** for conversational human UAT. This is
the handoff from automated gate to human validation.

---

## Rules

1. **Mandatory gate.** Phase incomplete without it.
2. **Codex always runs.** No install check.
3. **Regression gate blocks, never auto-reverts.** User decides.
4. **Scenarios derived from PLAN.md/SUMMARY.md**, not just git diff.
5. **Dimension asserts are mandatory** on any container scenario.
6. **DB assertions for every mutation scenario** when Supabase MCP is
   available.
7. **Headless only.** We use Playwright Test, not the interactive CLI.
8. **Serial execution.** No test parallelism — state leaks break debuggability.

---

## Fallback: no GSD artifacts

If `.planning/current/` doesn't exist (non-GSD project), skip Step 3's
requirement parsing. Use `derive-routes.sh` + `base_routes` from config to
build page-load scenarios only. Dimension asserts still apply. DB assertions
skip unless the user manually supplies a scenarios JSON.

## Fallback: no Playwright Test installed

Offer to install: `npm i -D @playwright/test && npx playwright install chromium`.
If user declines, degrade to curl-based HTTP status checks via
`derive-routes.sh`. Flag clearly: "Visual + interaction verification skipped —
install @playwright/test for full coverage."

## What this still won't catch

Pixel-level visual regressions, performance (LCP/CLS), cross-browser quirks,
mobile breakpoints, RLS permission edge cases (row exists ≠ RLS correct),
Server Action race conditions, third-party API failures, empty-state vs
data-state divergence. `/gsd-verify-work` covers the human-judgment gaps.
