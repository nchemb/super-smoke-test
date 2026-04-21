#!/bin/bash
# generate-spec.sh — Writes a single Playwright spec file exercising UAT scenarios.
# Usage: bash generate-spec.sh <scenarios_json_path> <base_url> <output_spec_path>
#
# scenarios_json format:
# [
#   {
#     "id": "LEAG-01",
#     "name": "create league",
#     "route": "/dashboard/leagues/new",
#     "needs_auth": true,
#     "min_dimensions": { "selector": "[data-testid=league-card]", "min_width": 200, "min_height": 80 },
#     "steps": [
#       { "action": "fill", "selector": "input[name=name]", "value": "Smoke League" },
#       { "action": "click", "selector": "button[type=submit]" },
#       { "action": "waitFor", "selector": "text=League created" }
#     ],
#     "db_assert": {
#       "enabled": true,
#       "description": "row exists in bc_leagues with matching name"
#     }
#   }
# ]

SCENARIOS_JSON="${1:?scenarios json required}"
BASE_URL="${2:-http://localhost:3000}"
OUTPUT="${3:-tests/smoke/super-smoke.spec.ts}"

mkdir -p "$(dirname "$OUTPUT")"

python3 - "$SCENARIOS_JSON" "$BASE_URL" "$OUTPUT" <<'PY'
import json, sys, os

scenarios_path, base_url, output = sys.argv[1], sys.argv[2], sys.argv[3]
with open(scenarios_path) as f:
    scenarios = json.load(f)

lines = []
lines.append("import { test, expect } from '@playwright/test';")
lines.append("")
lines.append(f"const BASE = {json.dumps(base_url)};")
lines.append("")
lines.append("test.describe.configure({ mode: 'serial' });")
lines.append("")

for s in scenarios:
    sid = s.get("id", "scenario")
    name = s.get("name", sid)
    route = s.get("route", "/")
    needs_auth = s.get("needs_auth", False)
    steps = s.get("steps", [])
    min_dims = s.get("min_dimensions")

    lines.append(f"test('{sid} — {name}', async ({{ page, context }}) => {{")
    if needs_auth:
        lines.append("  await context.addCookies([{ name: '__dev_bypass', value: '1', url: BASE }]);")
    lines.append(f"  const resp = await page.goto(BASE + {json.dumps(route)}, {{ waitUntil: 'networkidle' }});")
    lines.append("  expect(resp?.status()).toBeLessThan(400);")
    # Console error watcher
    lines.append("  const consoleErrors: string[] = [];")
    lines.append("  page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });")
    # Dimension assertion
    if min_dims:
        sel = min_dims.get("selector")
        mw = min_dims.get("min_width", 0)
        mh = min_dims.get("min_height", 0)
        lines.append(f"  const dimEl = page.locator({json.dumps(sel)}).first();")
        lines.append("  await expect(dimEl).toBeVisible();")
        lines.append("  const box = await dimEl.boundingBox();")
        lines.append(f"  expect(box?.width ?? 0, 'dimension check: width of {sel}').toBeGreaterThanOrEqual({mw});")
        lines.append(f"  expect(box?.height ?? 0, 'dimension check: height of {sel}').toBeGreaterThanOrEqual({mh});")
    # Steps
    for step in steps:
        action = step.get("action")
        selector = step.get("selector")
        value = step.get("value")
        if action == "fill":
            lines.append(f"  await page.locator({json.dumps(selector)}).fill({json.dumps(value)});")
        elif action == "click":
            lines.append(f"  await page.locator({json.dumps(selector)}).click();")
        elif action == "waitFor":
            lines.append(f"  await page.locator({json.dumps(selector)}).waitFor({{ timeout: 10000 }});")
        elif action == "expectVisible":
            lines.append(f"  await expect(page.locator({json.dumps(selector)})).toBeVisible();")
        elif action == "expectText":
            lines.append(f"  await expect(page.locator({json.dumps(selector)})).toContainText({json.dumps(value)});")
    # Screenshot
    safe_id = "".join(c if c.isalnum() else "_" for c in sid)
    lines.append(f"  await page.screenshot({{ path: 'test-results/smoke/{safe_id}.png', fullPage: true }});")
    # Assert no console errors (after filter)
    lines.append("  expect(consoleErrors.filter(e => !/Download the React DevTools|Clerk:/.test(e))).toEqual([]);")
    lines.append("});")
    lines.append("")

with open(output, "w") as f:
    f.write("\n".join(lines))

print(f"Wrote {len(scenarios)} scenarios to {output}")
PY
