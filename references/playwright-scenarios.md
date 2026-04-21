# Playwright Scenario Patterns

This skill generates a single `*.spec.ts` file from a scenarios JSON array. Each
scenario exercises one requirement end-to-end: navigate → (fill/click) → assert
DOM + dimensions → (optionally) verify DB state via Supabase MCP.

## Scenario shape

```json
{
  "id": "LEAG-01",
  "name": "user creates a league from dashboard",
  "route": "/dashboard/leagues/new",
  "needs_auth": true,
  "min_dimensions": {
    "selector": "[data-testid=league-form]",
    "min_width": 300,
    "min_height": 200
  },
  "steps": [
    { "action": "fill",         "selector": "input[name=name]", "value": "Smoke League" },
    { "action": "click",        "selector": "button[type=submit]" },
    { "action": "waitFor",      "selector": "text=League created" },
    { "action": "expectVisible","selector": "[data-testid=league-card]" }
  ],
  "db_assert": {
    "enabled": true,
    "table": "bc_leagues",
    "where": { "name": "Smoke League" },
    "expect_row_count_gte": 1
  }
}
```

## Supported step actions
- `fill` — fill an input with a value
- `click` — click an element
- `waitFor` — wait for selector to appear (10s timeout)
- `expectVisible` — assert the element is visible
- `expectText` — assert element contains text (`value` field)

## How to derive scenarios from PLAN.md

For each requirement ID (e.g. `LEAG-01`) extracted by `parse-gsd-artifacts.sh`:

1. Read the requirement's acceptance criteria from PLAN.md.
2. Identify the primary route the user interacts with.
3. Identify the primary user action (create/update/delete/view).
4. Build a minimal happy-path click-through that fulfills the acceptance criteria.
5. Add dimension assertions on the most important visual container (card, form, dashboard).
6. If the action mutates data, set `db_assert.enabled = true` and record the table + where clause.

## DB assertions via Supabase MCP

The spec file itself does NOT query the DB — the spec runs in a separate node
process and has no MCP access. Instead, after `npx playwright test` completes:

1. Skill reads `test-results/smoke/` to find passing scenarios with `db_assert`.
2. For each, skill calls `mcp__supabase__execute_sql` with the where clause.
3. Asserts row count ≥ `expect_row_count_gte`.
4. Failure here = smoke test regression even if playwright passed.

## Dimension assertions catch CSS bugs

Always add `min_dimensions` for scenarios that render a primary container.
Catches regressions like `max-w-md` collapsing to 16px — the page loads, but the
card is 64px wide and the test still passed under the old skill.

## Keep the spec lean

One spec file, one describe block, serial mode. Don't parallelize — state
(auth cookies, DB rows) leaks between scenarios and makes failures impossible to
debug. Serial + single browser context = reproducible runs.
