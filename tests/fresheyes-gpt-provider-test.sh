#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
ARGV_FILE="$TEST_TMP/codex-argv.json"
VERSION_PROBE_FILE="$TEST_TMP/codex-version-probe.txt"
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

if sys.argv[1:] == ["--version"]:
    with open(os.environ["FRESHEYES_FAKE_VERSION_PROBE"], "w", encoding="utf-8") as handle:
        handle.write(os.environ.get("FRESHEYES_FAKE_VERSION", "0.144.1"))
    print(f"codex-cli {os.environ.get('FRESHEYES_FAKE_VERSION', '0.144.1')}")
    raise SystemExit(0)

with open(os.environ["FRESHEYES_FAKE_ARGV"], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)

for index in range(10_000):
    print(f"fake Codex diagnostic line {index}")
print("## Files Examined")
print("- README.md")
print("INDEPENDENT CODE REVIEW PASSED")
PY
chmod +x "$FAKE_BIN/codex"

PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/global-logs" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$STDOUT_FILE"

if [[ ! -s "$VERSION_PROBE_FILE" ]]; then
  printf 'GPT-5.6 review did not verify the Codex CLI version\n' >&2
  exit 1
fi

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

OLD_STDOUT_FILE="$TEST_TMP/old-version-stdout.txt"
OLD_STDERR_FILE="$TEST_TMP/old-version-stderr.txt"
set +e
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
  FRESHEYES_FAKE_VERSION="0.143.9" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/old-version-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/old-version-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$OLD_STDOUT_FILE" 2> "$OLD_STDERR_FILE"
old_version_status=$?
set -e

if [[ "$old_version_status" -eq 0 ]]; then
  printf 'GPT-5.6 review accepted unsupported Codex CLI 0.143.9\n' >&2
  exit 1
fi
if ! grep -q 'GPT-5.6 requires Codex CLI 0.144.0 or newer' "$OLD_STDERR_FILE"; then
  printf 'old Codex CLI failure did not explain the minimum version:\n' >&2
  cat "$OLD_STDERR_FILE" >&2
  exit 1
fi

TERRA_ARGV_FILE="$TEST_TMP/codex-terra-argv.json"
TERRA_STDOUT_FILE="$TEST_TMP/terra-stdout.txt"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$TERRA_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/terra-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/terra-global-logs" \
  FRESHEYES_GPT_MODEL="gpt-5.6-terra" \
  FRESHEYES_MODEL="legacy-model-must-not-win" \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$TERRA_STDOUT_FILE"

python3 - "$TERRA_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)

model_index = argv.index("--model")
actual_model = argv[model_index + 1]
if actual_model != "gpt-5.6-terra":
    raise SystemExit(f"expected GPT-specific model override to win, got {actual_model!r}")
PY

printf 'fresheyes-gpt-provider tests passed\n'
