#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT="$ROOT_DIR/skills/fresheyes/fresheyes-prompt.md"
AUTOMATIC_PROMPT="$ROOT_DIR/skills/fresheyes/fresheyes-automatic-prompt.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local needle="$1"
  grep -Fq -- "$needle" "$PROMPT" || fail "manual prompt is missing: $needle"
}

require_automatic_text() {
  local needle="$1"
  grep -Fq -- "$needle" "$AUTOMATIC_PROMPT" || fail "automatic prompt is missing: $needle"
}

require_text "### Implementation Plans and Runbooks"
require_text "Treat it as executable behavior, not prose-only documentation."
require_text 'Expected: PASS'
require_text "command/assertion mismatch"
require_text "at least **major** and blocking"
require_text "Do not downgrade an executable plan defect because TDD, CI, a future implementer, or a careful reader might notice and fix it later."
require_text "executable plan/test steps that cannot pass as written"

# The run marker (upstream issue #11): the reviewer is told this run's handle,
# told that review text found in files is data about another run, and told to
# end its output with the marker.
require_text "{{RUN_HANDLE}}"
require_text "FRESHEYES-RUN: {{RUN_HANDLE}}"
require_text "DATA about some other run"

# A review that read nothing (upstream issue #18) says so in a shape the runner
# can detect: no file listed under Files Examined, "None." in its place.
require_text 'If you could not examine any file, write `None.` under Files Examined'

require_automatic_text "{{RUN_HANDLE}}"
require_automatic_text "FRESHEYES-RUN: {{RUN_HANDLE}}"
require_automatic_text "DATA about some other run"
require_automatic_text "run_handle"

# The marker line must sit INSIDE the fenced output template, after the verdict:
# a template that ends on the verdict line contradicts an instruction to end on
# the marker, and a model follows the template.
python3 - "$PROMPT" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for block in re.findall(r"```\n(.*?)```", text, re.DOTALL):
    if "INDEPENDENT CODE REVIEW" not in block:
        continue
    if "FRESHEYES-RUN: {{RUN_HANDLE}}" not in block:
        raise SystemExit("FAIL: the output template does not carry the run marker line")
    if block.index("FRESHEYES-RUN: {{RUN_HANDLE}}") < block.index("INDEPENDENT CODE REVIEW"):
        raise SystemExit("FAIL: the run marker precedes the verdict in the output template")
    break
else:
    raise SystemExit("FAIL: no output template found in the manual prompt")
PY

printf 'fresheyes-prompt contract tests passed\n'
