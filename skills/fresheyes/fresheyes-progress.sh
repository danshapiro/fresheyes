#!/usr/bin/env bash
# fresheyes-progress.sh - Check Fresh Eyes review status or result.
# Usage: fresheyes-progress.sh [--json|--result] [PID]
#
# Without PID: returns the line count of the legacy .active review (backward compat).
# With PID:    requires --json or --result by default. Bare PID output is disabled
#              because it is easy to mistake stale or truncated legacy logs for
#              current progress.
# With --json: returns compact machine-readable status for polling.
# With --result: returns final review text only after completion.

GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
LOG_DIR="${FRESHEYES_LOG_DIR:-$GLOBAL_LOG_DIR}"
ALLOW_LEGACY_PROGRESS="${FRESHEYES_ALLOW_LEGACY_PROGRESS:-0}"
OUTPUT_MODE="legacy"
PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_MODE="json"
      shift
      ;;
    --result)
      OUTPUT_MODE="result"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PID" ]]; then
        echo "Error: only one PID may be provided." >&2
        exit 2
      fi
      PID="$1"
      shift
      ;;
  esac
done

if [[ -n "$PID" && "$OUTPUT_MODE" == "legacy" && "$ALLOW_LEGACY_PROGRESS" != "1" ]]; then
  echo "Error: PID polling requires --json or --result. Bare PID output is disabled to avoid stale or truncated Fresh Eyes progress." >&2
  exit 2
fi

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

_process_state() {
  local pid="$1"
  local stat

  if [[ -z "$pid" ]]; then
    printf 'unknown\n'
    return 0
  fi

  stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$stat" ]]; then
    printf 'missing\n'
  elif [[ "$stat" == *Z* ]]; then
    printf 'zombie\n'
  else
    printf 'active\n'
  fi
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

_path_is_under_dir() {
  local path="$1"
  local dir="${2%/}"
  [[ "$path" == "$dir"/* ]]
}

_tracker_target_allowed() {
  local dir="$1"
  local tracked_path="$2"

  if [[ "$ALLOW_LEGACY_PROGRESS" == "1" ]]; then
    return 0
  fi

  if _path_is_under_dir "$tracked_path" "$dir"; then
    return 0
  fi

  if _path_is_under_dir "$tracked_path" "$GLOBAL_LOG_DIR"; then
    return 0
  fi

  return 1
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
      if ! _tracker_target_allowed "$dir" "$tracked_path"; then
        continue
      fi
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

  if [[ $(_process_state "$pid") != "active" ]]; then
    tracker_file="$dir/.parent.$pid"
    if tracked_path=$(_tracker_path "$tracker_file"); then
      if ! _tracker_target_allowed "$dir" "$tracked_path"; then
        return 1
      fi
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
  if [[ "$ALLOW_LEGACY_PROGRESS" == "1" && -d /tmp/claude-1000/fresheyes-logs && "/tmp/claude-1000/fresheyes-logs" != "$LOG_DIR" && "/tmp/claude-1000/fresheyes-logs" != "$GLOBAL_LOG_DIR" ]]; then
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

  if [[ $(_process_state "$requested_pid") == "active" ]]; then
    return 0
  fi

  owner_pid=$(_pid_from_base "$base" 2>/dev/null || true)
  if [[ -n "$owner_pid" && "$owner_pid" != "$requested_pid" ]]; then
    if [[ $(_process_state "$owner_pid") == "active" ]]; then
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

detect_manual_verdict() {
  local base="$1"
  if [[ ! -f "$base" ]]; then
    return 1
  fi

  python3 - "$base" <<'PY' 2>/dev/null
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

status_file_field() {
  local base="$1"
  local field="$2"
  local status_file="$base.status.json"

  if [[ ! -f "$status_file" ]]; then
    return 1
  fi

  python3 - "$status_file" "$field" <<'PY' 2>/dev/null
import json
import sys

path, field = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)

value = data.get(field) if isinstance(data, dict) else None
if value in (None, ""):
    sys.exit(1)
print(value)
PY
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

print_json_status() {
  local state="$1"
  local base="$2"
  local requested_pid="$3"
  local owner_pid="$4"
  local requested_pid_state="$5"
  local owner_pid_state="$6"
  local verdict="$7"
  local message="${8:-}"

  python3 - "$state" "$base" "$requested_pid" "$owner_pid" "$requested_pid_state" "$owner_pid_state" "$verdict" "$message" <<'PY'
import json
import sys
from pathlib import Path

state, base_arg, requested_pid, owner_pid, requested_pid_state, owner_pid_state, verdict, message = sys.argv[1:9]

record = {"state": state}
if message:
    record["message"] = message
if requested_pid:
    try:
        record["pid"] = int(requested_pid)
    except ValueError:
        record["pid"] = requested_pid
if requested_pid_state:
    record["pid_state"] = requested_pid_state
if owner_pid:
    try:
        record["owner_pid"] = int(owner_pid)
    except ValueError:
        record["owner_pid"] = owner_pid
if owner_pid_state:
    record["owner_pid_state"] = owner_pid_state

base = Path(base_arg) if base_arg else None
status_data = {}
provider_events = 0
last_provider_event = ""

if base is not None:
    record["log_path"] = str(base)
    if base.exists():
        try:
            record["line_count"] = sum(1 for _ in base.open(encoding="utf-8", errors="replace"))
        except OSError:
            record["line_count"] = 0
        try:
            record["last_log_mtime_epoch"] = int(base.stat().st_mtime)
        except OSError:
            pass
    else:
        record["line_count"] = 0

    status_path = Path(str(base) + ".status.json")
    if status_path.exists():
        record["status_path"] = str(status_path)
        try:
            with status_path.open(encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                status_data = loaded
        except Exception:
            status_data = {}

    event_path = Path(str(base) + ".events.jsonl")
    if event_path.exists():
        try:
            with event_path.open(encoding="utf-8") as handle:
                for line in handle:
                    try:
                        item = json.loads(line)
                    except Exception:
                        continue
                    if not isinstance(item, dict):
                        continue
                    if isinstance(item.get("provider"), str) and item["provider"]:
                        record["provider"] = item["provider"]
                    if item.get("event") == "provider_event":
                        provider_events += 1
                        last_provider_event = (
                            item.get("stream_event_type")
                            or item.get("type")
                            or item.get("event")
                            or ""
                        )
        except OSError:
            pass

for key in ("provider", "mode", "exit_code", "updated_at_epoch"):
    if key in status_data and key not in record:
        record[key] = status_data[key]

if "state" in status_data:
    record["runner_state"] = status_data["state"]
if provider_events:
    record["provider_events"] = provider_events
if last_provider_event:
    record["last_provider_event"] = last_provider_event
if verdict:
    record["verdict"] = verdict
elif isinstance(status_data.get("verdict"), str) and status_data["verdict"]:
    record["verdict"] = status_data["verdict"]
record["result_available"] = bool(record.get("verdict") and record.get("line_count", 0) > 0)

print(json.dumps(record, separators=(",", ":"), sort_keys=True))
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

print_result_or_pending() {
  local state="$1"
  local base="$2"

  case "$state" in
    complete)
      if cat_if_nonempty "$base"; then
        return 0
      fi
      print_failure_diagnostic "$base"
      return 1
      ;;
    failed)
      print_failure_diagnostic "$base"
      return 1
      ;;
    *)
      printf 'Fresh Eyes review is not complete yet. Poll with --json for current status.\n'
      return 1
      ;;
  esac
}

if [[ -n "$PID" ]]; then
  LOG_FILE=$(_find_base_for_pid "$PID" || true)
  if [[ -z "$LOG_FILE" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      print_json_status "missing" "" "$PID" "" "$(_process_state "$PID")" "" "" "no tracked Fresh Eyes output found"
      exit 0
    fi
    if [[ "$OUTPUT_MODE" == "result" ]]; then
      printf 'Fresh Eyes review output is not available.\n'
      exit 1
    fi
    echo "0"
    exit 0
  fi
else
  LOG_FILE=$(_find_legacy_base || true)
  if [[ -z "$LOG_FILE" ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      print_json_status "missing" "" "" "" "" "" "" "no active Fresh Eyes review found"
      exit 0
    fi
    if [[ "$OUTPUT_MODE" == "result" ]]; then
      printf 'Fresh Eyes review output is not available.\n'
      exit 1
    fi
    echo "0"
    exit 0
  fi
fi

OWNER_PID=$(_pid_from_base "$LOG_FILE" 2>/dev/null || true)
REQUESTED_PID_STATE=$(_process_state "$PID")
OWNER_PID_STATE=""
if [[ -n "$OWNER_PID" && "$OWNER_PID" != "$PID" ]]; then
  OWNER_PID_STATE=$(_process_state "$OWNER_PID")
fi

VERDICT=$(detect_manual_verdict "$LOG_FILE" 2>/dev/null || true)
STATUS_STATE=$(status_file_field "$LOG_FILE" "state" 2>/dev/null || true)
STATUS_VERDICT=$(status_file_field "$LOG_FILE" "verdict" 2>/dev/null || true)
if [[ "$STATUS_STATE" == "running" ]]; then
  # Codex logs include inspected source and command output while the review is
  # active. Those intermediate lines can contain verdict examples, so the
  # runner's explicit state is authoritative until it finishes.
  VERDICT=""
elif [[ -z "$VERDICT" && "$STATUS_VERDICT" =~ ^(passed|failed)$ ]]; then
  VERDICT="$STATUS_VERDICT"
fi

if [[ -n "$VERDICT" || "$STATUS_STATE" == "complete" ]]; then
  REVIEW_STATE="complete"
elif [[ "$STATUS_STATE" == "failed" ]]; then
  REVIEW_STATE="failed"
elif [[ -n "$PID" ]] && _review_is_running "$PID" "$LOG_FILE"; then
  REVIEW_STATE="running"
elif [[ -n "$PID" ]]; then
  REVIEW_STATE="failed"
else
  REVIEW_STATE="running"
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
  print_json_status "$REVIEW_STATE" "$LOG_FILE" "$PID" "$OWNER_PID" "$REQUESTED_PID_STATE" "$OWNER_PID_STATE" "$VERDICT"
  exit 0
fi

if [[ "$OUTPUT_MODE" == "result" ]]; then
  print_result_or_pending "$REVIEW_STATE" "$LOG_FILE"
  exit $?
fi

if [[ "$REVIEW_STATE" == "complete" ]]; then
  if cat_if_nonempty "$LOG_FILE"; then
    exit 0
  fi
  print_failure_diagnostic "$LOG_FILE"
  exit 0
fi

if [[ "$REVIEW_STATE" == "failed" && -n "$PID" ]]; then
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
