#!/usr/bin/env bash
# Fresh Eyes - Independent Code Review runner
# Usage: ./fresheyes.sh [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] [--foreground]
#                       [--since COMMIT] [--rebuttals FILE] ['scope text']
# Manual mode detaches into its own session by default (prints FRESHPID=<pid>); --foreground runs synchronously.
# --since COMMIT reviews only git diff COMMIT..HEAD (a later round after fixes) and builds the scope itself.
# --rebuttals FILE gives the reviewer findings the caller declined earlier, with the caller's reasons.

set -euo pipefail

# --- Defaults ---
PROVIDER=""
# Two modes:
#   manual    – thorough, human-readable markdown review (xhigh reasoning by default;
#               FRESHEYES_REASONING=low|medium|high|xhigh overrides it for both providers).
#               Designed for interactive use: rich prose, full context, PASSED/FAILED verdict.
#   automatic – fast, machine-readable JSON review (medium reasoning).
#               Designed for pre-commit hooks: structured {approve_commit, issues[]} output.
MODE="${FRESHEYES_MODE:-manual}"
SCOPE_PARTS=()
# Manual reviews detach into their own session by default so a caller's process
# group / harness timeout can't kill them. --foreground (alias --no-detach)
# forces a synchronous run. Automatic mode never detaches.
FOREGROUND=0
# Delta review (upstream #19): the last reviewed commit, and a file of findings
# the caller declined with its reasons. Both are manual-mode only.
SINCE=""
REBUTTALS_FILE=""
# Capture argv verbatim before the parse loop consumes it, so the detach re-exec
# can relaunch with identical arguments.
ORIG_ARGS=("$@")

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpt)
      PROVIDER="gpt"
      shift
      ;;
    --claude)
      PROVIDER="claude"
      shift
      ;;
    --provider)
      if [[ $# -lt 2 ]]; then
        echo "Error: --provider requires a value (gpt|claude)." >&2
        exit 1
      fi
      PROVIDER="$2"
      shift 2
      ;;
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "Error: --mode requires a value (manual|automatic)." >&2
        exit 1
      fi
      MODE="$2"
      shift 2
      ;;
    --manual)
      MODE="manual"
      shift
      ;;
    --automatic)
      MODE="automatic"
      shift
      ;;
    --foreground|--no-detach)
      FOREGROUND=1
      shift
      ;;
    --since)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --since requires a commit (the head of the last reviewed state)." >&2
        exit 1
      fi
      SINCE="$2"
      shift 2
      ;;
    --rebuttals)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --rebuttals requires a file of declined findings and their rebuttals." >&2
        exit 1
      fi
      REBUTTALS_FILE="$2"
      shift 2
      ;;
    --)
      shift
      SCOPE_PARTS+=("$@")
      break
      ;;
    *)
      SCOPE_PARTS+=("$1")
      shift
      ;;
  esac
done

# --- Resolve provider ---
PROVIDER="${PROVIDER:-${FRESHEYES_PROVIDER:-gpt}}"

case "$PROVIDER" in
  gpt)
    MODEL="${FRESHEYES_GPT_MODEL:-${FRESHEYES_MODEL:-gpt-6-sol}}"
    PROVIDER_LABEL="Codex"
    ;;
  claude)
    MODEL="${FRESHEYES_CLAUDE_MODEL:-${FRESHEYES_MODEL:-claude-opus-5-5}}"
    PROVIDER_LABEL="Claude"
    ;;
  *)
    echo "Error: Unknown provider '$PROVIDER'. Use gpt or claude." >&2
    exit 1
    ;;
esac

version_at_least() {
  python3 - "$1" "$2" <<'PY'
import sys

current_text, minimum_text = sys.argv[1:3]
current_core_text, separator, _ = current_text.partition("-")
current = tuple(int(part) for part in current_core_text.split("."))
minimum = tuple(int(part) for part in minimum_text.split("."))
supported = current > minimum or (current == minimum and not separator)
raise SystemExit(0 if supported else 1)
PY
}

# A `--version` probe must answer or fail; it must never hang. This check runs
# before $GLOBAL_LOG_DIR exists and before a handle is minted, so a probe that
# blocks forever leaves the caller with no FRESHPID, no tracker and an empty
# output file — indistinguishable from a slow launch. Seen 2026-09-16 on macOS
# 26.6.2: a wedged Gatekeeper evaluation (syspolicyd) slept `codex --version`
# in the kernel before dyld ran, so nothing in the exec path ever returned.
# Written as a watchdog rather than timeout(1), which is coreutils and is not
# present on a stock macOS.
VERSION_PROBE_TIMEOUT="${FRESHEYES_VERSION_PROBE_TIMEOUT:-20}"
if [[ ! "$VERSION_PROBE_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: FRESHEYES_VERSION_PROBE_TIMEOUT must be a positive whole number of seconds (got '$VERSION_PROBE_TIMEOUT')." >&2
  exit 1
fi

probe_version() {
  # Runs "$@" with stdin closed, prints its combined output, and returns its
  # exit status — or 124, like timeout(1), when it did not answer in time.
  # The watchdog signals the probe process itself, which is all a `--version`
  # launch is; a wrapper that execs its real binary keeps the same pid, so the
  # one it kills is the one that is stuck. A wrapper that forks instead would
  # leave its child behind — harmless for a probe, and the launch still fails
  # instead of hanging. The one case this cannot bound is a probe wedged in an
  # uninterruptible kernel wait, where even SIGKILL does not land; the macOS
  # Gatekeeper sleep that prompted this is interruptible, and timeout(1)
  # returned 124 against it. One more limit: if the caller started fresheyes
  # with SIGTERM ignored, bash cannot trap it, so the watchdog outlives its
  # cancellation and every fast probe costs the full limit — slow, never stuck.
  # Both temp files live in a private directory: the marker decides the verdict,
  # so a predictable name in shared /tmp would let anyone forge one.
  local probe_dir out_file timeout_marker probe_pid watchdog_pid status=0
  if ! probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/fresheyes-version.XXXXXX")"; then
    echo "Error: could not create a temporary directory for the version probe." >&2
    return 1
  fi
  out_file="$probe_dir/output"
  timeout_marker="$probe_dir/timeout"

  "$@" </dev/null >"$out_file" 2>&1 &
  probe_pid=$!
  # The watchdog waits on a `sleep` it can hand back: killing a subshell does not
  # kill the `sleep` it is blocked in, and a stray `sleep` per launch would
  # outlive every fast probe.
  (
    nap_pid=""
    trap 'kill -TERM "$nap_pid" 2>/dev/null; exit 0' TERM
    sleep "$VERSION_PROBE_TIMEOUT" & nap_pid=$!
    wait "$nap_pid" 2>/dev/null || exit 0
    # Never let a failed marker write (a full or over-quota $TMPDIR) exit this
    # subshell before the kill: the whole point is that the probe gets bounded.
    # Without the marker the parent reports "unable to determine the version"
    # rather than the hang, which is a worse message but not a hang.
    : > "$timeout_marker" || true
    kill -TERM "$probe_pid" 2>/dev/null || true
    sleep 2 & nap_pid=$!
    wait "$nap_pid" 2>/dev/null || exit 0
    kill -KILL "$probe_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  watchdog_pid=$!

  wait "$probe_pid" || status=$?
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  cat "$out_file"
  # The marker decides, tempered by one thing the probe can still prove: an
  # answer. If the marker is there and the probe either failed or printed
  # nothing, it outlived the limit — whether it died on the signal, or handled
  # it and exited 0 without saying anything. A probe that answered just as the
  # marker landed did answer, and its output is worth more than the clock.
  # Without a marker, a probe that chose 124 for its own reasons must not read
  # back as our timeout.
  if [[ -e "$timeout_marker" && ( "$status" -ne 0 || ! -s "$out_file" ) ]]; then
    status=124
  elif [[ "$status" -eq 124 ]]; then
    status=1
  fi
  rm -rf "$probe_dir"
  return "$status"
}

# --- CLI prerequisite check ---
if [[ "$PROVIDER" == "gpt" ]]; then
  if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_CODEX_BIN:-}" ]]; then
    # Parent already validated the CLI + version; cheap re-check only.
    if [[ ! -x "$FRESHEYES_CODEX_BIN" ]]; then
      echo "Error: forwarded codex binary '$FRESHEYES_CODEX_BIN' is not executable." >&2
      exit 1
    fi
    CODEX_BIN="$FRESHEYES_CODEX_BIN"
  else
    if ! command -v codex &> /dev/null; then
      echo "Error: codex CLI not found." >&2
      echo "Install it with: npm install -g @openai/codex" >&2
      exit 1
    fi

    MINIMUM_CODEX_VERSION=""
    CODEX_MODEL_FAMILY=""
    case "$MODEL" in
      gpt-6*)   MINIMUM_CODEX_VERSION="0.153.1"; CODEX_MODEL_FAMILY="GPT-6" ;;
      gpt-5.6*) MINIMUM_CODEX_VERSION="0.144.0"; CODEX_MODEL_FAMILY="GPT-5.6" ;;
    esac
    if [[ -n "$MINIMUM_CODEX_VERSION" ]]; then
      CODEX_VERSION_STATUS=0
      CODEX_VERSION_OUTPUT="$(probe_version codex --version)" || CODEX_VERSION_STATUS=$?
      if [[ "$CODEX_VERSION_STATUS" -eq 124 ]]; then
        echo "Error: 'codex --version' did not answer within ${VERSION_PROBE_TIMEOUT}s." >&2
        echo "The CLI is installed but did not respond. Raise the limit with" >&2
        echo "FRESHEYES_VERSION_PROBE_TIMEOUT if the host is merely slow. One known cause" >&2
        echo "on macOS is a wedged Gatekeeper evaluation, which blocks exec before the" >&2
        echo "binary runs; 'sudo killall syspolicyd' clears that one." >&2
        exit 1
      fi
      if [[ "$CODEX_VERSION_STATUS" -ne 0 ]]; then
        echo "Error: unable to determine the Codex CLI version." >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
      if [[ "$CODEX_VERSION_OUTPUT" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        CODEX_VERSION="${BASH_REMATCH[1]}"
      else
        echo "Error: unable to parse the Codex CLI version from: $CODEX_VERSION_OUTPUT" >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
      if ! version_at_least "$CODEX_VERSION" "$MINIMUM_CODEX_VERSION"; then
        echo "Error: $CODEX_MODEL_FAMILY requires Codex CLI $MINIMUM_CODEX_VERSION or newer; found $CODEX_VERSION." >&2
        echo "Update it with: npm install -g @openai/codex@latest" >&2
        exit 1
      fi
    fi
    CODEX_BIN="$(command -v codex)"
  fi
elif [[ "$PROVIDER" == "claude" ]]; then
  if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_CLAUDE_BIN:-}" ]]; then
    # Parent already validated the CLI + version; cheap re-check only.
    if [[ ! -x "$FRESHEYES_CLAUDE_BIN" ]]; then
      echo "Error: forwarded claude binary '$FRESHEYES_CLAUDE_BIN' is not executable." >&2
      exit 1
    fi
    CLAUDE_BIN="$FRESHEYES_CLAUDE_BIN"
  else
    if ! command -v claude &> /dev/null; then
      echo "Error: claude CLI not found." >&2
      echo "Install it with: npm install -g @anthropic-ai/claude-code" >&2
      exit 1
    fi

    MINIMUM_CLAUDE_VERSION=""
    CLAUDE_MODEL_FAMILY=""
    case "$MODEL" in
      claude-opus-5-5*)  MINIMUM_CLAUDE_VERSION="2.1.280"; CLAUDE_MODEL_FAMILY="Claude Opus 5.5" ;;
      claude-fable-5-1*) MINIMUM_CLAUDE_VERSION="2.1.257"; CLAUDE_MODEL_FAMILY="Claude Fable 5.1" ;;
      claude-fable-5*)   MINIMUM_CLAUDE_VERSION="2.1.170"; CLAUDE_MODEL_FAMILY="Claude Fable 5" ;;
    esac
    if [[ -n "$MINIMUM_CLAUDE_VERSION" ]]; then
      CLAUDE_VERSION_STATUS=0
      CLAUDE_VERSION_OUTPUT="$(probe_version claude --version)" || CLAUDE_VERSION_STATUS=$?
      if [[ "$CLAUDE_VERSION_STATUS" -eq 124 ]]; then
        echo "Error: 'claude --version' did not answer within ${VERSION_PROBE_TIMEOUT}s." >&2
        echo "The CLI is installed but did not respond. Raise the limit with" >&2
        echo "FRESHEYES_VERSION_PROBE_TIMEOUT if the host is merely slow. One known cause" >&2
        echo "on macOS is a wedged Gatekeeper evaluation, which blocks exec before the" >&2
        echo "binary runs; 'sudo killall syspolicyd' clears that one." >&2
        exit 1
      fi
      if [[ "$CLAUDE_VERSION_STATUS" -ne 0 ]]; then
        echo "Error: unable to determine the Claude Code version." >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
      if [[ "$CLAUDE_VERSION_OUTPUT" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        CLAUDE_VERSION="${BASH_REMATCH[1]}"
      else
        echo "Error: unable to parse the Claude Code version from: $CLAUDE_VERSION_OUTPUT" >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
      if ! version_at_least "$CLAUDE_VERSION" "$MINIMUM_CLAUDE_VERSION"; then
        echo "Error: $CLAUDE_MODEL_FAMILY requires Claude Code $MINIMUM_CLAUDE_VERSION or newer; found $CLAUDE_VERSION." >&2
        echo "Update it with: npm install -g @anthropic-ai/claude-code@latest" >&2
        exit 1
      fi
    fi
    CLAUDE_BIN="$(command -v claude)"
  fi
fi

# --- Resolve scope ---
if [[ ${#SCOPE_PARTS[@]} -gt 0 ]]; then
  SCOPE_TEXT="${SCOPE_PARTS[*]}"
else
  if [[ "$MODE" == "automatic" ]]; then
    SCOPE_TEXT="Review the staged changes using git diff --cached."
  else
    SCOPE_TEXT="Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
  fi
fi

# --- Resolve mode-specific files ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE=""
SCHEMA_FILE=""
REASONING_EFFORT=""

case "$MODE" in
  manual)
    PROMPT_FILE="$SCRIPT_DIR/fresheyes-prompt.md"
    REASONING_EFFORT="${FRESHEYES_REASONING:-xhigh}"
    case "$REASONING_EFFORT" in
      low|medium|high|xhigh) ;;
      *)
        echo "Error: FRESHEYES_REASONING must be one of low, medium, high, xhigh (got '$REASONING_EFFORT')." >&2
        exit 1
        ;;
    esac
    ;;
  automatic)
    PROMPT_FILE="$SCRIPT_DIR/fresheyes-automatic-prompt.md"
    SCHEMA_FILE="$SCRIPT_DIR/fresheyes-automatic-schema.json"
    REASONING_EFFORT="medium"
    ;;
  *)
    echo "Error: Unknown mode '$MODE'. Use manual or automatic." >&2
    exit 1
    ;;
esac

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

if [[ "$MODE" == "automatic" && ! -f "$SCHEMA_FILE" ]]; then
  echo "Error: Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

# --- Delta scope and standing rebuttals (upstream #19) ---
if [[ "$MODE" != "manual" && ( -n "$SINCE" || -n "$REBUTTALS_FILE" ) ]]; then
  echo "Error: --since and --rebuttals are for manual reviews only." >&2
  exit 1
fi

REVIEWED_BASE=""
REVIEWED_HEAD=""
if [[ -n "$SINCE" ]]; then
  if [[ ${#SCOPE_PARTS[@]} -gt 0 ]]; then
    echo "Error: --since builds the scope itself; give no scope text with it." >&2
    exit 1
  fi
  if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_REVIEWED_BASE:-}" && -n "${FRESHEYES_REVIEWED_HEAD:-}" ]]; then
    # Detached child: review the commits the parent resolved, not whatever
    # HEAD has moved to since the receipt was printed.
    if [[ ! "$FRESHEYES_REVIEWED_BASE" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ || ! "$FRESHEYES_REVIEWED_HEAD" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
      echo "Error: FRESHEYES_REVIEWED_BASE and FRESHEYES_REVIEWED_HEAD must be full commit ids." >&2
      exit 1
    fi
    REVIEWED_BASE="$FRESHEYES_REVIEWED_BASE"
    REVIEWED_HEAD="$FRESHEYES_REVIEWED_HEAD"
  else
    if ! REVIEWED_BASE="$(git rev-parse --verify --quiet "$SINCE^{commit}")"; then
      echo "Error: --since '$SINCE' is not a commit in $PWD." >&2
      exit 1
    fi
    if ! REVIEWED_HEAD="$(git rev-parse --verify --quiet "HEAD^{commit}")"; then
      echo "Error: --since needs a git repository with a HEAD commit; $PWD has none." >&2
      exit 1
    fi
    if git diff --quiet "$REVIEWED_BASE" "$REVIEWED_HEAD"; then
      echo "Error: nothing to review: HEAD ($REVIEWED_HEAD) has the same tree as --since $SINCE ($REVIEWED_BASE)." >&2
      exit 1
    fi
  fi
  # Two dots, never three: BASE...HEAD diffs from the merge base and omits the
  # removal of code that existed only in the reviewed tree, which is exactly
  # what a later round exists to look at.
  SCOPE_TEXT="Review only the changes between commit $REVIEWED_BASE and commit $REVIEWED_HEAD using git diff $REVIEWED_BASE..$REVIEWED_HEAD (two dots: the difference between the two trees, including code removed since $REVIEWED_BASE). An earlier review round covered $REVIEWED_BASE. List the commits with git log $REVIEWED_BASE..$REVIEWED_HEAD. Read any other code you need for context; report a finding about code outside this diff only when this diff makes it wrong or depends on it."
fi

REBUTTALS_PROMPT_FILE=""
if [[ -n "$REBUTTALS_FILE" ]]; then
  if [[ ! -f "$REBUTTALS_FILE" || ! -r "$REBUTTALS_FILE" ]]; then
    echo "Error: cannot read the rebuttals file: $REBUTTALS_FILE" >&2
    exit 1
  fi
  if [[ ! -s "$REBUTTALS_FILE" ]]; then
    echo "Error: the rebuttals file is empty: $REBUTTALS_FILE" >&2
    exit 1
  fi
  REBUTTALS_PROMPT_FILE="$SCRIPT_DIR/fresheyes-rebuttals-prompt.md"
  if [[ ! -f "$REBUTTALS_PROMPT_FILE" ]]; then
    echo "Error: Prompt file not found: $REBUTTALS_PROMPT_FILE" >&2
    exit 1
  fi
fi

GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
LOG_DIR="${FRESHEYES_LOG_DIR:-$GLOBAL_LOG_DIR}"
mkdir -p "$LOG_DIR"

# Opaque run handle: parent-minted, never a pid. The 6-hex suffix must
# contain at least one [a-f]: all-digit suffixes (probability (10/16)^6
# ≈ 6%) match the retained legacy filename-pid regex `-([0-9]+)\.log$`,
# and with leading zeros stripped a suffix like 000002 resolves to an
# always-live low pid — permanently masking killed_at_launch/died during
# the ownerless launching window (proven by repro).
mint_handle() {
  local suffix
  while :; do
    suffix="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    [[ "$suffix" =~ [a-f] ]] && break
  done
  printf '%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$suffix"
}

# Identity arrives from the environment ONLY for a detached child, which always
# sets FRESHEYES_DAEMONIZED=1 (both launch paths do). The handle now names a
# file and decides an equality test, so an ambient FRESHEYES_HANDLE must not be
# able to take either over: adopt it only for that child, and only in the shape
# mint_handle produces.
if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_HANDLE:-}" && -n "${FRESHEYES_LOG_FILE:-}" ]]; then
  if [[ ! "$FRESHEYES_HANDLE" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]; then
    echo "Error: FRESHEYES_HANDLE is not a Fresh Eyes run handle: $FRESHEYES_HANDLE" >&2
    exit 1
  fi
  # Detached child: identity was minted by the parent and arrives via env.
  HANDLE="$FRESHEYES_HANDLE"
  LOG_FILE="$FRESHEYES_LOG_FILE"
else
  # Foreground / automatic / direct runs mint locally.
  HANDLE="$(mint_handle)"
  LOG_FILE="$LOG_DIR/fresheyes-$HANDLE.log"
fi
RESULT_FILE="$LOG_FILE.result.md"
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
STDERR_LOG="$LOG_FILE.stderr"
STATUS_FILE="$LOG_FILE.status.json"
LAUNCH_STDERR="$LOG_FILE.launch.stderr"
# The file that IS this run's result, as opposed to its transcript: the one file
# the handle check, the verdict and the caller's output all read. It stays
# INSIDE the runner. An earlier revision of this branch published it in
# status.json so the poller could use it too; three review rounds found three
# generations of defects in treating a recorded path as trustworthy, so the
# poller makes its own selection and this is written nowhere. Automatic mode's
# output is still named for the handle, so it belongs to this run like every
# other artifact.
if [[ "$MODE" == "automatic" ]]; then
  RESULT_PATH="$LOG_DIR/fresheyes-automatic-$HANDLE.json"
elif [[ "$PROVIDER" == "gpt" ]]; then
  RESULT_PATH="$RESULT_FILE"
else
  RESULT_PATH="$LOG_FILE"
fi
HANDLE_PARSER="$SCRIPT_DIR/fresheyes-handle.py"
# The detached child must record the parent's ACTUAL detach method:
# write_status overwrites detach_method on every write, so a child that
# hardcoded "setsid" would clobber a systemd-run launch's method on its
# first "running" write. The parent forwards FRESHEYES_DETACH_METHOD in
# both launch paths (Task 3 setsid prefix; Task 8 --setenv).
DETACH_METHOD="${FRESHEYES_DETACH_METHOD:-setsid}"
LAUNCHED_AT_EPOCH="$(date +%s)"
OWNER_PID=""

write_tracker_alias() {
  local dir="$1"
  local name="$2"

  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$LOG_FILE" > "$dir/$name" 2>/dev/null || true
}

# Atomic status.json writer. Read-modify-write so parent-written fields
# (launched_at) survive child updates. Call shape unchanged:
#   write_status <state> <exit_code> <verdict>
# Returns the python writer's exit status. The parent's pre-detach
# "launching" write is a contract (locator + status MUST exist before the
# receipt is printed) and checks this; every child-side/heartbeat/trap call
# site appends `|| true` for best-effort semantics.
write_status() {
  local state="$1"
  local exit_code="${2:-}"
  local verdict="${3:-}"
  # The foreign handle, written only when this run refuses a result: the poller
  # must be able to name both handles even when the result artifact is not there
  # to re-read (the Claude automatic is_error path never writes one).
  local result_handle="${4:-}"
  python3 - "$STATUS_FILE" "$state" "$PROVIDER" "$MODE" "$LOG_FILE" \
    "$exit_code" "$verdict" "${OWNER_PID:-}" "${LAUNCHED_AT_EPOCH:-}" \
    "${DETACH_METHOD:-}" "$HANDLE" "$result_handle" \
    "${REVIEWED_BASE:-}" "${REVIEWED_HEAD:-}" <<'PY'
import json, os, sys, time

(path, state, provider, mode, log_path,
 exit_code, verdict, owner_pid, launched_at, detach_method,
 run_handle, result_handle, reviewed_base, reviewed_head) = sys.argv[1:15]

record = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except Exception:
        record = {}

record["severity"] = "error" if state in ("failed", "handle_mismatch") else "info"
record["state"] = state
record["provider"] = provider
record["mode"] = mode
record["log_path"] = log_path
record["updated_at_epoch"] = time.time()
if state != "launching":
    record["heartbeat_at"] = time.time()
if exit_code:
    record["exit_code"] = int(exit_code)
if verdict:
    record["verdict"] = verdict
if owner_pid:
    record["owner_pid"] = int(owner_pid)
    record["pid"] = int(owner_pid)  # legacy readers
if launched_at:
    record.setdefault("launched_at", float(launched_at))
if detach_method:
    record["detach_method"] = detach_method
if run_handle:
    record["handle"] = run_handle
if result_handle:
    record["result_handle"] = result_handle
# A --since run's commits, so the caller can pass reviewed_head to the next
# round's --since.
if reviewed_base:
    record["reviewed_base"] = reviewed_base
if reviewed_head:
    record["reviewed_head"] = reviewed_head

tmp_path = f"{path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    # Keep the current writer's exact serialization (compact separators +
    # sorted keys + trailing newline): the provider tests assert compact
    # substrings like '"state":"complete"' against this file.
    json.dump(record, handle, separators=(",", ":"), sort_keys=True)
    handle.write("\n")
os.replace(tmp_path, path)
PY
}

# Runtime probe: systemd-run being installed is NOT enough (the user bus can
# be unreachable in some harnesses). Prove it by launching a trivial unit.
_probe_systemd_run() {
  command -v systemd-run &> /dev/null || return 1
  # Hard 2s cap (measured): healthy-bus probe is 0.02-0.28s, but a half-up
  # (accepting-but-mute) bus socket blocks the probe >40s in the sd-bus auth
  # handshake — dead/absent sockets fail in 0.01s, only the half-up case hangs.
  timeout 2s systemd-run --user --collect --quiet --wait /bin/true >/dev/null 2>&1
}

launch_via_systemd_run() {
  local script_abs="$SCRIPT_DIR/$(basename -- "$0")"
  # These must be in the environment BEFORE the forward loop reads them.
  FRESHEYES_CODEX_BIN="${CODEX_BIN:-${FRESHEYES_CODEX_BIN:-}}"
  FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-${FRESHEYES_CLAUDE_BIN:-}}"
  local -a setenv_args=(
    --setenv "FRESHEYES_DAEMONIZED=1"
    --setenv "FRESHEYES_HANDLE=$HANDLE"
    --setenv "FRESHEYES_LOG_FILE=$LOG_FILE"
    --setenv "FRESHEYES_DETACH_METHOD=systemd-run"
    --setenv "PATH=$PATH"
    --setenv "HOME=$HOME"
  )
  if [[ -n "$REVIEWED_HEAD" ]]; then
    setenv_args+=(--setenv "FRESHEYES_REVIEWED_BASE=$REVIEWED_BASE"
                  --setenv "FRESHEYES_REVIEWED_HEAD=$REVIEWED_HEAD")
  fi
  # The unit inherits NOTHING from the caller: forward every var the child
  # needs explicitly (verified live: nvm-installed CLIs vanish otherwise).
  local var
  for var in FRESHEYES_LOG_DIR FRESHEYES_GLOBAL_LOG_DIR FRESHEYES_MODE \
             FRESHEYES_PROVIDER FRESHEYES_GPT_MODEL FRESHEYES_CLAUDE_MODEL \
             FRESHEYES_MODEL FRESHEYES_CODEX_BIN FRESHEYES_CLAUDE_BIN \
             FRESHEYES_HEARTBEAT_SECS FRESHEYES_VERSION_PROBE_TIMEOUT TMPDIR \
             HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
             ALL_PROXY SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE \
             NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE \
             FRESHEYES_FAKE_ARGV FRESHEYES_FAKE_DELAY \
             FRESHEYES_FAKE_CLAUDE_VERSION FRESHEYES_FAKE_CLAUDE_VERSION_PROBE \
             FRESHEYES_FAKE_VERSION FRESHEYES_FAKE_VERSION_PROBE; do
    if [[ -n "${!var:-}" ]]; then
      setenv_args+=(--setenv "$var=${!var}")
    fi
  done
  # systemd applies ExecStart-style variable expansion to transient-unit argv
  # (probed live on this machine: '${PATH}' expands, bare '$HOME' survives,
  # '$$' unescapes to '$'), so a scope like 'review the ${VAR} handling' would
  # be silently corrupted. Escape every '$' as '$$'; systemd unescapes it back,
  # delivering the child's argv byte-identical to ORIG_ARGS. --setenv VALUES
  # are not expansion-subject, so the forwards above need no escaping.
  # The pattern and replacement are held in variables: quoting them inline
  # as ${arg//'$'/'$$'} is a bash 4+ reading, and bash 3.2 (macOS's
  # /bin/bash) instead keeps the quotes literally and expands $$ to its own
  # pid, turning a scope's '$' into "'12345'".
  local dollar='$' escaped_dollar='$$'
  local -a unit_args=()
  local arg
  for arg in "${ORIG_ARGS[@]}"; do
    unit_args+=("${arg//$dollar/$escaped_dollar}")
  done
  systemd-run --user --collect --quiet \
    --property=WorkingDirectory="$PWD" \
    --property=StandardOutput=null \
    --property=StandardError="append:$LAUNCH_STDERR" \
    "${setenv_args[@]}" \
    /usr/bin/env bash "$script_abs" "${unit_args[@]}" >/dev/null 2>>"$LAUNCH_STDERR"
}

# --- Detach manual reviews into their own session (default) ---
# Manual reviews are long (5-30 min). By default we re-exec under setsid so the
# review survives the caller's process group — e.g. an agent harness timeout on
# the launch call. The foreground parent prints the review PID and exits in
# under a second; the detached child runs the review and writes all output to
# its log files, retrieved via fresheyes-progress.sh. FRESHEYES_DAEMONIZED=1
# stops the child re-detaching. Automatic mode (the pre-commit gate) and
# --foreground both skip this and run synchronously.
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  # Parent-owned identity: locator + initial status exist BEFORE the child
  # runs, so a child killed at launch still leaves a loud, diagnosable trail.
  write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
  if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
    write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
  fi

  DETACH_METHOD="setsid"
  case "${FRESHEYES_DETACH:-auto}" in
    systemd-run) DETACH_METHOD="systemd-run" ;;
    setsid)      DETACH_METHOD="setsid" ;;
    auto)        if _probe_systemd_run; then DETACH_METHOD="systemd-run"; fi ;;
    *)           echo "Error: FRESHEYES_DETACH must be auto, setsid, or systemd-run." >&2; exit 1 ;;
  esac

  # Status must carry the final detach_method BEFORE the child launches.
  # write_status overwrites detach_method, so the fallback rewrite below is
  # safe — and for the same reason the child MUST inherit the chosen method
  # via FRESHEYES_DETACH_METHOD (setsid env prefix / --setenv above): its
  # own writes would otherwise clobber the field back to "setsid".
  # The parent's launching write is its contract with the poller: FRESHPID=
  # must never be printed when the locator/status trail failed to appear
  # (python3 missing, ENOSPC, ...), so this write fails LOUD, unlike the
  # best-effort child-side writes.
  _write_launching_or_die() {
    if ! write_status "launching" "" ""; then
      echo "Error: failed to write the initial status file: $STATUS_FILE" >&2
      echo "Cannot hand off a trackable detached review; nothing was launched." >&2
      exit 1
    fi
  }
  _write_launching_or_die
  if [[ "$DETACH_METHOD" == "systemd-run" ]]; then
    if ! launch_via_systemd_run; then
      DETACH_METHOD="setsid"
      _write_launching_or_die
    fi
  fi
  if [[ "$DETACH_METHOD" == "setsid" ]]; then
    if ! command -v setsid &> /dev/null; then
      echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
      exit 2
    fi
    FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="$HANDLE" FRESHEYES_LOG_FILE="$LOG_FILE" \
    FRESHEYES_DETACH_METHOD="$DETACH_METHOD" \
    FRESHEYES_REVIEWED_BASE="$REVIEWED_BASE" FRESHEYES_REVIEWED_HEAD="$REVIEWED_HEAD" \
    FRESHEYES_CODEX_BIN="${CODEX_BIN:-}" FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-}" \
      setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>>"$LAUNCH_STDERR" &
  fi
  echo "FRESHPID=$HANDLE"
  echo "NEXT: bash $SCRIPT_DIR/fresheyes-progress.sh --json $HANDLE   (reviews take 5-30 min; poll every 30-60s)"
  exit 0
fi

# --- Build prompt ---
# One pass over the template: text substituted in (the scope, the rebuttals)
# is never scanned for placeholders itself.
PROMPT=$(python3 - "$PROMPT_FILE" "$SCOPE_TEXT" "$HANDLE" "$REBUTTALS_PROMPT_FILE" "$REBUTTALS_FILE" <<'PY'
import re
import sys

prompt_file, scope, run_handle, rebuttals_prompt_file, rebuttals_file = sys.argv[1:6]
rebuttals = ""
if rebuttals_prompt_file:
    with open(rebuttals_prompt_file, encoding="utf-8") as handle:
        section = handle.read()
    with open(rebuttals_file, encoding="utf-8") as handle:
        rebuttals = section.replace("{{REBUTTALS}}", handle.read().rstrip("\n"))
values = {"REVIEW_SCOPE": scope, "RUN_HANDLE": run_handle, "STANDING_REBUTTALS": rebuttals}
with open(prompt_file, encoding="utf-8") as handle:
    template = handle.read()
print(re.sub(r"\{\{(REVIEW_SCOPE|RUN_HANDLE|STANDING_REBUTTALS)\}\}",
             lambda match: values[match.group(1)], template))
PY
)

if [[ "$PROVIDER" == "claude" ]]; then
  : > "$LOG_FILE"
  : > "$EVENT_LOG"
  : > "$STREAM_LOG"
  : > "$STDERR_LOG"
fi

OWNER_PID=$$
echo "$LOG_FILE" > "$LOG_DIR/.active.$HANDLE"

write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
  write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
fi

HEARTBEAT_PID=""
FINAL_STATUS_WRITTEN="0"
# Set by enforce_result_handle: 1 only when the result was checked and IS this
# run's. The provider-failure branches consult it before printing anything that
# came from the provider.
HANDLE_CHECK_OK=0

manual_verdict_from_log() {
  # The verdict is read from the file that IS the result — the same file the
  # handle check and the caller's output use. One selection, not three.
  local review_file="$LOG_FILE"
  if [[ -s "$RESULT_PATH" ]]; then
    review_file="$RESULT_PATH"
  fi
  # Shared with fresheyes-progress.sh: the one home for the verdict marker.
  python3 "$SCRIPT_DIR/fresheyes-verdict.py" "$review_file" 2>/dev/null
}

# Ask the one home for the run marker whose review this file is.
# Echoes the checker's word; returns its status. Callers MUST capture the
# status explicitly — an unhandled exit would kill the run under `set -e` and
# throw away a review that had already succeeded.
check_result_handle() {
  local review_file="$1"
  local output
  local status
  set +e
  output="$(python3 "$HANDLE_PARSER" "$review_file" "$HANDLE" 2>/dev/null)"
  status=$?
  set -e
  printf '%s\n' "$output"
  return "$status"
}

# Refuse a result that belongs to another run, before any of it is delivered.
# Manual mode fails OPEN when the check cannot be made; automatic mode, which
# is a commit gate, fails CLOSED.
#   enforce_result_handle <file> <manual|automatic> [allow_unverified]
# With allow_unverified=1 only a mismatch refuses: the caller has a provider
# failure of its own to report and its diagnostic is worth more than a
# could-not-verify message.
enforce_result_handle() {
  local review_file="$1"
  local mode="$2"
  local allow_unverified="${3:-0}"
  local output
  local status
  HANDLE_CHECK_OK=0
  set +e
  output="$(check_result_handle "$review_file")"
  status=$?
  set -e

  case "$status" in
    0)
      HANDLE_CHECK_OK=1
      return 0
      ;;
    6)
      local foreign="${output#mismatch }"
      _stop_heartbeat
      write_status "handle_mismatch" "6" "" "$foreign" || true
      FINAL_STATUS_WRITTEN="1"
      echo "Fresh Eyes: handle_mismatch — this result carries review run $foreign, not this run ($HANDLE)." >&2
      echo "It is another review's text, so it was NOT returned. Re-run the review." >&2
      # Name the file that actually holds the withheld text. In automatic mode
      # that is the JSON result, not the transcript, and steering a reader away
      # from the harmless file while leaving the other unnamed is worse than
      # saying nothing.
      echo "The withheld text is in $review_file; it is not evidence about this run and must not be read back." >&2
      if [[ "$review_file" != "$LOG_FILE" ]]; then
        echo "The run's transcript is $LOG_FILE, and it may quote the same text." >&2
      fi
      exit 6
      ;;
  esac

  # Everything else: no marker (1), the result could not be read (7), or the
  # checker could not run at all (any other status — a missing python3 or a
  # partially-synced skill directory, where python itself exits 2).
  local why="carries no run marker"
  if [[ "$status" == "7" ]]; then
    why="could not be read"
  elif [[ "$status" != "1" ]]; then
    why="could not be checked (the run-marker checker did not run)"
  fi

  if [[ "$mode" == "automatic" && "$allow_unverified" != "1" ]]; then
    _stop_heartbeat
    write_status "handle_mismatch" "6" "" "" || true
    FINAL_STATUS_WRITTEN="1"
    echo "Fresh Eyes: handle_mismatch — this result $why, so it cannot be tied to this run ($HANDLE). Commit blocked." >&2
    exit 6
  fi

  echo "Fresh Eyes: this result $why — it is delivered unverified (handle_verified=false)." >&2
  return 0
}

_cleanup() {
  local status=$?
  # Stop the heartbeat BEFORE any terminal write: a beat racing the terminal
  # write_status could re-commit a stale non-terminal record over it.
  _stop_heartbeat
  if [[ "${FINAL_STATUS_WRITTEN:-0}" != "1" ]]; then
    if [[ "$status" -eq 0 ]]; then
      write_status "complete" "$status" "$(manual_verdict_from_log 2>/dev/null || true)" || true
    else
      write_status "failed" "$status" "" || true
    fi
  fi
  rm -f "$LOG_DIR/.active.$HANDLE"
}
trap _cleanup EXIT

log_event() {
  local severity="$1"
  local event="$2"
  local message="${3:-}"

  [[ "$PROVIDER" == "claude" ]] || return 0

  python3 - "$EVENT_LOG" "$severity" "$event" "$PROVIDER" "$MODE" "$$" "$message" <<'PY'
import json
import sys
import time

path, severity, event, provider, mode, pid, message = sys.argv[1:8]
record = {
    "severity": severity,
    "event": event,
    "provider": provider,
    "mode": mode,
    "pid": int(pid),
    "ts_epoch": time.time(),
}
if message:
    record["message"] = message
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
    handle.write("\n")
PY
}

log_event "info" "review_started" "Fresh Eyes review starting."
write_status "running" "" "" || true

echo "Fresh Eyes [$$]: review starting. This may take up to 30 minutes, please wait patiently." >&2

# --- Provider functions ---
# Each provider (GPT/Codex, Claude) has a manual and automatic variant.
#
# Manual functions stream a free-form markdown review to stdout.
#
# Automatic functions write structured JSON to an output file.
# The two providers handle structured output differently:
#   GPT/Codex: --output-schema takes a file path; output is written directly in schema format.
#   Claude:    --json-schema takes inline schema content; stream-json output is parsed into the
#              same schema-conforming output file.

CLAUDE_TOOLS='Bash(git diff:*,git show:*,git log:*,git status:*),Read,Glob,Grep'
# The Claude reviewer is read-only. --allowedTools only pre-approves tools: it
# removes none, and --dangerously-skip-permissions approves all the others, so
# together they left Edit, Write and any shell command available. Each flag
# below closes one gap that was measured with the real CLI (Claude Code 2.1.269):
#   --tools              the only built-in tools that exist in the session
#   --allowedTools       of those, what runs without asking
#   --permission-mode    dontAsk: whatever would prompt is denied, never bypassed
#   --setting-sources '' the user's and the repo's own allow rules, hooks and
#                        plugins do not load (an `allow: ["Bash"]` there would
#                        otherwise grant the shell again)
#   --strict-mcp-config  no --mcp-config is passed, so no MCP servers load
# Because settings do not load, neither do `apiKeyHelper` or an `env` block in
# them: the reviewer needs a logged-in CLI.
# Claude Code still runs its built-in read-only commands (ls, cat, pwd).
# The launch also sets GIT_OPTIONAL_LOCKS=0: without it a plain `git status`
# rewrites .git/index, which is a write to the repository under review.
# The review prompts ask for `timeout 300s` around slow commands. A wrapped
# command is no longer one of the allowed git commands and is denied, so the
# appended system prompt tells the reviewer to run git bare.
CLAUDE_SHELL_NOTE='Your shell is restricted to bare `git diff`, `git show`, `git log` and `git status` commands. Run them directly: do not wrap them in `timeout` or pipe or chain them into other programs, because such commands are denied. Use Read, Glob and Grep for everything else. If you still cannot read the change under review, say so and do not approve it.'
CLAUDE_RESTRICT_ARGS=(
  --tools 'Bash,Read,Glob,Grep'
  --allowedTools "$CLAUDE_TOOLS"
  --permission-mode dontAsk
  --setting-sources ''
  --strict-mcp-config
  --append-system-prompt "$CLAUDE_SHELL_NOTE"
)
CLAUDE_STREAM_PARSER="$SCRIPT_DIR/fresheyes-claude-stream.py"

# FRESHEYES_CODEX_IGNORE_USER_CONFIG=1 launches the Codex reviewer with
# --ignore-user-config: no hooks, plugins, service tier or model overrides from
# the caller's config.toml reach the review, and the prompt carries less
# preamble on every call. Off by default because config.toml is also where a
# custom model provider or trust settings live.
# Codex also reads extra prompt text from stdin whenever stdin is not a TTY, and
# blocks until EOF. The prompt is an argument here, so both launches get
# </dev/null: a caller with an open, silent stdin (a background job, a
# supervisor's pipe) would otherwise hang the review before its first call.
CODEX_USER_CONFIG_FLAG=""
if [[ "${FRESHEYES_CODEX_IGNORE_USER_CONFIG:-0}" == "1" ]]; then
  CODEX_USER_CONFIG_FLAG="--ignore-user-config"
fi

run_gpt_manual() {
  # --skip-git-repo-check: codex exec aborts when its working directory is not
  # inside a git repo. Reviews run read-only and the scope names its own repo
  # (often via `git -C`), so the caller's CWD must not gate the review.
  if ! env -u FRESHEYES_HANDLE -u FRESHEYES_LOG_FILE "$CODEX_BIN" exec \
    $CODEX_USER_CONFIG_FLAG \
    --sandbox read-only \
    --skip-git-repo-check \
    --color never \
    --model "$MODEL" \
    -c features.shell_snapshot=false \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    -o "$RESULT_FILE" \
    "$PROMPT" </dev/null 2>&1 | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    exit 1
  fi
  if [[ ! -s "$RESULT_FILE" ]]; then
    echo "Fresh Eyes: $PROVIDER_LABEL produced no final review. See log: $LOG_FILE" >&2
    exit 1
  fi
  # Before the review is delivered, not after.
  enforce_result_handle "$RESULT_FILE" manual
  cat "$RESULT_FILE"
}

run_gpt_automatic() {
  local output_file="$1"
  # Codex writes schema-conforming JSON directly to the output file — no post-processing needed.
  if ! env -u FRESHEYES_HANDLE -u FRESHEYES_LOG_FILE "$CODEX_BIN" exec \
    $CODEX_USER_CONFIG_FLAG \
    --sandbox read-only \
    --skip-git-repo-check \
    --color never \
    --model "$MODEL" \
    -c features.shell_snapshot=false \
    --output-schema "$SCHEMA_FILE" \
    -o "$output_file" \
    -c model_reasoning_effort="$REASONING_EFFORT" \
    "$PROMPT" </dev/null 2>&1 | tee "$LOG_FILE" > /dev/null; then
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi
}

run_claude_manual() {
  local status
  log_event "info" "provider_started" "Claude manual review started."
  # The parser prints the review once, at the end, and writes the same text to
  # --review-log on every branch. Its stdout is discarded and the review is
  # delivered from the log AFTER the check — the script runs under
  # `set -o pipefail`, so a provider that emits a good result and then exits
  # non-zero would otherwise take the failure branch with the whole review
  # already printed.
  set +e
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT \
    -u FRESHEYES_HANDLE -u FRESHEYES_LOG_FILE GIT_OPTIONAL_LOCKS=0 "$CLAUDE_BIN" -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    "${CLAUDE_RESTRICT_ARGS[@]}" \
    -- \
    "$PROMPT" 2>"$STDERR_LOG" | python3 "$CLAUDE_STREAM_PARSER" \
      --mode manual \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG" > /dev/null
  status=$?
  set -e

  enforce_result_handle "$LOG_FILE" manual

  if [[ "$status" -ne 0 ]]; then
    cat "$LOG_FILE"
    log_event "error" "provider_failed" "Claude manual review failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    # Manual mode delivers an unverified review by design, but the provider's
    # stderr is a second, unverifiable copy: quote it only when the result was
    # checked and is this run's.
    if [[ "$HANDLE_CHECK_OK" == "1" && -s "$STDERR_LOG" ]]; then
      cat "$STDERR_LOG" >&2
    elif [[ -s "$STDERR_LOG" ]]; then
      echo "Provider stderr withheld (this result could not be tied to this run): $STDERR_LOG" >&2
    fi
    exit 1
  fi
  cat "$LOG_FILE"
  log_event "info" "provider_finished" "Claude manual review finished."
}

run_claude_automatic() {
  local output_file="$1"
  # Claude CLI takes schema contents inline (not a file path like Codex).
  local json_schema
  json_schema=$(cat "$SCHEMA_FILE")

  local status
  log_event "info" "provider_started" "Claude automatic review started."
  # Same deferral as the manual path, and for a sharper reason: the parser
  # handles an is_error event before structured output exists at all, printing
  # the provider's text and returning 1 — so the check has to precede the
  # failure branch. Only a MISMATCH may preempt that branch, though: the
  # parser also writes unmarked failure text to the review log on
  # missing_result and structured_output_missing, and refusing there for a
  # missing marker would report every API error, rate limit and auth failure as
  # a handle failure and throw away the diagnostic that says what went wrong.
  set +e
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT \
    -u FRESHEYES_HANDLE -u FRESHEYES_LOG_FILE GIT_OPTIONAL_LOCKS=0 "$CLAUDE_BIN" -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    --json-schema "$json_schema" \
    "${CLAUDE_RESTRICT_ARGS[@]}" \
    -- \
    "$PROMPT" 2>"$STDERR_LOG" | python3 "$CLAUDE_STREAM_PARSER" \
      --mode automatic \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG" \
      --automatic-output "$output_file" > /dev/null
  status=$?
  set -e

  enforce_result_handle "$LOG_FILE" automatic 1

  if [[ "$status" -ne 0 ]]; then
    log_event "error" "provider_failed" "Claude automatic review failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    if [[ "$HANDLE_CHECK_OK" == "1" ]]; then
      cat "$LOG_FILE"
      [[ -s "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2
    else
      # The provider failed AND its output could not be tied to this run: the
      # text is withheld rather than printed as a diagnostic. The commit is
      # blocked either way.
      echo "The provider's output could not be tied to this run, so it was withheld. Its path is named above; it is not evidence about this run." >&2
    fi
    exit 1
  fi
  log_event "info" "provider_finished" "Claude automatic review finished."
}

# Liveness heartbeat: touch status.json's heartbeat_at every ~20s so the
# progress script can distinguish a live review from a dead one. Replaces
# the old 300s stderr echo, which was invisible when detached.
touch_heartbeat() {
  python3 - "$STATUS_FILE" <<'PY' || true
import json, os, sys, time
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        record = json.load(handle)
except Exception:
    record = {}
# Terminal-state precedence: `kill $HEARTBEAT_PID` covers only the subshell —
# an already-forked python can commit a whole stale record AFTER the terminal
# write, resurrecting state=running (later misread as died). Never write over
# a terminal state.
if record.get("state") in ("complete", "failed", "handle_mismatch"):
    sys.exit(0)
record["heartbeat_at"] = time.time()
tmp_path = f"{path}.tmp.hb.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
os.replace(tmp_path, path)
PY
}

_start_heartbeat() {
  (
    while true; do
      sleep "${FRESHEYES_HEARTBEAT_SECS:-20}"
      # Self-terminate when the owner is gone: a SIGKILLed owner never runs
      # _stop_heartbeat, and an orphan loop beating status.json forever would
      # mask `died` permanently.
      kill -0 "${OWNER_PID:-$$}" 2>/dev/null || exit 0
      touch_heartbeat
    done
  ) &
  HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

# --- Dispatch ---

_start_heartbeat

if [[ "$MODE" == "automatic" ]]; then
  # Named for the handle, like every other artifact of this run, so the poller
  # can find the file that IS the result.
  OUTPUT_FILE="$RESULT_PATH"

  case "$PROVIDER" in
    gpt)    run_gpt_automatic "$OUTPUT_FILE" ;;
    claude) run_claude_automatic "$OUTPUT_FILE" ;;
  esac

  if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "Fresh Eyes: $PROVIDER_LABEL produced no output. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    exit 1
  fi

  # Through the same checker as every other call site: the Claude parser's
  # JSON-text fallback never meets the output schema, so the schema's required
  # run_handle is not enough, and a second implementation here would leave the
  # GPT path passing when the checker is missing — the opposite of fail-closed.
  enforce_result_handle "$OUTPUT_FILE" automatic

  set +e
  python3 - "$OUTPUT_FILE" "$PROVIDER_LABEL" <<'PY'
import json
import sys

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "Provider"
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"Fresh Eyes: unable to parse {label} output. Commit blocked.", file=sys.stderr)
    print(f"Error: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict) or "approve_commit" not in data:
    print(f"Fresh Eyes: approve_commit missing from {label} output. Commit blocked.", file=sys.stderr)
    sys.exit(2)

approve = data.get("approve_commit")
issues = data.get("issues") or []
if not isinstance(issues, list):
    issues = []

if approve is True:
    print("Fresh Eyes: approved.")
    if issues:
        print("Notes:")
        for issue in issues:
            severity = issue.get("severity", "unspecified")
            file = issue.get("file", "unknown")
            line = issue.get("line")
            loc = f"{file}:{line}" if line not in (None, "") else file
            desc = issue.get("description", "").strip()
            if desc:
                print(f"- [{severity}] {loc} - {desc}")
            else:
                print(f"- [{severity}] {loc}")
    sys.exit(0)

print("Fresh Eyes: commit not approved.")
if issues:
    print("Issues found:")
    for issue in issues:
        severity = issue.get("severity", "unspecified")
        file = issue.get("file", "unknown")
        line = issue.get("line")
        loc = f"{file}:{line}" if line not in (None, "") else file
        desc = issue.get("description", "").strip()
        if desc:
            print(f"- [{severity}] {loc} - {desc}")
        else:
            print(f"- [{severity}] {loc}")
else:
    print("No issues listed, but approval was denied.")
sys.exit(1)
PY
  status=$?
  set -e
  _stop_heartbeat
  if [[ "$status" -eq 0 ]]; then
    write_status "complete" "$status" "approved" || true
  else
    write_status "failed" "$status" "not_approved" || true
  fi
  FINAL_STATUS_WRITTEN="1"

  echo ""
  echo "---"
  echo "Full log: $LOG_FILE"
  exit "$status"
fi

# --- Manual mode dispatch ---
case "$PROVIDER" in
  gpt)    run_gpt_manual ;;
  claude) run_claude_manual ;;
esac

_stop_heartbeat
write_status "complete" "0" "$(manual_verdict_from_log 2>/dev/null || true)" || true
FINAL_STATUS_WRITTEN="1"

# Output log file path AFTER review (so agents don't check it mid-stream)
echo ""
echo "---"
echo "Full log: $LOG_FILE"
