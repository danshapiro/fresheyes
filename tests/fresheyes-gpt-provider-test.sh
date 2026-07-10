#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
ARGV_FILE="$TEST_TMP/codex-argv.json"
STDOUT_FILE="$TEST_TMP/stdout.txt"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

cat > "$FAKE_BIN/codex" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["FRESHEYES_FAKE_ARGV"], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)

print("## Files Examined")
print("- README.md")
print("INDEPENDENT CODE REVIEW PASSED")
PY
chmod +x "$FAKE_BIN/codex"

PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/global-logs" \
  FRESHEYES_MODEL= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$STDOUT_FILE"

python3 - "$ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)

model_index = argv.index("--model")
actual_model = argv[model_index + 1]
if actual_model != "gpt-5.6-sol":
    raise SystemExit(f"expected default GPT model gpt-5.6-sol, got {actual_model!r}")

if "model_reasoning_effort=xhigh" not in argv:
    raise SystemExit(f"manual GPT review did not use xhigh reasoning: {argv!r}")
PY

if ! grep -q '^INDEPENDENT CODE REVIEW PASSED$' "$STDOUT_FILE"; then
  printf 'manual GPT review did not return a passing review:\n' >&2
  cat "$STDOUT_FILE" >&2
  exit 1
fi

printf 'fresheyes-gpt-provider tests passed\n'
