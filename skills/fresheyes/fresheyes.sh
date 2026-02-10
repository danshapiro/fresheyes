#!/usr/bin/env bash
# Fresh Eyes - Independent Code Review runner
# Usage: ./fresheyes.sh [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] 'scope text'

set -euo pipefail

# --- Defaults ---
PROVIDER=""
# Two modes:
#   manual    – thorough, human-readable markdown review (xhigh reasoning).
#               Designed for interactive use: rich prose, full context, PASSED/FAILED verdict.
#   automatic – fast, machine-readable JSON review (medium reasoning).
#               Designed for pre-commit hooks: structured {approve_commit, issues[]} output.
MODE="${FRESHEYES_MODE:-manual}"
SCOPE_PARTS=()

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpt)
      PROVIDER="gpt"
      shift
      ;;
    --claude)
      PROVIDER="claude"
      shift
      ;;
    --provider)
      if [[ $# -lt 2 ]]; then
        echo "Error: --provider requires a value (gpt|claude)." >&2
        exit 1
      fi
      PROVIDER="$2"
      shift 2
      ;;
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

# --- Resolve provider ---
PROVIDER="${PROVIDER:-${FRESHEYES_PROVIDER:-gpt}}"

case "$PROVIDER" in
  gpt)
    MODEL="${FRESHEYES_MODEL:-gpt-5.3-codex}"
    PROVIDER_LABEL="Codex"
    ;;
  claude)
    MODEL="${FRESHEYES_MODEL:-opus}"
    PROVIDER_LABEL="Claude"
    ;;
  *)
    echo "Error: Unknown provider '$PROVIDER'. Use gpt or claude." >&2
    exit 1
    ;;
esac

# --- CLI prerequisite check ---
if [[ "$PROVIDER" == "gpt" ]]; then
  if ! command -v codex &> /dev/null; then
    echo "Error: codex CLI not found." >&2
    echo "Install it with: npm install -g @openai/codex" >&2
    exit 1
  fi
elif [[ "$PROVIDER" == "claude" ]]; then
  if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI not found." >&2
    echo "Install it with: npm install -g @anthropic-ai/claude-code" >&2
    exit 1
  fi
fi

# --- Resolve scope ---
if [[ ${#SCOPE_PARTS[@]} -gt 0 ]]; then
  SCOPE_TEXT="${SCOPE_PARTS[*]}"
else
  if [[ "$MODE" == "automatic" ]]; then
    SCOPE_TEXT="Review the staged changes using git diff --cached."
  else
    SCOPE_TEXT="Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
  fi
fi

# --- Resolve mode-specific files ---
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

# --- Build prompt ---
PROMPT=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
print(template.replace('{{REVIEW_SCOPE}}', sys.argv[2]))
" "$PROMPT_FILE" "$SCOPE_TEXT")

# --- Log file setup ---
LOG_DIR="${TMPDIR:-/tmp}/fresheyes-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fresheyes-$(date +%Y%m%d-%H%M%S)-$$.log"

# Mark this log as the active run so the progress helper can find it without the caller
# needing to know the log path (which is large and would blow up the caller's context).
echo "$LOG_FILE" > "$LOG_DIR/.active"

echo "Fresh Eyes: review starting. This may take up to 30 minutes, please wait patiently." >&2
echo "To see the size of the response so far, invoke: $SCRIPT_DIR/fresheyes-progress.sh" >&2

# --- Provider functions ---
# Each provider (GPT/Codex, Claude) has a manual and automatic variant.
#
# Manual functions stream a free-form markdown review to stdout.
#
# Automatic functions write structured JSON to an output file.
# The two providers handle structured output differently:
#   GPT/Codex: --output-schema takes a file path; output is written directly in schema format.
#   Claude:    --json-schema takes inline schema content; output is wrapped in a JSON envelope
#              (under .structured_output), so we post-process to extract the inner object.

CLAUDE_TOOLS='Bash(git diff:*,git show:*,git log:*,git status:*),Read,Glob,Grep'

run_gpt_manual() {
  if ! codex exec \
    --sandbox read-only \
    --color never \
    --model "$MODEL" \
    -c features.shell_snapshot=false \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    "$PROMPT" 2>&1 | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    exit 1
  fi
  # Extract just the final review section (last occurrence of "## Files Examined" to end)
  tac "$LOG_FILE" | sed '/^## Files Examined/q' | tac
}

run_gpt_automatic() {
  local output_file="$1"
  # Codex writes schema-conforming JSON directly to the output file — no post-processing needed.
  if ! codex exec \
    --sandbox read-only \
    --color never \
    --model "$MODEL" \
    -c features.shell_snapshot=false \
    --output-schema "$SCHEMA_FILE" \
    -o "$output_file" \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    "$PROMPT" 2>&1 | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi
}

run_claude_manual() {
  if ! env -u ANTHROPIC_API_KEY claude -p \
    --model "$MODEL" \
    --output-format text \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>"$LOG_FILE.stderr" | tee "$LOG_FILE"; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    [[ -s "$LOG_FILE.stderr" ]] && cat "$LOG_FILE.stderr" >&2
    exit 1
  fi
}

run_claude_automatic() {
  local output_file="$1"
  # Claude CLI takes schema contents inline (not a file path like Codex).
  local json_schema
  json_schema=$(cat "$SCHEMA_FILE")

  if ! env -u ANTHROPIC_API_KEY claude -p \
    --model "$MODEL" \
    --output-format json \
    --json-schema "$json_schema" \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>"$LOG_FILE.stderr" | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    [[ -s "$LOG_FILE.stderr" ]] && cat "$LOG_FILE.stderr" >&2
    exit 1
  fi

  # Claude wraps structured output in a JSON envelope at .structured_output — extract it
  python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    envelope = json.load(f)
inner = envelope.get('structured_output') or envelope.get('result', envelope)
with open(sys.argv[2], 'w') as f:
    json.dump(inner, f, indent=2)
" "$LOG_FILE" "$output_file"
}

# --- Dispatch ---

if [[ "$MODE" == "automatic" ]]; then
  OUTPUT_FILE="$LOG_DIR/fresheyes-automatic-$(date +%Y%m%d-%H%M%S)-$$.json"

  case "$PROVIDER" in
    gpt)    run_gpt_automatic "$OUTPUT_FILE" ;;
    claude) run_claude_automatic "$OUTPUT_FILE" ;;
  esac

  if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "Fresh Eyes: $PROVIDER_LABEL produced no output. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi

  python3 - "$OUTPUT_FILE" "$PROVIDER_LABEL" <<'PY'
import json
import sys

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "Provider"
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"Fresh Eyes: unable to parse {label} output. Commit blocked.", file=sys.stderr)
    print(f"Error: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict) or "approve_commit" not in data:
    print(f"Fresh Eyes: approve_commit missing from {label} output. Commit blocked.", file=sys.stderr)
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

# --- Manual mode dispatch ---
case "$PROVIDER" in
  gpt)    run_gpt_manual ;;
  claude) run_claude_manual ;;
esac

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
