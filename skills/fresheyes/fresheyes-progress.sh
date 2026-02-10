#!/usr/bin/env bash
# fresheyes-progress.sh - Check if a fresheyes review is still producing output.
# Takes no arguments. Prints the line count of the active review's log.
# If this number is growing between calls, the review is not dead.

LOG_DIR="${TMPDIR:-/tmp}/fresheyes-logs"
ACTIVE_FILE="$LOG_DIR/.active"

if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "0"
  exit 0
fi

LOG_FILE=$(cat "$ACTIVE_FILE")

if [[ ! -f "$LOG_FILE" ]]; then
  echo "0"
  exit 0
fi

wc -l < "$LOG_FILE"
