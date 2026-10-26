#!/usr/bin/env bash
# fresheyes-progress.sh - Check Fresh Eyes review status or result.
# Usage: fresheyes-progress.sh [--json|--result] [HANDLE]
#
# HANDLE is an opaque review handle: the FRESHPID= receipt value printed at
# launch (historically a pid, now an opaque key). It resolves through the
# .locator.<handle>/.active.<handle> tracker files. This script is strictly
# read-only: it never writes, touches, or removes anything on disk.
#
# Without HANDLE: returns the line count of the legacy .active review (backward compat).
# With HANDLE:   requires --json or --result by default. Bare handle output is
#                disabled because it is easy to mistake stale or truncated
#                legacy logs for current progress.
# With --json: returns compact machine-readable status for polling.
# With --result: returns final review text only after completion.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared with fresheyes.sh: the one home for the verdict marker.
VERDICT_PARSER="$SCRIPT_DIR/fresheyes-verdict.py"
# Shared with fresheyes.sh: the one home for the run marker.
HANDLE_PARSER="$SCRIPT_DIR/fresheyes-handle.py"
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

# The run identity a log file's NAME carries: fresheyes-<handle>.log.
_handle_from_base() {
  local name="${1##*/}"
  name="${name#fresheyes-}"
  printf '%s\n' "${name%.log}"
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

# Owner pid of a run: status.json owner_pid (new), then status.json pid
# (legacy), then the legacy numeric filename suffix. Prints nothing and
# returns 1 when no owner is recorded.
_owner_pid_for_base() {
  local base="$1"
  local owner=""
  owner=$(status_file_field "$base" "owner_pid" 2>/dev/null || true)
  if [[ -z "$owner" ]]; then
    owner=$(status_file_field "$base" "pid" 2>/dev/null || true)
  fi
  if [[ -z "$owner" ]]; then
    owner=$(_pid_from_base "$base" 2>/dev/null || true)
  fi
  if [[ -z "$owner" || ! "$owner" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$owner"
}

# Message discipline for failure states: observation + likely cause +
# certain action, conditioned on captured evidence.
_killed_at_launch_message() {
  local base="$1"
  local launch_stderr="$base.launch.stderr"
  if [[ -s "$launch_stderr" ]]; then
    printf 'the review child crashed during launch — it wrote errors before dying (see %s; last lines: %s). Re-run the same command with --foreground to see the failure directly.' \
      "$launch_stderr" \
      "$(tail -n 3 "$launch_stderr" | tr '\n' ' ' | cut -c1-300)"
  else
    printf 'the review child never wrote its first heartbeat — commonly because the calling harness kills or reaps detached processes when the launch command exits; re-run the same command with --foreground (works regardless of cause)'
  fi
}

_died_message() {
  local base="$1"
  local died_epoch="${HEARTBEAT_AT:-$LAUNCHED_AT}"
  local died_human="unknown"
  if [[ -n "$died_epoch" ]]; then
    died_human=$(date -d "@${died_epoch%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$died_epoch")
  fi
  local recorded=""
  if [[ "$STATUS_STATE" == "failed" ]]; then
    recorded=" The runner recorded state=failed${STATUS_EXIT_CODE:+ (exit_code=$STATUS_EXIT_CODE)}."
  fi
  if [[ "${WITHHOLD_STDERR:-0}" == "1" ]]; then
    # The log holds text that could not be tied to this run. Telling a reader to
    # inspect it for evidence is the same leak as printing it.
    printf 'review died before producing a verdict.%s Last sign of life: %s. The log at %s holds output that could not be tied to this run — it is not evidence about this run and must not be read back. To retry synchronously, re-run the same command with --foreground.' \
      "$recorded" "$died_human" "$base"
  else
    printf 'review died before producing a verdict — inspect the log at %s for evidence.%s Last sign of life: %s. To retry synchronously, re-run the same command with --foreground.' \
      "$base" "$recorded" "$died_human"
  fi
}

_process_state() {
  local pid="$1"
  local stat

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
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
  local count=""
  if [[ -f "$base" ]]; then
    # BSD `wc` pads its count with leading spaces. This value is printed as
    # the legacy numeric progress output and interpolated into the running
    # status line as `final_lines=<n>`, so the padding would reach callers
    # that parse either. Strip it so both platforms emit the bare number.
    count=$(wc -l < "$base" | tr -d '[:space:]')
  fi
  printf '%s\n' "${count:-0}"
}

# The file that IS the run's result. This is upstream's selection, unchanged:
# the GPT manual sidecar when there is one, otherwise the run's log. An earlier
# revision of this branch let status.json name the file instead; three review
# rounds found three generations of defects in that (a confinement that `..`
# and symlinks walked out of, a fallback to the provider transcript, and an
# identity a repointed locator could choose), so it is gone. Verification and
# delivery still read ONE file — this one.
resolve_result_file() {
  local base="$1"
  local provider mode
  provider=$(status_file_field "$base" "provider" 2>/dev/null || true)
  mode=$(status_file_field "$base" "mode" 2>/dev/null || true)
  if [[ "$provider" == "gpt" && "$mode" == "manual" && -s "$base.result.md" ]]; then
    printf '%s\n' "$base.result.md"
    return 0
  fi
  printf '%s\n' "$base"
}

detect_manual_verdict() {
  local base="$1"
  local review_file
  # One selection site, with no fallback to the transcript: a verdict read from
  # provider stdout is a verdict from whatever the reviewer happened to read.
  review_file=$(resolve_result_file "$base")
  python3 "$VERDICT_PARSER" "$review_file" 2>/dev/null
}

print_final_review_if_nonempty() {
  local base="$1"
  local review_file
  review_file=$(resolve_result_file "$base")
  if [[ -s "$review_file" ]]; then
    cat "$review_file"
    return 0
  fi
  return 1
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

  python3 - "$state" "$base" "$requested_pid" "$owner_pid" "$requested_pid_state" "$owner_pid_state" "$verdict" "$message" "${HANDLE_VERIFIED:-}" "${RESULT_HANDLE:-}" <<'PY'
import json
import sys
from pathlib import Path

(state, base_arg, requested_pid, owner_pid, requested_pid_state, owner_pid_state,
 verdict, message, handle_verified, result_handle) = sys.argv[1:11]

record = {"state": state}
record["handle"] = requested_pid
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

for key in (
    "provider",
    "mode",
    "exit_code",
    "updated_at_epoch",
    "detach_method",
    "heartbeat_at",
    "launched_at",
    "owner_pid",
    "reviewed_base",
    "reviewed_head",
):
    if key in status_data and key not in record:
        record[key] = status_data[key]

if "state" in status_data:
    record["runner_state"] = status_data["state"]
if provider_events:
    record["provider_events"] = provider_events
if last_provider_event:
    record["last_provider_event"] = last_provider_event
if state == "handle_mismatch":
    # The result was refused: it must not carry a verdict, from either source.
    record.pop("verdict", None)
elif verdict:
    record["verdict"] = verdict
elif isinstance(status_data.get("verdict"), str) and status_data["verdict"]:
    record["verdict"] = status_data["verdict"]
if handle_verified in ("true", "false"):
    record["handle_verified"] = handle_verified == "true"
if result_handle:
    record["result_handle"] = result_handle
record["result_available"] = bool(record.get("verdict") and record.get("line_count", 0) > 0)
if state == "handle_mismatch":
    record["result_available"] = False

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

# print_failure_diagnostic <base> [withhold_stderr]
# With withhold_stderr=1 the provider's stderr is named, not quoted: on a run
# whose result could not be verified, those lines are unverified review text and
# must not reach the caller through a diagnostic. The killed_at_launch and died
# paths, where no result exists at all, keep the quoted tail.
print_failure_diagnostic() {
  local base="$1"
  local withhold_stderr="${2:-0}"
  python3 - "$base" "$withhold_stderr" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

base = Path(sys.argv[1])
withhold_stderr = len(sys.argv) > 2 and sys.argv[2] == "1"
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
if stderr_log.exists() and not withhold_stderr:
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
if withhold_stderr and stderr_log.exists():
    print()
    print(f"stderr (withheld — this run's result could not be verified): {stderr_log}")
elif stderr_lines:
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

# The refusal's own diagnostic: metadata and paths, never the review text and
# never the provider's stderr.
print_mismatch_diagnostic() {
  local base="$1"
  printf '%s\n' "$MESSAGE"
  printf '\n'
  printf 'state=handle_mismatch\n'
  printf 'expected_handle=%s\n' "${EXPECTED_HANDLE:-unknown}"
  printf 'result_handle=%s\n' "${RESULT_HANDLE:-unknown}"
  printf 'log_path=%s\n' "$base"
  printf 'result_path=%s\n' "$(resolve_result_file "$base")"
}

print_result_or_pending() {
  local state="$1"
  local base="$2"

  case "$state" in
    complete)
      if print_final_review_if_nonempty "$base"; then
        return 0
      fi
      print_failure_diagnostic "$base" "$WITHHOLD_STDERR"
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
    UNKNOWN_MSG="no tracker for this handle in $LOG_DIR"
    if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
      UNKNOWN_MSG="$UNKNOWN_MSG or $GLOBAL_LOG_DIR"
    fi
    UNKNOWN_MSG="$UNKNOWN_MSG — the handle is wrong, or its trackers were removed (e.g. /tmp cleanup)"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      print_json_status "unknown_handle" "" "$PID" "" "$(_process_state "$PID")" "" "" "$UNKNOWN_MSG"
      exit 5
    fi
    if [[ "$OUTPUT_MODE" == "result" ]]; then
      printf '%s\n' "$UNKNOWN_MSG"
      exit 5
    fi
    printf '%s\n' "$UNKNOWN_MSG"
    exit 5
  fi
else
  LOG_FILE=$(_find_legacy_base || true)
  if [[ -z "$LOG_FILE" ]]; then
    UNKNOWN_MSG="no active Fresh Eyes review found in $LOG_DIR — the handle is wrong, or its trackers were removed (e.g. /tmp cleanup)"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      print_json_status "unknown_handle" "" "" "" "" "" "" "$UNKNOWN_MSG"
      exit 5
    fi
    if [[ "$OUTPUT_MODE" == "result" ]]; then
      printf '%s\n' "$UNKNOWN_MSG"
      exit 5
    fi
    printf '%s\n' "$UNKNOWN_MSG"
    exit 5
  fi
fi

OWNER_PID=$(_owner_pid_for_base "$LOG_FILE" 2>/dev/null || true)
REQUESTED_PID_STATE=$(_process_state "$PID")
OWNER_PID_STATE=""
if [[ -n "$OWNER_PID" && "$OWNER_PID" != "$PID" ]]; then
  OWNER_PID_STATE=$(_process_state "$OWNER_PID")
fi

STATUS_STATE=$(status_file_field "$LOG_FILE" "state" 2>/dev/null || true)
STATUS_VERDICT=$(status_file_field "$LOG_FILE" "verdict" 2>/dev/null || true)
STATUS_EXIT_CODE=$(status_file_field "$LOG_FILE" "exit_code" 2>/dev/null || true)
STATUS_HANDLE=$(status_file_field "$LOG_FILE" "handle" 2>/dev/null || true)
STATUS_RESULT_HANDLE=$(status_file_field "$LOG_FILE" "result_handle" 2>/dev/null || true)
# The expectation is the handle the CALLER polled with. Two things it must not
# be, both learned by getting it wrong:
#   - status.json's `handle`. Repointing .locator.<caller's handle> at ANOTHER
#     run's genuine base — one line, in the same shared directory — then makes
#     the poller read that run's handle, compare it with that run's own marker,
#     and deliver its review as this one's. No text has to be forged.
#   - "$PID" with no exception. A handle also resolves through the glob in
#     _find_base_for_pid_in_dir, which matches fresheyes-*-<pid>.log, so a
#     caller may legitimately poll with a SUFFIX of the real handle, and
#     comparing a correct marker against that suffix accuses a good review.
# So: the polled handle, widened to the resolved file's name ONLY in the case the
# glob creates — a legacy NUMERIC pid, matched as fresheyes-*-<pid>.log. Both
# halves are needed: an unanchored suffix would let a repointed locator through
# (1234 is a suffix of ...-ab1234), and allowing a non-numeric handle to widen
# would reach past the one resolution path that can hand back a shortened name.
BASE_HANDLE="$(_handle_from_base "$LOG_FILE")"
EXPECTED_HANDLE="$PID"
if [[ -n "$PID" && "$PID" =~ ^[0-9]+$ && -n "$BASE_HANDLE" && "$BASE_HANDLE" != "$PID" && "$BASE_HANDLE" == *-"$PID" ]]; then
  EXPECTED_HANDLE="$BASE_HANDLE"
fi
if [[ -z "$EXPECTED_HANDLE" ]]; then
  # The legacy no-handle invocation has nothing else to go on. It only feeds
  # the comparison; a record with no handle at all delivers unverified anyway.
  EXPECTED_HANDLE="$STATUS_HANDLE"
fi
HANDLE_VERIFIED=""
RESULT_HANDLE=""
# The provider's .stderr can hold review text and can never be verified, so the
# failure diagnostics quote it only for a run whose result IS verified as this
# run's. A record with no `handle` was written before this check existed: its
# result is delivered unverified by design, so its diagnostics are unchanged.
WITHHOLD_STDERR=0

# Ask the one home for the run marker whose review the resolved result is.
# Sets HANDLE_VERIFIED (true/false) and RESULT_HANDLE; returns the checker's
# status. Never lets an unhandled exit take the poller down.
# This script does not run under errexit (it never enables it), so no set-flag
# juggling is needed here — and none may be added: `set +e` … `set -e` around a
# call would switch errexit ON for the rest of the run, breaking the paths that
# let a command fail on purpose (print_claude_running_status, line_count_or_zero).
verify_result_handle() {
  local base="$1"
  local review_file output status
  review_file=$(resolve_result_file "$base")
  output="$(python3 "$HANDLE_PARSER" "$review_file" "$EXPECTED_HANDLE" 2>/dev/null)"
  status=$?
  case "$status" in
    0) HANDLE_VERIFIED="true" ;;
    6) HANDLE_VERIFIED="false"; RESULT_HANDLE="${output#mismatch }" ;;
    *) HANDLE_VERIFIED="false" ;;
  esac
  return "$status"
}
HEARTBEAT_AT=$(status_file_field "$LOG_FILE" "heartbeat_at" 2>/dev/null || true)
LAUNCHED_AT=$(status_file_field "$LOG_FILE" "launched_at" 2>/dev/null || true)
NOW_EPOCH=$(date +%s)
STALE_SECS="${FRESHEYES_HEARTBEAT_STALE_SECS:-60}"
LAUNCH_GRACE_SECS="${FRESHEYES_LAUNCH_GRACE_SECS:-15}"

_owner_alive() {
  [[ -n "$OWNER_PID" ]] || return 1
  [[ "$(_process_state "$OWNER_PID")" == "active" ]]
}

_epoch_within() {
  # _epoch_within <epoch> <window_secs> : true when now - epoch < window
  local epoch="$1" window="$2"
  [[ -n "$epoch" ]] || return 1
  python3 - "$epoch" "$NOW_EPOCH" "$window" <<'PY'
import sys
epoch, now, window = (float(a) for a in sys.argv[1:4])
sys.exit(0 if now - epoch < window else 1)
PY
}

# Verdict extraction: status.json wins over raw-log regex (Codex logs can
# contain verdict-shaped examples).
VERDICT=""
if [[ -n "$STATUS_STATE" ]]; then
  if [[ "$STATUS_STATE" == "complete" && "$STATUS_VERDICT" =~ ^(passed|failed)$ ]]; then
    VERDICT="$STATUS_VERDICT"
  fi
else
  VERDICT=$(detect_manual_verdict "$LOG_FILE" 2>/dev/null || true)
fi

# Verify ONCE, before the state machine, so every terminal state knows whether
# this run's result is its own — not only `complete`. A refusal whose terminal
# status write failed leaves a stale `running` record, and the poller then
# reports `died`: that path must withhold the provider's stderr too.
_HANDLE_STATUS=""
if [[ -n "$EXPECTED_HANDLE" ]]; then
  # Every record, automatic included. Exempting automatic ones was tried and
  # reverted: it skipped this block entirely, so a `.locator` repointed at a
  # completed automatic run delivered THAT run's result under this caller's
  # handle — for the Claude provider the review log IS the structured JSON — and
  # it skipped the stderr suppression below with it. Reading an automatic
  # record's log is sound: for Claude it is the JSON result and carries
  # run_handle; for GPT it is the transcript, which has no marker line and so
  # reports unverified rather than refusing.
  verify_result_handle "$LOG_FILE"
  _HANDLE_STATUS=$?
  # A DETECTED mismatch withholds whatever the metadata says: the provider's
  # stderr is a second copy of the same refused text, and a record can reach the
  # `died` branch (state=failed) where that tail would otherwise be quoted.
  # Short of a mismatch, the suppression applies to runs this tooling produced —
  # a record with no `handle` is a pre-change run whose result is delivered
  # unverified by design, and its diagnostics are unchanged.
  if [[ "$_HANDLE_STATUS" == "6" ]]; then
    WITHHOLD_STDERR=1
  elif [[ "$HANDLE_VERIFIED" != "true" && -n "$STATUS_HANDLE" ]]; then
    WITHHOLD_STDERR=1
  fi
fi

MESSAGE=""
STATE_EXIT_CODE=0
_mismatch_message() {
  local foreign="${1:-}"
  local result_file
  result_file=$(resolve_result_file "$LOG_FILE")
  if [[ -n "$foreign" ]]; then
    printf 'handle_mismatch — this result carries review run %s, not %s. It is another review'"'"'s text, so it was not returned; re-run the review. The withheld text is in %s, which is not evidence about this run and must not be read back.' \
      "$foreign" "${EXPECTED_HANDLE:-this run}" "$result_file"
  else
    # No foreign marker: the result simply could not be tied to this run — the
    # reviewer omitted the marker, or the check could not be made. Saying "it is
    # another review's text" here would be a false accusation.
    printf 'handle_mismatch — this result could not be tied to review run %s: it carries no run marker, or the marker could not be checked. It was not returned; re-run the review. The unverified text is in %s and is not evidence about this run.' \
      "${EXPECTED_HANDLE:-this run}" "$result_file"
  fi
}
if [[ "$STATUS_STATE" == "handle_mismatch" ]]; then
  # Recorded by the runner. This branch precedes the "failed" → died branch so
  # a detached run's refusal is never reported as a death.
  REVIEW_STATE="handle_mismatch"
  STATE_EXIT_CODE=6
  HANDLE_VERIFIED="false"
  RESULT_HANDLE="$STATUS_RESULT_HANDLE"
  WITHHOLD_STDERR=1
  MESSAGE=$(_mismatch_message "$STATUS_RESULT_HANDLE")
elif [[ "$STATUS_STATE" == "complete" || -n "$VERDICT" ]]; then
  REVIEW_STATE="complete"
  # The verification above is this script's own, whatever status.json claims:
  # the poller is what the caller trusts, and a status file written by another
  # version, or by a racing writer, must not be able to talk it into printing a
  # foreign review. A mismatch is the only outcome that refuses; no marker, an
  # unreadable result and a checker that could not run all deliver unverified.
  if [[ "$_HANDLE_STATUS" == "6" ]]; then
    REVIEW_STATE="handle_mismatch"
    STATE_EXIT_CODE=6
    VERDICT=""
    MESSAGE=$(_mismatch_message "$RESULT_HANDLE")
  fi
elif [[ "$STATUS_STATE" == "launching" ]]; then
  if _owner_alive || _epoch_within "$LAUNCHED_AT" "$LAUNCH_GRACE_SECS"; then
    REVIEW_STATE="launching"
    MESSAGE="review starting — poll again in ~15s"
  else
    REVIEW_STATE="killed_at_launch"
    STATE_EXIT_CODE=3
    MESSAGE=$(_killed_at_launch_message "$LOG_FILE")
  fi
elif [[ "$STATUS_STATE" == "failed" ]]; then
  # Terminal child-recorded failure: report immediately. This branch MUST
  # precede the heartbeat-freshness check — the runner stamps heartbeat_at
  # on the terminal "failed" write too, so freshness-first would mask a
  # recorded failure as healthy "running" for up to STALE_SECS.
  REVIEW_STATE="died"
  STATE_EXIT_CODE=4
  MESSAGE=$(_died_message "$LOG_FILE")
elif _epoch_within "$HEARTBEAT_AT" "$STALE_SECS" || _owner_alive; then
  REVIEW_STATE="running"
elif [[ -z "$STATUS_STATE" && ! -s "$LOG_FILE" && -n "$PID" ]] && ! _owner_alive; then
  # Resolvable handle but nothing was ever written and nobody is alive:
  # the child never started (e.g. killed between the parent's two writes).
  REVIEW_STATE="killed_at_launch"
  STATE_EXIT_CODE=3
  MESSAGE=$(_killed_at_launch_message "$LOG_FILE")
elif [[ -z "$PID" ]]; then
  # Legacy no-handle invocation has no liveness signal; preserve old default.
  REVIEW_STATE="running"
else
  REVIEW_STATE="died"
  STATE_EXIT_CODE=4
  MESSAGE=$(_died_message "$LOG_FILE")
fi

if [[ "$OUTPUT_MODE" == "json" ]]; then
  print_json_status "$REVIEW_STATE" "$LOG_FILE" "$PID" "$OWNER_PID" "$REQUESTED_PID_STATE" "$OWNER_PID_STATE" "$VERDICT" "$MESSAGE"
  exit "$STATE_EXIT_CODE"
fi

if [[ "$OUTPUT_MODE" == "result" ]]; then
  if [[ "$REVIEW_STATE" == "handle_mismatch" ]]; then
    # A diagnostic of its own: print_failure_diagnostic quotes the provider's
    # stderr, which on a replay is the very review just refused.
    print_mismatch_diagnostic "$LOG_FILE"
    exit "$STATE_EXIT_CODE"
  fi
  if [[ "$REVIEW_STATE" == "killed_at_launch" || "$REVIEW_STATE" == "died" ]]; then
    printf '%s\n' "$MESSAGE"
    print_failure_diagnostic "$LOG_FILE" "$WITHHOLD_STDERR"
    exit "$STATE_EXIT_CODE"
  fi
  print_result_or_pending "$REVIEW_STATE" "$LOG_FILE"
  exit $?
fi

if [[ "$REVIEW_STATE" == "handle_mismatch" ]]; then
  print_mismatch_diagnostic "$LOG_FILE"
  exit "$STATE_EXIT_CODE"
fi

if [[ "$REVIEW_STATE" == "complete" ]]; then
  if print_final_review_if_nonempty "$LOG_FILE"; then
    exit 0
  fi
  print_failure_diagnostic "$LOG_FILE" "$WITHHOLD_STDERR"
  exit 0
fi

if [[ "$REVIEW_STATE" == "killed_at_launch" || "$REVIEW_STATE" == "died" ]]; then
  printf '%s\n' "$MESSAGE"
  print_failure_diagnostic "$LOG_FILE" "$WITHHOLD_STDERR"
  exit "$STATE_EXIT_CODE"
fi

if [[ "$REVIEW_STATE" == "launching" ]]; then
  printf '%s\n' "$MESSAGE"
  exit 0
fi

PROVIDER="$(event_log_provider "$LOG_FILE")"
if [[ "$PROVIDER" == "claude" ]]; then
  print_claude_running_status "$LOG_FILE"
else
  line_count_or_zero "$LOG_FILE"
fi
