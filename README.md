# super-smoke-test

A Claude Code skill that adds a mandatory QA gate after every AI execution phase. Code review + browser smoke testing must pass before the agent can say "done."

## The Problem

AI coding agents execute a build phase, say "done" — and when you open the browser, routes are broken, API calls fail, and console errors are everywhere. Telling the agent to "always test before presenting" in CLAUDE.md works early in a session, but under context bloat after a long execution phase, the instruction gets deprioritized or forgotten.

**super-smoke-test** solves this with a deterministic Stop hook that fires after every response, plus a structured QA pipeline the agent follows. No CLAUDE.md dependency. No relying on the LLM to remember.

## What It Does

Runs **after** `/gsd-execute-phase` completes. Execute is NOT part of this skill — you run it yourself first, then invoke this as the gate.

After any execution phase (GSD, Superpowers, or any phased build):

1. **Checks if QA is needed** — Skips for planning-only, docs, migration, or config-only phases.
2. **`/gsd-code-review` + auto-fix** — Claude re-reads changed source, produces severity-classified `REVIEW.md`, auto-applies fixes.
3. **Regression gate** — `tsc + lint + build`. Blocks on regression, never auto-reverts.
4. **`/codex:review` + fix** — Second-opinion review from an external LLM (Codex / GPT-5). Catches what Claude self-review missed.
5. **Regression gate** (again) — After Codex fixes.
6. **Playwright headless smoke** — DOM + dimension + console + network asserts + screenshots, scenarios derived from PLAN.md/SUMMARY.md requirement IDs.
7. **DB assertions via Supabase MCP** — For every mutation scenario. Catches "spec passed but nothing was written."
8. **Auto-fix loop** (max 3 attempts) — Auth bypass, stale cache, missing deps — fix and re-test.
9. **Conditional `/gsd-verify-work`** — Auto-invokes conversational UAT **only** if the phase diff includes user-facing surface (routes, components, middleware, server actions). Skipped for pure infra/API/migration phases.
10. **`/gsd-extract_learnings`** — Persists decisions, surprises, patterns for future phases.
11. **Final report** — Two-LLM review summary + smoke test pass/fail table + verify-work decision + learnings path.

The phase is **not complete** until the QA gate passes.

## Why Playwright CLI (not MCP, not Computer Use)

**Playwright CLI** writes snapshots and screenshots to disk instead of injecting them into the model's context window. Microsoft's benchmarks: ~27K tokens via CLI vs ~114K via MCP for the same task. After a heavy execution phase, your context is already full — CLI keeps QA lean.

**Computer Use** (Claude's screen control) works via screenshots and mouse movements. It's a last resort for apps with no CLI. For structured browser verification of localhost routes, Playwright CLI is faster, deterministic, and headless.

## Install

### 1. Prerequisites

```bash
npm install -g @playwright/cli
playwright-cli install-browser

# Optional: for code review step
npm install -g @openai/codex
```

### 2. Install the Skill

```bash
# Global (works across all projects)
cp -r super-smoke-test ~/.claude/skills/

# Or project-specific
cp -r super-smoke-test .claude/skills/
```

### 3. Install the Stop Hook (Required for Reliable Triggering)

The Stop hook is what makes this airtight. It fires deterministically after every Claude response and checks if a QA gate should run. Without it, you're relying on Claude to remember.

Copy the hook into your Claude Code settings. If you already have hooks, merge the `Stop` array:

```bash
# View the hook config
cat templates/stop-hook.json
```

Add to `~/.claude/settings.json` (global) or `.claude/settings.json` (project):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "BEFORE presenting your response to the user, check: did you just complete an EXECUTION phase (GSD, Superpowers, or any phased build) that produced code changes? Look for signals: you just wrote or modified multiple files, you completed a numbered phase from a plan, you're about to say 'done' or 'phase complete' or 'try it now'. If YES: run the super-smoke-test skill NOW. Do not present results until the QA gate passes. If NO (this was a planning phase, conversation, documentation, or you already ran the QA gate): proceed normally."
          }
        ]
      }
    ]
  }
}
```

### 4. First Run (Per Project)

The first time the skill runs in a project, it creates `smoke-test.config.json` with your auth provider, routes, and settings. After that, subsequent runs just verify and test.

```
> init smoke tests for this project
```

## How It Triggers

**Primary trigger (Stop hook):** Fires after every Claude response. A `type: "prompt"` hook evaluates whether an execution phase just completed. If yes, invokes the skill. If no, does nothing. This is deterministic — it fires every time, regardless of context bloat.

**Secondary trigger (manual):** You can always invoke it directly:
```
> run the QA gate
> smoke test the changes
```

**Why not CLAUDE.md?** Instructions in CLAUDE.md degrade under context bloat. After a 2-hour GSD execution with heavy code generation, Claude deprioritizes post-execution instructions. The Stop hook doesn't have this problem — it fires at the infrastructure level, not the instruction level.

## The QA Pipeline

```
/gsd-execute-phase completes  (NOT part of this skill — run yourself)
        │
        ▼
   should-trigger.sh → SKIP or TRIGGER
        │
      TRIGGER
        │
        ▼
   ┌── /gsd-code-review <N>                (Claude self-review → REVIEW.md)
   ├── /gsd-code-review-fix <N> --auto     (if findings)
   ├── regression-gate.sh                  (tsc + lint + build — BLOCK on fail)
   │
   ├── /codex:review                       (external-LLM review, second opinion)
   ├── Apply Codex fixes                   (critical → easy medium)
   ├── regression-gate.sh                  (again, after Codex fixes)
   │
   ├── parse-gsd-artifacts.sh              (PLAN.md + SUMMARY.md → scenarios JSON)
   ├── smoke-test-auth-bypass skill        (wire bypass if auth provider detected)
   ├── detect-server.sh                    (port + SMOKE_TEST_BYPASS=true)
   ├── generate-spec.sh → Playwright       (headless, serial, persistent ctx)
   │    ├── DOM asserts
   │    ├── Dimension asserts (CSS collapse)
   │    ├── Console filter
   │    └── Network 4xx/5xx
   ├── DB assertions                       (mcp__supabase__execute_sql per mutation)
   ├── Auto-fix loop (max 3)               → regression gate → re-run spec
   │
   ├── should-verify.sh                    (stricter heuristic than trigger)
   │    ├── VERIFY → /gsd-verify-work <N>  (conversational UAT)
   │    └── SKIP  → note in report (pure infra / API / migration)
   │
   ├── /gsd-extract_learnings <N>          (always, if .planning/ exists)
   │
   ▼
   Report → ONLY NOW "Phase complete"
```

## Configuration

`smoke-test.config.json` in your project root (auto-created on first run):

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

| Field | Description | Default |
|-------|-------------|---------|
| `framework` | `nextjs`, `vite`, `remix` | Auto-detected |
| `port` | Fixed port, or `null` for auto-detect | `null` |
| `auth.type` | `clerk`, `nextauth`, `supabase`, `custom`, `none` | Auto-detected |
| `base_routes` | Routes to always test (regression) | `["/"]` |
| `protected_prefixes` | URL prefixes requiring auth | `["/dashboard"]` |
| `ignore_console` | Console patterns to skip | `[]` |
| `max_fix_attempts` | Auto-fix retry limit | `3` |

## Trigger Heuristics (two scripts, different strictness)

The skill uses two git-diff-based scripts at different stages:

**`should-trigger.sh`** (Step 0) — decides if the full QA gate runs at all:
- Triggers: Page/layout/route files, components, middleware, styling, `package.json`, `src/lib/`, `src/hooks/`, etc.
- Skips: Docs, test files, config, migrations, scripts, CI/CD files.

**`should-verify.sh`** (Step 12) — stricter, decides if `/gsd-verify-work` auto-invokes:
- Verifies: `page.tsx`, `layout.tsx`, `loading.tsx`, `error.tsx`, `not-found.tsx`, `template.tsx`, `src/components/`, `middleware.ts`, server actions (`src/actions/`, `app/actions/`).
- Skips: API routes, lib/, tools/, types/, migrations, config, docs, public/ assets, global CSS. Those phases pass the gate via automated smoke + DB asserts alone; a human has nothing to click-through for invisible plumbing.

Both scripts use ERE-compatible regex (plain parens, not `\(a\|b\)`) so they work on BSD grep (macOS default). If you're extending either, keep that convention.

## Supported Auth Providers

| Provider | Middleware Bypass | Auth Helper Bypass | Notes |
|----------|------------------|--------------------|-------|
| Clerk | ✅ | ✅ | Most common setup |
| NextAuth | ✅ | ✅ | Session mock |
| Supabase Auth | ✅ | ✅ | RLS needs service role |
| Custom JWT | ✅ | ✅ | Generic pattern |
| None | Skipped | Skipped | |

## Auto-Fix Capabilities

| Issue | Fix |
|-------|-----|
| API route 401 | Swap `auth()` for bypass-aware helper |
| Stale `.next` cache | Delete `.next/`, restart server |
| Port conflict | Find available port |
| Hydration mismatch | Warn (non-blocking) |
| `crypto.randomUUID` on HTTP | Add fallback |
| Missing dependency | `npm install` |

## Works With

- **GSD** — QA gate as final execution phase
- **Superpowers** — Complements existing review with browser verification
- **Raw Claude Code** — Any phased or unphased development
- **Codex plugin** (`openai/codex-plugin-cc`) — Optional code review before smoke test

## Project Structure

```
super-smoke-test/
├── SKILL.md                          ← QA gate protocol (14 steps)
├── README.md                         ← This file
├── scripts/
│   ├── should-trigger.sh             ← Step 0 trigger heuristic (TRIGGER/SKIP)
│   ├── should-verify.sh              ← Step 12 verify-work heuristic (VERIFY/SKIP)
│   ├── regression-gate.sh            ← tsc + lint + build gate
│   ├── parse-gsd-artifacts.sh        ← PLAN.md + SUMMARY.md → scenarios JSON
│   ├── derive-routes.sh              ← Fallback: file path → browser route mapping
│   ├── detect-server.sh              ← Port detection + conflict resolution
│   └── generate-spec.sh              ← scenarios JSON → Playwright spec file
├── references/
│   ├── auth-patterns.md              ← Auth bypass patterns (Clerk, NextAuth, etc.)
│   ├── common-failures.md            ← Diagnostic + fix lookup table
│   └── playwright-scenarios.md       ← Scenario JSON schema + action vocabulary
└── templates/
    ├── smoke-test.config.json        ← Default project config
    └── stop-hook.json                ← Stop hook for deterministic triggering
```

## Pro Tip: Overnight Autonomous Builds

This skill is designed for hands-off development. Tell Claude:

```
Execute the GSD plan. I'm going to sleep.
```

The Stop hook ensures that after each execution phase, Claude runs the full QA pipeline — code review, fixes, browser verification, more fixes — before moving to the next phase. You wake up to verified, tested code, not "done (but actually broken)."

## Fallback

If Playwright CLI isn't installed, the skill falls back to `curl`-based HTTP checks. This catches server errors but can't verify client-side rendering.

## Contributing

PRs welcome. Main areas:
- More framework support (SvelteKit, Astro, Nuxt)
- More auth provider patterns
- CI/CD integration patterns
- Playwright CLI skill integration

## License

MIT
