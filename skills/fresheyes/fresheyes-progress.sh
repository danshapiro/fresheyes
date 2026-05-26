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

if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "0"
  exit 0
fi

LOG_FILE=$(cat "$ACTIVE_FILE")

if [[ ! -f "$LOG_FILE" ]]; then
  echo "0"
  exit 0
fi

# If a PID was given and the process is dead, output the review and exit.
if [[ -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then
  # Remove the orphaned active pointer — the process exited (trap would have
  # cleaned it up during normal exit, but guard against crashes).
  rm -f "$ACTIVE_FILE"
  cat "$LOG_FILE"
  exit 0
fi

wc -l < "$LOG_FILE"
