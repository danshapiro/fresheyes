#!/usr/bin/env bash
# Detach/tracking harness matrix for the parent-owned-identity redesign.
# Standalone: bash tests/fresheyes-detach-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
cleanup() {
  pkill -f "fresheyes-detach-test-marker" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label: expected to find '$needle' in:
$haystack"
  fi
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
record = json.loads(sys.argv[1])
value = record
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

snapshot_dir() {
  find "$1" -mindepth 1 -printf '%p %s %T@\n' 2>/dev/null | sort
}

# Fake claude provider: emits a minimal valid stream and a PASSED verdict.
# FRESHEYES_FAKE_DELAY (seconds) stretches the review for liveness tests.
make_fake_claude() {
  cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env python3
# fresheyes-detach-test-marker
import json, os, sys, time
if "--version" in sys.argv:
    print(os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION", "2.1.170 (Claude Code)"))
    sys.exit(0)
delay = float(os.environ.get("FRESHEYES_FAKE_DELAY", "0"))
print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
if delay:
    time.sleep(delay)
review = "# Review\n\nAll good.\n\nINDEPENDENT CODE REVIEW PASSED\n"
print(json.dumps({"type": "result", "subtype": "success", "result": review}), flush=True)
FAKE
  chmod +x "$FAKE_BIN/claude"
}

# Launch wrapper: isolated log dir per test, fake provider on PATH.
# Pins FRESHEYES_DETACH=setsid for determinism (overridable by env prefix);
# harmless before Task 8 introduces the variable, load-bearing after.
launch() {
  local log_dir="$1"; shift
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" \
  FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  FRESHEYES_DETACH="${FRESHEYES_DETACH:-setsid}" \
  FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
  PATH="$FAKE_BIN:$PATH" \
  timeout 30s bash "$@"
}

poll_json() {
  local log_dir="$1" handle="$2"
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" \
  FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  timeout 30s bash "$PROGRESS" --json "$handle"
}

wait_for_state() {
  local log_dir="$1" handle="$2" want="$3" label="$4"
  local output state
  for _ in $(seq 1 100); do
    output=$(poll_json "$log_dir" "$handle" || true)
    state=$(json_field "$output" "state" 2>/dev/null || echo "")
    if [[ "$state" == "$want" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 0.2
  done
  fail "$label: never reached state=$want; last: $output"
}

parse_handle() {
  # $1 = captured launch stdout. Prints the handle.
  local handle
  handle=$(sed -n 's/^FRESHPID=//p' <<<"$1" | tr -d '[:space:]')
  [[ "$handle" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] \
    || fail "receipt handle is not an opaque handle: '$handle' (stdout: $1)"
  printf '%s\n' "$handle"
}

# --- (a) plain bash launch: receipt + trackers at parent exit, resolves to complete
test_plain_launch_trackers_and_completion() {
  local log_dir="$TEST_TMP/logs-a"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")

  # Trackers must exist the moment the parent has exited (created BEFORE detach).
  [[ -f "$log_dir/.locator.$handle" ]] || fail "no .locator.$handle at parent exit"
  local log_file
  log_file=$(tr -d '\n' < "$log_dir/.locator.$handle")
  [[ -f "$log_file.status.json" ]] || fail "no status.json at parent exit"
  assert_contains "$(cat "$log_file.status.json")" '"detach_method"' "initial status has detach_method"
  assert_contains "$(cat "$log_file.status.json")" '"launched_at"' "initial status has launched_at"

  # No .parent.* files, ever.
  if compgen -G "$log_dir/.parent.*" > /dev/null; then
    fail ".parent.* tracker written; that mechanism is deleted"
  fi

  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "plain launch")
  [[ "$(json_field "$output" "verdict")" == "passed" ]] || fail "plain launch verdict"
}

# --- (b) amplifier-style launch: monitor mode makes the backgrounded setsid
# process a process-group leader, so util-linux setsid FORKS and $! diverges
# from the child pid. The printed handle must resolve anyway (regression for
# field failure 2).
test_monitor_mode_launch_handle_still_resolves() {
  local log_dir="$TEST_TMP/logs-b"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(launch "$log_dir" -m "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  wait_for_state "$log_dir" "$handle" "complete" "monitor-mode launch" >/dev/null
}

# --- handle minting: the 6-hex suffix must always contain >=1 [a-f].
# All-digit suffixes match the retained legacy filename-pid regex
# -([0-9]+)\.log$ and (leading zeros stripped) can resolve to always-live
# low pids, permanently masking killed_at_launch/died — guarded at mint time.
test_mint_handle_suffix_always_has_hex_letter() {
  local fn
  fn=$(sed -n '/^mint_handle()/,/^}/p' "$RUNNER")
  [[ -n "$fn" ]] || fail "mint_handle not found in runner"
  local i handle suffix
  for i in $(seq 1 50); do
    handle=$(bash -c "$fn; mint_handle")
    [[ "$handle" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] \
      || fail "minted handle malformed: $handle"
    suffix="${handle##*-}"
    [[ "$suffix" =~ [a-f] ]] \
      || fail "all-digit suffix minted (collides with legacy filename-pid fallback): $handle"
  done
}

make_fake_claude
test_plain_launch_trackers_and_completion
test_monitor_mode_launch_handle_still_resolves
test_mint_handle_suffix_always_has_hex_letter

printf 'fresheyes-detach tests passed\n'
