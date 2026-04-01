#!/bin/bash
# derive-routes.sh — Maps changed files to testable browser routes.
# Usage: bash derive-routes.sh [project_dir]
#
# Reads smoke-test.config.json for route_dir, base_routes, and protected_prefixes.
# Outputs JSON array of test routes.

PROJECT_DIR="${1:-.}"
CONFIG="$PROJECT_DIR/smoke-test.config.json"

# Read config values (defaults if no config)
if [ -f "$CONFIG" ]; then
  ROUTE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('route_dir', 'src/app'))" 2>/dev/null || echo "src/app")
  BASE_ROUTES=$(python3 -c "import json; print('\n'.join(json.load(open('$CONFIG')).get('base_routes', ['/'])))" 2>/dev/null || echo "/")
  PROTECTED=$(python3 -c "import json; print('\n'.join(json.load(open('$CONFIG')).get('protected_prefixes', ['/dashboard','/admin','/settings','/account'])))" 2>/dev/null || echo "/dashboard")
else
  ROUTE_DIR="src/app"
  BASE_ROUTES="/"
  PROTECTED="/dashboard
/admin
/settings
/account"
fi

# Get changed files in the route directory
CHANGED=$(
  git diff --name-only HEAD~1 -- "$ROUTE_DIR" 2>/dev/null || \
  git diff --name-only --cached -- "$ROUTE_DIR" 2>/dev/null || \
  git status --porcelain | awk '{print $2}' | grep "^${ROUTE_DIR}/"
)

# Convert file path to route
file_to_route() {
  local filepath="$1"
  local route="$filepath"

  # Strip route_dir prefix
  route="${route#$ROUTE_DIR}"

  # Strip route group names like (dashboard) or (marketing)
  route=$(echo "$route" | sed 's|/([^)]*)||g')

  # Strip file names
  route=$(echo "$route" | sed 's|/page\.\(tsx\|ts\|jsx\|js\)$||')
  route=$(echo "$route" | sed 's|/layout\.\(tsx\|ts\|jsx\|js\)$||')
  route=$(echo "$route" | sed 's|/route\.\(tsx\|ts\)$||')
  route=$(echo "$route" | sed 's|/loading\.\(tsx\|ts\)$||')
  route=$(echo "$route" | sed 's|/error\.\(tsx\|ts\)$||')

  # Ensure starts with /
  [[ "$route" != /* ]] && route="/$route"

  # Clean double slashes and trailing slash
  route=$(echo "$route" | sed 's|//|/|g')
  [[ "$route" != "/" ]] && route="${route%/}"

  echo "$route"
}

# Check if route needs auth
needs_auth() {
  local route="$1"
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    if [[ "$route" == "$prefix"* ]]; then
      echo "true"
      return
    fi
  done <<< "$PROTECTED"
  echo "false"
}

# Collect routes (using associative array for dedup)
declare -A ROUTES

# Add base routes
while IFS= read -r route; do
  [ -z "$route" ] && continue
  ROUTES["$route"]="page|base_route"
done <<< "$BASE_ROUTES"

# Process changed files
while IFS= read -r file; do
  [ -z "$file" ] && continue

  # Determine file type
  if [[ "$file" == *"/route.ts"* ]] || [[ "$file" == *"/route.tsx"* ]]; then
    file_type="api"
  elif [[ "$file" == *"/layout.ts"* ]] || [[ "$file" == *"/layout.tsx"* ]]; then
    file_type="layout"
  elif [[ "$file" == *"/page.ts"* ]] || [[ "$file" == *"/page.tsx"* ]] || \
       [[ "$file" == *"/page.js"* ]] || [[ "$file" == *"/page.jsx"* ]]; then
    file_type="page"
  else
    # Component or other file — skip direct route mapping
    continue
  fi

  route=$(file_to_route "$file")

  # For layout changes, find all child pages
  if [[ "$file_type" == "layout" ]]; then
    layout_dir=$(dirname "$file")
    while IFS= read -r child; do
      [ -z "$child" ] && continue
      child_route=$(file_to_route "$child")
      ROUTES["$child_route"]="page|layout_changed"
    done < <(find "$layout_dir" -name "page.tsx" -o -name "page.ts" -o -name "page.jsx" -o -name "page.js" 2>/dev/null)
    continue
  fi

  # API routes — add for network-level testing
  if [[ "$file_type" == "api" ]]; then
    ROUTES["$route"]="api|changed"
    continue
  fi

  ROUTES["$route"]="page|changed"
done <<< "$CHANGED"

# Output JSON
echo "["
first=true
for route in "${!ROUTES[@]}"; do
  IFS='|' read -r type source <<< "${ROUTES[$route]}"
  auth=$(needs_auth "$route")

  if [ "$first" = true ]; then
    first=false
  else
    echo ","
  fi

  printf '  {"route": "%s", "type": "%s", "needs_auth": %s, "source": "%s"}' \
    "$route" "$type" "$auth" "$source"
done
echo ""
echo "]"
