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
# FRESHEYES_FAKE_ARGV (path) records the review invocation's argv (one
# element per line; --version probes are not recorded).
make_fake_claude() {
  cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env python3
# fresheyes-detach-test-marker
import json, os, sys, time
if "--version" in sys.argv:
    print(os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION", "2.1.170 (Claude Code)"))
    sys.exit(0)
argv_path = os.environ.get("FRESHEYES_FAKE_ARGV")
if argv_path:
    with open(argv_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(sys.argv))
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
  FRESHEYES_LAUNCH_GRACE_SECS="${FRESHEYES_LAUNCH_GRACE_SECS:-15}" \
  FRESHEYES_HEARTBEAT_STALE_SECS="${FRESHEYES_HEARTBEAT_STALE_SECS:-60}" \
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

# --- launch receipt: exactly two lines, self-instructing, no noise
test_receipt_is_exactly_two_lines() {
  local log_dir="$TEST_TMP/logs-receipt"
  mkdir -p "$log_dir"
  local stdout_file="$TEST_TMP/receipt-stdout.txt"
  launch "$log_dir" "$RUNNER" --claude "review HEAD" > "$stdout_file"
  local lines
  lines=$(wc -l < "$stdout_file")
  [[ "$lines" -eq 2 ]] || fail "receipt must be exactly 2 lines, got $lines:
$(cat "$stdout_file")"
  local handle
  handle=$(parse_handle "$(cat "$stdout_file")")
  local second
  second=$(sed -n '2p' "$stdout_file")
  assert_contains "$second" "NEXT: bash " "receipt line 2 prefix"
  assert_contains "$second" "/fresheyes-progress.sh --json $handle" "receipt line 2 poll command"
  assert_contains "$second" "reviews take 5-30 min; poll every 30-60s" "receipt line 2 cadence"
  # Guardrails: no NOTE/warning line, no status-file path.
  if grep -qi 'NOTE\|warning' "$stdout_file"; then
    fail "receipt must not contain a NOTE/warning line"
  fi
  if grep -q 'status\.json' "$stdout_file"; then
    fail "receipt must not print the status-file path"
  fi
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

# Heartbeat: with a slowed fake provider and a 1s heartbeat period, the
# status.json heartbeat_at field must advance while the review runs.
test_heartbeat_advances() {
  local log_dir="$TEST_TMP/logs-hb"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(FRESHEYES_HEARTBEAT_SECS=1 FRESHEYES_FAKE_DELAY=6 \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local base=""
  for _ in $(seq 1 50); do
    [[ -f "$log_dir/.locator.$handle" ]] && base=$(tr -d '\n' < "$log_dir/.locator.$handle") && break
    sleep 0.1
  done
  [[ -n "$base" ]] || fail "heartbeat test: locator never appeared"

  hb_at() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("heartbeat_at",0))' \
      "$base.status.json" 2>/dev/null || echo 0
  }
  local first="0"
  for _ in $(seq 1 50); do
    first=$(hb_at)
    [[ "$first" != "0" ]] && break
    sleep 0.1
  done
  [[ "$first" != "0" ]] || fail "heartbeat_at never written"
  sleep 2.5
  local second
  second=$(hb_at)
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) > float(sys.argv[1]) else 1)' \
    "$first" "$second" || fail "heartbeat_at did not advance ($first -> $second)"
  wait_for_state "$log_dir" "$handle" "complete" "heartbeat run completes" >/dev/null
}

# Terminal-state precedence: a stale touch_heartbeat must never resurrect
# state=running over a terminal record (the orphaned-python interleaving —
# kill $HEARTBEAT_PID covers only the subshell). Exercise the writer
# directly against a completed run's status.json.
test_heartbeat_never_overwrites_terminal_state() {
  local log_dir="$TEST_TMP/logs-hbterm"
  mkdir -p "$log_dir"
  local stdout handle base
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  handle=$(parse_handle "$stdout")
  wait_for_state "$log_dir" "$handle" "complete" "terminal-guard run completes" >/dev/null
  base=$(tr -d '\n' < "$log_dir/.locator.$handle")
  local fn
  fn=$(sed -n '/^touch_heartbeat()/,/^}/p' "$RUNNER")
  [[ -n "$fn" ]] || fail "touch_heartbeat not found in runner"
  local before after
  before=$(cat "$base.status.json")
  bash -c "STATUS_FILE='$base.status.json'; $fn; touch_heartbeat"
  after=$(cat "$base.status.json")
  [[ "$before" == "$after" ]] || fail "touch_heartbeat wrote over a terminal state:
before: $before
after:  $after"
}

# --- (c) killed at launch: a fake setsid that launches NOTHING simulates the
# harness killing the child before its first write (parent-side artifacts
# only), exactly like the codex exec field failure.
make_noop_setsid() {
  cat > "$FAKE_BIN/setsid" <<'FAKE'
#!/usr/bin/env bash
# Swallow the child: simulates the harness tree-kill landing before the
# child's first write. Consumes stdin/stdout silently.
exit 0
FAKE
  chmod +x "$FAKE_BIN/setsid"
}

make_crashing_setsid() {
  cat > "$FAKE_BIN/setsid" <<'FAKE'
#!/usr/bin/env bash
echo "boom: provider exploded during startup" >&2
exit 1
FAKE
  chmod +x "$FAKE_BIN/setsid"
}

remove_fake_setsid() {
  rm -f "$FAKE_BIN/setsid"
}

test_killed_at_launch_harness_variant() {
  local log_dir="$TEST_TMP/logs-c1"
  mkdir -p "$log_dir"
  make_noop_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")

  sleep 2  # exceed the (overridden) launch grace
  # Removed only AFTER the settle sleep: removing immediately races the
  # backgrounded child's exec of setsid, and a lost race writes a shell
  # "No such file or directory" error into launch.stderr, turning the
  # harness-kill (empty stderr) variant into the crashed variant.
  remove_fake_setsid
  local output rc
  set +e
  output=$(FRESHEYES_LAUNCH_GRACE_SECS=1 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 3 ]] || fail "killed_at_launch exit code: got $rc, want 3"
  [[ "$(json_field "$output" "state")" == "killed_at_launch" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "never wrote its first heartbeat" "killed_at_launch observation"
  assert_contains "$message" "kills or reaps detached processes" "killed_at_launch likely cause (hedged)"
  assert_contains "$message" "--foreground" "killed_at_launch remediation"
}

test_killed_at_launch_crashed_variant() {
  local log_dir="$TEST_TMP/logs-c2"
  mkdir -p "$log_dir"
  make_crashing_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")

  sleep 2
  remove_fake_setsid  # after settle: see harness-variant race note
  local output rc
  set +e
  output=$(FRESHEYES_LAUNCH_GRACE_SECS=1 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 3 ]] || fail "crashed-at-launch exit code: got $rc, want 3"
  [[ "$(json_field "$output" "state")" == "killed_at_launch" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "crashed" "crashed variant names the crash"
  assert_contains "$message" "launch.stderr" "crashed variant points at stderr file"
}

# --- (d) died mid-review: kill the whole review session, heartbeat goes stale.
test_died_midreview() {
  local log_dir="$TEST_TMP/logs-d"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(FRESHEYES_HEARTBEAT_SECS=1 FRESHEYES_FAKE_DELAY=20 \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local output
  output=$(wait_for_state "$log_dir" "$handle" "running" "died-test reaches running")
  local owner_pid
  owner_pid=$(json_field "$output" "owner_pid")
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "no owner_pid while running: $output"
  # Kill the whole detached session (child + heartbeat + provider).
  pkill -9 -s "$owner_pid" 2>/dev/null || kill -9 "$owner_pid" 2>/dev/null || true
  sleep 3   # > 2x the 1s heartbeat; we poll with a 2s staleness override

  local rc
  set +e
  output=$(FRESHEYES_HEARTBEAT_STALE_SECS=2 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 4 ]] || fail "died exit code: got $rc, want 4 (output: $output)"
  [[ "$(json_field "$output" "state")" == "died" ]] || fail "state: $output"
  local message log_path
  message=$(json_field "$output" "message")
  log_path=$(json_field "$output" "log_path")
  assert_contains "$message" "$log_path" "died message leads with log path"
  assert_contains "$message" "--foreground" "died message offers foreground re-run"
  assert_contains "$message" "Last sign of life" "died message includes time of death"
}

# --- (e) unknown handle
test_unknown_handle() {
  local log_dir="$TEST_TMP/logs-e"
  mkdir -p "$log_dir"
  local output rc
  set +e
  output=$(poll_json "$log_dir" "20990101-000000-deadbe")
  rc=$?
  set -e
  [[ "$rc" -eq 5 ]] || fail "unknown_handle exit code: got $rc, want 5"
  [[ "$(json_field "$output" "state")" == "unknown_handle" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "no tracker for this handle" "unknown_handle observation"
  assert_contains "$message" "trackers were removed" "unknown_handle hedged cause"
}

# --- launching state right after a (stalled) launch
test_launching_state_is_calm() {
  local log_dir="$TEST_TMP/logs-l"
  mkdir -p "$log_dir"
  make_noop_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  # Within the 15s default grace: launching, exit 0, calm message.
  local output
  output=$(poll_json "$log_dir" "$handle") || fail "launching poll must exit 0"
  remove_fake_setsid  # after poll: see harness-variant race note
  [[ "$(json_field "$output" "state")" == "launching" ]] || fail "state: $output"
  assert_contains "$(json_field "$output" "message")" "poll again in ~15s" "launching message"
}

# --- forwarded provider binary: cheap re-check in the daemonized child
test_forwarded_bin_cheap_recheck() {
  local log_dir="$TEST_TMP/logs-bin"
  mkdir -p "$log_dir"
  # Daemonized child with a bogus forwarded binary must fail loudly.
  local rc
  set +e
  FRESHEYES_DAEMONIZED=1 FRESHEYES_CLAUDE_BIN="$TEST_TMP/does-not-exist" \
    launch "$log_dir" "$RUNNER" --claude "review HEAD" >/dev/null 2>"$TEST_TMP/bin-err.txt"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "bogus forwarded binary must fail"
  assert_contains "$(cat "$TEST_TMP/bin-err.txt")" "not executable" "cheap re-check message"

  # A valid forwarded binary is used directly: strip the fake bin from PATH
  # and rely solely on FRESHEYES_CLAUDE_BIN. Version re-parsing is skipped.
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
  FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="20260729-130000-abcdef" \
  FRESHEYES_LOG_FILE="$log_dir/fresheyes-20260729-130000-abcdef.log" \
  FRESHEYES_CLAUDE_BIN="$FAKE_BIN/claude" \
    timeout 30s bash "$RUNNER" --claude "review HEAD" >/dev/null \
    || fail "forwarded valid binary should run the review without PATH"
  local status="$log_dir/fresheyes-20260729-130000-abcdef.log.status.json"
  local final_state
  final_state=$(json_field "$(cat "$status")" "state")
  [[ "$final_state" == "complete" ]] || fail "forwarded-bin review state: $final_state"
}

# --- systemd-run detach path (Task 8) ---
# Fake systemd-run: records its argv, applies real systemd's ExecStart-style
# variable expansion to the wrapped command argv, then runs it with the
# --setenv environment applied (simulating the unit's clean env).
# The expansion model matches live-probed systemd behavior: ${VAR} expands
# from the unit environment (empty when unset), $$ unescapes to $, and bare
# $VAR survives untouched. Without this modeling, the runner's $-escaping
# regression (user scope text silently corrupted) would be untestable.
make_fake_systemd_run() {
  cat > "$FAKE_BIN/systemd-run" <<'FAKE'
#!/usr/bin/env bash
argv_log="${FRESHEYES_TEST_SDRUN_ARGV:?}"
printf '%s\n' "$@" > "$argv_log"
declare -a child_env=() cmd=()
seen_cmd=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setenv)      child_env+=("$2"); shift 2 ;;
    --user|--collect|--quiet|--wait) shift ;;
    --property=*)  shift ;;
    *)             cmd+=("$1"); seen_cmd=1; shift ;;
  esac
done
if [[ "$seen_cmd" -eq 0 ]]; then exit 1; fi
# Model real systemd's expansion of the unit argv (probed live):
# ${VAR} -> value from the unit env (empty when unset), $$ -> $,
# bare $VAR left alone.
mapfile -d '' -t cmd < <(python3 - "${child_env[@]}" -- "${cmd[@]}" <<'PY'
import sys
args = sys.argv[1:]
split = args.index("--")
env = dict(entry.split("=", 1) for entry in args[:split])
out = []
for arg in args[split + 1:]:
    result = []
    i = 0
    while i < len(arg):
        if arg.startswith("$$", i):
            result.append("$")
            i += 2
        elif arg.startswith("${", i):
            end = arg.find("}", i)
            if end == -1:
                result.append(arg[i:])
                i = len(arg)
            else:
                result.append(env.get(arg[i + 2:end], ""))
                i = end + 1
        else:
            result.append(arg[i])
            i += 1
    out.append("".join(result))
sys.stdout.write("\x00".join(out) + "\x00")
PY
)
# Run detached-ish: background with a clean env (unit semantics).
env -i "${child_env[@]}" "${cmd[@]}" &
exit 0
FAKE
  chmod +x "$FAKE_BIN/systemd-run"
}

# Fake systemd-run that records its argv, then fails (probe passed but the
# transient unit could not start, e.g. bus reset mid-launch).
make_failing_systemd_run() {
  cat > "$FAKE_BIN/systemd-run" <<'FAKE'
#!/usr/bin/env bash
argv_log="${FRESHEYES_TEST_SDRUN_ARGV:?}"
printf '%s\n' "$@" > "$argv_log"
echo "Failed to start transient service unit: Connection reset by peer" >&2
exit 1
FAKE
  chmod +x "$FAKE_BIN/systemd-run"
}

test_systemd_run_detach_forwards_env_and_records_method() {
  local log_dir="$TEST_TMP/logs-sdrun"
  mkdir -p "$log_dir"
  make_fake_systemd_run
  local argv_log="$TEST_TMP/sdrun-argv.txt"
  local stdout
  stdout=$(FRESHEYES_DETACH=systemd-run FRESHEYES_TEST_SDRUN_ARGV="$argv_log" \
    HTTPS_PROXY="http://proxy.example:3128" NODE_EXTRA_CA_CERTS="/etc/ssl/corp.pem" \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  rm -f "$FAKE_BIN/systemd-run"
  local handle
  handle=$(parse_handle "$stdout")
  # Receipt shape identical to the setsid path (2 lines incl. NEXT).
  [[ "$(wc -l <<<"$stdout")" -eq 2 ]] || fail "systemd-run receipt not 2 lines: $stdout"

  local argv
  argv=$(cat "$argv_log")
  assert_contains "$argv" "--user" "sdrun argv --user"
  assert_contains "$argv" "--collect" "sdrun argv --collect"
  assert_contains "$argv" "FRESHEYES_DAEMONIZED=1" "sdrun forwards daemonize sentinel"
  assert_contains "$argv" "FRESHEYES_HANDLE=$handle" "sdrun forwards handle"
  assert_contains "$argv" "FRESHEYES_LOG_FILE=" "sdrun forwards log file"
  assert_contains "$argv" "FRESHEYES_DETACH_METHOD=systemd-run" "sdrun forwards detach method"
  assert_contains "$argv" "FRESHEYES_CLAUDE_BIN=" "sdrun forwards provider bin"
  assert_contains "$argv" "PATH=" "sdrun forwards PATH"
  assert_contains "$argv" "HTTPS_PROXY=http://proxy.example:3128" "sdrun forwards proxy vars"
  assert_contains "$argv" "NODE_EXTRA_CA_CERTS=/etc/ssl/corp.pem" "sdrun forwards CA vars"
  assert_contains "$argv" "WorkingDirectory=" "sdrun sets working directory"
  assert_contains "$argv" "StandardError=append:" "sdrun captures launch stderr"

  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "systemd-run detach")
  [[ "$(json_field "$output" "detach_method")" == "systemd-run" ]] \
    || fail "detach_method not recorded: $output"
}

# Regression (systemd ${VAR} expansion): a scope containing literal ${HOME}
# / $PATH must reach the provider byte-identical on the systemd-run path.
# The fake systemd-run models real systemd's argv expansion, so this fails
# if the runner stops escaping '$' as '$$'.
test_systemd_run_scope_dollar_sequences_survive() {
  local log_dir="$TEST_TMP/logs-sddollar"
  mkdir -p "$log_dir"
  make_fake_systemd_run
  local argv_log="$TEST_TMP/sdrun-dollar-argv.txt"
  local fake_argv="$TEST_TMP/sdrun-dollar-claude-argv.txt"
  # Single-quoted: bash must NOT expand these; they are user scope text.
  local scope='review the ${HOME} and $PATH handling in foo.sh'
  local stdout
  stdout=$(FRESHEYES_DETACH=systemd-run FRESHEYES_TEST_SDRUN_ARGV="$argv_log" \
    FRESHEYES_FAKE_ARGV="$fake_argv" \
    launch "$log_dir" "$RUNNER" --claude "$scope")
  rm -f "$FAKE_BIN/systemd-run"
  local handle
  handle=$(parse_handle "$stdout")
  wait_for_state "$log_dir" "$handle" "complete" "dollar-scope systemd-run" >/dev/null
  [[ -s "$fake_argv" ]] || fail "fake claude never recorded its argv"
  assert_contains "$(cat "$fake_argv")" "$scope" \
    "scope with literal \${HOME}/\$PATH must reach the provider intact"
}

# Probe/force passes but the transient unit fails to start: the parent must
# fall back to setsid, the review must complete, and the fallback rewrite
# must leave detach_method=setsid in the final status.json.
test_systemd_run_launch_failure_falls_back_to_setsid() {
  local log_dir="$TEST_TMP/logs-sdfall"
  mkdir -p "$log_dir"
  make_failing_systemd_run
  local argv_log="$TEST_TMP/sdrun-fail-argv.txt"
  local stdout
  stdout=$(FRESHEYES_DETACH=systemd-run FRESHEYES_TEST_SDRUN_ARGV="$argv_log" \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  rm -f "$FAKE_BIN/systemd-run"
  local handle
  handle=$(parse_handle "$stdout")
  [[ -s "$argv_log" ]] || fail "failing systemd-run was never invoked"
  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "systemd-run launch-failure fallback")
  [[ "$(json_field "$output" "detach_method")" == "setsid" ]] \
    || fail "launch failure must rewrite detach_method=setsid: $output"
}

test_bus_absent_probe_falls_back_to_setsid() {
  local log_dir="$TEST_TMP/logs-nobus"
  mkdir -p "$log_dir"
  # No fake systemd-run on PATH; unset the bus env so the REAL probe (if
  # systemd-run exists) fails, engaging the setsid fallback.
  local stdout
  stdout=$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
    TMPDIR="$TEST_TMP" \
    FRESHEYES_LOG_DIR="$log_dir" FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
    FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
    PATH="$FAKE_BIN:$PATH" \
    timeout 60s bash "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "bus-absent fallback")
  [[ "$(json_field "$output" "detach_method")" == "setsid" ]] \
    || fail "bus-absent launch should fall back to setsid: $output"
}

# --- (f) progress never writes, across every state
test_progress_read_only_all_states() {
  for dir in "$TEST_TMP"/logs-*; do
    [[ -d "$dir" ]] || continue
    local before after
    before=$(snapshot_dir "$dir")
    for locator in "$dir"/.locator.*; do
      [[ -e "$locator" ]] || continue
      local handle="${locator##*/.locator.}"
      FRESHEYES_LAUNCH_GRACE_SECS=1 FRESHEYES_HEARTBEAT_STALE_SECS=2 \
        poll_json "$dir" "$handle" >/dev/null 2>&1 || true
      TMPDIR="$TEST_TMP" FRESHEYES_LOG_DIR="$dir" FRESHEYES_GLOBAL_LOG_DIR="$dir" \
        timeout 30s bash "$PROGRESS" --result "$handle" >/dev/null 2>&1 || true
    done
    poll_json "$dir" "20990101-000000-deadbe" >/dev/null 2>&1 || true
    after=$(snapshot_dir "$dir")
    [[ "$before" == "$after" ]] || fail "progress mutated $dir:
--- before ---
$before
--- after ---
$after"
  done
}

make_fake_claude
test_plain_launch_trackers_and_completion
test_receipt_is_exactly_two_lines
test_monitor_mode_launch_handle_still_resolves
test_mint_handle_suffix_always_has_hex_letter
test_heartbeat_advances
test_heartbeat_never_overwrites_terminal_state
test_killed_at_launch_harness_variant
test_killed_at_launch_crashed_variant
test_died_midreview
test_unknown_handle
test_launching_state_is_calm
test_forwarded_bin_cheap_recheck
test_systemd_run_detach_forwards_env_and_records_method
test_systemd_run_scope_dollar_sequences_survive
test_systemd_run_launch_failure_falls_back_to_setsid
test_bus_absent_probe_falls_back_to_setsid
test_progress_read_only_all_states

printf 'fresheyes-detach tests passed\n'
