#!/bin/bash
# regression-gate.sh — Run tsc + build + lint after fixes. Block on regression.
# Usage: bash regression-gate.sh [project_dir]
# Exit 0 = pass, non-zero = regression detected.

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR" || exit 1

FAIL=0
REPORT=""

has_script() {
  node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts['$1'] ? 0 : 1)" 2>/dev/null
}

# TypeScript
if [ -f "tsconfig.json" ]; then
  echo "[gate] tsc --noEmit..."
  if has_script "typecheck"; then
    npm run -s typecheck 2>&1 | tail -30 > /tmp/gate-tsc.log
  else
    npx tsc --noEmit 2>&1 | tail -30 > /tmp/gate-tsc.log
  fi
  if [ ${PIPESTATUS[0]} -ne 0 ]; then
    REPORT="${REPORT}TSC FAIL:\n$(cat /tmp/gate-tsc.log)\n\n"
    FAIL=1
  fi
fi

# Lint
if has_script "lint"; then
  echo "[gate] npm run lint..."
  npm run -s lint 2>&1 | tail -30 > /tmp/gate-lint.log
  if [ ${PIPESTATUS[0]} -ne 0 ]; then
    REPORT="${REPORT}LINT FAIL:\n$(cat /tmp/gate-lint.log)\n\n"
    FAIL=1
  fi
fi

# Build (skip if SKIP_BUILD_GATE=1 — user may prefer to skip for speed)
if [ "${SKIP_BUILD_GATE:-0}" != "1" ] && has_script "build"; then
  echo "[gate] npm run build..."
  npm run -s build 2>&1 | tail -40 > /tmp/gate-build.log
  if [ ${PIPESTATUS[0]} -ne 0 ]; then
    REPORT="${REPORT}BUILD FAIL:\n$(cat /tmp/gate-build.log)\n\n"
    FAIL=1
  fi
fi

if [ $FAIL -eq 1 ]; then
  echo "---"
  echo "REGRESSION GATE FAILED"
  echo "---"
  printf "%b" "$REPORT"
  exit 1
fi

echo "REGRESSION GATE PASSED"
exit 0
