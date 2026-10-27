#!/usr/bin/env bash
# Regression test for upstream issue #11: a review that finds an earlier run's
# result on disk and re-emits it as its own.
#
# The prior run's artifacts here are FABRICATED, not produced by a real run:
# they carry a FRESHEYES-RUN marker, which only a fixed fresheyes writes. That
# is deliberate — the point is that once every result is marked, a replayed one
# is detectable. It is not a reproduction of #11's own (unmarked) case.
#
# Assertion order matters. On unmodified upstream/main the runner exits 0 and
# the poller returns the replayed review, so the LEAK is asserted before the
# exit code: a file stops at its first failed assertion, and the first one has
# to name the leak. "The caller's streams" means stdout AND stderr — both
# Claude failure branches cat the provider's stderr.
#
# A run against unmodified upstream/main proves only the FIRST case: the file
# aborts there. The later cases are RED on that base too — its poller returns the
# foreign review with rc=0 — but this file does not demonstrate it; run a case on
# its own against the base tree if you need that evidence.
#
# Portability: macOS bash 3.2 and BSD userland. No find -printf, no mapfile,
# no ps -o sess=. `setsid` and `timeout` are required (Homebrew on macOS).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

PRIOR_HANDLE="20260101-000000-aaaaaa"
LEAK="PRIOR-RUN-FINDING"

CASE_DIR=""
RUNNER_PATH="$RUNNER"
PROGRESS_PATH="$PROGRESS"
OUT_FILE=""
ERR_FILE=""
STATUS=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) : ;;
    *) fail "$label: expected to find '$needle' in: $haystack" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) fail "$label: found '$needle' where it must never appear: $haystack" ;;
    *) : ;;
  esac
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: got '$actual', want '$expected'"
}

# No review text may reach either stream the caller reads.
assert_no_leak() {
  local label="$1"
  assert_not_contains "$(cat "$OUT_FILE")" "$LEAK" "$label (stdout)"
  assert_not_contains "$(cat "$ERR_FILE")" "$LEAK" "$label (stderr)"
}

# Run a command, capturing stdout, stderr and exit status separately.
run_capture() {
  local tag="$1"
  shift
  OUT_FILE="$TEST_TMP/$tag.out"
  ERR_FILE="$TEST_TMP/$tag.err"
  set +e
  "$@" >"$OUT_FILE" 2>"$ERR_FILE" </dev/null
  STATUS=$?
  set -e
}

# --- Fake provider binaries -------------------------------------------------

cat > "$FAKE_BIN/codex" <<'PYCODEX'
#!/usr/bin/env python3
"""Fake codex. Replays a prior run's result, exactly as upstream #11 reports."""
import glob
import json
import os
import re
import sys

argv = sys.argv[1:]

if argv[:1] == ["--version"]:
    probe = os.environ.get("FRESHEYES_FAKE_VERSION_PROBE")
    if probe:
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("0.154.0")
    print("codex-cli 0.154.0")
    raise SystemExit(0)

argv_file = os.environ.get("FRESHEYES_FAKE_ARGV")
if argv_file:
    with open(argv_file, "w", encoding="utf-8") as handle:
        json.dump(argv, handle)

behaviour = os.environ.get("FAKE_BEHAVIOUR", "replay")
log_dir = os.environ["FRESHEYES_LOG_DIR"]
prompt = argv[-1] if argv else ""
# The run's own handle is only knowable from the prompt: the launch strips
# FRESHEYES_HANDLE from the environment. Finding it here is also the assertion
# that {{RUN_HANDLE}} was substituted.
match = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", prompt)
own_handle = match.group(1) if match else ""

def prior_markdown():
    hits = sorted(glob.glob(os.path.join(log_dir, "fresheyes-*.log.result.md")))
    if not hits:
        return ""
    with open(hits[0], encoding="utf-8") as handle:
        return handle.read()

def prior_json():
    hits = sorted(glob.glob(os.path.join(log_dir, "fresheyes-automatic-*.json")))
    for path in hits:
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except Exception:
            continue
    return {}

out_path = argv[argv.index("-o") + 1] if "-o" in argv else None

if "--output-schema" in argv:
    if behaviour == "replay":
        payload = prior_json()
    elif behaviour == "own":
        payload = {"approve_commit": True, "issues": [], "run_handle": own_handle}
    else:
        payload = {"approve_commit": True, "issues": []}
    if out_path:
        with open(out_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
    print("fake automatic Codex review complete")
    raise SystemExit(int(os.environ.get("FAKE_EXIT", "0")))

if behaviour == "replay":
    review = prior_markdown()
else:
    review = (
        "## Files Examined\n- README.md\n\n"
        "## Issues Found\n- **minor** `README.md:1` - a fresh finding\n\n"
        "## Summary\nA review of this run's own scope.\n\n"
        "---\n**INDEPENDENT CODE REVIEW PASSED**\n"
    )
    if behaviour == "own" and own_handle:
        review += "FRESHEYES-RUN: %s\n" % own_handle
    if behaviour == "quote":
        # Upstream #13: the reviewer quotes an earlier round's notes, verdict
        # and run marker included, and leaves out a verdict of its own.
        review = (
            "## Files Examined\n- docs/reviews/round-1.md\n\n"
            "## Issues Found\n- **minor** `docs/reviews/round-1.md:9` - the earlier round ended:\n\n"
            "**INDEPENDENT CODE REVIEW FAILED**\n"
            "FRESHEYES-RUN: 20260101-000000-aaaaaa\n\n"
            "## Summary\nA review of this run's own scope.\n\n"
            "---\nFRESHEYES-RUN: %s\n" % own_handle
        )

if out_path:
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(review)

for index in range(50):
    print("fake Codex diagnostic line %d" % index)
raise SystemExit(int(os.environ.get("FAKE_EXIT", "0")))
PYCODEX
chmod +x "$FAKE_BIN/codex"

cat > "$FAKE_BIN/claude" <<'PYCLAUDE'
#!/usr/bin/env python3
"""Fake claude. Same replay behaviour, through the stream-json protocol."""
import glob
import json
import os
import re
import sys

argv = sys.argv[1:]

if argv[:1] == ["--version"]:
    probe = os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION_PROBE")
    if probe:
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("2.1.283")
    print("2.1.283 (Claude Code)")
    raise SystemExit(0)

argv_file = os.environ.get("FRESHEYES_FAKE_ARGV")
if argv_file:
    with open(argv_file, "w", encoding="utf-8") as handle:
        json.dump(argv, handle)

behaviour = os.environ.get("FAKE_BEHAVIOUR", "replay")
log_dir = os.environ["FRESHEYES_LOG_DIR"]
prompt = argv[-1] if argv else ""
match = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", prompt)
own_handle = match.group(1) if match else ""

def prior_markdown():
    hits = sorted(glob.glob(os.path.join(log_dir, "fresheyes-*.log.result.md")))
    if not hits:
        return ""
    with open(hits[0], encoding="utf-8") as handle:
        return handle.read()

def prior_json():
    hits = sorted(glob.glob(os.path.join(log_dir, "fresheyes-automatic-*.json")))
    for path in hits:
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except Exception:
            continue
    return {}

def emit(obj):
    print(json.dumps(obj), flush=True)

automatic = "--json-schema" in argv

if behaviour == "replay":
    review = prior_markdown()
    # The provider's own stderr reaches the run's .stderr, which the poller's
    # failure diagnostic reads. Put the review on a NON-FINAL line so both the
    # stderr tail and the derived last_error= line are exercised.
    print(review, file=sys.stderr)
    print("fake claude stderr trailer", file=sys.stderr, flush=True)
else:
    review = (
        "## Files Examined\n- README.md\n\n"
        "## Issues Found\n- **minor** `README.md:1` - a fresh finding\n\n"
        "## Summary\nA review of this run's own scope.\n\n"
        "---\n**INDEPENDENT CODE REVIEW PASSED**\n"
    )
    if behaviour == "own" and own_handle:
        review += "FRESHEYES-RUN: %s\n" % own_handle
    if behaviour == "quote":
        # Upstream #13: the reviewer quotes an earlier round's notes, verdict
        # and run marker included, and leaves out a verdict of its own.
        review = (
            "## Files Examined\n- docs/reviews/round-1.md\n\n"
            "## Issues Found\n- **minor** `docs/reviews/round-1.md:9` - the earlier round ended:\n\n"
            "**INDEPENDENT CODE REVIEW FAILED**\n"
            "FRESHEYES-RUN: 20260101-000000-aaaaaa\n\n"
            "## Summary\nA review of this run's own scope.\n\n"
            "---\nFRESHEYES-RUN: %s\n" % own_handle
        )
    print("fake claude stderr line", file=sys.stderr, flush=True)

emit({"type": "system", "subtype": "init", "session_id": "fake-session"})

if automatic:
    if behaviour == "replay":
        structured = prior_json()
    elif behaviour == "own":
        structured = {"approve_commit": True, "issues": [], "run_handle": own_handle}
    else:
        structured = {"approve_commit": True, "issues": []}
    if os.environ.get("FAKE_IS_ERROR") == "1":
        emit({
            "type": "result",
            "subtype": "error",
            "is_error": True,
            "result": json.dumps(structured),
        })
    else:
        emit({
            "type": "result",
            "subtype": "success",
            "is_error": False,
            "result": "Done.",
            "structured_output": structured,
        })
else:
    emit({
        "type": "result",
        "subtype": "error" if os.environ.get("FAKE_IS_ERROR") == "1" else "success",
        "is_error": os.environ.get("FAKE_IS_ERROR") == "1",
        "result": review,
    })

raise SystemExit(int(os.environ.get("FAKE_EXIT", "0")))
PYCLAUDE
chmod +x "$FAKE_BIN/claude"

# --- Fixtures ---------------------------------------------------------------

prior_review_text() {
  printf '%s\n' \
    '## Files Examined' \
    '- calc.py' \
    '' \
    '## Issues Found' \
    "- **major** \`calc.py:12\` - $LEAK: the loop kills a tmux session" \
    '' \
    '## Summary' \
    'The review of an entirely different run.' \
    '' \
    '---' \
    '**INDEPENDENT CODE REVIEW FAILED**' \
    "FRESHEYES-RUN: $PRIOR_HANDLE"
}

seed_prior_run() {
  local dir="$1"
  local base="$dir/fresheyes-$PRIOR_HANDLE.log"
  mkdir -p "$dir"

  # The provider transcript: it quotes the review, as a real transcript does.
  {
    printf 'fake Codex diagnostic line 0\n'
    prior_review_text
  } > "$base"
  prior_review_text > "$base.result.md"
  cat > "$base.status.json" <<JSON
{"exit_code":0,"handle":"$PRIOR_HANDLE","heartbeat_at":1767225600.0,"launched_at":1767225500.0,"log_path":"$base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1767225600.0,"verdict":"failed"}
JSON
  printf '%s\n' "$base" > "$dir/.locator.$PRIOR_HANDLE"
  cat > "$dir/fresheyes-automatic-$PRIOR_HANDLE.json" <<JSON
{"approve_commit": false, "issues": [{"severity": "major", "file": "calc.py", "line": 12, "description": "$LEAK: the loop kills a tmux session"}], "run_handle": "$PRIOR_HANDLE"}
JSON
}

new_case() {
  CASE_DIR="$TEST_TMP/$1"
  mkdir -p "$CASE_DIR/logs"
  seed_prior_run "$CASE_DIR/logs"
}

# Every runner invocation: fakes on PATH, a private log dir, fleet env pins off.
run_fresheyes() {
  local tag="$1"
  shift
  run_capture "$tag" env \
    -u FRESHEYES_GPT_MODEL -u FRESHEYES_MODEL -u FRESHEYES_CLAUDE_MODEL \
    -u FRESHEYES_PROVIDER -u FRESHEYES_REASONING -u FRESHEYES_MODE \
    "PATH=$FAKE_BIN:$PATH" \
    "FRESHEYES_LOG_DIR=$CASE_DIR/logs" \
    "FRESHEYES_GLOBAL_LOG_DIR=$CASE_DIR/logs" \
    "FRESHEYES_FAKE_ARGV=$CASE_DIR/argv.json" \
    "FRESHEYES_FAKE_VERSION_PROBE=$CASE_DIR/version.txt" \
    "FRESHEYES_FAKE_CLAUDE_VERSION_PROBE=$CASE_DIR/claude-version.txt" \
    "FAKE_BEHAVIOUR=${FAKE_BEHAVIOUR:-replay}" \
    "FAKE_IS_ERROR=${FAKE_IS_ERROR:-0}" \
    "FAKE_EXIT=${FAKE_EXIT:-0}" \
    timeout 60s bash "$RUNNER_PATH" "$@"
}

run_progress() {
  local tag="$1"
  shift
  run_capture "$tag" env \
    "FRESHEYES_LOG_DIR=$CASE_DIR/logs" \
    "FRESHEYES_GLOBAL_LOG_DIR=$CASE_DIR/logs" \
    timeout 30s bash "$PROGRESS_PATH" "$@"
}

status_field() {
  local file="$1" field="$2"
  python3 - "$file" "$field" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(sys.argv[2], "")
print(value if value is not None else "")
PY
}

# The handle of the run this case just made (the one that is NOT the prior run).
current_base() {
  local dir="$CASE_DIR/logs"
  local path
  for path in "$dir"/fresheyes-*.log; do
    case "$path" in
      *"$PRIOR_HANDLE"*) continue ;;
      *"*"*) continue ;;
    esac
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

current_handle() {
  local base
  base="$(current_base)" || return 1
  base="${base##*/fresheyes-}"
  printf '%s\n' "${base%.log}"
}

# --- 1.5 / 1.6  GPT manual foreground: the reproduced case -------------------

new_case gpt-manual
FAKE_BEHAVIOUR=replay run_fresheyes gpt-manual --foreground --gpt --manual "Review calc.py."
assert_no_leak "GPT manual replay"
assert_equals "$STATUS" "6" "GPT manual replay exit status"
assert_contains "$(cat "$ERR_FILE")" "handle_mismatch" "GPT manual replay state name"
assert_contains "$(cat "$ERR_FILE")" "$PRIOR_HANDLE" "GPT manual replay names the foreign handle"

GPT_BASE="$(current_base)" || fail "GPT manual replay: no run artifacts were written"
GPT_HANDLE="$(current_handle)"
assert_contains "$(cat "$ERR_FILE")" "$GPT_HANDLE" "GPT manual replay names this run's handle"
assert_equals "$(status_field "$GPT_BASE.status.json" state)" "handle_mismatch" "GPT manual replay recorded state"
assert_equals "$(status_field "$GPT_BASE.status.json" exit_code)" "6" "GPT manual replay recorded exit code"

run_progress gpt-manual-result --result "$GPT_HANDLE"
assert_no_leak "GPT manual replay --result"
assert_equals "$STATUS" "6" "GPT manual replay --result exit status"

run_progress gpt-manual-json --json "$GPT_HANDLE"
assert_no_leak "GPT manual replay --json"
assert_equals "$STATUS" "6" "GPT manual replay --json exit status"
assert_contains "$(cat "$OUT_FILE")" '"state":"handle_mismatch"' "GPT manual replay --json state"
assert_contains "$(cat "$OUT_FILE")" '"result_available":false' "GPT manual replay --json result availability"
assert_contains "$(cat "$OUT_FILE")" '"handle_verified":false' "GPT manual replay --json handle_verified"
assert_contains "$(cat "$OUT_FILE")" "$PRIOR_HANDLE" "GPT manual replay --json names the foreign handle"

# The result artifact can be gone by the time anyone polls: the diagnostic that
# then runs must not hand back the provider's stderr.
rm -f "$GPT_BASE.result.md"
run_progress gpt-manual-missing --result "$GPT_HANDLE"
assert_no_leak "GPT manual replay --result with the result file deleted"

# --- 1.7  Claude manual foreground ------------------------------------------

new_case claude-manual
FAKE_BEHAVIOUR=replay run_fresheyes claude-manual --foreground --claude --manual "Review calc.py."
assert_no_leak "Claude manual replay"
assert_equals "$STATUS" "6" "Claude manual replay exit status"
assert_contains "$(cat "$ERR_FILE")" "handle_mismatch" "Claude manual replay state name"

CLAUDE_HANDLE="$(current_handle)" || fail "Claude manual replay: no run artifacts were written"
run_progress claude-manual-result --result "$CLAUDE_HANDLE"
assert_no_leak "Claude manual replay --result"
assert_equals "$STATUS" "6" "Claude manual replay --result exit status"

# --- 1.8  Claude manual, good result then a non-zero provider exit ----------
# `set -o pipefail` sends this down the failure branch with the whole review
# already produced, so the check has to precede the branch.

new_case claude-manual-exit
FAKE_BEHAVIOUR=replay FAKE_EXIT=1 run_fresheyes claude-manual-exit --foreground --claude --manual "Review calc.py."
assert_no_leak "Claude manual replay with a non-zero provider exit"
assert_equals "$STATUS" "6" "Claude manual replay with a non-zero provider exit status"

# --- 1.9  Detached manual launches ------------------------------------------

poll_until_terminal() {
  local handle="$1" tag="$2"
  local attempt=0
  while [ "$attempt" -lt 150 ]; do
    run_progress "$tag" --json "$handle"
    case "$(cat "$OUT_FILE")" in
      *'"state":"handle_mismatch"'*|*'"state":"complete"'*|*'"state":"died"'*|*'"state":"killed_at_launch"'*)
        return 0
        ;;
    esac
    attempt=$((attempt + 1))
    sleep 0.1
  done
  return 1
}

for provider in gpt claude; do
  new_case "detached-$provider"
  FAKE_BEHAVIOUR=replay run_fresheyes "detached-$provider" "--$provider" --manual "Review calc.py."
  assert_equals "$STATUS" "0" "detached $provider launch exit status"
  detached_handle="$(sed -n 's/^FRESHPID=//p' "$OUT_FILE" | tr -d '[:space:]')"
  [ -n "$detached_handle" ] || fail "detached $provider launch printed no FRESHPID receipt"

  poll_until_terminal "$detached_handle" "detached-$provider-json" \
    || fail "detached $provider review never reached a terminal state"
  assert_no_leak "detached $provider replay --json"
  assert_contains "$(cat "$OUT_FILE")" '"state":"handle_mismatch"' "detached $provider replay state"
  assert_equals "$STATUS" "6" "detached $provider replay --json exit status"

  run_progress "detached-$provider-result" --result "$detached_handle"
  assert_no_leak "detached $provider replay --result"
  assert_equals "$STATUS" "6" "detached $provider replay --result exit status"
done

# --- 1.10  Automatic mode ---------------------------------------------------

for provider in gpt claude; do
  new_case "automatic-$provider"
  FAKE_BEHAVIOUR=replay run_fresheyes "automatic-$provider" --foreground "--$provider" --automatic "Review the staged changes."
  assert_no_leak "automatic $provider replay"
  assert_equals "$STATUS" "6" "automatic $provider replay exit status"
  assert_contains "$(cat "$ERR_FILE")" "handle_mismatch" "automatic $provider replay state name"
  auto_base="$(current_base)" || fail "automatic $provider replay: no run artifacts were written"
  assert_equals "$(status_field "$auto_base.status.json" state)" "handle_mismatch" \
    "automatic $provider replay recorded state"
done

# (b) The Claude parser handles an is_error event before structured output ever
# exists, printing the provider's text and returning 1.
new_case automatic-claude-error
FAKE_BEHAVIOUR=replay FAKE_IS_ERROR=1 run_fresheyes automatic-claude-error --foreground --claude --automatic "Review the staged changes."
assert_no_leak "automatic Claude replay through the is_error branch"
assert_equals "$STATUS" "6" "automatic Claude is_error replay exit status"

# (c) Automatic mode fails CLOSED on a result it cannot verify; manual does not.
for provider in gpt claude; do
  new_case "automatic-unmarked-$provider"
  FAKE_BEHAVIOUR=unmarked run_fresheyes "automatic-unmarked-$provider" --foreground "--$provider" --automatic "Review the staged changes."
  assert_equals "$STATUS" "6" "automatic $provider unmarked exit status"
done

# --- 1.11  The poller checks for itself, with no runner involved ------------

new_case poller-independent
POLLER_HANDLE="20260202-111111-bbbbbb"
poller_base="$CASE_DIR/logs/fresheyes-$POLLER_HANDLE.log"
prior_review_text > "$poller_base.result.md"      # a FOREIGN marker
printf 'transcript line\n' > "$poller_base"
cat > "$poller_base.status.json" <<JSON
{"exit_code":0,"handle":"$POLLER_HANDLE","heartbeat_at":1770000000.0,"launched_at":1770000000.0,"log_path":"$poller_base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1770000000.0,"verdict":"failed"}
JSON
printf '%s\n' "$poller_base" > "$CASE_DIR/logs/.locator.$POLLER_HANDLE"

run_progress poller-independent-result --result "$POLLER_HANDLE"
assert_no_leak "poller-only foreign result --result"
assert_equals "$STATUS" "6" "poller-only foreign result --result exit status"
run_progress poller-independent-json --json "$POLLER_HANDLE"
assert_contains "$(cat "$OUT_FILE")" '"state":"handle_mismatch"' "poller-only foreign result --json state"

# The inverse control: a correctly marked result whose sibling TRANSCRIPT is
# full of foreign markers must still be delivered.
new_case poller-transcript-control
CONTROL_HANDLE="20260202-222222-cccccc"
control_base="$CASE_DIR/logs/fresheyes-$CONTROL_HANDLE.log"
prior_review_text > "$control_base"               # foreign markers in the transcript
printf '%s\n' \
  '## Files Examined' \
  '- calc.py' \
  '' \
  '## Summary' \
  'This run reviewed its own scope.' \
  '' \
  '---' \
  '**INDEPENDENT CODE REVIEW PASSED**' \
  "FRESHEYES-RUN: $CONTROL_HANDLE" > "$control_base.result.md"
cat > "$control_base.status.json" <<JSON
{"exit_code":0,"handle":"$CONTROL_HANDLE","heartbeat_at":1770000000.0,"launched_at":1770000000.0,"log_path":"$control_base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1770000000.0,"verdict":"passed"}
JSON
printf '%s\n' "$control_base" > "$CASE_DIR/logs/.locator.$CONTROL_HANDLE"

run_progress poller-control-result --result "$CONTROL_HANDLE"
assert_equals "$STATUS" "0" "marked result beside a foreign transcript --result exit status"
assert_contains "$(cat "$OUT_FILE")" "This run reviewed its own scope." \
  "marked result beside a foreign transcript is delivered"

# --- 1.12  Controls that must not fire --------------------------------------

new_case own-marker
FAKE_BEHAVIOUR=own run_fresheyes own-marker --foreground --gpt --manual "Review calc.py."
assert_equals "$STATUS" "0" "own-marker run exit status"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" "own-marker run delivers its review"
own_handle_value="$(current_handle)" || fail "own-marker run: no run artifacts were written"
run_progress own-marker-json --json "$own_handle_value"
assert_contains "$(cat "$OUT_FILE")" '"handle_verified":true' "own-marker run --json handle_verified"

new_case unmarked-manual
FAKE_BEHAVIOUR=unmarked run_fresheyes unmarked-manual --foreground --gpt --manual "Review calc.py."
assert_equals "$STATUS" "0" "unmarked manual run exit status"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" "unmarked manual run delivers its review"
unmarked_handle="$(current_handle)" || fail "unmarked manual run: no run artifacts were written"
run_progress unmarked-json --json "$unmarked_handle"
assert_contains "$(cat "$OUT_FILE")" '"handle_verified":false' "unmarked manual run --json handle_verified"

# Upstream #13 and #5: a verdict the reviewer quoted is not this run's verdict.
# The result is this run's (its last run marker is its own), so it is delivered,
# but the quoted FAILED must not be recorded as the run's verdict.
for provider in gpt claude; do
  new_case "quoted-verdict-$provider"
  FAKE_BEHAVIOUR=quote run_fresheyes "quoted-verdict-$provider" --foreground "--$provider" --manual "Review docs/reviews."
  assert_equals "$STATUS" "0" "$provider quoted verdict run exit status"
  assert_contains "$(cat "$OUT_FILE")" "A review of this run's own scope." "$provider quoted verdict run delivers its review"
  quoted_base="$(current_base)" || fail "$provider quoted verdict run: no run artifacts were written"
  assert_equals "$(status_field "$quoted_base.status.json" state)" "complete" "$provider quoted verdict recorded state"
  assert_equals "$(status_field "$quoted_base.status.json" verdict)" "" "$provider quoted verdict is not the run's verdict"
  run_progress "quoted-verdict-$provider-json" --json "$(current_handle)"
  assert_not_contains "$(cat "$OUT_FILE")" '"verdict"' "$provider quoted verdict --json"
done

# The control: the run's own verdict, bound to its own marker, is recorded.
for provider in gpt claude; do
  new_case "own-verdict-$provider"
  FAKE_BEHAVIOUR=own run_fresheyes "own-verdict-$provider" --foreground "--$provider" --manual "Review calc.py."
  assert_equals "$STATUS" "0" "$provider own verdict run exit status"
  own_verdict_base="$(current_base)" || fail "$provider own verdict run: no run artifacts were written"
  assert_equals "$(status_field "$own_verdict_base.status.json" verdict)" "passed" "$provider own verdict is recorded"
done

# A record written before this change carries neither field: deliver it.
new_case legacy-record
LEGACY_HANDLE="20251201-090000-dddddd"
legacy_base="$CASE_DIR/logs/fresheyes-$LEGACY_HANDLE.log"
printf '%s\n' \
  '## Files Examined' \
  '- calc.py' \
  '' \
  '---' \
  '**INDEPENDENT CODE REVIEW PASSED**' > "$legacy_base"
cat > "$legacy_base.status.json" <<JSON
{"exit_code":0,"heartbeat_at":1764000000.0,"launched_at":1764000000.0,"log_path":"$legacy_base","mode":"manual","provider":"claude","severity":"info","state":"complete","updated_at_epoch":1764000000.0,"verdict":"passed"}
JSON
printf '%s\n' "$legacy_base" > "$CASE_DIR/logs/.locator.$LEGACY_HANDLE"

run_progress legacy-result --result "$LEGACY_HANDLE"
assert_equals "$STATUS" "0" "legacy record --result exit status"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" "legacy record is delivered"

# --- 1.13  The checker itself is unavailable --------------------------------
# Manual fails OPEN (a finished review is never destroyed by a missing helper);
# automatic fails CLOSED, for both providers.

NO_HELPER_DIR="$TEST_TMP/skill-no-helper"
mkdir -p "$NO_HELPER_DIR"
cp "$ROOT_DIR"/skills/fresheyes/* "$NO_HELPER_DIR/" 2>/dev/null || true
rm -f "$NO_HELPER_DIR/fresheyes-handle.py"

saved_runner="$RUNNER_PATH"
saved_progress="$PROGRESS_PATH"
RUNNER_PATH="$NO_HELPER_DIR/fresheyes.sh"
PROGRESS_PATH="$NO_HELPER_DIR/fresheyes-progress.sh"

new_case no-helper-manual
FAKE_BEHAVIOUR=own run_fresheyes no-helper-manual --foreground --gpt --manual "Review calc.py."
assert_equals "$STATUS" "0" "manual run with no checker still delivers its review"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" "manual run with no checker output"

for provider in gpt claude; do
  new_case "no-helper-automatic-$provider"
  FAKE_BEHAVIOUR=own run_fresheyes "no-helper-automatic-$provider" --foreground "--$provider" --automatic "Review the staged changes."
  assert_equals "$STATUS" "6" "automatic $provider with no checker exit status"
done

RUNNER_PATH="$saved_runner"
PROGRESS_PATH="$saved_progress"

# --- 1.14  The environment must not be able to name the run -----------------

new_case env-handle
run_capture env-handle-traversal env \
  -u FRESHEYES_GPT_MODEL -u FRESHEYES_MODEL -u FRESHEYES_CLAUDE_MODEL \
  -u FRESHEYES_PROVIDER -u FRESHEYES_REASONING -u FRESHEYES_MODE \
  "PATH=$FAKE_BIN:$PATH" \
  "FRESHEYES_LOG_DIR=$CASE_DIR/logs" \
  "FRESHEYES_GLOBAL_LOG_DIR=$CASE_DIR/logs" \
  "FRESHEYES_FAKE_ARGV=$CASE_DIR/argv.json" \
  "FRESHEYES_FAKE_VERSION_PROBE=$CASE_DIR/version.txt" \
  "FRESHEYES_DAEMONIZED=1" \
  "FRESHEYES_HANDLE=../../etc/passwd" \
  "FRESHEYES_LOG_FILE=$CASE_DIR/logs/fresheyes-injected.log" \
  "FAKE_BEHAVIOUR=own" \
  timeout 60s bash "$RUNNER_PATH" --foreground --gpt --automatic "Review the staged changes."
[ "$STATUS" -ne 0 ] || fail "a handle supplied through the environment was accepted verbatim"
[ ! -e "$CASE_DIR/logs/../../etc/passwd" ] || fail "the injected handle created a path outside the log dir"

# Without FRESHEYES_DAEMONIZED the identity variables are ignored: a fresh
# handle is minted and the run proceeds.
new_case env-handle-ignored
run_capture env-handle-ignored env \
  -u FRESHEYES_GPT_MODEL -u FRESHEYES_MODEL -u FRESHEYES_CLAUDE_MODEL \
  -u FRESHEYES_PROVIDER -u FRESHEYES_REASONING -u FRESHEYES_MODE \
  "PATH=$FAKE_BIN:$PATH" \
  "FRESHEYES_LOG_DIR=$CASE_DIR/logs" \
  "FRESHEYES_GLOBAL_LOG_DIR=$CASE_DIR/logs" \
  "FRESHEYES_FAKE_ARGV=$CASE_DIR/argv.json" \
  "FRESHEYES_FAKE_VERSION_PROBE=$CASE_DIR/version.txt" \
  "FRESHEYES_HANDLE=$PRIOR_HANDLE" \
  "FRESHEYES_LOG_FILE=$CASE_DIR/logs/fresheyes-$PRIOR_HANDLE.log" \
  "FAKE_BEHAVIOUR=own" \
  timeout 60s bash "$RUNNER_PATH" --foreground --gpt --manual "Review calc.py."
assert_equals "$STATUS" "0" "an un-daemonized run with identity variables set"
current_base >/dev/null || fail "an un-daemonized run did not mint its own handle"

# --- Error paths: a refusal must not hand the text back sideways -------------
# Each of these was a live leak before it was closed.

# (a) The runner refused, but its terminal status write did not land, so the
# record still says `running`. Once the heartbeat goes stale the poller reports
# `died` — and that diagnostic must withhold the provider's stderr too.
new_case died-after-refusal
FAKE_BEHAVIOUR=replay run_fresheyes died-after-refusal --foreground --claude --manual "Review calc.py."
assert_equals "$STATUS" "6" "died-after-refusal: the run refused"
died_base="$(current_base)" || fail "died-after-refusal: no run artifacts"
died_handle="$(current_handle)"
# Simulate the failed terminal write: restore the pre-refusal record, stale.
python3 - "$died_base.status.json" <<'PYSTATUS'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    record = json.load(fh)
record["state"] = "running"
record.pop("exit_code", None)
record.pop("result_handle", None)
record["heartbeat_at"] = 1.0
record["launched_at"] = 1.0
with open(path, "w", encoding="utf-8") as fh:
    json.dump(record, fh, separators=(",", ":"), sort_keys=True)
    fh.write("\n")
PYSTATUS
run_progress died-after-refusal-result --result "$died_handle"
assert_no_leak "died-after-refusal --result"
assert_contains "$(cat "$OUT_FILE")" "must not be read back" \
  "the died diagnostic must say the log is not evidence about this run"

# (b) The checker is unavailable AND the provider fails: the automatic branch
# must not print the unchecked result or the provider's stderr as a diagnostic.
saved_runner2="$RUNNER_PATH"
RUNNER_PATH="$NO_HELPER_DIR/fresheyes.sh"
new_case no-helper-provider-failure
FAKE_BEHAVIOUR=replay FAKE_EXIT=1 run_fresheyes no-helper-provider-failure --foreground --claude --automatic "Review the staged changes."
assert_no_leak "automatic replay with no checker and a provider failure"
[ "$STATUS" -ne 0 ] || fail "automatic run with no checker and a provider failure was approved"
nohelper_handle="$(current_handle)" || fail "no-helper-provider-failure: no run artifacts"
RUNNER_PATH="$saved_runner2"
run_progress no-helper-provider-failure-poll --result "$nohelper_handle"
assert_no_leak "polling a run whose checker was unavailable and whose provider failed"

# (c) A COMPLETE record whose result is empty reads as `absent`, not
# unreadable, so the suppression must not depend on the checker's exit code
# alone. Built as a fixture: a run that already recorded handle_mismatch would
# take the recorded-state branch and prove nothing.
new_case empty-result
EMPTY_HANDLE="20260606-161616-aaaaac"
empty_base="$CASE_DIR/logs/fresheyes-$EMPTY_HANDLE.log"
: > "$empty_base"
: > "$empty_base.result.md"
printf 'provider noise\n%s: the loop kills a tmux session\nfake trailer\n' "$LEAK" > "$empty_base.stderr"
cat > "$empty_base.status.json" <<JSON
{"exit_code":0,"handle":"$EMPTY_HANDLE","heartbeat_at":1776000000.0,"launched_at":1776000000.0,"log_path":"$empty_base","mode":"manual","provider":"claude","severity":"info","state":"complete","updated_at_epoch":1776000000.0,"verdict":"passed"}
JSON
printf '%s\n' "$empty_base" > "$CASE_DIR/logs/.locator.$EMPTY_HANDLE"
run_progress empty-result-result --result "$EMPTY_HANDLE"
assert_no_leak "a complete record with an empty result must not quote the provider's stderr"

# (d) A refused result must not keep an authoritative verdict through the status
# file — the jibot-code#f1vd lens: rejected output carries no verdict.
new_case refused-verdict
REFUSED_HANDLE="20260404-131313-ffffff"
refused_base="$CASE_DIR/logs/fresheyes-$REFUSED_HANDLE.log"
prior_review_text > "$refused_base.result.md"
printf 'transcript\n' > "$refused_base"
cat > "$refused_base.status.json" <<JSON
{"exit_code":0,"handle":"$REFUSED_HANDLE","heartbeat_at":1774000000.0,"launched_at":1774000000.0,"log_path":"$refused_base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1774000000.0,"verdict":"passed"}
JSON
printf '%s\n' "$refused_base" > "$CASE_DIR/logs/.locator.$REFUSED_HANDLE"
run_progress refused-verdict-json --json "$REFUSED_HANDLE"
assert_contains "$(cat "$OUT_FILE")" '"state":"handle_mismatch"' "refused verdict state"
assert_not_contains "$(cat "$OUT_FILE")" '"verdict"' "a refused result must carry no verdict"

# (f) The legacy glob resolves fresheyes-*-<numeric pid>.log, so a caller can
# poll with just the pid and get a run whose file name is longer. That is a
# resolution detail, not a replay: the review must still be delivered. No
# locator here — the glob is the point.
new_case suffix-poll
GLOB_PID="424242"
glob_base="$CASE_DIR/logs/fresheyes-20260101-030303-$GLOB_PID.log"
printf '%s\n' \
  '## Files Examined' \
  '- calc.py' \
  '' \
  '## Summary' \
  'This run reviewed its own scope.' \
  '' \
  '---' \
  '**INDEPENDENT CODE REVIEW PASSED**' \
  "FRESHEYES-RUN: 20260101-030303-$GLOB_PID" > "$glob_base"
cat > "$glob_base.status.json" <<JSON
{"exit_code":0,"handle":"20260101-030303-$GLOB_PID","heartbeat_at":1781000000.0,"launched_at":1781000000.0,"log_path":"$glob_base","mode":"manual","provider":"claude","severity":"info","state":"complete","updated_at_epoch":1781000000.0,"verdict":"passed"}
JSON
run_progress suffix-poll-result --result "$GLOB_PID"
assert_equals "$STATUS" "0" "a run resolved through the legacy glob must not be refused"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" "glob-resolved run delivers its review"

# (g) The poller makes its own selection: a status file that names some other
# file as the result changes nothing. (An earlier revision let status.json name
# it, and a path escaping the log dir was then printed as "the review".)
new_case result-path-ignored
IGNORED_HANDLE="20260707-171717-aaaa0b"
ignored_base="$CASE_DIR/logs/fresheyes-$IGNORED_HANDLE.log"
printf 'SECRET-OUTSIDE-THE-LOG-DIR\n' > "$TEST_TMP/outside.txt"
printf '## Files Examined\n- calc.py\n\n**INDEPENDENT CODE REVIEW PASSED**\nFRESHEYES-RUN: %s\n' "$IGNORED_HANDLE" > "$ignored_base"
cat > "$ignored_base.status.json" <<JSON
{"exit_code":0,"handle":"$IGNORED_HANDLE","heartbeat_at":1777000000.0,"launched_at":1777000000.0,"log_path":"$ignored_base","mode":"manual","provider":"claude","result_path":"$TEST_TMP/outside.txt","severity":"info","state":"complete","updated_at_epoch":1777000000.0,"verdict":"passed"}
JSON
printf '%s\n' "$ignored_base" > "$CASE_DIR/logs/.locator.$IGNORED_HANDLE"
run_progress result-path-ignored --result "$IGNORED_HANDLE"
assert_not_contains "$(cat "$OUT_FILE")" "SECRET-OUTSIDE-THE-LOG-DIR" \
  "a path named in status.json must not be printed as the review (stdout)"
assert_not_contains "$(cat "$ERR_FILE")" "SECRET-OUTSIDE-THE-LOG-DIR" \
  "a path named in status.json must not be printed as the review (stderr)"
assert_contains "$(cat "$OUT_FILE")" "INDEPENDENT CODE REVIEW PASSED" \
  "the run's own result is delivered regardless of what status.json names"

# (h) A record that names a DIFFERENT run must not have its own review verified
# against its own claim: the expectation comes from the resolved file name.
new_case foreign-identity-record
IMPOSTOR_HANDLE="20260808-181818-aaaa0d"
impostor_base="$CASE_DIR/logs/fresheyes-$IMPOSTOR_HANDLE.log"
prior_review_text > "$impostor_base.result.md"
printf 'transcript\n' > "$impostor_base"
cat > "$impostor_base.status.json" <<JSON
{"exit_code":0,"handle":"$PRIOR_HANDLE","heartbeat_at":1778000000.0,"launched_at":1778000000.0,"log_path":"$impostor_base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1778000000.0,"verdict":"failed"}
JSON
printf '%s\n' "$impostor_base" > "$CASE_DIR/logs/.locator.$IMPOSTOR_HANDLE"
run_progress foreign-identity --result "$IMPOSTOR_HANDLE"
assert_no_leak "a record claiming another run's handle must not verify its review against that claim"
assert_equals "$STATUS" "6" "foreign-identity record exit status"

# (i) A record with NO handle field, beside a result carrying another run's
# marker, must still be checked — verification may not be gated on metadata.
new_case no-handle-field
NOHANDLE_HANDLE="20260909-191919-aaaa0e"
nohandle_base="$CASE_DIR/logs/fresheyes-$NOHANDLE_HANDLE.log"
prior_review_text > "$nohandle_base"
cat > "$nohandle_base.status.json" <<JSON
{"exit_code":0,"heartbeat_at":1779000000.0,"launched_at":1779000000.0,"log_path":"$nohandle_base","mode":"manual","provider":"claude","severity":"info","state":"complete","updated_at_epoch":1779000000.0,"verdict":"failed"}
JSON
printf '%s\n' "$nohandle_base" > "$CASE_DIR/logs/.locator.$NOHANDLE_HANDLE"
run_progress no-handle-field --result "$NOHANDLE_HANDLE"
assert_no_leak "a record with no handle field must still be checked"
assert_equals "$STATUS" "6" "no-handle-field record exit status"

# (j) The locator for THIS run's handle repointed at ANOTHER run's genuine
# base. Everything involved is inside the log directory and nothing is forged,
# so only the expected identity can refuse it: taking that from the record
# would compare the other run's review against the other run's own handle and
# deliver it.
new_case locator-repoint
OTHER_HANDLE="20261010-202020-aaaa0f"
other_base="$CASE_DIR/logs/fresheyes-$OTHER_HANDLE.log"
prior_review_text > "$other_base.result.md"
printf 'transcript\n' > "$other_base"
cat > "$other_base.status.json" <<JSON
{"exit_code":0,"handle":"$OTHER_HANDLE","heartbeat_at":1780000000.0,"launched_at":1780000000.0,"log_path":"$other_base","mode":"manual","provider":"gpt","severity":"info","state":"complete","updated_at_epoch":1780000000.0,"verdict":"failed"}
JSON
# The other run's result carries the other run's own marker: genuine for it.
python3 - "$other_base.result.md" "$OTHER_HANDLE" <<'PYMARK'
import re
import sys

path, handle = sys.argv[1:3]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
text = re.sub(r"FRESHEYES-RUN: .*", "FRESHEYES-RUN: %s" % handle, text)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PYMARK
CALLER_HANDLE="20261010-212121-aaaa10"
printf '%s\n' "$other_base" > "$CASE_DIR/logs/.locator.$CALLER_HANDLE"
run_progress locator-repoint --result "$CALLER_HANDLE"
assert_no_leak "a locator repointed at another run must not deliver that run's review"
assert_equals "$STATUS" "6" "locator repoint exit status"

# (k) The same locator repoint, at a completed AUTOMATIC run. For the Claude
# provider that run's review log IS its structured result, so a poller that
# exempted automatic records from the check handed it back under this caller's
# handle.
new_case locator-repoint-automatic
AUTO_OTHER="20261111-222222-aaaa11"
auto_other_base="$CASE_DIR/logs/fresheyes-$AUTO_OTHER.log"
cat > "$auto_other_base" <<JSON
{"approve_commit": false, "issues": [{"severity": "major", "file": "calc.py", "line": 12, "description": "$LEAK: the loop kills a tmux session"}], "run_handle": "$AUTO_OTHER"}
JSON
cat > "$auto_other_base.status.json" <<JSON
{"exit_code":1,"handle":"$AUTO_OTHER","heartbeat_at":1782000000.0,"launched_at":1782000000.0,"log_path":"$auto_other_base","mode":"automatic","provider":"claude","severity":"info","state":"complete","updated_at_epoch":1782000000.0,"verdict":"not_approved"}
JSON
AUTO_CALLER="20261111-232323-aaaa12"
printf '%s\n' "$auto_other_base" > "$CASE_DIR/logs/.locator.$AUTO_CALLER"
run_progress locator-repoint-automatic --result "$AUTO_CALLER"
assert_no_leak "a locator repointed at an automatic run must not deliver its result"
assert_equals "$STATUS" "6" "automatic locator repoint exit status"

printf 'fresheyes-handle-binding tests passed\n'
