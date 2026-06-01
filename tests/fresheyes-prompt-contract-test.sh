#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT="$ROOT_DIR/skills/fresheyes/fresheyes-prompt.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local needle="$1"
  grep -Fq -- "$needle" "$PROMPT" || fail "manual prompt is missing: $needle"
}

require_text "### Implementation Plans and Runbooks"
require_text "Treat it as executable behavior, not prose-only documentation."
require_text 'Expected: PASS'
require_text "command/assertion mismatch"
require_text "at least **major** and blocking"
require_text "Do not downgrade an executable plan defect because TDD, CI, a future implementer, or a careful reader might notice and fix it later."
require_text "executable plan/test steps that cannot pass as written"

printf 'fresheyes-prompt contract tests passed\n'
