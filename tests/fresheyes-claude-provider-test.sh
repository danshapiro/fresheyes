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
VERSION_PROBE_FILE="$TEST_TMP/claude-version-probe.txt"
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

if sys.argv[1:] == ["--version"]:
    probe = os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION_PROBE")
    if probe:
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write(os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION", "2.1.283"))
    print(f"{os.environ.get('FRESHEYES_FAKE_CLAUDE_VERSION', '2.1.283')} (Claude Code)")
    raise SystemExit(0)

argv_file = os.environ["FRESHEYES_FAKE_ARGV"]
with open(argv_file, "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)
with open(argv_file + ".env", "w", encoding="utf-8") as handle:
    json.dump({"GIT_OPTIONAL_LOCKS": os.environ.get("GIT_OPTIONAL_LOCKS")}, handle)

mode = os.environ.get("FRESHEYES_FAKE_MODE")
if not mode:
    mode = "automatic" if "--json-schema" in sys.argv else "manual"

# The run's handle reaches the reviewer only through the prompt: the launch
# strips FRESHEYES_HANDLE from the environment. Echoing it back is also the
# assertion that {{RUN_HANDLE}} was substituted.
import re
run_handle = ""
if sys.argv[1:]:
    found = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", sys.argv[-1])
    run_handle = found.group(1) if found else ""

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
        "structured_output": {"approve_commit": True, "issues": [], "run_handle": run_handle},
    })
elif os.environ.get("FRESHEYES_FAKE_EXAMINED_NONE") == "1":
    emit({
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": (
            "## Files Examined\n\n"
            "None. Every read failed.\n\n"
            "## Issues Found\n\n"
            "- **critical** review unavailable: nothing could be read.\n\n"
            "---\n"
            "**INDEPENDENT CODE REVIEW FAILED**\n"
            "FRESHEYES-RUN: %s" % run_handle
        ),
    })
else:
    emit({
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": (
            "## Files Examined\n\n"
            "- README.md\n\n"
            "## Issues Found\n\n"
            "- A fixture quotes this heading without replacing the review:"
            "\n\n## Files Examined\n\n"
            "INDEPENDENT CODE REVIEW PASSED\n"
            "FRESHEYES-RUN: %s" % run_handle
        ),
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

# The reviewer must be read-only. --allowedTools only pre-approves tools; it
# removes none, and a bypass flag approves everything else. These assertions pin
# the flags that do restrict, for every launch path (manual, automatic, detached).
assert_restricted_argv() {
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
env = json.load(open(sys.argv[1] + ".env", encoding="utf-8"))

if "--" not in argv:
    raise SystemExit(f"missing -- prompt separator: {argv!r}")
flags = argv[:argv.index("--")]

for forbidden in ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "bypassPermissions"]:
    if forbidden in argv:
        raise SystemExit(f"reviewer launched with {forbidden}: {argv!r}")

def value_of(flag):
    if flags.count(flag) != 1:
        raise SystemExit(f"expected exactly one {flag} before --: {argv!r}")
    idx = flags.index(flag)
    if idx + 1 >= len(flags):
        raise SystemExit(f"{flag} has no value: {argv!r}")
    return flags[idx + 1]

expected = {
    "--tools": "Bash,Read,Glob,Grep",
    "--allowedTools": "Bash(git diff:*,git show:*,git log:*,git status:*),Read,Glob,Grep",
    "--permission-mode": "dontAsk",
    "--setting-sources": "",
}
for flag, want in expected.items():
    got = value_of(flag)
    if got != want:
        raise SystemExit(f"{flag} was {got!r}, expected {want!r}: {argv!r}")
if "--strict-mcp-config" not in flags:
    raise SystemExit(f"missing --strict-mcp-config before --: {argv!r}")
if "--mcp-config" in flags:
    raise SystemExit(f"unexpected --mcp-config: {argv!r}")
# A `timeout`-wrapped git command is denied, and the review prompt asks for
# that wrapper, so the launch must tell the reviewer to run git bare.
if "timeout" not in value_of("--append-system-prompt"):
    raise SystemExit(f"--append-system-prompt does not tell the reviewer to run git without timeout: {argv!r}")

# The test exports GIT_OPTIONAL_LOCKS=1, so only the launcher's own assignment
# can produce the 0 seen here. Without it `git status` rewrites .git/index.
if env.get("GIT_OPTIONAL_LOCKS") != "0":
    raise SystemExit(f"GIT_OPTIONAL_LOCKS was {env.get('GIT_OPTIONAL_LOCKS')!r} in the reviewer's environment, expected '0'")
PY
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
if model_idx + 1 >= len(argv) or argv[model_idx + 1] != "claude-opus-5-5":
    raise SystemExit(f"manual Claude review did not use Opus 5.5: {argv!r}")
effort_idx = argv.index("--effort")
if effort_idx + 1 >= len(argv) or argv[effort_idx + 1] != "xhigh":
    raise SystemExit(f"manual Claude review did not use xhigh effort: {argv!r}")
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
model_idx = argv.index("--model")
if model_idx + 1 >= len(argv) or argv[model_idx + 1] != "claude-opus-5-5":
    raise SystemExit(f"automatic Claude review did not use Opus 5.5: {argv!r}")
effort_idx = argv.index("--effort")
if effort_idx + 1 >= len(argv) or argv[effort_idx + 1] != "medium":
    raise SystemExit(f"automatic Claude review did not use medium effort: {argv!r}")
if "--" not in argv:
    raise SystemExit(f"missing -- prompt separator: {argv!r}")
if argv[-1].startswith("--") or "Review staged changes." not in argv[-1]:
    raise SystemExit(f"prompt was not the final argv entry: {argv!r}")
schema_idx = argv.index("--json-schema")
if schema_idx + 1 >= len(argv) or "approve_commit" not in argv[schema_idx + 1]:
    raise SystemExit(f"inline schema missing approve_commit: {argv!r}")
PY
}

# The handle the runner minted for the latest run, read from the prompt it sent.
expected_run_handle() {
  "$PYTHON" - "$ARGV_FILE" <<'PYHANDLE'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        argv = json.load(fh)
except Exception:
    print("")
    raise SystemExit(0)
found = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", argv[-1] if argv else "")
print(found.group(1) if found else "")
PYHANDLE
}

assert_automatic_output_json() {
  local json_file="$1"
  "$PYTHON" - "$json_file" "${2:-}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
if data.get("approve_commit") is not True or data.get("issues") != []:
    raise SystemExit(f"unexpected automatic output: {data!r}")
# The result must name the run it belongs to, and the handle must be this run's.
run_handle = data.get("run_handle")
if not isinstance(run_handle, str) or not run_handle:
    raise SystemExit(f"automatic output carries no run_handle: {data!r}")
expected = sys.argv[2] if len(sys.argv) > 2 else ""
if not expected:
    raise SystemExit("no expected run handle was passed: the comparison would not run")
if run_handle != expected:
    raise SystemExit(f"automatic output carries another run's handle: {run_handle!r}")
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
    FRESHEYES_CLAUDE_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    GIT_OPTIONAL_LOCKS=1 \
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
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  run_runner_capture "$run_tmp" "$stdout_file" --foreground --claude "Review README.md."
  output=$(cat "$stdout_file")

  assert_manual_argv
  assert_restricted_argv
  [[ -s "$VERSION_PROBE_FILE" ]] || fail "Opus 5.5 review did not verify the Claude Code version"
  assert_contains "$output" "INDEPENDENT CODE REVIEW PASSED" "manual Claude output"
  assert_contains "$output" "- README.md" "manual Claude output preserves the first files list"
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
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  run_runner_capture "$run_tmp" "$stdout_file" --claude --mode automatic "Review staged changes."
  output=$(cat "$stdout_file")

  assert_automatic_argv
  assert_restricted_argv
  assert_contains "$output" "Fresh Eyes: approved." "automatic Claude output"
  output_file=$(read_latest_file "$run_tmp" 'fresheyes-automatic-*.json')
  assert_automatic_output_json "$output_file" "$(expected_run_handle)"
  assert_contains "$(cat "$(read_latest_file "$run_tmp" 'fresheyes-*.log.status.json')")" '"state":"complete"' "automatic Claude status"
  assert_contains "$(cat "$(read_latest_file "$run_tmp" 'fresheyes-*.log.status.json')")" '"verdict":"approved"' "automatic Claude status"
}

test_default_log_dir_uses_global_log_dir() {
  local run_tmp stdout_file log_file
  run_tmp="$(mktemp -d "$TEST_TMP/default-log.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  mkdir -p "$run_tmp/tmp"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

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

test_manual_detaches_by_default_and_completes() {
  local run_tmp stdout_file fresh_pid progress_output status self_sid child_sid locator base owner_pid sid_reader
  run_tmp="$(mktemp -d "$TEST_TMP/detach.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  # Slow the fake provider (2s) so the detached review is provably STILL RUNNING
  # when the launch call returns. That gives us a window to (a) prove the launch
  # returned before the provider completed, and (b) inspect the review's session.
  if ! TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    FRESHEYES_FAKE_DELAY="2" \
    GIT_OPTIONAL_LOCKS=1 \
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
  [[ "$fresh_pid" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] || fail "default manual launch printed no opaque FRESHPID handle: $(cat "$stdout_file")"

  # SAFETY PROPERTY — the whole point of detach-by-default. The review must run
  # in its OWN session, not the launcher's, so a caller's process-group/harness
  # timeout cannot kill it. FRESHPID is now an opaque handle, not a pid, so
  # resolve the run's base via the locator, poll status.json for the child's
  # owner_pid, and check THAT process's session while the 2s fake provider
  # keeps it alive. If the review finishes before we can look up the owner, an
  # empty child_sid is acceptable — only a MATCHING session is a failure.
  locator="$run_tmp/fresheyes-logs/.locator.$fresh_pid"
  [[ -f "$locator" ]] || fail "no locator for handle $fresh_pid"
  base=$(tr -d '\n' < "$locator")
  owner_pid=""
  for _ in $(seq 1 100); do
    owner_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("owner_pid",""))' \
      "$base.status.json" 2>/dev/null || true)
    [[ -n "$owner_pid" ]] && break
    sleep 0.1
  done
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "status.json never recorded owner_pid"
  # The detached child is a separate launch path: it must carry the same
  # restricted argv as the foreground one. The provider writes its argv when it
  # starts, which can be a moment after owner_pid appears.
  for _ in $(seq 1 100); do
    [[ -s "$ARGV_FILE.env" ]] && break
    sleep 0.1
  done
  [[ -s "$ARGV_FILE.env" ]] || fail "detached provider never started: no argv was recorded"
  assert_restricted_argv
  # `ps -o sess=` prints 0 for every process on macOS, which would make self
  # and child compare equal and hide a real detach failure. getsid(2) answers
  # on both platforms, and python3 is already a prerequisite of this test.
  sid_reader='import os, sys
try:
    print(os.getsid(int(sys.argv[1])))
except (OSError, ValueError):
    pass'
  self_sid=$(python3 -c "$sid_reader" "$$" | tr -d '[:space:]')
  child_sid=$(python3 -c "$sid_reader" "$owner_pid" 2>/dev/null | tr -d '[:space:]' || true)
  # An unreadable own session id would make the comparison below vacuous.
  [[ "$self_sid" =~ ^[0-9]+$ ]] || fail "could not read the launcher's own session id"
  if [[ -n "$child_sid" && "$child_sid" == "$self_sid" ]]; then
    fail "detached review shares the launcher's session ($child_sid); setsid did not detach it, so a caller timeout could still kill it"
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
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

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
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  run_runner_capture "$run_tmp" "$stdout_file" --mode automatic --claude "Review staged changes."
  output=$(cat "$stdout_file")

  assert_contains "$output" "Fresh Eyes: approved." "automatic mode stays synchronous"
  if [[ "$output" == *"FRESHPID="* ]]; then
    fail "automatic mode unexpectedly detached (printed FRESHPID): $output"
  fi
}

test_opus_5_5_rejects_old_claude_code() {
  local run_tmp stdout_file stderr_file status
  run_tmp="$(mktemp -d "$TEST_TMP/old-claude-opus.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  # 2.1.279 sits between the two gates: fine for a Fable 5.1 override, too old
  # for the Opus 5.5 default.
  set +e
  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.279" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "Opus 5.5 accepted unsupported Claude Code 2.1.279"
  assert_contains "$(cat "$stderr_file")" "Claude Opus 5.5 requires Claude Code 2.1.280 or newer" "old Claude Code failure"
}

test_opus_5_5_accepts_exact_minimum() {
  local run_tmp stdout_file stderr_file
  run_tmp="$(mktemp -d "$TEST_TMP/boundary-opus.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  # Exact-boundary acceptance: the new minimum itself must pass (pins
  # version_at_least and the floor constant against off-by-one).
  if ! TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.280" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"; then
    printf 'Opus 5.5 rejected its exact minimum Claude Code 2.1.280. stderr:\n' >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
model_idx = argv.index("--model")
if argv[model_idx + 1] != "claude-opus-5-5":
    raise SystemExit(f"boundary-version run did not use the default model: {argv!r}")
PY
}

test_fable_5_1_override_rejects_old_claude_code() {
  local run_tmp stdout_file stderr_file status
  run_tmp="$(mktemp -d "$TEST_TMP/old-claude.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  # 2.1.256 sits between the two gates: fine for a Fable 5 override, too old
  # for a Fable 5.1 override.
  set +e
  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL="claude-fable-5-1" \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.256" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "Fable 5.1 accepted unsupported Claude Code 2.1.256"
  assert_contains "$(cat "$stderr_file")" "Claude Fable 5.1 requires Claude Code 2.1.257 or newer" "old Claude Code failure"
}

test_fable_5_1_override_accepts_exact_minimum() {
  local run_tmp stdout_file stderr_file
  run_tmp="$(mktemp -d "$TEST_TMP/boundary.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  # Exact-boundary acceptance: the new minimum itself must pass (pins
  # version_at_least and the floor constant against off-by-one).
  if ! TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL="claude-fable-5-1" \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.257" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"; then
    printf 'Fable 5.1 rejected its exact minimum Claude Code 2.1.257. stderr:\n' >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
model_idx = argv.index("--model")
if argv[model_idx + 1] != "claude-fable-5-1":
    raise SystemExit(f"boundary-version run did not use the Fable 5.1 override: {argv!r}")
PY
}

test_fable_5_override_keeps_its_own_gate() {
  local run_tmp stdout_file stderr_file status
  run_tmp="$(mktemp -d "$TEST_TMP/fable5-gate.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"

  # Claude Code 2.1.170 (exactly the Fable 5 minimum, below the Fable 5.1
  # minimum) runs a Fable 5 override fine.
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"
  if ! TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL="claude-fable-5" \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.170" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"; then
    printf 'Fable 5 override unexpectedly failed on Claude Code 2.1.170. stderr:\n' >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  assert_contains "$(cat "$stdout_file")" "INDEPENDENT CODE REVIEW PASSED" "Fable 5 override on Claude Code 2.1.170"
  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
model_idx = argv.index("--model")
if argv[model_idx + 1] != "claude-fable-5":
    raise SystemExit(f"Fable 5 override did not reach the CLI: {argv!r}")
PY

  # ...but below its own 2.1.170 floor, the override is still rejected.
  stderr_file="$run_tmp/stderr-old.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"
  set +e
  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL="claude-fable-5" \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_FAKE_CLAUDE_VERSION="2.1.169" \
    FRESHEYES_FAKE_CLAUDE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "Fable 5 override accepted unsupported Claude Code 2.1.169"
  assert_contains "$(cat "$stderr_file")" "Claude Fable 5 requires Claude Code 2.1.170 or newer" "Fable 5 override old Claude Code failure"
}

test_claude_specific_model_override_wins() {
  local run_tmp stdout_file
  run_tmp="$(mktemp -d "$TEST_TMP/claude-override.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL="opus" \
    FRESHEYES_MODEL="legacy-model-must-not-win" \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file"

  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
model_index = argv.index("--model")
if argv[model_index + 1] != "opus":
    raise SystemExit(f"Claude-specific model override did not win: {argv!r}")
PY
}

test_reasoning_env_sets_claude_effort() {
  local run_tmp stdout_file
  run_tmp="$(mktemp -d "$TEST_TMP/reasoning.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  rm -f "$ARGV_FILE"

  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING=high \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG=1 \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file"

  "$PYTHON" - "$ARGV_FILE" <<'PY'
import json
import sys

argv = json.load(open(sys.argv[1], encoding="utf-8"))
effort_idx = argv.index("--effort")
if effort_idx + 1 >= len(argv) or argv[effort_idx + 1] != "high":
    raise SystemExit(f"FRESHEYES_REASONING=high did not reach the Claude launch: {argv!r}")
if "--ignore-user-config" in argv:
    raise SystemExit(f"the Codex-only user-config flag leaked into the Claude launch: {argv!r}")
PY
}

test_manual_review_that_examined_no_files_exits_7() {
  local run_tmp stdout_file stderr_file status log_file
  run_tmp="$(mktemp -d "$TEST_TMP/unreviewed.XXXXXX")"
  stdout_file="$run_tmp/stdout.txt"
  stderr_file="$run_tmp/stderr.txt"
  rm -f "$ARGV_FILE" "$ARGV_FILE.env"

  set +e
  TMPDIR="$run_tmp" \
    FRESHEYES_LOG_DIR="$run_tmp/fresheyes-logs" \
    FRESHEYES_GLOBAL_LOG_DIR="$run_tmp/global-fresheyes-logs" \
    FRESHEYES_CLAUDE_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_FAKE_EXAMINED_NONE=1 \
    PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  [[ "$status" == "7" ]] || fail "a Claude review that examined no files exited $status, not 7: $(cat "$stderr_file")"
  assert_contains "$(cat "$stdout_file")" "review unavailable" "unreviewed Claude output"
  assert_contains "$(cat "$stderr_file")" "unreviewed" "unreviewed Claude stderr"
  log_file=$(read_latest_file "$run_tmp" 'fresheyes-*.log')
  assert_contains "$(cat "$log_file.status.json")" '"state":"unreviewed"' "unreviewed Claude status"
  if [[ "$(cat "$log_file.status.json")" == *'"verdict"'* ]]; then
    fail "an unreviewed Claude run recorded a verdict: $(cat "$log_file.status.json")"
  fi
}

make_fake_claude
test_manual_claude_invocation_uses_streaming_flags
test_manual_review_that_examined_no_files_exits_7
test_automatic_claude_extracts_structured_output
test_default_log_dir_uses_global_log_dir
test_parser_missing_result_writes_failure_log
test_manual_detaches_by_default_and_completes
test_manual_foreground_runs_synchronously
test_automatic_mode_does_not_detach
test_opus_5_5_rejects_old_claude_code
test_fable_5_1_override_rejects_old_claude_code
test_reasoning_env_sets_claude_effort
test_opus_5_5_accepts_exact_minimum
test_fable_5_1_override_accepts_exact_minimum
test_fable_5_override_keeps_its_own_gate
test_claude_specific_model_override_wins

printf 'fresheyes-claude-provider tests passed\n'
