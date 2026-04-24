---
name: super-smoke-test
description: >
  Post-execution QA gate for phased AI development workflows (GSD, Superpowers,
  any phased build). Runs AFTER `/gsd-execute-phase` completes — execute-phase
  is NOT part of this skill. Orchestrates, in order: (1) `/gsd-code-review` +
  `/gsd-code-review-fix --auto`, (2) regression gate (tsc + build + lint),
  (3) `/codex:review` + apply fixes, (4) regression gate again, (5) parse GSD
  phase artifacts (PLAN.md / SUMMARY.md) to derive UAT scenarios per
  requirement, (6) wire auth bypass via smoke-test-auth-bypass skill, (7)
  generate + run a Playwright spec file headlessly with DOM + dimension +
  console + network asserts, (8) DB assertions via Supabase MCP for mutation
  scenarios, (9) auto-fix loop + regression gate, (10) conditional
  `/gsd-verify-work` — only if user-facing surface changed (routes, components,
  middleware, server actions), skipped for pure infra / API / migration
  phases, (11) `/gsd-extract_learnings` to persist phase decisions. Trigger on:
  "smoke test", "run tests", "QA this", "verify the build", phase completion.
  A build is not done until this gate passes. Invoke manually after any
  execute-phase that produced frontend or API changes.
---

# Super Smoke Test — Post-Execution QA Gate

Automated UAT-level QA pipeline. Exercises what was built, not just "does the
page load". Catches CSS collapses, missing hrefs, broken Server Actions, RLS
issues, and regressions introduced by auto-fixes.

**The phase is not complete until this gate passes.**

> **This skill runs AFTER `/gsd-execute-phase`. Execute is not part of the gate
> — run it yourself first, then invoke this.**

## Pipeline

```
Execute phase complete
  │
  ▼
  Step 0:  should-trigger.sh                    → SKIP or TRIGGER
  │        (scans full phase diff)
  ▼
  Step 1:  /gsd-code-review <N>                 → REVIEW.md
  │        Claude re-reads changed source; severity-classified findings.
  ▼
  Step 2:  /gsd-code-review-fix <N> --auto      (only if findings exist)
  │        Auto-fix loop applies fixes, commits each atomically.
  ▼
  Step 3:  regression-gate.sh                   (tsc + lint + build)
  │        BLOCK on regression, no auto-revert.
  ▼
  Step 4:  /codex:review  ← ALWAYS runs         → external-LLM (Codex) findings
  │        Second-opinion review from a different model.
  ▼
  Step 5:  Apply Codex fixes                    (Critical + High + easy Medium)
  ▼
  Step 6:  regression-gate.sh                   (tsc + lint + build)
  ▼
  Step 7:  parse-gsd-artifacts.sh               → UAT scenarios per requirement ID
  ▼
  Step 8:  Wire auth bypass                     via smoke-test-auth-bypass skill
  ▼
  Step 9:  generate-spec.sh + Playwright        (headless, serial, persistent ctx)
  │        DOM + dimension + console + network asserts + screenshots.
  ▼
  Step 10: DB assertions                        via mcp__supabase__execute_sql
  │        For every mutation scenario.
  ▼
  Step 11: Auto-fix failures (max 3)            → regression gate → re-run spec
  ▼
  Step 12: should-verify.sh                     → VERIFY or SKIP
  │        VERIFY → auto-invoke /gsd-verify-work <N> (conversational UAT)
  │        SKIP → note in report (pure infra / API / migration phase)
  ▼
  Step 13: /gsd-extract_learnings <N>           (always, if GSD project)
  │        Persist decisions, surprises, patterns to phase artifact.
  ▼
  Step 14: Report
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
HEAD~10. Not limited to HEAD~1 (which silently skipped multi-commit phases).

If SKIP → tell user "No frontend or API impact — QA gate skipped." Exit.
If TRIGGER → proceed.

---

## Step 1: /gsd-code-review (skip if not a GSD project)

Claude re-reads changed files in context and produces a severity-classified
`REVIEW.md`. This is the **internal-Claude** review — different from Codex's
external-LLM review in Step 4. Running both gives you two-LLM coverage.

```
Skill({ skill: "gsd-code-review", args: "<phase-number>" })
```

If `.planning/` doesn't exist (non-GSD project), skip to Step 4 (`/codex:review`).
Codex still runs; Claude self-review only runs when phase context is available.

After completion, parse `REVIEW.md` frontmatter:
- `status: clean` → no findings, go to Step 3 (regression gate, still run it
  in case the review edited something).
- `status: findings` → proceed to Step 2 (auto-fix).

---

## Step 2: /gsd-code-review-fix --auto (only if findings)

Apply fixes from `REVIEW.md` atomically — one commit per finding.

```
Skill({ skill: "gsd-code-review-fix", args: "<phase-number> --auto" })
```

Writes `REVIEW-FIX.md` summary. If any fix is flagged "needs-review" rather
than auto-applied, report it in the final summary and continue — don't block.

---

## Step 3: Regression gate (after Claude fixes)

```bash
bash <skill_dir>/scripts/regression-gate.sh "$(pwd)"
```

Runs `tsc --noEmit` (or `npm run typecheck`), `npm run lint`, `npm run build`.

- Pass → proceed to Step 4.
- Fail → **BLOCK**. Report the regression. Do NOT auto-revert. User decides.

Set `SKIP_BUILD_GATE=1` to skip the build step (slow on some projects).

---

## Step 4: /codex:review (always)

Second-opinion review from the external Codex CLI (different model from Claude
— usually GPT-5 under the hood). Catches things Claude's self-review missed.

Run unconditionally. No `which codex` gate.

```
/codex:review --wait
```

Wait for results. Read every finding. Categorize by severity.

---

## Step 5: Apply Codex fixes

Fix Critical and High findings. Fix Medium where straightforward. Note Low in
the report.

---

## Step 6: Regression gate (after Codex fixes)

Same script as Step 3. Rerun because Codex fixes may have broken something.

```bash
bash <skill_dir>/scripts/regression-gate.sh "$(pwd)"
```

Single pass — no codex re-review loop. Move on to smoke tests.

---

## Step 7: Parse GSD phase artifacts

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

## Step 8: Wire auth bypass

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

## Step 9: Generate spec + run headless

### 9a: Ensure dev server running

```bash
bash <skill_dir>/scripts/detect-server.sh "$(pwd)" "${PORT:-}"
```

Must have `SMOKE_TEST_BYPASS=true` in its env. If the server was already
running without the env var, restart it.

### 9b: Generate Playwright spec

```bash
bash <skill_dir>/scripts/generate-spec.sh \
  .playwright-cli/scenarios.json \
  "http://localhost:${PORT}" \
  tests/smoke/super-smoke.spec.ts
```

### 9c: Run headless

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

## Step 10: DB assertions

For scenarios with `db_assert.enabled = true`:

```
mcp__supabase__execute_sql with:
  SELECT count(*) FROM <table> WHERE <where clause from db_assert>
```

Assert row count ≥ `expect_row_count_gte`. If the spec passed but DB is empty,
that's a regression (commonly: Server Action silently failing, RLS blocking,
or trigger race on dependent row).

---

## Step 11: Auto-fix loop

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

Apply fix → re-run regression gate (Step 3) → re-run failed scenarios only.
Max `max_fix_attempts` (default 3).

See `references/common-failures.md` for extended diagnostics.

---

## Step 12: Conditional /gsd-verify-work

```bash
bash <skill_dir>/scripts/should-verify.sh
```

Stricter heuristic than `should-trigger.sh`. Only VERIFIES if the phase diff
includes user-facing surface:

- `page.tsx` / `layout.tsx` / `loading.tsx` / `error.tsx` / `not-found.tsx`
- `src/components/` or `components/`
- `middleware.ts`
- Server actions (`src/actions/`, `app/actions/`, `actions.ts`)

SKIPS if phase only touched API routes, lib/, tools/, types/, migrations,
config, docs, assets, or global CSS. A human has nothing to click-through
for those — automated smoke + DB asserts are sufficient.

**If VERIFY:**
```
Skill({ skill: "gsd-verify-work", args: "<phase-number>" })
```

**If SKIP:** note in report — "verify-work skipped: pure {infra|api|migration}
phase with no user-facing surface."

---

## Step 13: /gsd-extract_learnings (always, if GSD project)

Persist decisions, surprises, and patterns from the phase to durable artifact.
Cheap to run (~30s) and the "why did we do X in P3?" insurance policy for
later phases.

```
Skill({ skill: "gsd-extract_learnings", args: "<phase-number>" })
```

Skip if `.planning/` doesn't exist (non-GSD project).

---

## Step 14: Report

```
## QA Gate Results — {phase name}

### Code Review (Claude — gsd-code-review)
Status: PASS (N findings auto-fixed, M needs-review)
Findings:
- [summary per finding]

### Code Review (External — Codex)
Status: PASS (N findings fixed)
Findings fixed:
- [summary per finding]

### Regression Gate
Post-Claude-fix:  tsc ✅   lint ✅   build ✅
Post-Codex-fix:   tsc ✅   lint ✅   build ✅
Post-smoke-fix:   tsc ✅   lint ✅   build ✅

### Smoke Test
Phase: {phase_dir}
Requirements exercised: LEAG-01, LEAG-02, PICK-01, ...
Scenarios: X/Y passed

| ID | Scenario | Status | DB Assert | Fix Applied |
|----|----------|--------|-----------|-------------|
| LEAG-01 | create league | ✅ | ✅ row in bc_leagues | — |
| PICK-01 | submit pick | ✅ | ✅ row in bc_picks | auth helper |

Screenshots: test-results/smoke/

### Verify-Work
Status: VERIFY triggered → /gsd-verify-work invoked (conversational UAT below)
  — OR —
Status: SKIP (pure infra phase, no user-facing surface)

### Learnings
Extracted → .planning/phases/{phase}/LEARNINGS.md
```

---

## Rules

1. **Mandatory gate.** Phase incomplete without it.
2. **Execute-phase is NOT part of this skill.** Run `/gsd-execute-phase` yourself first.
3. **Two-LLM review.** `/gsd-code-review` (Claude) AND `/codex:review` (external) both run.
4. **Regression gate blocks after each fix pass, never auto-reverts.** User decides.
5. **Scenarios derived from PLAN.md/SUMMARY.md**, not just git diff.
6. **Dimension asserts are mandatory** on any container scenario.
7. **DB assertions for every mutation scenario** when Supabase MCP is available.
8. **Headless only.** Playwright Test, not the interactive CLI.
9. **Serial execution.** No test parallelism — state leaks break debuggability.
10. **`/gsd-verify-work` is conditional**, gated by `should-verify.sh`. Do not force on pure infra phases.
11. **`/gsd-extract_learnings` always runs** when `.planning/` exists.

---

## Fallback: no GSD artifacts

If `.planning/current/` doesn't exist (non-GSD project):
- Skip Step 1 (`/gsd-code-review`) and Step 13 (`/gsd-extract_learnings`).
- Step 12 (`should-verify.sh`) still works — it's git-diff-based.
- Step 7 (requirement parsing) falls back to `derive-routes.sh` + page-load-only smoke tests.

## Fallback: no Playwright Test installed

Offer to install: `npm i -D @playwright/test && npx playwright install chromium`.
If user declines, degrade to curl-based HTTP status checks via
`derive-routes.sh`. Flag clearly: "Visual + interaction verification skipped —
install @playwright/test for full coverage."

## What this still won't catch

Pixel-level visual regressions, performance (LCP/CLS), cross-browser quirks,
mobile breakpoints, RLS permission edge cases (row exists ≠ RLS correct),
Server Action race conditions, third-party API failures, empty-state vs
data-state divergence. `/gsd-verify-work` covers the human-judgment gaps —
which is why Step 12 auto-invokes it for any user-facing phase.
