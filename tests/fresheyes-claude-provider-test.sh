#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS_SCRIPT="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"
PARSER="$ROOT_DIR/skills/fresheyes/fresheyes-claude-stream.py"
PYTHON=".venv-wsl/bin/python"
if [[ ! -x "$ROOT_DIR/$PYTHON" ]]; then
  PYTHON="python3"
else
  PYTHON="$ROOT_DIR/$PYTHON"
fi

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
ARGV_FILE="$TEST_TMP/claude-argv.json"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Output for %s did not contain %q:\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

make_fake_claude() {
  cat > "$FAKE_BIN/claude" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time

argv_file = os.environ["FRESHEYES_FAKE_ARGV"]
with open(argv_file, "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)

mode = os.environ.get("FRESHEYES_FAKE_MODE")
if not mode:
    mode = "automatic" if "--json-schema" in sys.argv else "manual"

delay = float(os.environ.get("FRESHEYES_FAKE_DELAY", "0"))

def emit(obj):
    print(json.dumps(obj), flush=True)
    if delay:
        time.sleep(delay)

print("fake claude stderr line", file=sys.stderr, flush=True)
emit({"type": "system", "subtype": "init", "session_id": "fake-session"})
emit({
    "type": "assistant",
    "message": {
        "content": [
            {"type": "tool_use", "name": "Read", "id": "tool-1"}
        ]
    },
})
emit({
    "type": "user",
    "message": {
        "content": [
            {
                "type": "tool_result",
                "tool_use_id": "tool-1",
                "content": "README.md contents",
            }
        ]
    },
})

if mode == "automatic":
    emit({
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": "Done.",
        "structured_output": {"approve_commit": True, "issues": []},
    })
else:
    emit({
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": "## Files Examined\n\n- README.md\n\nINDEPENDENT CODE REVIEW PASSED",
    })
PY
  chmod +x "$FAKE_BIN/claude"
}

read_latest_file() {
  local dir="$1"
  local glob="$2"
  local latest
  latest=$(ls -t "$dir"/fresheyes-logs/$glob 2>/dev/null | head -1)
  [[ -n "$latest" ]] || fail "No file matched $glob in $dir/fresheyes-logs"
  printf '%s\n' "$latest"
}

assert_manual_argv() {
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))

def require(value):
    if value not in argv:
        raise SystemExit(f"missing argv value: {value!r}\nargv={argv!r}")

require("--output-format")
idx = argv.index("--output-format")
if idx + 1 >= len(argv) or argv[idx + 1] != "stream-json":
    raise SystemExit(f"--output-format was not stream-json: {argv!r}")
for value in ["--verbose", "--include-partial-messages", "--disable-slash-commands"]:
    require(value)
if "--bare" in argv:
    raise SystemExit(f"unexpected --bare: {argv!r}")
if "--" not in argv:
    raise SystemExit(f"missing -- prompt separator: {argv!r}")
if argv[-1].startswith("--") or "Review README.md." not in argv[-1]:
    raise SystemExit(f"prompt was not the final argv entry: {argv!r}")
PY
}

assert_automatic_argv() {
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
for value in [
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--disable-slash-commands",
    "--json-schema",
]:
    if value not in argv:
        raise SystemExit(f"missing argv value: {value!r}\nargv={argv!r}")
if "--bare" in argv:
    raise SystemExit(f"unexpected --bare: {argv!r}")
if "--" not in argv:
    raise SystemExit(f"missing -- prompt separator: {argv!r}")
if argv[-1].startswith("--") or "Review staged changes." not in argv[-1]:
    raise SystemExit(f"prompt was not the final argv entry: {argv!r}")
schema_idx = argv.index("--json-schema")
if schema_idx + 1 >= len(argv) or "approve_commit" not in argv[schema_idx + 1]:
    raise SystemExit(f"inline schema missing approve_commit: {argv!r}")
PY
}

assert_automatic_output_json() {
  local json_file="$1"
  "$PYTHON" - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if data != {"approve_commit": True, "issues": []}:
    raise SystemExit(f"unexpected automatic output: {data!r}")
PY
}

run_runner_capture() {
  local run_tmp="$1"
  local stdout_file="$2"
  shift 2

  if ! TMPDIR="$run_tmp" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" "$@" > "$stdout_file"; then
    printf 'Runner failed or timed out. stdout:\n' >&2
    cat "$stdout_file" >&2 2>/dev/null || true
    return 1
  fi
}

test_manual_claude_invocation_uses_streaming_flags() {
  local run_tmp output log_file stdout_file
  run_tmp="$(mktemp -d "$TEST_TMP/manual.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  run_runner_capture "$run_tmp" "$stdout_file" --claude "Review README.md."
  output=$(cat "$stdout_file")

  assert_manual_argv
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "manual Claude output"
  log_file=$(read_latest_file "$run_tmp" 'fresheyes-*.log')
  [[ -f "$log_file.events.jsonl" ]] || fail "missing event log"
  [[ -f "$log_file.stream.jsonl" ]] || fail "missing stream log"
  [[ -f "$log_file.stderr" ]] || fail "missing stderr log"
  [[ -f "$log_file" ]] || fail "missing final log"
}

test_automatic_claude_extracts_structured_output() {
  local run_tmp output output_file stdout_file
  run_tmp="$(mktemp -d "$TEST_TMP/automatic.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  run_runner_capture "$run_tmp" "$stdout_file" --claude --mode automatic "Review staged changes."
  output=$(cat "$stdout_file")

  assert_automatic_argv
  assert_contains "$output" "Fresh Eyes: approved." "automatic Claude output"
  output_file=$(read_latest_file "$run_tmp" 'fresheyes-automatic-*.json')
  assert_automatic_output_json "$output_file"
}

test_parser_missing_result_writes_failure_log() {
  local run_tmp review_log event_log stream_log output status
  run_tmp="$(mktemp -d "$TEST_TMP/parser.XXXXXX")"
  review_log="$run_tmp/fresheyes-test.log"
  event_log="$review_log.events.jsonl"
  stream_log="$review_log.stream.jsonl"

  set +e
  output=$(
    printf '%s\n' \
      '{"type":"system","subtype":"init","session_id":"fake-session"}' \
      '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' |
      "$PYTHON" "$PARSER" \
        --mode manual \
        --review-log "$review_log" \
        --event-log "$event_log" \
        --stream-log "$stream_log"
  )
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "parser missing-result case unexpectedly succeeded"
  [[ -f "$review_log" ]] || fail "parser did not write failure review log"
  [[ -f "$event_log" ]] || fail "parser did not write event log"
  [[ -f "$stream_log" ]] || fail "parser did not write stream log"
  assert_contains "$(cat "$review_log")" "Fresh Eyes review failed before final output" "parser failure log"
  assert_contains "$(cat "$review_log")" "error=missing_result" "parser failure log"
  assert_contains "$(cat "$event_log")" "missing_result" "parser event log"
  assert_contains "$output" "Fresh Eyes review failed before final output" "parser failure stdout"
}

test_compound_launch_parent_pid_recovers_review() {
  local run_tmp stdout_file captured_pid progress_output
  run_tmp="$(mktemp -d "$TEST_TMP/compound.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  captured_pid=$(
    TMPDIR="$run_tmp" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash -c \
      'true && setsid bash "$1" --claude "Review README.md." </dev/null > "$2" 2>/dev/null & echo "$!"' \
      bash "$RUNNER" "$stdout_file"
  )

  [[ "$captured_pid" =~ ^[0-9]+$ ]] || fail "compound launch did not return a pid: $captured_pid"
  for _ in {1..50}; do
    progress_output=$(
      TMPDIR="$run_tmp" \
      FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
      bash "$PROGRESS_SCRIPT" "$captured_pid"
    )
    if [[ "$progress_output" == *"INDEPENDENT CODE REVIEW PASSED"* ]]; then
      return 0
    fi
    sleep 0.1
  done

  printf 'Compound launch progress never returned final review. pid=%s output:\n%s\n' "$captured_pid" "$progress_output" >&2
  exit 1
}

make_fake_claude
test_manual_claude_invocation_uses_streaming_flags
test_automatic_claude_extracts_structured_output
test_parser_missing_result_writes_failure_log
test_compound_launch_parent_pid_recovers_review

printf 'fresheyes-claude-provider tests passed\n'
