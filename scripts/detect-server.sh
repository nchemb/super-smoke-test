#!/bin/bash
# detect-server.sh — Find, verify, or start the dev server.
# Usage: bash detect-server.sh [project_dir] [preferred_port]
# Outputs JSON with server status and recommended action.

PROJECT_DIR="${1:-.}"
PREFERRED_PORT="${2:-}"
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")

# Check if a port has our project running
check_port() {
  local port=$1
  local pid=$(lsof -ti:$port 2>/dev/null | head -1)

  if [ -z "$pid" ]; then
    echo "free"
    return
  fi

  # Check if the process is running our project
  local proc_cwd=$(readlink /proc/$pid/cwd 2>/dev/null || lsof -p $pid 2>/dev/null | grep cwd | awk '{print $NF}')

  if [[ "$proc_cwd" == "$PROJECT_DIR"* ]]; then
    echo "ours:$pid"
  else
    echo "other:$pid"
  fi
}

# Find first available port
find_port() {
  for port in 3000 3001 3002 3003 3004 3005; do
    if ! lsof -ti:$port > /dev/null 2>&1; then
      echo $port
      return
    fi
  done
  echo "none"
}

# If preferred port specified, check it first
if [ -n "$PREFERRED_PORT" ]; then
  STATUS=$(check_port $PREFERRED_PORT)
  case "$STATUS" in
    free)
      printf '{"status":"available","port":%d,"action":"start"}\n' "$PREFERRED_PORT"
      ;;
    ours:*)
      PID="${STATUS#ours:}"
      printf '{"status":"running","port":%d,"pid":%d,"action":"none"}\n' "$PREFERRED_PORT" "$PID"
      ;;
    other:*)
      PID="${STATUS#other:}"
      AVAIL=$(find_port)
      printf '{"status":"conflict","port":%d,"blocking_pid":%d,"available_port":"%s","action":"use_available"}\n' \
        "$PREFERRED_PORT" "$PID" "$AVAIL"
      ;;
  esac
  exit 0
fi

# No preferred port — scan for our running instance
for port in 3000 3001 3002 3003 3004 3005; do
  STATUS=$(check_port $port)
  case "$STATUS" in
    ours:*)
      PID="${STATUS#ours:}"
      printf '{"status":"running","port":%d,"pid":%d,"action":"none"}\n' "$port" "$PID"
      exit 0
      ;;
  esac
done

# No running instance — find available port
AVAIL=$(find_port)
if [ "$AVAIL" = "none" ]; then
  printf '{"status":"error","message":"No available ports 3000-3005","action":"manual"}\n'
else
  printf '{"status":"available","port":%d,"action":"start"}\n' "$AVAIL"
fi
