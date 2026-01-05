#!/usr/bin/env bash
# Fresh Eyes - Independent Code Review runner
# Usage: ./fresheyes.sh 'scope text'

set -euo pipefail

SCOPE_TEXT="${1:-Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/fresheyes-prompt.md"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
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

# Run Codex and capture all output to log file
codex exec \
  --sandbox read-only \
  --model gpt-5.2-codex \
  -c max_output_tokens=25000 \
  -c model_reasoning_effort=xhigh \
  "$PROMPT" > "$LOG_FILE" 2>&1

# Extract just the final review section (last occurrence of "## Files Examined" to end)
# Use tac to reverse, find first match, then reverse back
tac "$LOG_FILE" | sed '/^## Files Examined/q' | tac

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
