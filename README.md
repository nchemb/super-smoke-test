# super-smoke-test

A Claude Code skill that adds a mandatory QA gate after every AI execution phase. Code review + browser smoke testing must pass before the agent can say "done."

## The Problem

AI coding agents execute a build phase, say "done" — and when you open the browser, routes are broken, API calls fail, and console errors are everywhere. Telling the agent to "always test before presenting" in CLAUDE.md works early in a session, but under context bloat after a long execution phase, the instruction gets deprioritized or forgotten.

**super-smoke-test** solves this with a deterministic Stop hook that fires after every response, plus a structured QA pipeline the agent follows. No CLAUDE.md dependency. No relying on the LLM to remember.

## What It Does

After any execution phase (GSD, Superpowers, or any phased build):

1. **Checks if QA is needed** — Skips for planning phases, docs, config, migrations
2. **Code review via Codex** (optional) — Runs `/codex:review`, waits, fixes all findings
3. **Browser smoke test via Playwright CLI** — Navigates routes, screenshots, checks console + network
4. **Auto-fixes failures** — Auth bypass issues, stale cache, missing deps — fixes and re-tests
5. **Reports combined results** — Code review summary + smoke test pass/fail table with proof

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

### 3. Install the Stop Hook (Recommended)

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
Execution Phase Completes
        │
   should-trigger.sh → SKIP or TRIGGER
        │
      TRIGGER
        │
   ┌─ Codex installed? ─── NO ──→ Skip to Smoke Test
   │
  YES
   │
   ├─ /codex:review → wait for results
   ├─ Fix all findings (critical → low)
   ├─ Re-review if significant fixes applied
   │
   ▼
   Smoke Test (Playwright CLI)
   ├─ Load/create smoke-test.config.json
   ├─ Verify auth bypass is wired
   ├─ Detect/start dev server
   ├─ Derive test routes from git diff
   ├─ For each route:
   │   ├─ Navigate with auth bypass cookie
   │   ├─ Snapshot (accessibility tree → disk)
   │   ├─ Screenshot (PNG → disk)
   │   ├─ Check console (filter framework noise)
   │   └─ Check network (flag 4xx/5xx)
   ├─ Auto-fix failures (up to 3 attempts)
   │
   ▼
   Report: combined review + smoke test results
   │
   ▼
   ONLY NOW → "Phase complete"
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

## Trigger Heuristic

Not every phase needs QA. The skill checks `git diff` automatically:

**Triggers:** Page/layout/route files, components, middleware, styling, `package.json`

**Skips:** Docs, test files, config, migrations, scripts, CI/CD files

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
├── SKILL.md                          ← QA gate protocol
├── README.md                         ← This file
├── scripts/
│   ├── should-trigger.sh             ← Trigger heuristic (TRIGGER/SKIP)
│   ├── derive-routes.sh              ← File path → browser route mapping
│   └── detect-server.sh              ← Port detection + conflict resolution
├── references/
│   ├── auth-patterns.md              ← Auth bypass patterns (Clerk, NextAuth, etc.)
│   └── common-failures.md            ← Diagnostic + fix lookup table
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
