#!/usr/bin/env bash
# fresheyes-progress.sh - Check if a fresheyes review is still producing output.
# Usage: fresheyes-progress.sh [PID]
#
# Without PID: returns the line count of the legacy .active review (backward compat).
# With PID:    returns the line count of the review tracked by .active.$PID.
#              If the process identified by PID is dead, outputs the full review
#              log (so the caller sees the review without ever knowing the log path).

LOG_DIR="${TMPDIR:-/tmp}/fresheyes-logs"
PID="${1:-}"

if [[ -n "$PID" ]]; then
  ACTIVE_FILE="$LOG_DIR/.active.$PID"
else
  ACTIVE_FILE="$LOG_DIR/.active"
fi

_find_log() {
  local pid="$1"
  # First try the .active pointer
  local active_file="$LOG_DIR/.active.$pid"
  if [[ -f "$active_file" ]]; then
    local log
    log=$(cat "$active_file" 2>/dev/null)
    if [[ -n "$log" && -f "$log" ]]; then
      echo "$log"
      return 0
    fi
  fi
  # Fallback: search by PID in filename (fresheyes-YYYYMMDD-HHMMSS-<pid>.log)
  ls -t "$LOG_DIR"/fresheyes-*-"$pid".log 2>/dev/null | head -1
}

if [[ -n "$PID" ]]; then
  LOG_FILE=$(_find_log "$PID")
  if [[ -z "$LOG_FILE" ]]; then
    echo "0"
    exit 0
  fi
else
  if [[ ! -f "$LOG_DIR/.active" ]]; then
    echo "0"
    exit 0
  fi
  LOG_FILE=$(cat "$LOG_DIR/.active")
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "0"
    exit 0
  fi
fi

# If a PID was given and the process is dead, output the review and exit.
if [[ -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$LOG_DIR/.active.$PID"
  cat "$LOG_FILE"
  exit 0
fi

wc -l < "$LOG_FILE"
