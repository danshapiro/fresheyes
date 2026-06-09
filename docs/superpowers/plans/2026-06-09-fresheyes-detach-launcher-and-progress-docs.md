# Fresh Eyes Detach-by-Default Launcher + Progress Doc Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Fresh Eyes manual review impossible to launch in a way that the caller's harness timeout can kill — by detaching into its own session **by default** rather than via a flag the agent must remember — and document the two progress-script behaviors a weaker agent already misread (`result_available` semantics and the `state=complete`-with-no-verdict case).

**Architecture:** Two independent parts in one plan, both confined to the `fresheyes` skill.
- **Part A (docs + characterization test):** Document `result_available` and the verdict-less `complete` state in `SKILL.md`, and lock the underlying behavior with one regression test. No production code changes.
- **Part B (launcher):** Manual mode self-daemonizes by default: `fresheyes.sh` re-execs under `setsid`, returns in under a second, and prints `FRESHPID=<pid>`. The SKILL.md launch command becomes a bare `bash fresheyes.sh --gpt "scope"` with no `setsid`/`&`/`$!`/redirects to fumble — and critically, an agent that strips the command to its essentials *still* gets a detached review. `--foreground` (alias `--no-detach`) is the opt-out for humans watching a review live and for the existing synchronous tests. **Automatic mode never detaches**, so the pre-commit gate stays synchronous.

**Tech Stack:** Bash (`set -euo pipefail`), Python 3 helpers embedded via heredocs, bash integration tests that stub provider CLIs (`codex`/`claude`) by prepending a fake binary dir to `PATH`. No test runner/Makefile — each test file is run directly with `bash`.

---

## Background (why)

A less-capable agent consuming Fresh Eyes failed a review and misdiagnosed it. Ground truth from the code:

- The review is always written **durably** to `$LOG_FILE` — GPT via `tee` (`fresheyes.sh:317`), Claude via `fresheyes-claude-stream.py --review-log` (`fresheyes.sh:355`) — and is retrieved by design through `fresheyes-progress.sh --result`. Foreground manual mode *also* echoes the review to the script's stdout (the extraction at `fresheyes.sh:323`; Claude at `fresheyes-claude-stream.py:235`), but the skill's launch redirects that stdout to `/dev/null`. So the old launch line's `>/dev/null` discarded only a *duplicate* of the review, never its durable copy — it was correct, not a footgun.
- The agent's real launch error was dropping `setsid`, so its review ran in the caller's process group and died when the 120s tool timeout fired. It also never waited and never ran `--result`.
- It also tripped on two genuinely under-documented things: `result_available` (present in the JSON examples, absent from the Step 5 field list, easy to read as "tool failed") and `state=complete` + empty-`verdict` (not enumerated in Step 6).

**Why detach-by-default, not an opt-in `--detach` flag:** the incident proves this class of agent does not reliably reproduce the skill's launch text (it dropped a required `setsid`). A flag the agent must add is a flag it can drop — and dropping it reverts to the exact foreground-then-killed failure. Making detachment the default for manual mode means the *minimal* command works safely; the only way back to the dangerous path is to explicitly add `--foreground`, which the skill never tells it to. This closes the launch-death failure mode as a *mechanism*, not a request. (It does not fix the agent's other errors — not waiting, never calling `--result`, confabulating — those are instruction-following problems no launch design solves. Part A's doc fixes reduce the `result_available` misread specifically.)

## File structure

All paths relative to repo root `/home/dan/code/fresheyes`.

- **Modify** `skills/fresheyes/fresheyes.sh` — add the `--foreground`/`--no-detach` flag and the default self-daemonization for manual mode. The only production code change.
- **Modify** `skills/fresheyes/SKILL.md` — rewrite Step 4 (bare launch, no flags), add a `result_available` bullet to Step 5, add the verdict-less `complete` case to Step 6.
- **Modify** `README.md` (repo root) — one note that manual CLI runs detach by default and `--foreground` runs synchronously.
- **Modify** `tests/fresheyes-progress-test.sh` — add one characterization test for `state=complete` + `result_available=false`.
- **Modify** `tests/fresheyes-claude-provider-test.sh` — add three default-detach tests and add `--foreground` to the three existing manual-foreground invocations.

The human-facing README is at repo root `README.md` (the one with "Manual Mode" / "Automatic Mode" sections); there is no separate `skills/fresheyes/README.md`.

No new files or directories. `skills/fresheyes/SKILL.md` is the source of truth; the live copy under `~/.claude/skills/fresheyes/` (or the installed plugin) is re-synced by the normal install path and is out of scope for this plan.

## Conventions you must follow

- Run all test commands from the repo root `/home/dan/code/fresheyes`.
- Tests are standalone: `bash tests/<file>.sh`. A passing run prints `… tests passed` and exits 0; any assertion calls `fail`/`exit 1`.
- Provider CLIs are never really called in tests — a fake `claude`/`codex` is placed in `$FAKE_BIN` and `PATH="$FAKE_BIN:$PATH"`.
- Per repo `AGENTS.md`: do **not** write tautological tests that merely assert static copy. That is why the three `SKILL.md`/`README.md` prose edits have **no** automated test — a `grep` for the new sentences would just restate the copy. Their guarantee is the behavioral tests plus a manual read-back. The launcher has real behavior to test, so it gets real tests.

---

# Part A — Document `result_available` and the verdict-less `complete` state

### Task A1: Characterization test — `complete` + `result_available=false` still returns text via `--result`

This test proves the behavior the new docs will describe: a finished review whose log has content but no PASSED/FAILED marker reports `state=complete` with `result_available=false`, yet `--result` returns the review body and exits 0 (it is **not** a failure diagnostic). The behavior already exists, so this is a characterization/regression test — it passes on first run and prevents a future change to `result_available` from silently contradicting the docs.

**Files:**
- Test: `tests/fresheyes-progress-test.sh` (add one test function + register it)

- [ ] **Step 1: Write the characterization test**

In `tests/fresheyes-progress-test.sh`, add this function immediately after `test_dead_success_json_reports_complete()` (which ends at its closing `}` near line 285), before `test_dead_crash_missing_log_returns_diagnostics()`:

```bash
test_complete_without_verdict_returns_text() {
  local pid base output result status
  dead_pid pid
  base="$LOG_DIR/fresheyes-test-$pid.log"
  write_active "$pid" "$base"
  cat > "$base" <<'TEXT'
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
  assert_contains "$result" "no PASSED or FAILED marker" "complete-no-verdict --result text"
}
```

Then register it: in the list of test invocations at the bottom of the file (the block ending with `test_global_locator_ignores_external_log_by_default`, around line 425), add a new line after `test_dead_success_json_reports_complete`:

```bash
test_dead_success_json_reports_complete
test_complete_without_verdict_returns_text
```

- [ ] **Step 2: Run the test and confirm it passes (characterization, no red phase)**

Run: `bash tests/fresheyes-progress-test.sh`
Expected: PASS — final line `fresheyes-progress tests passed`. This documents that the behavior already exists; the test exists to keep it true. If it fails, stop — the docs in A2 must not be written until this is understood.

- [ ] **Step 3: Commit**

```bash
git add tests/fresheyes-progress-test.sh
git commit -m "test: lock complete-without-verdict result retrieval contract"
```

---

### Task A2: Document `result_available` (Step 5) and the verdict-less `complete` case (Step 6) in SKILL.md

**Files:**
- Modify: `skills/fresheyes/SKILL.md` (Step 5 field list ~line 93; Step 6 interpretation list ~line 110)

- [ ] **Step 1: Add the `result_available` bullet to Step 5**

In `skills/fresheyes/SKILL.md`, the Step 5 field list ends with the `log_path` bullet:

```markdown
- `log_path`: the tracked review log.
```

Replace that single line with:

```markdown
- `log_path`: the tracked review log.
- `result_available`: convenience boolean. `true` only when a final verdict marker **and** a non-empty log are both present. It is **not** a tool success/failure signal — a `false` value does not mean the review failed or that no text exists (a finished review can have retrievable text with `result_available=false`). Do not branch on this field; always retrieve the review with `--result` (Step 7).
```

- [ ] **Step 2: Add the verdict-less `complete` case to Step 6**

In Step 6, find the two `state=complete` bullets:

```markdown
- **`state=complete` + `verdict=passed`** → the review passed. Proceed to Step 7.
- **`state=complete` + `verdict=failed`** → the review completed and found blocking issues. Proceed to Step 7.
```

Replace those two lines with three (insert the new case after them):

```markdown
- **`state=complete` + `verdict=passed`** → the review passed. Proceed to Step 7.
- **`state=complete` + `verdict=failed`** → the review completed and found blocking issues. Proceed to Step 7.
- **`state=complete` with no `verdict`** → the review finished but emitted no PASSED/FAILED marker (`result_available` is `false`). This is **not** a tool failure. Run Step 7 (`--result`): it returns the review text when the log has content, or a failure diagnostic when it does not. Report exactly what `--result` returns.
```

- [ ] **Step 3: Verify the edits read correctly (manual; no automated test — would be tautological)**

Run: `git diff skills/fresheyes/SKILL.md`
Confirm: exactly the two insertions above, both landing inside their intended lists (Step 5 field list, Step 6 interpretation list), surrounding bullets unchanged. Re-read Step 5 → Step 7 as a zero-context agent and confirm an agent hitting `result_available=false` is now told to call `--result` rather than conclude failure.

- [ ] **Step 4: Commit**

```bash
git add skills/fresheyes/SKILL.md
git commit -m "docs: document result_available and verdict-less complete state"
```

---

# Part B — Detach-by-default manual launcher

### Task B1: Make manual mode detach by default, with a `--foreground` opt-out (TDD)

Single red→green cycle: write the new behavior tests (one truly red), then implement the flag/default in `fresheyes.sh` and migrate the three existing synchronous tests to `--foreground` in the same task so the whole suite ends green.

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (usage comment line 3; defaults ~line 15; arg parse ~line 51; new block before `# --- Build prompt ---` ~line 140)
- Modify: `tests/fresheyes-claude-provider-test.sh` (3 new tests + register; add `--foreground` to 3 existing invocations)

- [ ] **Step 1: Write the three new tests and register them**

In `tests/fresheyes-claude-provider-test.sh`, add these three functions immediately after `test_compound_launch_parent_pid_recovers_review()` (its closing `}` near line 326), before the bottom block that starts `make_fake_claude`:

```bash
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
```

Then register all three: in the invocation list at the bottom of the file (after `test_compound_launch_parent_pid_recovers_review`, before `printf 'fresheyes-claude-provider tests passed\n'`), add:

```bash
test_compound_launch_parent_pid_recovers_review
test_manual_detaches_by_default_and_completes
test_manual_foreground_runs_synchronously
test_automatic_mode_does_not_detach
```

- [ ] **Step 2: Run the suite and confirm the detach test fails**

Run: `bash tests/fresheyes-claude-provider-test.sh`
Expected: FAIL at `test_manual_detaches_by_default_and_completes` — manual mode currently runs synchronously, so the bare `--claude` launch streams the review to stdout and never prints `FRESHPID=`. It fails at the first assertion (`default manual detach stdout`), well before the new-session safety assertions; those become reachable only once Step 3 makes the launch actually detach. The two guard tests (`test_manual_foreground_runs_synchronously`, `test_automatic_mode_does_not_detach`) pass already (manual/automatic are both synchronous today, and `--foreground` is currently ignored as scope text) — they exist to prove Step 3 does not over-reach.

- [ ] **Step 3: Implement the flag and default in `fresheyes.sh`, and migrate the existing tests**

**Edit 3a — usage comment.** Find line 3:

```bash
# Usage: ./fresheyes.sh [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] 'scope text'
```

Replace with:

```bash
# Usage: ./fresheyes.sh [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] [--foreground] 'scope text'
# Manual mode detaches into its own session by default (prints FRESHPID=<pid>); --foreground runs synchronously.
```

**Edit 3b — defaults + captured argv.** Find:

```bash
MODE="${FRESHEYES_MODE:-manual}"
SCOPE_PARTS=()
```

Replace with:

```bash
MODE="${FRESHEYES_MODE:-manual}"
SCOPE_PARTS=()
# Manual reviews detach into their own session by default so a caller's process
# group / harness timeout can't kill them. --foreground (alias --no-detach)
# forces a synchronous run. Automatic mode never detaches.
FOREGROUND=0
# Capture argv verbatim before the parse loop consumes it, so the detach re-exec
# can relaunch with identical arguments.
ORIG_ARGS=("$@")
```

**Edit 3c — arg-parse case.** Find:

```bash
    --automatic)
      MODE="automatic"
      shift
      ;;
    --)
```

Replace with:

```bash
    --automatic)
      MODE="automatic"
      shift
      ;;
    --foreground|--no-detach)
      FOREGROUND=1
      shift
      ;;
    --)
```

**Edit 3d — self-daemonization block.** Find (the schema-file check followed by the build-prompt comment):

```bash
if [[ "$MODE" == "automatic" && ! -f "$SCHEMA_FILE" ]]; then
  echo "Error: Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

# --- Build prompt ---
```

Replace with:

```bash
if [[ "$MODE" == "automatic" && ! -f "$SCHEMA_FILE" ]]; then
  echo "Error: Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

# --- Detach manual reviews into their own session (default) ---
# Manual reviews are long (5-30 min). By default we re-exec under setsid so the
# review survives the caller's process group — e.g. an agent harness timeout on
# the launch call. The foreground parent prints the review PID and exits in
# under a second; the detached child runs the review and writes all output to
# its log files, retrieved via fresheyes-progress.sh. FRESHEYES_DAEMONIZED=1
# stops the child re-detaching. Automatic mode (the pre-commit gate) and
# --foreground both skip this and run synchronously.
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  if ! command -v setsid &> /dev/null; then
    echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
    exit 2
  fi
  FRESHEYES_DAEMONIZED=1 setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>&1 &
  echo "FRESHPID=$!"
  exit 0
fi

# --- Build prompt ---
```

**Edit 3e — migrate `test_manual_claude_invocation_uses_streaming_flags`.** In `tests/fresheyes-claude-provider-test.sh`, find:

```bash
  run_runner_capture "$run_tmp" "$stdout_file" --claude "Review README.md."
```

Replace with:

```bash
  run_runner_capture "$run_tmp" "$stdout_file" --foreground --claude "Review README.md."
```

**Edit 3f — migrate `test_default_log_dir_uses_global_log_dir`.** Find:

```bash
    timeout 30s bash "$RUNNER" --claude "Review README.md." > "$stdout_file"; then
```

Replace with:

```bash
    timeout 30s bash "$RUNNER" --foreground --claude "Review README.md." > "$stdout_file"; then
```

**Edit 3g — migrate `test_compound_launch_parent_pid_recovers_review`.** Find:

```bash
      'true && setsid bash "$1" --claude "Review README.md." </dev/null > "$2" 2>/dev/null & echo "$!"' \
```

Replace with:

```bash
      'true && setsid bash "$1" --foreground --claude "Review README.md." </dev/null > "$2" 2>/dev/null & echo "$!"' \
```

(This legacy test launches its own `setsid` backgrounding and captures `$!`; `--foreground` keeps the runner in-process so `captured_pid` is the review PID, preserving the test's deterministic PID→log recovery assertion.)

- [ ] **Step 4: Run the full suite and confirm green**

Run:
```bash
bash tests/fresheyes-claude-provider-test.sh
bash tests/fresheyes-progress-test.sh
bash tests/fresheyes-prompt-contract-test.sh
```
Expected: all three print their `… tests passed` line and exit 0. `test_manual_detaches_by_default_and_completes` now passes — the bare `--claude` launch self-detaches into its **own session** (the test asserts the printed PID is a session leader whose session id differs from the launcher's, i.e. setsid actually escaped the caller's process group) and the review is then recoverable by that PID; the three migrated tests pass with `--foreground`; `test_automatic_claude_extracts_structured_output` and the new `test_automatic_mode_does_not_detach` confirm the pre-commit/automatic path stays synchronous.

- [ ] **Step 5: Commit**

```bash
git add skills/fresheyes/fresheyes.sh tests/fresheyes-claude-provider-test.sh
git commit -m "feat: detach manual fresheyes reviews by default, add --foreground opt-out"
```

---

### Task B2: Rewrite SKILL.md Step 4 to a bare launch (no setsid/flag)

Replace the error-prone `setsid … </dev/null >/dev/null 2>/dev/null & FRESHPID=$!` instructions — the exact incantation the incident agent mangled — with a plain foreground command that returns `FRESHPID`. Remove the now-obsolete `cmd && setsid … &` warning. Steps 5–7 already reference `$FRESHPID` and remain valid.

**Files:**
- Modify: `skills/fresheyes/SKILL.md` (Step 4, ~lines 56–72)

- [ ] **Step 1: Replace Step 4**

Find:

```markdown
### Step 4: Launch the reviewer in background

The script path is `fresheyes.sh` inside this skill's base directory (shown at the top of these instructions).

Launch it in a new session (so it survives if the harness kills this call) and capture its PID:

```bash
setsid bash "<base-directory>/fresheyes.sh" [--gpt|--claude] "<scope from step 2>" </dev/null >/dev/null 2>/dev/null &
FRESHPID=$!
echo "FRESHPID=$FRESHPID"
```

`setsid` detaches the review from this call's process group so harness timeouts don't kill it. Review output and progress are accessible through `fresheyes-progress.sh`; Claude provider progress is tracked in structured sidecar logs.

Save `$FRESHPID`. This is your handle for the entire review lifecycle.

Do not prefix the launch line with `cmd &&` before the trailing `&`. In Bash, `cmd && setsid ... &` backgrounds the whole command list and `$!` can become a short-lived launcher shell instead of the review process. Run preflight commands separately, then launch Fresheyes exactly as its own background command.
```

Replace with:

```markdown
### Step 4: Launch the reviewer

The script path is `fresheyes.sh` inside this skill's base directory (shown at the top of these instructions).

Run it as a plain foreground command:

```bash
bash "<base-directory>/fresheyes.sh" [--gpt|--claude] "<scope from step 2>"
```

Manual reviews detach into their own session automatically, so this returns in under a second and prints a single line:

```
FRESHPID=12345
```

Read that number from the output and save it as `$FRESHPID` — it is your handle for the entire review lifecycle (polling in Step 5, result retrieval in Step 7). Because the review runs in its own session, a harness timeout on this call cannot kill it; all output goes to log files reachable through `fresheyes-progress.sh` (Claude provider progress is also tracked in structured sidecar logs).

Do not add `setsid`, a trailing `&`, output redirects, or `$!` — the script backgrounds itself. Run the command exactly as above and read `FRESHPID` from its output. (Adding `--foreground` would stream the review synchronously instead; you never want that here, because this call would then block and risk being killed by a harness timeout.)
```

- [ ] **Step 2: Verify references are still consistent**

Run: `grep -n 'FRESHPID\|setsid\|--foreground\|--detach' skills/fresheyes/SKILL.md`
Confirm: `setsid` no longer appears; `--foreground` appears only in the Step 4 caveat; no stray `--detach`; `$FRESHPID` is still referenced by Steps 5 and 7 and the "Parallel reviews" section. Read Step 4 → Step 7 once end-to-end as a zero-context agent and confirm the launch → poll → result flow is coherent.

- [ ] **Step 3: Commit**

```bash
git add skills/fresheyes/SKILL.md
git commit -m "docs: launch fresheyes via bare command (detach is automatic)"
```

---

### Task B3: README note on detach-by-default + `--foreground`

**Files:**
- Modify: `README.md` (repo root; "Manual Mode" section, after the Claude-provider progress line ~line 46)

- [ ] **Step 1: Add the note**

In `README.md`, find:

```markdown
Claude-provider reviews show live progress through the polling command and still return the final review text when complete.
```

Replace with:

```markdown
Claude-provider reviews show live progress through the polling command and still return the final review text when complete.

Manual reviews run in their own background session by default; the skill launches one, gets back a `FRESHPID`, and polls it to completion. If you invoke `fresheyes.sh` directly from a shell and want to watch the review stream live instead, pass `--foreground`.
```

- [ ] **Step 2: Verify**

Run: `git diff README.md`
Confirm: exactly the one inserted paragraph, under "Manual Mode", grammatical and accurate (manual detaches by default; `--foreground` runs synchronously).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: note manual reviews detach by default; --foreground for synchronous"
```

---

## Self-Review

**Spec coverage:**
- "Document `result_available`" → Task A2 Step 1. ✓
- "Step 6 doesn't enumerate `state=complete` with empty verdict" → Task A2 Step 2, behavior locked by Task A1. ✓
- "Detach-by-default for manual mode so a stripped-down command is still safe" → Task B1 Edit 3d (condition gated on `MODE==manual && FOREGROUND!=1`), proved by `test_manual_detaches_by_default_and_completes`. That test asserts the *safety property itself*, not just the symptom: the detached review's session id differs from the launcher's and equals its own PID (session leader) — so a plain `&` background without `setsid` (which would stay in the caller's session and remain killable by a harness timeout) fails the test even though it would still print `FRESHPID=`, not stream, and complete. ✓
- "`--foreground` opt-out" → Task B1 Edit 3c + 3d, proved by `test_manual_foreground_runs_synchronously`. ✓
- "Automatic/pre-commit path must stay synchronous" → block is `MODE==manual`-gated; guarded by `test_automatic_mode_does_not_detach` and the existing `test_automatic_claude_extracts_structured_output`. ✓
- "Update the two (three) foreground tests" → Task B1 Edits 3e/3f/3g. ✓
- "README note" → Task B3. ✓
- "SKILL.md launch no longer needs setsid/$!" → Task B2. ✓

**Placeholder scan:** No TBD/"add error handling"/"similar to" — every test and edit shows full content with exact anchor text.

**Type/identifier consistency:** Flag is `--foreground` (alias `--no-detach`); variable `FOREGROUND`; env guard `FRESHEYES_DAEMONIZED`; printed token `FRESHPID=` — consistent across impl (3b/3c/3d), tests (B1 Step 1, parsed via `sed -n 's/^FRESHPID=//p'`), and docs (B2/B3). The detached child's printed PID equals its own `$$` and its `fresheyes-<ts>-$$.log` filename via `setsid` exec-collapse in a non-job-control shell; if a platform's `setsid` instead forks, the existing `.parent.$PPID`/`owner_pid` recovery in `fresheyes-progress.sh` resolves it — so progress lookup by the printed PID holds either way. The new session-leader assertion in `test_manual_detaches_by_default_and_completes` (`sid==pid`) is predicated on that exec-collapse, which was verified to hold in this project's Linux/WSL environment (a `bash script.sh` runs the runner with job control off, so the backgrounded `setsid` is not a process-group leader and execs in place rather than forking). This is the same supported-platform assumption as the existing `setsid`-required caveat below. Test helpers used (`dead_pid`, `write_active`, `run_progress`, `assert_json_field_equals`, `assert_equals`, `assert_contains`, `run_runner_capture`, `fail`, `$RUNNER`, `$PROGRESS_SCRIPT`, `$FAKE_BIN`, `$ARGV_FILE`, `$TEST_TMP`, `make_fake_claude`) all exist in their target files.

**Known platform caveat (status quo, not a regression):** detach requires `setsid`; on a host without it (e.g. stock macOS), manual mode now errors with an actionable "re-run with `--foreground`" message. The previous SKILL.md launch line already required `setsid`, so this does not newly break any supported path; it surfaces the requirement explicitly instead of silently orphaning a process.

**Note on TDD ordering:** Task A1 is a characterization test (green on first run) because it locks existing behavior the docs will describe — intentional and called out. Task B1 is a true red→green cycle within one task: the new-behavior test is red at Step 2, green at Step 4, and the existing-test migration is bundled with the implementation it depends on.
