#!/bin/bash
# should-trigger.sh — Determines if smoke tests are needed after a GSD phase.
# Outputs: TRIGGER or SKIP with a reason.
# Usage: bash should-trigger.sh [base_ref]
#
# Checks git diff for changed files and applies rules to decide if browser
# smoke testing is warranted.

BASE_REF="${1:-HEAD~1}"

# Get changed files (try multiple strategies)
CHANGED=$(
  git diff --name-only "$BASE_REF" 2>/dev/null || \
  git diff --name-only --cached 2>/dev/null || \
  git status --porcelain | awk '{print $2}'
)

if [ -z "$CHANGED" ]; then
  echo "SKIP: No changed files detected."
  exit 0
fi

# --- TRIGGER patterns (any match = run smoke tests) ---
TRIGGER_PATTERNS=(
  # Route pages
  'page\.\(tsx\|ts\|jsx\|js\)$'
  # Layouts (affect all child routes)
  'layout\.\(tsx\|ts\|jsx\|js\)$'
  # API routes
  'route\.\(tsx\|ts\)$'
  # Shared components
  'src/components/'
  'components/'
  # Middleware (auth/routing)
  'middleware\.\(ts\|tsx\|js\)$'
  # Styling
  'globals\.css'
  'tailwind\.config'
  # Dependencies (can break rendering)
  'package\.json$'
  # App-level lib files that pages import
  'src/lib/'
  'src/hooks/'
  'src/utils/'
  'src/providers/'
  'src/context/'
)

# --- SKIP-ONLY patterns (if ALL changes match these, skip) ---
SKIP_PATTERNS=(
  '\.md$'
  '\.mdx$'
  '\.test\.'
  '\.spec\.'
  '__tests__/'
  '\.env\.example'
  'tsconfig'
  'eslint'
  'prettier'
  'migrations/'
  'seeds/'
  'supabase/migrations/'
  'scripts/'
  '\.github/'
  'CLAUDE\.md'
  'CHANGELOG'
  'README'
  'LICENSE'
  'smoke-test\.config\.json'
  '\.playwright-cli/'
)

# Check if any changed file matches a trigger pattern
TRIGGER_FILES=""
for file in $CHANGED; do
  for pattern in "${TRIGGER_PATTERNS[@]}"; do
    if echo "$file" | grep -qE "$pattern"; then
      TRIGGER_FILES="$TRIGGER_FILES $file"
      break
    fi
  done
done

if [ -n "$TRIGGER_FILES" ]; then
  # Count unique trigger files
  COUNT=$(echo "$TRIGGER_FILES" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
  echo "TRIGGER: $COUNT file(s) with frontend/API impact detected."
  echo "$TRIGGER_FILES" | tr ' ' '\n' | grep -v '^$' | sort -u | head -10
  if [ "$COUNT" -gt 10 ]; then
    echo "  ... and $((COUNT - 10)) more"
  fi
  exit 0
fi

# No trigger patterns matched — check if everything is skip-only
ALL_SKIP=true
for file in $CHANGED; do
  FILE_IS_SKIP=false
  for pattern in "${SKIP_PATTERNS[@]}"; do
    if echo "$file" | grep -qE "$pattern"; then
      FILE_IS_SKIP=true
      break
    fi
  done
  if [ "$FILE_IS_SKIP" = false ]; then
    # File doesn't match any skip pattern AND didn't match any trigger pattern
    # This is ambiguous — trigger to be safe
    echo "TRIGGER: Ambiguous change detected ($file) — running smoke tests to be safe."
    exit 0
  fi
done

# All files matched skip patterns
echo "SKIP: Only config/docs/test/migration changes detected. No frontend impact."
exit 0
