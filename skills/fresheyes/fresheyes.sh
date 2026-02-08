#!/usr/bin/env bash
# Fresh Eyes - Independent Code Review runner
# Usage: ./fresheyes.sh 'scope text'

set -euo pipefail

# Check for codex CLI
if ! command -v codex &> /dev/null; then
  echo "Error: codex CLI not found." >&2
  echo "Install it with: npm install -g @openai/codex" >&2
  exit 1
fi

MODEL="${FRESHEYES_MODEL:-gpt-5.3-codex}"
MODE="${FRESHEYES_MODE:-manual}"
SCOPE_PARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "Error: --mode requires a value (manual|automatic)." >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --manual)
      MODE="manual"
      shift
      ;;
    --automatic)
      MODE="automatic"
      shift
      ;;
    --)
      shift
      SCOPE_PARTS+=("$@")
      break
      ;;
    *)
      SCOPE_PARTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#SCOPE_PARTS[@]} -gt 0 ]]; then
  SCOPE_TEXT="${SCOPE_PARTS[*]}"
else
  if [[ "$MODE" == "automatic" ]]; then
    SCOPE_TEXT="Review the staged changes using git diff --cached."
  else
    SCOPE_TEXT="Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE=""
SCHEMA_FILE=""
REASONING_EFFORT=""

case "$MODE" in
  manual)
    PROMPT_FILE="$SCRIPT_DIR/fresheyes-prompt.md"
    REASONING_EFFORT="xhigh"
    ;;
  automatic)
    PROMPT_FILE="$SCRIPT_DIR/fresheyes-automatic-prompt.md"
    SCHEMA_FILE="$SCRIPT_DIR/fresheyes-automatic-schema.json"
    REASONING_EFFORT="medium"
    ;;
  *)
    echo "Error: Unknown mode '$MODE'. Use manual or automatic." >&2
    exit 1
    ;;
esac

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [[ "$MODE" == "automatic" && ! -f "$SCHEMA_FILE" ]]; then
  echo "Error: Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

PROMPT=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
print(template.replace('{{REVIEW_SCOPE}}', sys.argv[2]))
" "$PROMPT_FILE" "$SCOPE_TEXT")

# Create log file in system log directory
LOG_DIR="${TMPDIR:-/tmp}/fresheyes-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fresheyes-$(date +%Y%m%d-%H%M%S)-$$.log"

if [[ "$MODE" == "automatic" ]]; then
  OUTPUT_FILE="$LOG_DIR/fresheyes-automatic-$(date +%Y%m%d-%H%M%S)-$$.json"

  if ! codex exec \
    --sandbox read-only \
    --color never \
    --model "$MODEL" \
    --output-schema "$SCHEMA_FILE" \
    -o "$OUTPUT_FILE" \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    "$PROMPT" > "$LOG_FILE" 2>&1; then
    echo "Fresh Eyes: Codex failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi

  if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "Fresh Eyes: Codex produced no output. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi

  python3 - "$OUTPUT_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print("Fresh Eyes: unable to parse Codex output. Commit blocked.", file=sys.stderr)
    print(f"Error: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict) or "approve_commit" not in data:
    print("Fresh Eyes: approve_commit missing from Codex output. Commit blocked.", file=sys.stderr)
    sys.exit(2)

approve = data.get("approve_commit")
issues = data.get("issues") or []
if not isinstance(issues, list):
    issues = []

if approve is True:
    print("Fresh Eyes: approved.")
    if issues:
        print("Notes:")
        for issue in issues:
            severity = issue.get("severity", "unspecified")
            file = issue.get("file", "unknown")
            line = issue.get("line")
            loc = f"{file}:{line}" if line not in (None, "") else file
            desc = issue.get("description", "").strip()
            if desc:
                print(f"- [{severity}] {loc} - {desc}")
            else:
                print(f"- [{severity}] {loc}")
    sys.exit(0)

print("Fresh Eyes: commit not approved.")
if issues:
    print("Issues found:")
    for issue in issues:
        severity = issue.get("severity", "unspecified")
        file = issue.get("file", "unknown")
        line = issue.get("line")
        loc = f"{file}:{line}" if line not in (None, "") else file
        desc = issue.get("description", "").strip()
        if desc:
            print(f"- [{severity}] {loc} - {desc}")
        else:
            print(f"- [{severity}] {loc}")
else:
    print("No issues listed, but approval was denied.")
sys.exit(1)
PY
  status=$?

  echo ""
  echo "---"
  echo "Full log: $LOG_FILE"
  exit "$status"
fi

# Run Codex and capture all output to log file
if ! codex exec \
  --sandbox read-only \
  --color never \
  --model "$MODEL" \
  -c model_reasoning_effort="$REASONING_EFFORT" \
  "$PROMPT" > "$LOG_FILE" 2>&1; then
  echo "Fresh Eyes: Codex failed. See log: $LOG_FILE" >&2
  exit 1
fi

# Extract just the final review section (last occurrence of "## Files Examined" to end)
# Use tac to reverse, find first match, then reverse back
tac "$LOG_FILE" | sed '/^## Files Examined/q' | tac

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
