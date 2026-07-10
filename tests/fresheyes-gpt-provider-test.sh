#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS_SCRIPT="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

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

if "--output-schema" in sys.argv:
    output_path = sys.argv[sys.argv.index("-o") + 1]
    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump({"approve_commit": True, "issues": []}, handle)
    print("fake automatic Codex review complete")
else:
    if "-o" in sys.argv:
        output_path = sys.argv[sys.argv.index("-o") + 1]
        with open(output_path, "w", encoding="utf-8") as handle:
            handle.write("## Files Examined   \n")
            handle.write("- README.md\n")
            if os.environ.get("FRESHEYES_FAKE_OMIT_VERDICT") != "1":
                handle.write("INDEPENDENT CODE REVIEW PASSED\n")
    for index in range(10_000):
        print(f"fake Codex diagnostic line {index}")
    if os.environ.get("FRESHEYES_FAKE_OMIT_VERDICT") == "1":
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
if "-o" not in argv:
    raise SystemExit(f"manual GPT review did not request a last-message artifact: {argv!r}")
PY

if ! grep -q '^INDEPENDENT CODE REVIEW PASSED$' "$STDOUT_FILE"; then
  printf 'manual GPT review did not return a passing review:\n' >&2
  cat "$STDOUT_FILE" >&2
  exit 1
fi
if grep -q '^fake Codex diagnostic line' "$STDOUT_FILE"; then
  printf 'manual GPT review emitted the full diagnostic transcript instead of the final section\n' >&2
  exit 1
fi

assert_unsupported_version() {
  local version="$1"
  local slug="${version//[^0-9A-Za-z]/-}"
  local stdout_file="$TEST_TMP/unsupported-$slug-stdout.txt"
  local stderr_file="$TEST_TMP/unsupported-$slug-stderr.txt"
  local status

  set +e
  PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    FRESHEYES_FAKE_VERSION="$version" \
    FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    FRESHEYES_LOG_DIR="$TEST_TMP/unsupported-$slug-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/unsupported-$slug-global-logs" \
    FRESHEYES_GPT_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_MODE=manual \
    timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf 'GPT-5.6 review accepted unsupported Codex CLI %s\n' "$version" >&2
    exit 1
  fi
  if ! grep -q 'GPT-5.6 requires Codex CLI 0.144.0 or newer' "$stderr_file"; then
    printf 'unsupported Codex CLI failure did not explain the minimum version:\n' >&2
    cat "$stderr_file" >&2
    exit 1
  fi
}

assert_unsupported_version "0.143.9"
assert_unsupported_version "0.144.0-alpha.1"

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

AUTOMATIC_ARGV_FILE="$TEST_TMP/codex-automatic-argv.json"
AUTOMATIC_STDOUT_FILE="$TEST_TMP/automatic-stdout.txt"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$AUTOMATIC_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/automatic-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/automatic-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --automatic "Review staged changes." > "$AUTOMATIC_STDOUT_FILE"

python3 - "$AUTOMATIC_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)

model_index = argv.index("--model")
actual_model = argv[model_index + 1]
if actual_model != "gpt-5.6-sol":
    raise SystemExit(f"expected automatic GPT model gpt-5.6-sol, got {actual_model!r}")
if "model_reasoning_effort=medium" not in argv:
    raise SystemExit(f"automatic GPT review did not use medium reasoning: {argv!r}")
if "--output-schema" not in argv or "-o" not in argv:
    raise SystemExit(f"automatic GPT review did not request structured output: {argv!r}")
PY

if ! grep -q '^Fresh Eyes: approved\.$' "$AUTOMATIC_STDOUT_FILE"; then
  printf 'automatic GPT review did not approve the fake structured result:\n' >&2
  cat "$AUTOMATIC_STDOUT_FILE" >&2
  exit 1
fi

DETACHED_ARGV_FILE="$TEST_TMP/codex-detached-argv.json"
DETACHED_LOG_DIR="$TEST_TMP/detached-logs"
DETACHED_GLOBAL_LOG_DIR="$TEST_TMP/detached-global-logs"
detached_launch=$(
  PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$DETACHED_ARGV_FILE" \
    FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    FRESHEYES_LOG_DIR="$DETACHED_LOG_DIR" \
    FRESHEYES_GLOBAL_LOG_DIR="$DETACHED_GLOBAL_LOG_DIR" \
    FRESHEYES_GPT_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_MODE=manual \
    timeout 30s bash "$RUNNER" --gpt --manual "Review README.md."
)
detached_pid=$(sed -n 's/^FRESHPID=//p' <<< "$detached_launch" | tr -d '[:space:]')
if [[ ! "$detached_pid" =~ ^[0-9]+$ ]]; then
  printf 'detached GPT review did not return a numeric PID: %s\n' "$detached_launch" >&2
  exit 1
fi

detached_complete=0
for _ in {1..100}; do
  detached_status=$(
    FRESHEYES_LOG_DIR="$DETACHED_LOG_DIR" \
      FRESHEYES_GLOBAL_LOG_DIR="$DETACHED_GLOBAL_LOG_DIR" \
      bash "$PROGRESS_SCRIPT" --json "$detached_pid"
  )
  if [[ "$detached_status" == *'"runner_state":"complete"'* ]]; then
    detached_complete=1
    break
  fi
  if [[ "$detached_status" == *'"runner_state":"failed"'* ]]; then
    printf 'detached GPT review failed: %s\n' "$detached_status" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$detached_complete" != "1" ]]; then
  printf 'detached GPT review did not complete: %s\n' "$detached_status" >&2
  exit 1
fi

detached_result=$(
  FRESHEYES_LOG_DIR="$DETACHED_LOG_DIR" \
    FRESHEYES_GLOBAL_LOG_DIR="$DETACHED_GLOBAL_LOG_DIR" \
    bash "$PROGRESS_SCRIPT" --result "$detached_pid"
)
if [[ "$detached_result" == *"fake Codex diagnostic line"* ]]; then
  printf 'detached GPT result returned the raw diagnostic transcript\n' >&2
  exit 1
fi
if [[ "$detached_result" != *"INDEPENDENT CODE REVIEW PASSED"* ]]; then
  printf 'detached GPT result omitted the final verdict:\n%s\n' "$detached_result" >&2
  exit 1
fi

NO_VERDICT_ARGV_FILE="$TEST_TMP/codex-no-verdict-argv.json"
NO_VERDICT_LOG_DIR="$TEST_TMP/no-verdict-logs"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$NO_VERDICT_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_FAKE_OMIT_VERDICT=1 \
  FRESHEYES_LOG_DIR="$NO_VERDICT_LOG_DIR" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/no-verdict-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$TEST_TMP/no-verdict-stdout.txt"
no_verdict_status_file=$(ls -t "$NO_VERDICT_LOG_DIR"/*.status.json | head -n 1)
python3 - "$no_verdict_status_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
if status.get("state") != "complete":
    raise SystemExit(f"no-verdict GPT run did not complete: {status!r}")
if "verdict" in status:
    raise SystemExit(f"incidental transcript verdict leaked into runner status: {status!r}")
PY

printf 'fresheyes-gpt-provider tests passed\n'
