#!/bin/bash
# parse-gsd-artifacts.sh — Extract requirements and UAT criteria from GSD phase artifacts.
# Usage: bash parse-gsd-artifacts.sh [project_dir]
#
# Looks for .planning/current/ (symlink to active phase) or .planning/phases/<active>/
# Emits JSON: { "phase": "...", "requirements": [{id, description, acceptance}], "summary": "..." }

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR" || exit 1

# Locate active phase directory
PHASE_DIR=""
if [ -d ".planning/current" ]; then
  PHASE_DIR=".planning/current"
elif [ -L ".planning/current" ]; then
  PHASE_DIR="$(readlink .planning/current)"
fi

# Fallback: most recently modified phase directory
if [ -z "$PHASE_DIR" ] || [ ! -d "$PHASE_DIR" ]; then
  PHASE_DIR=$(find .planning/phases -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
fi

if [ -z "$PHASE_DIR" ] || [ ! -d "$PHASE_DIR" ]; then
  echo '{"phase": null, "requirements": [], "summary": "No GSD phase artifacts found"}'
  exit 0
fi

SUMMARY_MD="$PHASE_DIR/SUMMARY.md"
PLAN_MD="$PHASE_DIR/PLAN.md"
PHASE_NAME=$(basename "$PHASE_DIR")

python3 - "$PHASE_NAME" "$SUMMARY_MD" "$PLAN_MD" <<'PY'
import json, os, re, sys

phase_name, summary_path, plan_path = sys.argv[1], sys.argv[2], sys.argv[3]

def read(p):
    try:
        with open(p) as f: return f.read()
    except: return ""

def parse_frontmatter(text):
    m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
    if not m: return {}
    fm = {}
    for line in m.group(1).splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            fm[k.strip()] = v.strip()
    return fm

def extract_list_field(fm_value):
    # Handles: [A, B, C] or comma-separated or YAML list references in body
    if not fm_value: return []
    s = fm_value.strip('[]')
    return [x.strip() for x in s.split(',') if x.strip()]

summary = read(summary_path)
plan = read(plan_path)

fm = parse_frontmatter(summary) if summary else {}
req_ids = extract_list_field(fm.get('requirements-completed', '') or fm.get('requirements', ''))

# Fallback: scan summary/plan for requirement IDs like ABCD-01
if not req_ids:
    candidates = set()
    for text in (summary, plan):
        for m in re.finditer(r'\b([A-Z]{2,5}-\d{2,3})\b', text):
            candidates.add(m.group(1))
    req_ids = sorted(candidates)

# For each req ID, pull the nearest description from PLAN.md
requirements = []
for rid in req_ids:
    description = ""
    acceptance = ""
    for text in (plan, summary):
        m = re.search(rf'{re.escape(rid)}[:\s-]+([^\n]+)', text)
        if m:
            description = m.group(1).strip(' -:')
            break
    # Look for acceptance criteria block near the requirement
    m = re.search(
        rf'{re.escape(rid)}.*?(?:acceptance|criteria|verify|verification)[^\n]*\n((?:[-*]\s+[^\n]+\n?){{1,6}})',
        plan, re.IGNORECASE | re.DOTALL
    )
    if m:
        acceptance = m.group(1).strip()
    requirements.append({
        "id": rid,
        "description": description,
        "acceptance": acceptance,
    })

# Extract a short summary line for human display
summary_line = ""
for line in summary.splitlines():
    line = line.strip()
    if line and not line.startswith('#') and not line.startswith('---') and ':' not in line[:20]:
        summary_line = line[:200]
        break

print(json.dumps({
    "phase": phase_name,
    "phase_dir": os.path.dirname(summary_path),
    "requirements": requirements,
    "summary": summary_line,
    "has_summary_md": bool(summary),
    "has_plan_md": bool(plan),
}, indent=2))
PY
