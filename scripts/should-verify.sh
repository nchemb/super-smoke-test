#!/bin/bash
# should-verify.sh — Determines if /gsd-verify-work should auto-invoke after the smoke gate.
# Outputs: VERIFY or SKIP with a reason.
# Usage: bash should-verify.sh [base_ref]
#
# Strictest trigger among smoke-test scripts: only fires when the phase produced
# user-facing, UAT-able surface (routes, shared components, middleware, server
# actions). Pure infra / API-only / migration / config / CSS-only phases SKIP —
# /gsd-verify-work is conversational UAT and has nothing to exercise on
# headless backends or invisible plumbing.

BASE_REF="${1:-}"

# If no base ref, scan full phase diff (merge-base with main/master, fall back to HEAD~10).
if [ -z "$BASE_REF" ]; then
  for main_ref in main master; do
    if git rev-parse --verify "$main_ref" >/dev/null 2>&1; then
      BASE_REF=$(git merge-base HEAD "$main_ref" 2>/dev/null)
      break
    fi
  done
  [ -z "$BASE_REF" ] && BASE_REF="HEAD~10"
fi

CHANGED=$(
  { git diff --name-only "$BASE_REF"..HEAD 2>/dev/null; \
    git diff --name-only --cached 2>/dev/null; \
    git status --porcelain | awk '{print $2}'; \
  } | sort -u
)

if [ -z "$CHANGED" ]; then
  echo "SKIP: No changed files detected."
  exit 0
fi

# --- User-facing patterns (any match = VERIFY) ---
# Uses plain ERE parens — BSD grep (macOS default) does NOT honor
# backslash-paren groups under -E. Do not use \(a\|b\).
VERIFY_PATTERNS=(
  # Route pages + layouts (user-navigable surface)
  'page\.(tsx|ts|jsx|js)$'
  'layout\.(tsx|ts|jsx|js)$'
  'loading\.(tsx|ts|jsx|js)$'
  'error\.(tsx|ts|jsx|js)$'
  'not-found\.(tsx|ts|jsx|js)$'
  'template\.(tsx|ts|jsx|js)$'
  # Shared components (user sees these)
  'src/components/'
  'components/'
  # Middleware (gates user navigation)
  'middleware\.(ts|tsx|js)$'
  # Server actions (user-triggered from forms / client components)
  'src/actions/'
  'app/actions/'
  'actions\.(ts|tsx)$'
)

# Explicitly NOT verify-worthy on their own: API routes, lib/, tools/,
# types, migrations, tests, config, docs, public/ assets, global CSS.
# If a phase ONLY touches those, SKIP — automated smoke + DB asserts
# are sufficient. A human doesn't need to click through invisible plumbing.

MATCHED=""
for file in $CHANGED; do
  for pattern in "${VERIFY_PATTERNS[@]}"; do
    if echo "$file" | grep -qE "$pattern"; then
      MATCHED="$MATCHED $file"
      break
    fi
  done
done

if [ -n "$MATCHED" ]; then
  COUNT=$(echo "$MATCHED" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
  echo "VERIFY: $COUNT user-facing file(s) changed."
  echo "$MATCHED" | tr ' ' '\n' | grep -v '^$' | sort -u | head -10
  if [ "$COUNT" -gt 10 ]; then
    echo "  ... and $((COUNT - 10)) more"
  fi
  exit 0
fi

echo "SKIP: No user-facing changes (only API / lib / tools / config / docs / migrations / assets)."
exit 0
