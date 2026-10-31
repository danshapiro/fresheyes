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
        handle.write(os.environ.get("FRESHEYES_FAKE_VERSION", "0.153.4"))
    print(f"codex-cli {os.environ.get('FRESHEYES_FAKE_VERSION', '0.153.4')}")
    raise SystemExit(0)

# Like the real codex exec: when stdin is not a TTY, read it to EOF before
# doing anything. A launcher that leaves an open, silent stdin hangs here.
if not sys.stdin.isatty():
    sys.stdin.read()

with open(os.environ["FRESHEYES_FAKE_ARGV"], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)

# The run's handle reaches the reviewer only through the prompt: the launch
# strips FRESHEYES_HANDLE from the environment. Echoing it back is also the
# assertion that {{RUN_HANDLE}} was substituted.
import re
run_handle = ""
if sys.argv[1:]:
    found = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", sys.argv[-1])
    run_handle = found.group(1) if found else ""

if "--output-schema" in sys.argv:
    output_path = sys.argv[sys.argv.index("-o") + 1]
    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump({"approve_commit": True, "issues": [], "run_handle": run_handle}, handle)
    print("fake automatic Codex review complete")
else:
    if "-o" in sys.argv:
        output_path = sys.argv[sys.argv.index("-o") + 1]
        with open(output_path, "w", encoding="utf-8") as handle:
            handle.write("## Files Examined   \n")
            if os.environ.get("FRESHEYES_FAKE_EXAMINED_NONE") == "1":
                # The shape a reviewer returns when every read failed.
                handle.write("None. All three read attempts failed; no repository commands ran.\n\n")
                handle.write("## Issues Found\n- **BLOCKER - review unavailable:** I could not read anything.\n\n")
            else:
                handle.write("- README.md\n")
            if os.environ.get("FRESHEYES_FAKE_OMIT_VERDICT") != "1":
                handle.write("INDEPENDENT CODE REVIEW PASSED\n")
            if run_handle:
                handle.write("FRESHEYES-RUN: %s\n" % run_handle)
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
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$STDOUT_FILE"

if [[ ! -s "$VERSION_PROBE_FILE" ]]; then
  printf 'GPT-6 review did not verify the Codex CLI version\n' >&2
  exit 1
fi

python3 - "$ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)

model_index = argv.index("--model")
actual_model = argv[model_index + 1]
if actual_model != "gpt-6-sol":
    raise SystemExit(f"expected default GPT model gpt-6-sol, got {actual_model!r}")

if "model_reasoning_effort=xhigh" not in argv:
    raise SystemExit(f"manual GPT review did not use xhigh reasoning: {argv!r}")
if "-o" not in argv:
    raise SystemExit(f"manual GPT review did not request a last-message artifact: {argv!r}")
if "--skip-git-repo-check" not in argv:
    raise SystemExit(f"manual GPT review must skip the codex git-repo trust check: {argv!r}")
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
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_MODE=manual \
    timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf 'GPT-6 review accepted unsupported Codex CLI %s\n' "$version" >&2
    exit 1
  fi
  if ! grep -q 'GPT-6 requires Codex CLI 0.153.1 or newer' "$stderr_file"; then
    printf 'unsupported Codex CLI failure did not explain the minimum version:\n' >&2
    cat "$stderr_file" >&2
    exit 1
  fi
}

assert_unsupported_version "0.152.9"
assert_unsupported_version "0.153.1-alpha.1"
# Between the two gates: fine for a GPT-5.6 override, too old for the GPT-6 default.
assert_unsupported_version "0.145.0"

# Exact-boundary acceptance: the new minimum itself must pass (pins
# version_at_least and the floor constant against off-by-one).
BOUNDARY_ARGV_FILE="$TEST_TMP/codex-boundary-argv.json"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$BOUNDARY_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION="0.153.1" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/boundary-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/boundary-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > /dev/null

python3 - "$BOUNDARY_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)
model_index = argv.index("--model")
if argv[model_index + 1] != "gpt-6-sol":
    raise SystemExit(f"boundary-version run did not use the default model: {argv!r}")
PY

TERRA_ARGV_FILE="$TEST_TMP/codex-terra-argv.json"
TERRA_STDOUT_FILE="$TEST_TMP/terra-stdout.txt"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$TERRA_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/terra-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/terra-global-logs" \
  FRESHEYES_GPT_MODEL="gpt-5.6-terra" \
  FRESHEYES_MODEL="legacy-model-must-not-win" \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
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

# A GPT-5.6 override keeps its own (older) minimum: 0.145.0 is too old for the
# GPT-6 default but fine for Terra.
TERRA_OLD_CLI_ARGV_FILE="$TEST_TMP/codex-terra-old-cli-argv.json"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$TERRA_OLD_CLI_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION="0.145.0" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/terra-old-cli-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/terra-old-cli-global-logs" \
  FRESHEYES_GPT_MODEL="gpt-5.6-terra" \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > /dev/null

python3 - "$TERRA_OLD_CLI_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)
model_index = argv.index("--model")
if argv[model_index + 1] != "gpt-5.6-terra":
    raise SystemExit(f"GPT-5.6 override on Codex CLI 0.145.0 did not run: {argv!r}")
PY

# ...but a GPT-5.6 model still enforces its own 0.144.0 floor.
terra_gate_stdout="$TEST_TMP/terra-gate-stdout.txt"
terra_gate_stderr="$TEST_TMP/terra-gate-stderr.txt"
set +e
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$ARGV_FILE" \
  FRESHEYES_FAKE_VERSION="0.143.9" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/terra-gate-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/terra-gate-global-logs" \
  FRESHEYES_GPT_MODEL="gpt-5.6-terra" \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$terra_gate_stdout" 2> "$terra_gate_stderr"
terra_gate_status=$?
set -e

if [[ "$terra_gate_status" -eq 0 ]]; then
  printf 'GPT-5.6 override accepted unsupported Codex CLI 0.143.9\n' >&2
  exit 1
fi
if ! grep -q 'GPT-5.6 requires Codex CLI 0.144.0 or newer' "$terra_gate_stderr"; then
  printf 'GPT-5.6 override failure did not explain its minimum version:\n' >&2
  cat "$terra_gate_stderr" >&2
  exit 1
fi

AUTOMATIC_ARGV_FILE="$TEST_TMP/codex-automatic-argv.json"
AUTOMATIC_STDOUT_FILE="$TEST_TMP/automatic-stdout.txt"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$AUTOMATIC_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/automatic-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/automatic-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --automatic "Review staged changes." > "$AUTOMATIC_STDOUT_FILE"

python3 - "$AUTOMATIC_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)

model_index = argv.index("--model")
actual_model = argv[model_index + 1]
if actual_model != "gpt-6-sol":
    raise SystemExit(f"expected automatic GPT model gpt-6-sol, got {actual_model!r}")
if "model_reasoning_effort=medium" not in argv:
    raise SystemExit(f"automatic GPT review did not use medium reasoning: {argv!r}")
if "--output-schema" not in argv or "-o" not in argv:
    raise SystemExit(f"automatic GPT review did not request structured output: {argv!r}")
if "--skip-git-repo-check" not in argv:
    raise SystemExit(f"automatic GPT review must skip the codex git-repo trust check: {argv!r}")
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
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_MODE=manual \
    timeout 30s bash "$RUNNER" --gpt --manual "Review README.md."
)
detached_pid=$(sed -n 's/^FRESHPID=//p' <<< "$detached_launch" | tr -d '[:space:]')
if [[ ! "$detached_pid" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]; then
  printf 'detached GPT review did not return an opaque handle: %s\n' "$detached_launch" >&2
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
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
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

# FRESHEYES_REASONING overrides the manual reasoning level; nothing else in the
# launch changes and --ignore-user-config stays out unless asked for.
REASONING_ARGV_FILE="$TEST_TMP/codex-reasoning-argv.json"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$REASONING_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/reasoning-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/reasoning-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING=high \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > /dev/null

python3 - "$REASONING_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    argv = json.load(handle)
if "model_reasoning_effort=high" not in argv:
    raise SystemExit(f"FRESHEYES_REASONING=high did not reach the manual GPT launch: {argv!r}")
if "model_reasoning_effort=xhigh" in argv:
    raise SystemExit(f"manual GPT launch still carries the xhigh default: {argv!r}")
if "--ignore-user-config" in argv:
    raise SystemExit(f"--ignore-user-config appeared without FRESHEYES_CODEX_IGNORE_USER_CONFIG=1: {argv!r}")
PY

# An unknown reasoning level is refused before any launch.
BAD_REASONING_ARGV_FILE="$TEST_TMP/codex-bad-reasoning-argv.json"
BAD_REASONING_STDERR="$TEST_TMP/bad-reasoning-stderr.txt"
if PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$BAD_REASONING_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/bad-reasoning-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/bad-reasoning-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING=extreme \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > /dev/null 2> "$BAD_REASONING_STDERR"; then
  printf 'FRESHEYES_REASONING=extreme was accepted\n' >&2
  exit 1
fi
if ! grep -q 'FRESHEYES_REASONING must be one of' "$BAD_REASONING_STDERR"; then
  printf 'invalid FRESHEYES_REASONING did not explain itself:\n' >&2
  cat "$BAD_REASONING_STDERR" >&2
  exit 1
fi
if [[ -e "$BAD_REASONING_ARGV_FILE" ]]; then
  printf 'invalid FRESHEYES_REASONING still launched Codex\n' >&2
  exit 1
fi

# FRESHEYES_CODEX_IGNORE_USER_CONFIG=1 adds --ignore-user-config to the manual
# launch and to the automatic one, which keeps its medium reasoning regardless
# of FRESHEYES_REASONING.
IGNORE_ARGV_FILE="$TEST_TMP/codex-ignore-argv.json"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$IGNORE_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/ignore-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/ignore-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG=1 \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > /dev/null

IGNORE_AUTO_ARGV_FILE="$TEST_TMP/codex-ignore-auto-argv.json"
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$IGNORE_AUTO_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/ignore-auto-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/ignore-auto-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING=high \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG=1 \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --automatic "Review staged changes." > /dev/null

python3 - "$IGNORE_ARGV_FILE" "$IGNORE_AUTO_ARGV_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manual = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    automatic = json.load(handle)
if "--ignore-user-config" not in manual:
    raise SystemExit(f"manual GPT launch lacks --ignore-user-config: {manual!r}")
if manual.index("--ignore-user-config") > manual.index("exec") + 1:
    raise SystemExit(f"--ignore-user-config is not a top-level exec flag: {manual!r}")
if "model_reasoning_effort=xhigh" not in manual:
    raise SystemExit(f"manual GPT launch lost its xhigh default: {manual!r}")
if "--ignore-user-config" not in automatic:
    raise SystemExit(f"automatic GPT launch lacks --ignore-user-config: {automatic!r}")
if "model_reasoning_effort=medium" not in automatic:
    raise SystemExit(f"automatic GPT launch no longer runs at medium with FRESHEYES_REASONING set: {automatic!r}")
PY

# The launcher's own stdin may be an open pipe nobody closes (a background job,
# a supervisor). Codex must not inherit it, or the review blocks before its
# first call.
STDIN_ARGV_FILE="$TEST_TMP/codex-stdin-argv.json"
STDIN_STDOUT_FILE="$TEST_TMP/stdin-stdout.txt"
sleep 60 | PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$STDIN_ARGV_FILE" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_LOG_DIR="$TEST_TMP/stdin-logs" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/stdin-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 20s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$STDIN_STDOUT_FILE" || {
    printf 'a silent open stdin on the launcher stalled the Codex review (timeout hit)\n' >&2
    exit 1
  }
if ! grep -q '^INDEPENDENT CODE REVIEW PASSED$' "$STDIN_STDOUT_FILE"; then
  printf 'review with an open launcher stdin did not complete:\n' >&2
  cat "$STDIN_STDOUT_FILE" >&2
  exit 1
fi

# A review that examined no files is not a completed review: the runner exits 7
# with state "unreviewed", still prints the reviewer's text (it says why), and
# records no verdict. The detached poller reports the same state and exit code.
# The detached run is pinned to setsid: a systemd-run launch forwards only a
# fixed list of variables, and FRESHEYES_FAKE_EXAMINED_NONE is not on it.
UNREVIEWED_LOG_DIR="$TEST_TMP/unreviewed-logs"
UNREVIEWED_STDOUT="$TEST_TMP/unreviewed-stdout.txt"
UNREVIEWED_STDERR="$TEST_TMP/unreviewed-stderr.txt"
set +e
PATH="$FAKE_BIN:$PATH" \
  FRESHEYES_FAKE_ARGV="$TEST_TMP/codex-unreviewed-argv.json" \
  FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
  FRESHEYES_FAKE_EXAMINED_NONE=1 \
  FRESHEYES_LOG_DIR="$UNREVIEWED_LOG_DIR" \
  FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/unreviewed-global-logs" \
  FRESHEYES_GPT_MODEL= \
  FRESHEYES_MODEL= \
  FRESHEYES_REASONING= \
  FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
  FRESHEYES_MODE=manual \
  timeout 30s bash "$RUNNER" --foreground --gpt --manual "Review README.md." > "$UNREVIEWED_STDOUT" 2> "$UNREVIEWED_STDERR"
unreviewed_exit=$?
set -e
if [[ "$unreviewed_exit" != "7" ]]; then
  printf 'a review that examined no files exited %s, not 7\n' "$unreviewed_exit" >&2
  cat "$UNREVIEWED_STDERR" >&2
  exit 1
fi
if ! grep -q 'review unavailable' "$UNREVIEWED_STDOUT"; then
  printf 'the unreviewed run did not print the reviewer'"'"'s explanation:\n' >&2
  cat "$UNREVIEWED_STDOUT" >&2
  exit 1
fi
if ! grep -q 'unreviewed' "$UNREVIEWED_STDERR"; then
  printf 'the unreviewed run did not name its state on stderr:\n' >&2
  cat "$UNREVIEWED_STDERR" >&2
  exit 1
fi
unreviewed_status_file=$(ls -t "$UNREVIEWED_LOG_DIR"/*.status.json | head -n 1)
python3 - "$unreviewed_status_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
if status.get("state") != "unreviewed":
    raise SystemExit(f"runner status is not unreviewed: {status!r}")
if status.get("exit_code") != 7:
    raise SystemExit(f"runner status does not record exit 7: {status!r}")
if "verdict" in status:
    raise SystemExit(f"an unreviewed run recorded a verdict: {status!r}")
PY

UNREVIEWED_DETACHED_LOG_DIR="$TEST_TMP/unreviewed-detached-logs"
UNREVIEWED_DETACHED_GLOBAL_LOG_DIR="$TEST_TMP/unreviewed-detached-global-logs"
unreviewed_launch=$(
  PATH="$FAKE_BIN:$PATH" \
    FRESHEYES_FAKE_ARGV="$TEST_TMP/codex-unreviewed-detached-argv.json" \
    FRESHEYES_FAKE_VERSION_PROBE="$VERSION_PROBE_FILE" \
    FRESHEYES_FAKE_EXAMINED_NONE=1 \
    FRESHEYES_DETACH=setsid \
    FRESHEYES_LOG_DIR="$UNREVIEWED_DETACHED_LOG_DIR" \
    FRESHEYES_GLOBAL_LOG_DIR="$UNREVIEWED_DETACHED_GLOBAL_LOG_DIR" \
    FRESHEYES_GPT_MODEL= \
    FRESHEYES_MODEL= \
    FRESHEYES_REASONING= \
    FRESHEYES_CODEX_IGNORE_USER_CONFIG= \
    FRESHEYES_MODE=manual \
    timeout 30s bash "$RUNNER" --gpt --manual "Review README.md."
)
unreviewed_handle=$(sed -n 's/^FRESHPID=//p' <<< "$unreviewed_launch" | tr -d '[:space:]')
unreviewed_poll=""
unreviewed_poll_exit=0
for _ in {1..100}; do
  set +e
  unreviewed_poll=$(
    FRESHEYES_LOG_DIR="$UNREVIEWED_DETACHED_LOG_DIR" \
      FRESHEYES_GLOBAL_LOG_DIR="$UNREVIEWED_DETACHED_GLOBAL_LOG_DIR" \
      bash "$PROGRESS_SCRIPT" --json "$unreviewed_handle"
  )
  unreviewed_poll_exit=$?
  set -e
  if [[ "$unreviewed_poll" != *'"state":"running"'* && "$unreviewed_poll" != *'"state":"launching"'* ]]; then
    break
  fi
  sleep 0.1
done
python3 - "$unreviewed_poll" "$unreviewed_poll_exit" <<'PY'
import json
import sys

record = json.loads(sys.argv[1])
if record.get("state") != "unreviewed" or sys.argv[2] != "7":
    raise SystemExit(f"poller did not report unreviewed with exit 7 (exit {sys.argv[2]}): {record!r}")
if "verdict" in record or record.get("result_available"):
    raise SystemExit(f"poller offered an unreviewed run as a result: {record!r}")
if "examined no files" not in record.get("message", ""):
    raise SystemExit(f"poller message does not say why: {record!r}")
PY
set +e
unreviewed_result=$(
  FRESHEYES_LOG_DIR="$UNREVIEWED_DETACHED_LOG_DIR" \
    FRESHEYES_GLOBAL_LOG_DIR="$UNREVIEWED_DETACHED_GLOBAL_LOG_DIR" \
    bash "$PROGRESS_SCRIPT" --result "$unreviewed_handle"
)
unreviewed_result_exit=$?
set -e
if [[ "$unreviewed_result_exit" != "7" || "$unreviewed_result" != *"review unavailable"* ]]; then
  printf -- '--result on an unreviewed run exited %s, wanted 7 with the reviewer text:\n%s\n' \
    "$unreviewed_result_exit" "$unreviewed_result" >&2
  exit 1
fi

printf 'fresheyes-gpt-provider tests passed\n'
