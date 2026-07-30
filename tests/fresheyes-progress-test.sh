#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS_SCRIPT="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"
PYTHON="$ROOT_DIR/.venv-wsl/bin/python"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="python3"
fi
TEST_TMP="$(mktemp -d)"
LOG_DIR="$TEST_TMP/fresheyes-logs"
GLOBAL_LOG_DIR="$TEST_TMP/global-fresheyes-logs"
LIVE_PIDS=()

cleanup() {
  for pid in "${LIVE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
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

assert_not_equals() {
  local actual="$1"
  local unexpected="$2"
  local label="$3"
  if [[ "$actual" == "$unexpected" ]]; then
    printf 'Output for %s unexpectedly equaled %q\n' "$label" "$unexpected" >&2
    exit 1
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Output for %s expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

run_progress() {
  TMPDIR="$TEST_TMP" FRESHEYES_LOG_DIR="$LOG_DIR" FRESHEYES_GLOBAL_LOG_DIR="$GLOBAL_LOG_DIR" bash "$PROGRESS_SCRIPT" "$@"
}

run_progress_allow_legacy() {
  TMPDIR="$TEST_TMP" FRESHEYES_LOG_DIR="$LOG_DIR" FRESHEYES_GLOBAL_LOG_DIR="$GLOBAL_LOG_DIR" FRESHEYES_ALLOW_LEGACY_PROGRESS=1 bash "$PROGRESS_SCRIPT" "$@"
}

json_field() {
  local payload="$1"
  local field="$2"

  JSON_PAYLOAD="$payload" "$PYTHON" - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
data = json.loads(os.environ["JSON_PAYLOAD"])
value = data
for part in field.split("."):
    value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

assert_json_field_equals() {
  local payload="$1"
  local field="$2"
  local expected="$3"
  local label="$4"
  local actual

  actual=$(json_field "$payload" "$field")
  assert_equals "$actual" "$expected" "$label"
}

start_live_pid() {
  local __target_var="$1"
  sleep 60 &
  local started_pid=$!
  LIVE_PIDS+=("$started_pid")
  printf -v "$__target_var" '%s' "$started_pid"
}

dead_pid() {
  local __target_var="$1"
  (
    exit 0
  ) &
  local exited_pid=$!
  wait "$exited_pid" || true
  printf -v "$__target_var" '%s' "$exited_pid"
}

write_active() {
  local pid="$1"
  local base="$2"
  mkdir -p "$LOG_DIR"
  printf '%s\n' "$base" > "$LOG_DIR/.active.$pid"
}

write_legacy_active() {
  local base="$1"
  mkdir -p "$LOG_DIR"
  printf '%s\n' "$base" > "$LOG_DIR/.active"
}

write_locator_alias() {
  local pid="$1"
  local base="$2"
  local dir="${3:-$LOG_DIR}"
  mkdir -p "$dir"
  printf '%s\n' "$base" > "$dir/.locator.$pid"
}

snapshot_dir() {
  # Stable fingerprint of every file's path, size, and mtime under a dir.
  find "$1" -mindepth 1 -printf '%p %s %T@\n' 2>/dev/null | sort
}

write_claude_events() {
  local base="$1"
  cat > "$base.events.jsonl" <<'JSON'
{"severity":"info","event":"review_started","provider":"claude","ts_epoch":1}
{"severity":"info","event":"provider_event","provider":"claude","ts_epoch":2,"type":"system","subtype":"init"}
{"severity":"info","event":"provider_event","provider":"claude","ts_epoch":3,"type":"assistant","stream_event_type":"content_block_start","tool":"Bash"}
JSON
}

test_alive_claude_sidecars_missing_log() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  write_claude_events "$base"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "running" "alive Claude missing log JSON state"
  assert_json_field_equals "$output" "provider" "claude" "alive Claude missing log JSON provider"
  assert_json_field_equals "$output" "provider_events" "2" "alive Claude missing log JSON provider events"
  assert_json_field_equals "$output" "line_count" "0" "alive Claude missing log JSON line count"
}

test_alive_claude_sidecars_empty_log() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  : > "$base"
  write_claude_events "$base"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "running" "alive Claude empty log JSON state"
  assert_json_field_equals "$output" "provider" "claude" "alive Claude empty log JSON provider"
  assert_json_field_equals "$output" "provider_events" "2" "alive Claude empty log JSON provider events"
  assert_json_field_equals "$output" "line_count" "0" "alive Claude empty log JSON line count"
}

test_legacy_no_pid_preserves_numeric_progress() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_legacy_active "$base"
  printf 'one\ntwo\nthree\n' > "$base"
  printf '%s\n' '{"severity":"info","event":"provider_event","provider":"gpt","ts_epoch":1}' > "$base.events.jsonl"

  output=$(run_progress)
  assert_equals "$output" "3" "legacy no-PID numeric progress"
}

test_bare_pid_legacy_output_is_rejected() {
  local pid base output status
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  printf 'one\ntwo\nthree\n' > "$base"

  set +e
  output=$(run_progress "$pid" 2>&1)
  status=$?
  set -e

  assert_equals "$status" "2" "bare PID legacy output status"
  assert_contains "$output" "requires --json or --result" "bare PID legacy output error"
}

test_alive_gpt_json_reports_running_progress() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  printf 'one\ntwo\nthree\n' > "$base"
  printf '%s\n' '{"severity":"info","event":"provider_event","provider":"gpt","ts_epoch":1}' > "$base.events.jsonl"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "running" "alive GPT JSON state"
  assert_json_field_equals "$output" "line_count" "3" "alive GPT JSON line count"
  assert_json_field_equals "$output" "pid_state" "active" "alive GPT JSON pid state"
}

test_alive_gpt_incidental_verdict_while_running_reports_running() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
The reviewer is still inspecting a test fixture containing this text:
## Files Examined
- fixture.md
INDEPENDENT CODE REVIEW PASSED
The reviewer has not produced its own final response yet.
TEXT
  printf '%s\n' '{"state":"running","provider":"gpt","mode":"manual"}' > "$base.status.json"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "running" "alive GPT incidental verdict JSON state"
  assert_json_field_equals "$output" "runner_state" "running" "alive GPT incidental verdict runner state"
  assert_json_field_equals "$output" "result_available" "false" "alive GPT incidental verdict result availability"
}

test_alive_gpt_final_verdict_reports_complete() {
  local pid base output result
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
## Files Examined

- README.md

INDEPENDENT CODE REVIEW PASSED
TEXT
  printf '%s\n' '{"severity":"info","event":"provider_event","provider":"gpt","ts_epoch":1}' > "$base.events.jsonl"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "complete" "alive GPT final verdict JSON state"
  assert_json_field_equals "$output" "verdict" "passed" "alive GPT final verdict JSON verdict"
  assert_json_field_equals "$output" "pid_state" "active" "alive GPT final verdict PID evidence"
  assert_json_field_equals "$output" "result_available" "true" "alive GPT final verdict result availability"

  result=$(run_progress --result "$pid")
  assert_contains "$result" "INDEPENDENT CODE REVIEW PASSED" "alive GPT final verdict result"
}

test_dead_success_returns_final_review() {
  local pid base output
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
## Files Examined

- README.md

INDEPENDENT CODE REVIEW PASSED
TEXT

  output=$(run_progress --result "$pid")
  assert_contains "$output" "## Files Examined" "dead success final text"
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "dead success final text"
}

test_dead_success_json_reports_complete() {
  local pid base output
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
## Files Examined

- README.md

INDEPENDENT CODE REVIEW FAILED
TEXT

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "complete" "dead success JSON state"
  assert_json_field_equals "$output" "verdict" "failed" "dead success JSON verdict"
  assert_json_field_equals "$output" "result_available" "true" "dead success JSON result availability"
}

test_failed_status_ignores_incidental_verdict() {
  local pid base output result status
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
The provider failed after inspecting a fixture containing:
## Files Examined
- fixture.md
INDEPENDENT CODE REVIEW PASSED
TEXT
  # The real runner stamps heartbeat_at on the terminal "failed" write too:
  # a FRESH heartbeat must not mask the recorded failure as "running".
  printf '{"state":"failed","provider":"gpt","mode":"manual","exit_code":1,"heartbeat_at":%s}\n' \
    "$(date +%s)" > "$base.status.json"

  set +e
  output=$(run_progress --json "$pid")
  status=$?
  set -e
  assert_equals "$status" "4" "failed status incidental verdict JSON exit code"
  assert_json_field_equals "$output" "state" "died" "failed status incidental verdict JSON state"
  assert_json_field_equals "$output" "runner_state" "failed" "failed status incidental verdict runner state"
  assert_json_field_equals "$output" "result_available" "false" "failed status incidental verdict result availability"
  assert_contains "$(json_field "$output" "message")" "exit_code=1" "died message quotes recorded exit code"

  set +e
  result=$(run_progress --result "$pid")
  status=$?
  set -e
  assert_equals "$status" "4" "failed status incidental verdict result status"
  assert_contains "$result" "Fresh Eyes review failed before final output" "failed status incidental verdict result"
}

test_complete_without_verdict_returns_text() {
  local pid base output result status
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
The reviewer inspected a fixture containing:
## Files Examined
- fixture.md
INDEPENDENT CODE REVIEW PASSED

## Files Examined

- README.md

The reviewer finished but emitted no PASSED or FAILED marker.
TEXT
  # Force the runner-written "complete" state without a verdict, exactly as a
  # clean exit whose log lacks the verdict marker would record it.
  printf '%s\n' '{"state":"complete","provider":"gpt","mode":"manual"}' > "$base.status.json"

  output=$(run_progress --json "$pid")
  assert_json_field_equals "$output" "state" "complete" "complete-no-verdict JSON state"
  assert_json_field_equals "$output" "result_available" "false" "complete-no-verdict result availability"

  set +e
  result=$(run_progress --result "$pid")
  status=$?
  set -e
  assert_equals "$status" "0" "complete-no-verdict --result exit status"
  assert_contains "$result" "## Files Examined" "complete-no-verdict --result text"
  assert_contains "$result" "no PASSED or FAILED marker" "complete-no-verdict --result body content"
}

test_dead_crash_missing_log_returns_diagnostics() {
  local pid base output status
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base.events.jsonl" <<'JSON'
{"severity":"info","event":"provider_started","provider":"claude","ts_epoch":1}
{"severity":"error","event":"missing_result","provider":"claude","ts_epoch":2,"message":"stream ended before result"}
JSON
  printf 'claude crashed while reading prompt\n' > "$base.stderr"

  set +e
  output=$(run_progress --result "$pid")
  status=$?
  set -e

  assert_not_equals "$status" "0" "dead missing log diagnostics status"
  assert_contains "$output" "Fresh Eyes review failed before final output" "dead missing log diagnostics"
  assert_contains "$output" "missing_result" "dead missing log diagnostics"
  assert_contains "$output" "claude crashed while reading prompt" "dead missing log diagnostics"
}

test_dead_crash_empty_log_returns_diagnostics() {
  local pid base output status
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  : > "$base"
  cat > "$base.events.jsonl" <<'JSON'
{"severity":"info","event":"provider_started","provider":"claude","ts_epoch":1}
{"severity":"error","event":"structured_output_missing","provider":"claude","ts_epoch":2,"message":"no structured output"}
JSON
  printf 'schema output was empty\n' > "$base.stderr"

  set +e
  output=$(run_progress --result "$pid")
  status=$?
  set -e

  assert_not_equals "$status" "0" "dead empty log diagnostics status"
  assert_contains "$output" "Fresh Eyes review failed before final output" "dead empty log diagnostics"
  assert_contains "$output" "structured_output_missing" "dead empty log diagnostics"
  assert_contains "$output" "schema output was empty" "dead empty log diagnostics"
}

test_global_locator_ignores_external_log_by_default() {
  local pid alt_log_dir base output
  dead_pid pid
  alt_log_dir="$TEST_TMP/claude-1000/fresheyes-logs"
  base="$alt_log_dir/fresheyes-test-$pid.log"
  write_locator_alias "$pid" "$base" "$GLOBAL_LOG_DIR"
  mkdir -p "$alt_log_dir"
  cat > "$base" <<'TEXT'
## Files Examined

- README.md

INDEPENDENT CODE REVIEW PASSED
TEXT

  local status
  set +e
  output=$(run_progress --json "$pid")
  status=$?
  set -e
  assert_equals "$status" "5" "global locator external log default exit code"
  assert_json_field_equals "$output" "state" "unknown_handle" "global locator external log default state"

  output=$(run_progress_allow_legacy --result "$pid")
  assert_contains "$output" "## Files Examined" "global locator legacy override"
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "global locator legacy override"
}

test_opaque_handle_resolves_via_locator() {
  local handle="20260729-120000-ab12cd"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  printf 'review output line\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual","owner_pid":%s}\n' "$$" \
    > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"

  local output
  output=$(run_progress --json "$handle")
  assert_json_field_equals "$output" "state" "running" "opaque handle state"
  assert_json_field_equals "$output" "log_path" "$log_file" "opaque handle log_path"
}

test_owner_pid_read_from_status_json() {
  # Log filename carries NO numeric pid suffix; liveness must come from
  # status.json owner_pid (a live pid -> running).
  local handle="20260729-120001-ff00aa"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  sleep 60 &
  local live_pid=$!
  LIVE_PIDS+=("$live_pid")
  printf 'in progress\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual","owner_pid":%s}\n' "$live_pid" \
    > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"

  local output
  output=$(run_progress --json "$handle")
  assert_json_field_equals "$output" "state" "running" "owner_pid liveness from status.json"
  assert_json_field_equals "$output" "owner_pid" "$live_pid" "owner_pid surfaced"
}

test_parent_alias_no_longer_resolves() {
  # .parent.<pid> trackers are dead: a handle whose ONLY tracker is a
  # .parent file must not resolve.
  local dead_pid
  dead_pid=$(bash -c 'echo $$')   # already-reaped pid
  local log_file="$LOG_DIR/fresheyes-20260729-120002-1234ab.log"
  printf 'orphan review\n' > "$log_file"
  printf '%s\n' "$log_file" > "$LOG_DIR/.parent.$dead_pid"

  local output
  output=$(run_progress --json "$dead_pid" || true)
  local state
  state=$(json_field "$output" "state")
  if [[ "$state" != "unknown_handle" ]]; then
    fail "expected unknown_handle for .parent-only tracker, got: $state"
  fi
}

test_progress_is_read_only() {
  local handle="20260729-120003-c0ffee"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  printf 'some output\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual"}\n' > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"
  # Also plant the legacy-text failed-state bait that used to trigger rm -f .active.*
  local dead_pid
  dead_pid=$(bash -c 'echo $$')
  local dead_log="$LOG_DIR/fresheyes-20260101-000000-$dead_pid.log"
  printf 'stale\n' > "$dead_log"
  printf '%s\n' "$dead_log" > "$LOG_DIR/.active.$dead_pid"

  local before after
  before=$(snapshot_dir "$LOG_DIR")
  run_progress --json "$handle" >/dev/null || true
  run_progress --result "$handle" >/dev/null 2>&1 || true
  run_progress --json "$dead_pid" >/dev/null || true
  run_progress --result "$dead_pid" >/dev/null 2>&1 || true
  FRESHEYES_ALLOW_LEGACY_PROGRESS=1 run_progress "$dead_pid" >/dev/null 2>&1 || true
  after=$(snapshot_dir "$LOG_DIR")
  if [[ "$before" != "$after" ]]; then
    fail "progress script mutated the log dir:
--- before ---
$before
--- after ---
$after"
  fi
}

test_alive_claude_sidecars_missing_log
test_alive_claude_sidecars_empty_log
test_legacy_no_pid_preserves_numeric_progress
test_bare_pid_legacy_output_is_rejected
test_alive_gpt_json_reports_running_progress
test_alive_gpt_incidental_verdict_while_running_reports_running
test_alive_gpt_final_verdict_reports_complete
test_dead_success_returns_final_review
test_dead_success_json_reports_complete
test_failed_status_ignores_incidental_verdict
test_complete_without_verdict_returns_text
test_dead_crash_missing_log_returns_diagnostics
test_dead_crash_empty_log_returns_diagnostics
test_global_locator_ignores_external_log_by_default
test_opaque_handle_resolves_via_locator
test_owner_pid_read_from_status_json
test_parent_alias_no_longer_resolves
test_progress_is_read_only

printf 'fresheyes-progress tests passed\n'
