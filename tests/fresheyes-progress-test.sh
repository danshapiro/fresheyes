#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS_SCRIPT="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"
TEST_TMP="$(mktemp -d)"
LOG_DIR="$TEST_TMP/fresheyes-logs"
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
  TMPDIR="$TEST_TMP" bash "$PROGRESS_SCRIPT" "$1"
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

  output=$(run_progress "$pid")
  assert_contains "$output" "running" "alive Claude missing log"
  assert_contains "$output" "provider=claude" "alive Claude missing log"
  assert_contains "$output" "provider_events=" "alive Claude missing log"
  assert_contains "$output" "final_lines=0" "alive Claude missing log"
}

test_alive_claude_sidecars_empty_log() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  : > "$base"
  write_claude_events "$base"

  output=$(run_progress "$pid")
  assert_contains "$output" "running" "alive Claude empty log"
  assert_contains "$output" "provider=claude" "alive Claude empty log"
  assert_contains "$output" "provider_events=" "alive Claude empty log"
  assert_contains "$output" "final_lines=0" "alive Claude empty log"
}

test_alive_gpt_preserves_numeric_progress() {
  local pid base output
  start_live_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  printf 'one\ntwo\nthree\n' > "$base"
  printf '%s\n' '{"severity":"info","event":"provider_event","provider":"gpt","ts_epoch":1}' > "$base.events.jsonl"

  output=$(run_progress "$pid")
  assert_equals "$output" "3" "alive GPT numeric progress"
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

  output=$(run_progress "$pid")
  assert_contains "$output" "## Files Examined" "dead success final text"
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "dead success final text"
}

test_dead_crash_missing_log_returns_diagnostics() {
  local pid base output
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base.events.jsonl" <<'JSON'
{"severity":"info","event":"provider_started","provider":"claude","ts_epoch":1}
{"severity":"error","event":"missing_result","provider":"claude","ts_epoch":2,"message":"stream ended before result"}
JSON
  printf 'claude crashed while reading prompt\n' > "$base.stderr"

  output=$(run_progress "$pid")
  assert_not_equals "$output" "0" "dead missing log diagnostics"
  assert_contains "$output" "Fresh Eyes review failed before final output" "dead missing log diagnostics"
  assert_contains "$output" "missing_result" "dead missing log diagnostics"
  assert_contains "$output" "claude crashed while reading prompt" "dead missing log diagnostics"
}

test_dead_crash_empty_log_returns_diagnostics() {
  local pid base output
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  : > "$base"
  cat > "$base.events.jsonl" <<'JSON'
{"severity":"info","event":"provider_started","provider":"claude","ts_epoch":1}
{"severity":"error","event":"structured_output_missing","provider":"claude","ts_epoch":2,"message":"no structured output"}
JSON
  printf 'schema output was empty\n' > "$base.stderr"

  output=$(run_progress "$pid")
  assert_not_equals "$output" "" "dead empty log diagnostics"
  assert_contains "$output" "Fresh Eyes review failed before final output" "dead empty log diagnostics"
  assert_contains "$output" "structured_output_missing" "dead empty log diagnostics"
  assert_contains "$output" "schema output was empty" "dead empty log diagnostics"
}

test_alive_claude_sidecars_missing_log
test_alive_claude_sidecars_empty_log
test_alive_gpt_preserves_numeric_progress
test_dead_success_returns_final_review
test_dead_crash_missing_log_returns_diagnostics
test_dead_crash_empty_log_returns_diagnostics

printf 'fresheyes-progress tests passed\n'
