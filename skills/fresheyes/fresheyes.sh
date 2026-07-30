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
    MODEL="${FRESHEYES_GPT_MODEL:-${FRESHEYES_MODEL:-gpt-5.6-sol}}"
    PROVIDER_LABEL="Codex"
    ;;
  claude)
    MODEL="${FRESHEYES_CLAUDE_MODEL:-${FRESHEYES_MODEL:-claude-fable-5}}"
    PROVIDER_LABEL="Claude"
    ;;
  *)
    echo "Error: Unknown provider '$PROVIDER'. Use gpt or claude." >&2
    exit 1
    ;;
esac

version_at_least() {
  python3 - "$1" "$2" <<'PY'
import sys

current_text, minimum_text = sys.argv[1:3]
current_core_text, separator, _ = current_text.partition("-")
current = tuple(int(part) for part in current_core_text.split("."))
minimum = tuple(int(part) for part in minimum_text.split("."))
supported = current > minimum or (current == minimum and not separator)
raise SystemExit(0 if supported else 1)
PY
}

# --- CLI prerequisite check ---
if [[ "$PROVIDER" == "gpt" ]]; then
  if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_CODEX_BIN:-}" ]]; then
    # Parent already validated the CLI + version; cheap re-check only.
    if [[ ! -x "$FRESHEYES_CODEX_BIN" ]]; then
      echo "Error: forwarded codex binary '$FRESHEYES_CODEX_BIN' is not executable." >&2
      exit 1
    fi
    CODEX_BIN="$FRESHEYES_CODEX_BIN"
  else
    if ! command -v codex &> /dev/null; then
      echo "Error: codex CLI not found." >&2
      echo "Install it with: npm install -g @openai/codex" >&2
      exit 1
    fi

    if [[ "$MODEL" == gpt-5.6* ]]; then
      MINIMUM_CODEX_VERSION="0.144.0"
      if ! CODEX_VERSION_OUTPUT="$(codex --version 2>&1)"; then
        echo "Error: unable to determine the Codex CLI version." >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
      if [[ "$CODEX_VERSION_OUTPUT" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        CODEX_VERSION="${BASH_REMATCH[1]}"
      else
        echo "Error: unable to parse the Codex CLI version from: $CODEX_VERSION_OUTPUT" >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
      if ! version_at_least "$CODEX_VERSION" "$MINIMUM_CODEX_VERSION"; then
        echo "Error: GPT-5.6 requires Codex CLI $MINIMUM_CODEX_VERSION or newer; found $CODEX_VERSION." >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
    fi
    CODEX_BIN="$(command -v codex)"
  fi
elif [[ "$PROVIDER" == "claude" ]]; then
  if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_CLAUDE_BIN:-}" ]]; then
    # Parent already validated the CLI + version; cheap re-check only.
    if [[ ! -x "$FRESHEYES_CLAUDE_BIN" ]]; then
      echo "Error: forwarded claude binary '$FRESHEYES_CLAUDE_BIN' is not executable." >&2
      exit 1
    fi
    CLAUDE_BIN="$FRESHEYES_CLAUDE_BIN"
  else
    if ! command -v claude &> /dev/null; then
      echo "Error: claude CLI not found." >&2
      echo "Install it with: npm install -g @anthropic-ai/claude-code" >&2
      exit 1
    fi

    if [[ "$MODEL" == claude-fable-5* ]]; then
      MINIMUM_CLAUDE_VERSION="2.1.170"
      if ! CLAUDE_VERSION_OUTPUT="$(claude --version 2>&1)"; then
        echo "Error: unable to determine the Claude Code version." >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
      if [[ "$CLAUDE_VERSION_OUTPUT" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        CLAUDE_VERSION="${BASH_REMATCH[1]}"
      else
        echo "Error: unable to parse the Claude Code version from: $CLAUDE_VERSION_OUTPUT" >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
      if ! version_at_least "$CLAUDE_VERSION" "$MINIMUM_CLAUDE_VERSION"; then
        echo "Error: Claude Fable 5 requires Claude Code $MINIMUM_CLAUDE_VERSION or newer; found $CLAUDE_VERSION." >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
    fi
    CLAUDE_BIN="$(command -v claude)"
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

GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
LOG_DIR="${FRESHEYES_LOG_DIR:-$GLOBAL_LOG_DIR}"
mkdir -p "$LOG_DIR"

# Opaque run handle: parent-minted, never a pid. The 6-hex suffix must
# contain at least one [a-f]: all-digit suffixes (probability (10/16)^6
# ≈ 6%) match the retained legacy filename-pid regex `-([0-9]+)\.log$`,
# and with leading zeros stripped a suffix like 000002 resolves to an
# always-live low pid — permanently masking killed_at_launch/died during
# the ownerless launching window (proven by repro).
mint_handle() {
  local suffix
  while :; do
    suffix="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    [[ "$suffix" =~ [a-f] ]] && break
  done
  printf '%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$suffix"
}

if [[ -n "${FRESHEYES_HANDLE:-}" && -n "${FRESHEYES_LOG_FILE:-}" ]]; then
  # Detached child: identity was minted by the parent and arrives via env.
  HANDLE="$FRESHEYES_HANDLE"
  LOG_FILE="$FRESHEYES_LOG_FILE"
else
  # Foreground / automatic / direct runs mint locally.
  HANDLE="$(mint_handle)"
  LOG_FILE="$LOG_DIR/fresheyes-$HANDLE.log"
fi
RESULT_FILE="$LOG_FILE.result.md"
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
STDERR_LOG="$LOG_FILE.stderr"
STATUS_FILE="$LOG_FILE.status.json"
LAUNCH_STDERR="$LOG_FILE.launch.stderr"
# The detached child must record the parent's ACTUAL detach method:
# write_status overwrites detach_method on every write, so a child that
# hardcoded "setsid" would clobber a systemd-run launch's method on its
# first "running" write. The parent forwards FRESHEYES_DETACH_METHOD in
# both launch paths (Task 3 setsid prefix; Task 8 --setenv).
DETACH_METHOD="${FRESHEYES_DETACH_METHOD:-setsid}"
LAUNCHED_AT_EPOCH="$(date +%s)"
OWNER_PID=""

write_tracker_alias() {
  local dir="$1"
  local name="$2"

  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$LOG_FILE" > "$dir/$name" 2>/dev/null || true
}

# Atomic status.json writer. Read-modify-write so parent-written fields
# (launched_at) survive child updates. Call shape unchanged:
#   write_status <state> <exit_code> <verdict>
write_status() {
  local state="$1"
  local exit_code="${2:-}"
  local verdict="${3:-}"
  python3 - "$STATUS_FILE" "$state" "$PROVIDER" "$MODE" "$LOG_FILE" \
    "$exit_code" "$verdict" "${OWNER_PID:-}" "${LAUNCHED_AT_EPOCH:-}" \
    "${DETACH_METHOD:-}" <<'PY' || true
import json, os, sys, time

(path, state, provider, mode, log_path,
 exit_code, verdict, owner_pid, launched_at, detach_method) = sys.argv[1:11]

record = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except Exception:
        record = {}

record["severity"] = "error" if state == "failed" else "info"
record["state"] = state
record["provider"] = provider
record["mode"] = mode
record["log_path"] = log_path
record["updated_at_epoch"] = time.time()
if state != "launching":
    record["heartbeat_at"] = time.time()
if exit_code:
    record["exit_code"] = int(exit_code)
if verdict:
    record["verdict"] = verdict
if owner_pid:
    record["owner_pid"] = int(owner_pid)
    record["pid"] = int(owner_pid)  # legacy readers
if launched_at:
    record.setdefault("launched_at", float(launched_at))
if detach_method:
    record["detach_method"] = detach_method

tmp_path = f"{path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    # Keep the current writer's exact serialization (compact separators +
    # sorted keys + trailing newline): the provider tests assert compact
    # substrings like '"state":"complete"' against this file.
    json.dump(record, handle, separators=(",", ":"), sort_keys=True)
    handle.write("\n")
os.replace(tmp_path, path)
PY
}

# Runtime probe: systemd-run being installed is NOT enough (the user bus can
# be unreachable in some harnesses). Prove it by launching a trivial unit.
_probe_systemd_run() {
  command -v systemd-run &> /dev/null || return 1
  # Hard 2s cap (measured): healthy-bus probe is 0.02-0.28s, but a half-up
  # (accepting-but-mute) bus socket blocks the probe >40s in the sd-bus auth
  # handshake — dead/absent sockets fail in 0.01s, only the half-up case hangs.
  timeout 2s systemd-run --user --collect --quiet --wait /bin/true >/dev/null 2>&1
}

launch_via_systemd_run() {
  local script_abs="$SCRIPT_DIR/$(basename -- "$0")"
  # These must be in the environment BEFORE the forward loop reads them.
  FRESHEYES_CODEX_BIN="${CODEX_BIN:-${FRESHEYES_CODEX_BIN:-}}"
  FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-${FRESHEYES_CLAUDE_BIN:-}}"
  local -a setenv_args=(
    --setenv "FRESHEYES_DAEMONIZED=1"
    --setenv "FRESHEYES_HANDLE=$HANDLE"
    --setenv "FRESHEYES_LOG_FILE=$LOG_FILE"
    --setenv "FRESHEYES_DETACH_METHOD=systemd-run"
    --setenv "PATH=$PATH"
    --setenv "HOME=$HOME"
  )
  # The unit inherits NOTHING from the caller: forward every var the child
  # needs explicitly (verified live: nvm-installed CLIs vanish otherwise).
  local var
  for var in FRESHEYES_LOG_DIR FRESHEYES_GLOBAL_LOG_DIR FRESHEYES_MODE \
             FRESHEYES_PROVIDER FRESHEYES_GPT_MODEL FRESHEYES_CLAUDE_MODEL \
             FRESHEYES_MODEL FRESHEYES_CODEX_BIN FRESHEYES_CLAUDE_BIN \
             FRESHEYES_HEARTBEAT_SECS TMPDIR \
             FRESHEYES_FAKE_ARGV FRESHEYES_FAKE_DELAY \
             FRESHEYES_FAKE_CLAUDE_VERSION FRESHEYES_FAKE_CLAUDE_VERSION_PROBE \
             FRESHEYES_FAKE_VERSION FRESHEYES_FAKE_VERSION_PROBE; do
    if [[ -n "${!var:-}" ]]; then
      setenv_args+=(--setenv "$var=${!var}")
    fi
  done
  systemd-run --user --collect --quiet \
    --property=WorkingDirectory="$PWD" \
    --property=StandardOutput=null \
    --property=StandardError="append:$LAUNCH_STDERR" \
    "${setenv_args[@]}" \
    /usr/bin/env bash "$script_abs" "${ORIG_ARGS[@]}" >/dev/null 2>>"$LAUNCH_STDERR"
}

# --- Detach manual reviews into their own session (default) ---
# Manual reviews are long (5-30 min). By default we re-exec under setsid so the
# review survives the caller's process group — e.g. an agent harness timeout on
# the launch call. The foreground parent prints the review PID and exits in
# under a second; the detached child runs the review and writes all output to
# its log files, retrieved via fresheyes-progress.sh. FRESHEYES_DAEMONIZED=1
# stops the child re-detaching. Automatic mode (the pre-commit gate) and
# --foreground both skip this and run synchronously.
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  # Parent-owned identity: locator + initial status exist BEFORE the child
  # runs, so a child killed at launch still leaves a loud, diagnosable trail.
  write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
  if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
    write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
  fi

  DETACH_METHOD="setsid"
  case "${FRESHEYES_DETACH:-auto}" in
    systemd-run) DETACH_METHOD="systemd-run" ;;
    setsid)      DETACH_METHOD="setsid" ;;
    auto)        if _probe_systemd_run; then DETACH_METHOD="systemd-run"; fi ;;
    *)           echo "Error: FRESHEYES_DETACH must be auto, setsid, or systemd-run." >&2; exit 1 ;;
  esac

  # Status must carry the final detach_method BEFORE the child launches.
  # write_status overwrites detach_method, so the fallback rewrite below is
  # safe — and for the same reason the child MUST inherit the chosen method
  # via FRESHEYES_DETACH_METHOD (setsid env prefix / --setenv above): its
  # own writes would otherwise clobber the field back to "setsid".
  write_status "launching" "" ""
  if [[ "$DETACH_METHOD" == "systemd-run" ]]; then
    if ! launch_via_systemd_run; then
      DETACH_METHOD="setsid"
      write_status "launching" "" ""
    fi
  fi
  if [[ "$DETACH_METHOD" == "setsid" ]]; then
    if ! command -v setsid &> /dev/null; then
      echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
      exit 2
    fi
    FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="$HANDLE" FRESHEYES_LOG_FILE="$LOG_FILE" \
    FRESHEYES_DETACH_METHOD="$DETACH_METHOD" \
    FRESHEYES_CODEX_BIN="${CODEX_BIN:-}" FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-}" \
      setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>>"$LAUNCH_STDERR" &
  fi
  echo "FRESHPID=$HANDLE"
  echo "NEXT: bash $SCRIPT_DIR/fresheyes-progress.sh --json $HANDLE   (reviews take 5-30 min; poll every 30-60s)"
  exit 0
fi

# --- Build prompt ---
PROMPT=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
print(template.replace('{{REVIEW_SCOPE}}', sys.argv[2]))
" "$PROMPT_FILE" "$SCOPE_TEXT")

if [[ "$PROVIDER" == "claude" ]]; then
  : > "$LOG_FILE"
  : > "$EVENT_LOG"
  : > "$STREAM_LOG"
  : > "$STDERR_LOG"
fi

OWNER_PID=$$
echo "$LOG_FILE" > "$LOG_DIR/.active.$HANDLE"

write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
  write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
fi

HEARTBEAT_PID=""
FINAL_STATUS_WRITTEN="0"

manual_verdict_from_log() {
  local review_file="$LOG_FILE"
  if [[ "$PROVIDER" == "gpt" && -s "$RESULT_FILE" ]]; then
    review_file="$RESULT_FILE"
  fi
  if [[ ! -f "$review_file" ]]; then
    return 1
  fi

  python3 - "$review_file" <<'PY' 2>/dev/null
import re
import sys
from pathlib import Path

try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
except OSError:
    raise SystemExit(1)

verdict = ""
for match in re.finditer(r"INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)\b", text, re.IGNORECASE):
    verdict = match.group(1).lower()
if not verdict:
    raise SystemExit(1)
print(verdict)
PY
}

_cleanup() {
  local status=$?
  # Stop the heartbeat BEFORE any terminal write: a beat racing the terminal
  # write_status could re-commit a stale non-terminal record over it.
  _stop_heartbeat
  if [[ "${FINAL_STATUS_WRITTEN:-0}" != "1" ]]; then
    if [[ "$status" -eq 0 ]]; then
      write_status "complete" "$status" "$(manual_verdict_from_log 2>/dev/null || true)" || true
    else
      write_status "failed" "$status" "" || true
    fi
  fi
  rm -f "$LOG_DIR/.active.$HANDLE"
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
  if ! "$CODEX_BIN" exec \
    --sandbox read-only \
    --color never \
    --model "$MODEL" \
    -c features.shell_snapshot=false \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    -o "$RESULT_FILE" \
    "$PROMPT" 2>&1 | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    exit 1
  fi
  if [[ ! -s "$RESULT_FILE" ]]; then
    echo "Fresh Eyes: $PROVIDER_LABEL produced no final review. See log: $LOG_FILE" >&2
    exit 1
  fi
  cat "$RESULT_FILE"
}

run_gpt_automatic() {
  local output_file="$1"
  # Codex writes schema-conforming JSON directly to the output file — no post-processing needed.
  if ! "$CODEX_BIN" exec \
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
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT "$CLAUDE_BIN" -p \
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
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT "$CLAUDE_BIN" -p \
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

# Liveness heartbeat: touch status.json's heartbeat_at every ~20s so the
# progress script can distinguish a live review from a dead one. Replaces
# the old 300s stderr echo, which was invisible when detached.
touch_heartbeat() {
  python3 - "$STATUS_FILE" <<'PY' || true
import json, os, sys, time
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        record = json.load(handle)
except Exception:
    record = {}
# Terminal-state precedence: `kill $HEARTBEAT_PID` covers only the subshell —
# an already-forked python can commit a whole stale record AFTER the terminal
# write, resurrecting state=running (later misread as died). Never write over
# a terminal state.
if record.get("state") in ("complete", "failed"):
    sys.exit(0)
record["heartbeat_at"] = time.time()
tmp_path = f"{path}.tmp.hb.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
os.replace(tmp_path, path)
PY
}

_start_heartbeat() {
  (
    while true; do
      sleep "${FRESHEYES_HEARTBEAT_SECS:-20}"
      # Self-terminate when the owner is gone: a SIGKILLed owner never runs
      # _stop_heartbeat, and an orphan loop beating status.json forever would
      # mask `died` permanently.
      kill -0 "${OWNER_PID:-$$}" 2>/dev/null || exit 0
      touch_heartbeat
    done
  ) &
  HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
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
  _stop_heartbeat
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

_stop_heartbeat
write_status "complete" "0" "$(manual_verdict_from_log 2>/dev/null || true)"
FINAL_STATUS_WRITTEN="1"

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
