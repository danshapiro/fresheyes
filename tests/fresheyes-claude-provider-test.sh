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
model_idx = argv.index("--model")
if model_idx + 1 >= len(argv) or argv[model_idx + 1] != "opus":
    raise SystemExit(f"Claude-specific override did not win: {argv!r}")
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
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_GPT_MODEL="gpt-5.6-terra" \
    FRESHEYES_CLAUDE_MODEL="opus" \
    FRESHEYES_MODEL="legacy-model-must-not-win" \
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

  run_runner_capture "$run_tmp" "$stdout_file" --foreground --claude "Review README.md."
  output=$(cat "$stdout_file")

  assert_manual_argv
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "manual Claude output"
  log_file=$(read_latest_file "$run_tmp" 'fresheyes-*.log')
  [[ -f "$log_file.events.jsonl" ]] || fail "missing event log"
  [[ -f "$log_file.stream.jsonl" ]] || fail "missing stream log"
  [[ -f "$log_file.stderr" ]] || fail "missing stderr log"
  [[ -f "$log_file.status.json" ]] || fail "missing status file"
  [[ -f "$log_file" ]] || fail "missing final log"
  assert_contains "$(cat "$log_file.status.json")" '"state":"complete"' "manual Claude status"
  assert_contains "$(cat "$log_file.status.json")" '"verdict":"passed"' "manual Claude status"
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
  assert_contains "$(cat "$(read_latest_file "$run_tmp" 'fresheyes-*.log.status.json')")" '"state":"complete"' "automatic Claude status"
  assert_contains "$(cat "$(read_latest_file "$run_tmp" 'fresheyes-*.log.status.json')")" '"verdict":"approved"' "automatic Claude status"
}

test_default_log_dir_uses_global_log_dir() {
  local run_tmp stdout_file log_file
  run_tmp="$(mktemp -d "$TEST_TMP/default-log.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  mkdir -p "$run_tmp/tmp"
  rm -f "$ARGV_FILE"

  if ! TMPDIR="$run_tmp/tmp" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file"; then
    printf 'Runner failed or timed out. stdout:\n' >&2
    cat "$stdout_file" >&2 2>/dev/null || true
    return 1
  fi

  log_file=$(ls -t "$run_tmp"/global-fresheyes-logs/fresheyes-*.log 2>/dev/null | head -1)
  [[ -n "$log_file" ]] || fail "default log dir did not write to global log dir"
  [[ ! -d "$run_tmp/tmp/fresheyes-logs" ]] || fail "default log dir unexpectedly used TMPDIR"
  assert_contains "$(cat "$log_file.status.json")" '"state":"complete"' "default global log dir status"
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
  local run_tmp stdout_file captured_pid progress_output status
  run_tmp="$(mktemp -d "$TEST_TMP/compound.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  captured_pid=$(
    TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash -c \
      'true && setsid bash "$1" --foreground --claude "Review README.md." </dev/null > "$2" 2>/dev/null & echo "$!"' \
      bash "$RUNNER" "$stdout_file"
  )

  [[ "$captured_pid" =~ ^[0-9]+$ ]] || fail "compound launch did not return a pid: $captured_pid"
  for _ in {1..50}; do
    set +e
    progress_output=$(
      TMPDIR="$run_tmp" \
      FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
      FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
      bash "$PROGRESS_SCRIPT" --result "$captured_pid" 2>/dev/null
    )
    status=$?
    set -e
    if [[ "$status" -eq 0 && "$progress_output" == *"INDEPENDENT CODE REVIEW PASSED"* ]]; then
      return 0
    fi
    sleep 0.1
  done

  printf 'Compound launch progress never returned final review. pid=%s output:\n%s\n' "$captured_pid" "$progress_output" >&2
  exit 1
}

test_manual_detaches_by_default_and_completes() {
  local run_tmp stdout_file fresh_pid progress_output status self_sid child_sid
  run_tmp="$(mktemp -d "$TEST_TMP/detach.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  # Slow the fake provider (2s) so the detached review is provably STILL RUNNING
  # when the launch call returns. That gives us a window to (a) prove the launch
  # returned before the provider completed, and (b) inspect the review's session.
  if ! TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    FRESHEYES_FAKE_DELAY="2" \
    timeout 30s bash "$RUNNER" --claude "Review README.md." > "$stdout_file"; then
    printf 'Default manual launch failed or timed out. stdout:\n' >&2
    cat "$stdout_file" >&2 2>/dev/null || true
    return 1
  fi

  # Bare manual launch must self-detach and return only the PID line.
  assert_contains "$(cat "$stdout_file")" "FRESHPID=" "default manual detach stdout"
  if [[ "$(cat "$stdout_file")" == *"INDEPENDENT CODE REVIEW"* ]]; then
    fail "default manual launch streamed the review instead of detaching: $(cat "$stdout_file")"
  fi
  fresh_pid=$(sed -n 's/^FRESHPID=//p' "$stdout_file" | tr -d '[:space:]')
  [[ "$fresh_pid" =~ ^[0-9]+$ ]] || fail "default manual launch printed no numeric FRESHPID: $(cat "$stdout_file")"

  # SAFETY PROPERTY — the whole point of detach-by-default. The review must run
  # in its OWN session, not the launcher's, so a caller's process-group/harness
  # timeout cannot kill it. setsid makes the detached review a session leader
  # (session id == its own PID); a plain `&` background WITHOUT setsid would
  # leave it in this test's session (and killable) yet still print FRESHPID=,
  # not stream, and complete — passing every other assertion here. So we must
  # check the session explicitly, while the 2s fake provider keeps it alive.
  self_sid=$(ps -o sess= -p "$$" | tr -d '[:space:]')
  child_sid=""
  for _ in {1..60}; do
    child_sid=$(ps -o sess= -p "$fresh_pid" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$child_sid" ]] && break
    sleep 0.05
  done
  [[ -n "$child_sid" ]] || fail "detached review pid $fresh_pid was not alive after launch; it was not backgrounded into its own session"
  if [[ "$child_sid" == "$self_sid" ]]; then
    fail "detached review shares the launcher's session ($child_sid); setsid did not detach it, so a caller timeout could still kill it"
  fi
  if [[ "$child_sid" != "$fresh_pid" ]]; then
    fail "detached review is not its own session leader (sid=$child_sid pid=$fresh_pid); FRESHPID does not name the detached session"
  fi

  # Detached review must complete and be retrievable by the printed PID.
  for _ in {1..100}; do
    set +e
    progress_output=$(
      TMPDIR="$run_tmp" \
      FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
      FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
      bash "$PROGRESS_SCRIPT" --result "$fresh_pid" 2>/dev/null
    )
    status=$?
    set -e
    if [[ "$status" -eq 0 && "$progress_output" == *"INDEPENDENT CODE REVIEW PASSED"* ]]; then
      return 0
    fi
    sleep 0.1
  done

  printf 'Detached review never returned final result. pid=%s output:\n%s\n' "$fresh_pid" "$progress_output" >&2
  exit 1
}

test_manual_foreground_runs_synchronously() {
  local run_tmp stdout_file output
  run_tmp="$(mktemp -d "$TEST_TMP/foreground.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  run_runner_capture "$run_tmp" "$stdout_file" --foreground --claude "Review README.md."
  output=$(cat "$stdout_file")

  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "foreground manual streams review"
  if [[ "$output" == *"FRESHPID="* ]]; then
    fail "--foreground unexpectedly detached (printed FRESHPID): $output"
  fi
}

test_automatic_mode_does_not_detach() {
  local run_tmp stdout_file output
  run_tmp="$(mktemp -d "$TEST_TMP/auto-nodetach.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  run_runner_capture "$run_tmp" "$stdout_file" --mode automatic --claude "Review staged changes."
  output=$(cat "$stdout_file")

  assert_contains "$output" "Fresh Eyes: approved." "automatic mode stays synchronous"
  if [[ "$output" == *"FRESHPID="* ]]; then
    fail "automatic mode unexpectedly detached (printed FRESHPID): $output"
  fi
}

make_fake_claude
test_manual_claude_invocation_uses_streaming_flags
test_automatic_claude_extracts_structured_output
test_default_log_dir_uses_global_log_dir
test_parser_missing_result_writes_failure_log
test_compound_launch_parent_pid_recovers_review
test_manual_detaches_by_default_and_completes
test_manual_foreground_runs_synchronously
test_automatic_mode_does_not_detach

printf 'fresheyes-claude-provider tests passed\n'
