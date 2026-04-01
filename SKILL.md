---
name: super-smoke-test
description: >
  Post-execution QA gate for phased AI development workflows. This skill runs
  automatically after any execution phase (GSD, Superpowers, or any phased build)
  that produces frontend or API changes. It orchestrates: (1) code review via
  Codex if installed, (2) fix all review findings, (3) browser smoke testing via
  Playwright CLI, (4) fix all runtime failures. The execution phase is NOT complete
  until this skill's QA gate passes. Trigger on: "smoke test", "run tests", "QA this",
  "verify the build", phase completion, or any indication that code was just built
  and needs verification. If you just finished building something and are about to
  say "done" — STOP and run this skill first. The QA Gate Enforcer (command-based Stop hook) triggers this
  automatically but if you see it was skipped, invoke it manually.
---

# QA Gate — Post-Execution Quality Verification

Automated QA pipeline that runs after any execution phase in phased AI development.
Ensures code review + browser verification pass before declaring work complete.

**This skill is the final phase of any execution plan.** A build is not done until
the QA gate passes. This is not a suggestion — it is a mandatory gate.

## Pipeline Overview

```
Execution Phase Completes
        │
   should-trigger.sh → SKIP or TRIGGER
        │
      TRIGGER
        │
   ┌─ Codex installed? ─── NO ──→ Skip to Step 3
   │
  YES
   │
   Step 1: /codex:review → wait for results
   Step 2: Fix everything Codex flagged
   │
   ▼
   Step 3: Smoke Test (Playwright CLI)
     ├─ Verify auth bypass wired
     ├─ Derive test routes from git diff
     ├─ Navigate each route, screenshot, check console + network
     ├─ Auto-fix failures (up to 3 attempts)
   │
   ▼
   Step 4: Report combined results
   │
   ▼
   ONLY NOW say "done"
```

## Prerequisites

- `@playwright/cli` installed globally (`npm install -g @playwright/cli`)
- Playwright browsers installed (`playwright-cli install-browser`)
- Git available in the project
- (Optional) Codex CLI installed and authenticated (`npm install -g @openai/codex`)

## Step 0: Should This Run?

Before doing anything, check if the changes warrant a QA gate.

```bash
bash <skill_dir>/scripts/should-trigger.sh
```

**TRIGGER** if any of these changed: page/layout/route files, components, middleware,
styling, `package.json`, lib/hooks/utils/providers/context directories.

**SKIP** if ONLY these changed: docs, test files, config, migrations, scripts,
CI/CD files. Tell the user: "No frontend or API impact — QA gate skipped."

If ambiguous, TRIGGER to be safe.

---

## Step 1: Code Review (Codex)

**Skip this step if Codex CLI is not installed.** Check:
```bash
which codex > /dev/null 2>&1 && echo "AVAILABLE" || echo "NOT_INSTALLED"
```

If available:
```bash
/codex:review
```

Wait for the review to complete. Do NOT proceed to Step 2 until results are in.
Read every finding. Categorize by severity.

If Codex is not available, log "Code review skipped — Codex not installed" and
proceed directly to Step 3.

---

## Step 2: Fix Review Findings

Address every issue Codex flagged:

- **Critical/High:** Fix immediately. These are bugs, security issues, or logic errors.
- **Medium:** Fix if the fix is straightforward. Flag if it requires architectural changes.
- **Low/Style:** Fix if trivial, otherwise note in the report.

After fixes are applied, verify with a quick re-check:
```bash
/codex:review --base HEAD~1
```

If significant new issues appear, fix and re-check again (max 2 iterations).
Then proceed to Step 3.

---

## Step 3: Browser Smoke Test (Playwright CLI)

### 3a: Load or Create Project Config

Check for `smoke-test.config.json` in the project root.

If it does NOT exist, create it by inspecting the project:
1. Check `package.json` for framework (next, vite, remix)
2. Check for auth provider (Clerk, NextAuth, Supabase Auth, none)
3. Detect route directory structure
4. Write config from template at `<skill_dir>/templates/smoke-test.config.json`

Config structure:
```json
{
  "framework": "nextjs",
  "port": null,
  "auth": {
    "type": "clerk",
    "bypass_cookie": "__dev_bypass",
    "bypass_value": "1",
    "middleware_path": "src/middleware.ts",
    "auth_helper_path": "src/lib/supabase/server.ts",
    "auth_function": "getAuthUserId",
    "dev_user_id": "DEV_BYPASS_USER_ID"
  },
  "base_routes": ["/", "/dashboard"],
  "route_dir": "src/app",
  "protected_prefixes": ["/dashboard", "/admin", "/settings", "/account"],
  "ignore_console": ["Download the React DevTools", "Clerk:"],
  "ignore_network": [],
  "max_fix_attempts": 3
}
```

### 3b: Verify Auth Bypass

**Skip if `auth.type` is `"none"`.**

Read the actual files and confirm bypass patterns exist:

1. **Middleware** (`auth.middleware_path`): dev cookie check runs BEFORE auth middleware
2. **Auth helper** (`auth.auth_helper_path`): returns mock user when cookie is set
3. **API routes**: no direct `auth()` calls — all use the bypass-aware helper

If anything is missing, wire it. See `references/auth-patterns.md` for provider-specific
patterns (Clerk, NextAuth, Supabase Auth, custom JWT).

### 3c: Ensure Dev Server Is Running

```bash
bash <skill_dir>/scripts/detect-server.sh "$(pwd)" "${PORT:-}"
```

Follow the script's recommendation (start, use available port, or proceed if running).
Wait for the server to respond (max 30s). If `Cannot find module` errors: `rm -rf .next`
and restart.

### 3d: Derive Test Routes

```bash
bash <skill_dir>/scripts/derive-routes.sh "$(pwd)"
```

Maps changed files to browser-navigable routes via git diff. Combines with
`base_routes` from config. Outputs JSON test matrix.

### 3e: Execute Tests

For EACH route in the test matrix:

```bash
# Open browser
playwright-cli open http://localhost:${PORT} --headless

# Set auth bypass cookie (if route needs auth)
playwright-cli execute "document.cookie = '__dev_bypass=1; path=/'"

# Navigate to target route
playwright-cli navigate http://localhost:${PORT}${ROUTE}

# Wait for hydration
sleep 3

# Verify — all results go to disk, minimal context usage
playwright-cli snapshot      # → .playwright-cli/*.yaml
playwright-cli screenshot    # → .playwright-cli/*.png
playwright-cli console       # check for errors
playwright-cli network       # check for 4xx/5xx

# Clean up between routes
playwright-cli close
```

For each route, record: PASS, FAIL, or WARN with details.

### 3f: Auto-Fix Loop

If ANY test fails:

| Failure Pattern | Auto-Fix |
|---|---|
| 401/500 on API route | Switch `auth()` to bypass-aware helper |
| `Cannot find module` | `rm -rf .next`, restart server |
| Redirect to /sign-in | Wire auth bypass for this route |
| Hydration mismatch | Fix nested elements or client/server divergence |
| Blank page | Check data fetching, verify API calls |
| `crypto.randomUUID` error | Add HTTP fallback |
| Network 500 | Read API route code, fix the error |

Apply fix → re-run ONLY failed tests → repeat up to `max_fix_attempts` (default 3).

For detailed diagnostics: `references/common-failures.md`

---

## Step 4: Report

After all gates pass (or max attempts exhausted):

```
## QA Gate Results — [Phase/Feature Name]

### Code Review (Codex)
Status: ✅ Passed (3 findings fixed) | ⬜ Skipped (not installed)
Findings fixed:
- [list of what Codex found and what was fixed]

### Smoke Test (Playwright CLI)
Server: localhost:{port}
Auth Bypass: ✅ Wired | ⬜ Not needed
Tests: X/Y passed

| Route | Status | Notes |
|-------|--------|-------|
| / | ✅ PASS | |
| /dashboard | ✅ PASS | |
| /dashboard/activity | ✅ PASS | Fixed: API route auth |

Fixes Applied:
- [list of smoke test fixes]

Screenshots: .playwright-cli/
```

**ONLY after this report is presented should you declare the phase complete.**

---

## Rules

1. **This is a mandatory gate, not a suggestion.** The phase is incomplete without it.
2. **Sequential execution:** Codex review → fix → smoke test → fix. Never parallel.
3. **Auth bypass is verified every time.** Not assumed. Read the files.
4. **Screenshots are mandatory.** They're proof of verification.
5. **Fix and re-test.** Don't just report failures — fix them.
6. **Framework noise is filtered.** React DevTools warnings, Clerk logs, etc.
   are excluded via `ignore_console` in config.

## Fallback: No Playwright CLI

If `playwright-cli` is not installed:
```bash
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -b "__dev_bypass=1" http://localhost:$PORT$ROUTE)
```
Catches server errors but NOT client-side rendering issues.
Flag: "Visual verification skipped — install Playwright CLI for full coverage."
