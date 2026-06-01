#!/usr/bin/env bash
# fresheyes-progress.sh - Check if a fresheyes review is still producing output.
# Usage: fresheyes-progress.sh [PID]
#
# Without PID: returns the line count of the legacy .active review (backward compat).
# With PID:    returns progress for the review tracked by .active.$PID.
#              If the process identified by PID is dead, outputs the full review
#              log or a concise diagnostic assembled from sidecar logs.

LOG_DIR="${TMPDIR:-/tmp}/fresheyes-logs"
GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
PID="${1:-}"

_base_from_related_path() {
  local path="$1"
  case "$path" in
    *.events.jsonl) printf '%s\n' "${path%.events.jsonl}" ;;
    *.stream.jsonl) printf '%s\n' "${path%.stream.jsonl}" ;;
    *.stderr) printf '%s\n' "${path%.stderr}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

_related_file_exists() {
  local base="$1"
  [[ -f "$base" || -f "$base.events.jsonl" || -f "$base.stream.jsonl" || -f "$base.stderr" ]]
}

_pid_from_base() {
  local base="$1"
  local name="${base##*/}"
  if [[ "$name" =~ -([0-9]+)\.log$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

_tracker_path() {
  local tracker_file="$1"
  if [[ ! -f "$tracker_file" ]]; then
    return 1
  fi

  local tracked_path
  tracked_path=$(cat "$tracker_file" 2>/dev/null)
  if [[ -z "$tracked_path" ]]; then
    return 1
  fi
  _base_from_related_path "$tracked_path"
}

_find_base_for_pid_in_dir() {
  local dir="$1"
  local pid="$2"
  local tracker_file
  local tracked_path
  local matches=()
  local newest

  for tracker_file in "$dir/.active.$pid" "$dir/.locator.$pid"; do
    if tracked_path=$(_tracker_path "$tracker_file"); then
      if _related_file_exists "$tracked_path"; then
        printf '%s\n' "$tracked_path"
        return 0
      fi
      case "$tracker_file" in
        "$dir/.locator.$pid")
          printf '%s\n' "$tracked_path"
          return 0
          ;;
      esac
    fi
  done

  if ! kill -0 "$pid" 2>/dev/null; then
    tracker_file="$dir/.parent.$pid"
    if tracked_path=$(_tracker_path "$tracker_file"); then
      printf '%s\n' "$tracked_path"
      return 0
    fi
  fi

  shopt -s nullglob
  matches=(
    "$dir"/fresheyes-*-"$pid".log
    "$dir"/fresheyes-*-"$pid".log.events.jsonl
    "$dir"/fresheyes-*-"$pid".log.stream.jsonl
    "$dir"/fresheyes-*-"$pid".log.stderr
  )
  shopt -u nullglob

  if [[ ${#matches[@]} -eq 0 ]]; then
    return 1
  fi

  newest=$(ls -t "${matches[@]}" 2>/dev/null | head -1)
  if [[ -z "$newest" ]]; then
    return 1
  fi
  _base_from_related_path "$newest"
}

_find_base_for_pid() {
  local pid="$1"
  local dir
  local candidate_dirs=("$LOG_DIR")

  if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
    candidate_dirs+=("$GLOBAL_LOG_DIR")
  fi
  if [[ -d /tmp/claude-1000/fresheyes-logs && "/tmp/claude-1000/fresheyes-logs" != "$LOG_DIR" && "/tmp/claude-1000/fresheyes-logs" != "$GLOBAL_LOG_DIR" ]]; then
    candidate_dirs+=("/tmp/claude-1000/fresheyes-logs")
  fi

  for dir in "${candidate_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      if _find_base_for_pid_in_dir "$dir" "$pid"; then
        return 0
      fi
    fi
  done

  return 1
}

_review_is_running() {
  local requested_pid="$1"
  local base="$2"
  local owner_pid

  if kill -0 "$requested_pid" 2>/dev/null; then
    return 0
  fi

  owner_pid=$(_pid_from_base "$base" 2>/dev/null || true)
  if [[ -n "$owner_pid" && "$owner_pid" != "$requested_pid" ]]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

_find_legacy_base() {
  local active_file="$LOG_DIR/.active"
  if [[ ! -f "$active_file" ]]; then
    return 1
  fi

  local active_path
  active_path=$(cat "$active_file" 2>/dev/null)
  if [[ -n "$active_path" ]] && _related_file_exists "$active_path"; then
    printf '%s\n' "$active_path"
    return 0
  fi
  return 1
}

line_count_or_zero() {
  local base="$1"
  if [[ -f "$base" ]]; then
    wc -l < "$base"
  else
    printf '0\n'
  fi
}

cat_if_nonempty() {
  local base="$1"
  if [[ -s "$base" ]]; then
    cat "$base"
    return 0
  fi
  return 1
}

event_log_provider() {
  local base="$1"
  local event_log="$base.events.jsonl"
  if [[ ! -f "$event_log" ]]; then
    return 0
  fi

  python3 - "$event_log" <<'PY' 2>/dev/null || true
import json
import sys

provider = ""
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        try:
            item = json.loads(line)
        except Exception:
            continue
        if isinstance(item, dict) and isinstance(item.get("provider"), str):
            provider = item["provider"]
print(provider)
PY
}

print_claude_running_status() {
  local base="$1"
  local final_lines
  local status
  final_lines=$(line_count_or_zero "$base")

  python3 - "$base.events.jsonl" "$final_lines" <<'PY' 2>/dev/null
import json
import sys

event_log = sys.argv[1]
final_lines = sys.argv[2]
provider_events = 0
last = {}

try:
    handle = open(event_log, encoding="utf-8")
except OSError:
    handle = None

if handle is not None:
    with handle:
        for line in handle:
            try:
                item = json.loads(line)
            except Exception:
                continue
            if (
                isinstance(item, dict)
                and item.get("provider") == "claude"
                and item.get("event") == "provider_event"
            ):
                provider_events += 1
                last = item

last_name = (
    last.get("stream_event_type")
    or last.get("type")
    or last.get("event")
    or "none"
)
parts = [
    "running",
    "provider=claude",
    f"provider_events={provider_events}",
    f"last_provider_event={last_name}",
    f"final_lines={final_lines}",
]
for key in ("stream_event_type", "tool", "subtype", "status"):
    value = last.get(key)
    if isinstance(value, str) and value:
        parts.append(f"{key}={value}")
print(" ".join(parts))
PY
  status=$?
  if [[ $status -ne 0 ]]; then
    printf 'running provider=claude provider_events=0 last_provider_event=none final_lines=%s\n' "$final_lines"
  fi
}

print_failure_diagnostic() {
  local base="$1"
  python3 - "$base" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

base = Path(sys.argv[1])
event_log = Path(str(base) + ".events.jsonl")
stderr_log = Path(str(base) + ".stderr")
stream_log = Path(str(base) + ".stream.jsonl")

provider = "unknown"
last_event = "unknown"
last_error = ""

if event_log.exists():
    with event_log.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except Exception:
                continue
            if not isinstance(item, dict):
                continue
            if isinstance(item.get("provider"), str) and item["provider"]:
                provider = item["provider"]
            if isinstance(item.get("event"), str) and item["event"]:
                last_event = item["event"]
            if item.get("severity") == "error":
                last_error = str(item.get("event") or item.get("message") or last_error)

stderr_lines = []
if stderr_log.exists():
    try:
        stderr_lines = stderr_log.read_text(encoding="utf-8", errors="replace").splitlines()[-20:]
    except OSError:
        stderr_lines = []

if not last_error and stderr_lines:
    last_error = stderr_lines[-1]
if not last_error:
    last_error = "unknown"

print("Fresh Eyes review failed before final output.")
print()
print(f"provider={provider}")
print(f"last_event={last_event}")
print(f"last_error={last_error}")
if stderr_lines:
    print()
    print("stderr:")
    for line in stderr_lines:
        print(line)
elif event_log.exists() or stream_log.exists():
    print()
    print("sidecars:")
    if event_log.exists():
        print(f"- {event_log}")
    if stream_log.exists():
        print(f"- {stream_log}")
PY
}

if [[ -n "$PID" ]]; then
  LOG_FILE=$(_find_base_for_pid "$PID")
  if [[ -z "$LOG_FILE" ]]; then
    echo "0"
    exit 0
  fi
else
  LOG_FILE=$(_find_legacy_base)
  if [[ -z "$LOG_FILE" ]]; then
    echo "0"
    exit 0
  fi
fi

if [[ -n "$PID" ]] && ! _review_is_running "$PID" "$LOG_FILE"; then
  rm -f "$LOG_DIR/.active.$PID"
  if cat_if_nonempty "$LOG_FILE"; then
    exit 0
  fi
  print_failure_diagnostic "$LOG_FILE"
  exit 0
fi

PROVIDER="$(event_log_provider "$LOG_FILE")"
if [[ "$PROVIDER" == "claude" ]]; then
  print_claude_running_status "$LOG_FILE"
else
  line_count_or_zero "$LOG_FILE"
fi
