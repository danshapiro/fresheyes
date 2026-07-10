#!/usr/bin/env bash
# Fresh Eyes - Independent Code Review runner
# Usage: ./fresheyes.sh [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] [--foreground] 'scope text'
# Manual mode detaches into its own session by default (prints FRESHPID=<pid>); --foreground runs synchronously.

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
# Manual reviews detach into their own session by default so a caller's process
# group / harness timeout can't kill them. --foreground (alias --no-detach)
# forces a synchronous run. Automatic mode never detaches.
FOREGROUND=0
# Capture argv verbatim before the parse loop consumes it, so the detach re-exec
# can relaunch with identical arguments.
ORIG_ARGS=("$@")

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
    --foreground|--no-detach)
      FOREGROUND=1
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
    MODEL="${FRESHEYES_MODEL:-gpt-5.6-sol}"
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

# --- Detach manual reviews into their own session (default) ---
# Manual reviews are long (5-30 min). By default we re-exec under setsid so the
# review survives the caller's process group — e.g. an agent harness timeout on
# the launch call. The foreground parent prints the review PID and exits in
# under a second; the detached child runs the review and writes all output to
# its log files, retrieved via fresheyes-progress.sh. FRESHEYES_DAEMONIZED=1
# stops the child re-detaching. Automatic mode (the pre-commit gate) and
# --foreground both skip this and run synchronously.
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  if ! command -v setsid &> /dev/null; then
    echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
    exit 2
  fi
  FRESHEYES_DAEMONIZED=1 setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>&1 &
  echo "FRESHPID=$!"
  exit 0
fi

# --- Build prompt ---
PROMPT=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
print(template.replace('{{REVIEW_SCOPE}}', sys.argv[2]))
" "$PROMPT_FILE" "$SCOPE_TEXT")

# --- Log file setup ---
GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
LOG_DIR="${FRESHEYES_LOG_DIR:-$GLOBAL_LOG_DIR}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fresheyes-$(date +%Y%m%d-%H%M%S)-$$.log"
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
STDERR_LOG="$LOG_FILE.stderr"
STATUS_FILE="$LOG_FILE.status.json"

if [[ "$PROVIDER" == "claude" ]]; then
  : > "$LOG_FILE"
  : > "$EVENT_LOG"
  : > "$STREAM_LOG"
  : > "$STDERR_LOG"
fi

echo "$LOG_FILE" > "$LOG_DIR/.active.$$"

write_tracker_alias() {
  local dir="$1"
  local name="$2"

  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$LOG_FILE" > "$dir/$name" 2>/dev/null || true
}

write_tracker_alias "$LOG_DIR" ".locator.$$"
write_tracker_alias "$LOG_DIR" ".parent.$PPID"
if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
  write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$$"
  write_tracker_alias "$GLOBAL_LOG_DIR" ".parent.$PPID"
fi

HEARTBEAT_PID=""
FINAL_STATUS_WRITTEN="0"

manual_verdict_from_log() {
  if [[ ! -f "$LOG_FILE" ]]; then
    return 1
  fi

  python3 - "$LOG_FILE" <<'PY' 2>/dev/null
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)

verdict = ""
for match in re.finditer(r"INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)\b", text, re.IGNORECASE):
    verdict = match.group(1).lower()

if not verdict:
    sys.exit(1)

print(verdict)
PY
}

write_status() {
  local state="$1"
  local exit_code="${2:-}"
  local verdict="${3:-}"

  python3 - "$STATUS_FILE" "$state" "$exit_code" "$verdict" "$PROVIDER" "$MODE" "$$" "$LOG_FILE" <<'PY'
import json
import os
import sys
import time

path, state, exit_code, verdict, provider, mode, pid, log_path = sys.argv[1:9]
record = {
    "severity": "error" if state == "failed" else "info",
    "state": state,
    "provider": provider,
    "mode": mode,
    "pid": int(pid),
    "log_path": log_path,
    "updated_at_epoch": time.time(),
}
if exit_code:
    record["exit_code"] = int(exit_code)
if verdict:
    record["verdict"] = verdict

tmp_path = f"{path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, separators=(",", ":"), sort_keys=True)
    handle.write("\n")
os.replace(tmp_path, path)
PY
}

_cleanup() {
  local status=$?
  if [[ "${FINAL_STATUS_WRITTEN:-0}" != "1" ]]; then
    if [[ "$status" -eq 0 ]]; then
      write_status "complete" "$status" "$(manual_verdict_from_log 2>/dev/null || true)" || true
    else
      write_status "failed" "$status" "" || true
    fi
  fi
  rm -f "$LOG_DIR/.active.$$"
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
}
trap _cleanup EXIT

log_event() {
  local severity="$1"
  local event="$2"
  local message="${3:-}"

  [[ "$PROVIDER" == "claude" ]] || return 0

  python3 - "$EVENT_LOG" "$severity" "$event" "$PROVIDER" "$MODE" "$$" "$message" <<'PY'
import json
import sys
import time

path, severity, event, provider, mode, pid, message = sys.argv[1:8]
record = {
    "severity": severity,
    "event": event,
    "provider": provider,
    "mode": mode,
    "pid": int(pid),
    "ts_epoch": time.time(),
}
if message:
    record["message"] = message
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
    handle.write("\n")
PY
}

log_event "info" "review_started" "Fresh Eyes review starting."
write_status "running" "" ""

echo "Fresh Eyes [$$]: review starting. This may take up to 30 minutes, please wait patiently." >&2

# --- Provider functions ---
# Each provider (GPT/Codex, Claude) has a manual and automatic variant.
#
# Manual functions stream a free-form markdown review to stdout.
#
# Automatic functions write structured JSON to an output file.
# The two providers handle structured output differently:
#   GPT/Codex: --output-schema takes a file path; output is written directly in schema format.
#   Claude:    --json-schema takes inline schema content; stream-json output is parsed into the
#              same schema-conforming output file.

CLAUDE_TOOLS='Bash(git diff:*,git show:*,git log:*,git status:*),Read,Glob,Grep'
CLAUDE_STREAM_PARSER="$SCRIPT_DIR/fresheyes-claude-stream.py"

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
  log_event "info" "provider_started" "Claude manual review started."
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT claude -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    -- \
    "$PROMPT" 2>"$STDERR_LOG" | python3 "$CLAUDE_STREAM_PARSER" \
      --mode manual \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG"; then
    log_event "error" "provider_failed" "Claude manual review failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    [[ -s "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2
    exit 1
  fi
  log_event "info" "provider_finished" "Claude manual review finished."
}

run_claude_automatic() {
  local output_file="$1"
  # Claude CLI takes schema contents inline (not a file path like Codex).
  local json_schema
  json_schema=$(cat "$SCHEMA_FILE")

  log_event "info" "provider_started" "Claude automatic review started."
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT claude -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    --json-schema "$json_schema" \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    -- \
    "$PROMPT" 2>"$STDERR_LOG" | python3 "$CLAUDE_STREAM_PARSER" \
      --mode automatic \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG" \
      --automatic-output "$output_file"; then
    log_event "error" "provider_failed" "Claude automatic review failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    [[ -s "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2
    exit 1
  fi
  log_event "info" "provider_finished" "Claude automatic review finished."
}

# --- Heartbeat ---
# Keeps the harness from killing this process during long, silent reviews.
_start_heartbeat() {
  (
    while true; do
      sleep 300 >/dev/null 2>/dev/null
      echo "Fresh Eyes [$$]: review in progress..." >&2
    done
  ) &
  HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
}

# --- Dispatch ---

_start_heartbeat

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

  set +e
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
  set -e
  if [[ "$status" -eq 0 ]]; then
    write_status "complete" "$status" "approved"
  else
    write_status "failed" "$status" "not_approved"
  fi
  FINAL_STATUS_WRITTEN="1"

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

write_status "complete" "0" "$(manual_verdict_from_log 2>/dev/null || true)"
FINAL_STATUS_WRITTEN="1"

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
