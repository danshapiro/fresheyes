# Claude Provider Streaming Progress Implementation Plan

> For agentic workers: implement this plan task-by-task. Keep commits scoped to one task when practical. Do not skip the failing-test steps; they guard the exact regressions validated during review.

## Goal

Make Fresheyes' Claude provider report real progress while a review is alive, surface useful diagnostics when Claude crashes before final output, and clean up process trees correctly on timeout.

The fix covers both Claude modes:

- `provider=claude, mode=manual`: human-readable markdown review.
- `provider=claude, mode=automatic`: pre-commit JSON review.

The GPT provider must keep its existing progress behavior unless a later task explicitly redesigns it.

## Validated Facts

These facts were checked by independent subagents and small local reproductions:

- Local Claude Code CLI is `2.1.159` and supports `-p`, `--output-format stream-json`, `--verbose`, `--include-partial-messages`, `--disable-slash-commands`, `--effort`, and `--json-schema`.
- Claude `stream-json` emits newline-delimited JSON before completion. A local run grew from 2 lines at about 1 second to 51 lines at completion.
- `--disable-slash-commands` does not prevent ordinary allowed tool use.
- `--bare` fails local auth and must not be added by default.
- `--json-schema` with `stream-json` surfaces final structured output in the final `result` event's `structured_output` field.
- Current `fresheyes-progress.sh` resolves a run only when the final `.log` exists. If only sidecars exist, it returns `0`.
- Fixing `_find_log` alone is not enough. Downstream `cat "$LOG_FILE"` and `wc -l < "$LOG_FILE"` must also tolerate missing or empty `.log` files.
- A test that pre-creates `.log` masks the bug. The progress tests must include sidecars present with `.log` missing.
- Shared `.events.jsonl` output for every provider would change GPT progress from numeric line counts to event summaries. Event progress must be gated to Claude.
- Current dead-process behavior can hide crashes: missing `.log` plus sidecars/stderr returns `0`, and empty `.log` returns empty output.
- `setsid bash script &` makes `$!` the wrapper PID, PGID, and SID on this Linux environment. `kill "$FRESHPID"` kills only the wrapper; `kill -- -"$FRESHPID"` kills children in the same process group.
- A child that deliberately calls its own `setsid` can escape the process group. This is an acceptable caveat and should be documented only if needed.

## Design

Use Claude Code `stream-json` only for the Claude provider. The runner keeps the existing `.log` as the final user-facing result and adds sidecars for live progress:

- `$LOG_FILE`: final review text for manual mode, final structured JSON text for automatic mode, or a concise failure report.
- `$LOG_FILE.events.jsonl`: normalized structured progress and error events. Every record includes at least `severity`, `event`, `provider`, and `ts_epoch`.
- `$LOG_FILE.stream.jsonl`: raw Claude `stream-json` lines.
- `$LOG_FILE.stderr`: Claude stderr.

Progress lookup must treat the active file as a base path, not only as an existing final log. If `.active.$PID` points to `/tmp/.../fresheyes-...-$PID.log`, progress can use that base path when any of these files exists:

- the base `.log`
- `.log.events.jsonl`
- `.log.stream.jsonl`
- `.log.stderr`

Alive progress behavior:

- If the event log proves `provider=claude`, print a single status line such as:

```text
running provider=claude provider_events=42 last_provider_event=tool_result final_lines=0
```

- Count only provider-originated Claude events in `provider_events`. Wrapper events such as `review_started`, `provider_started`, and `heartbeat` must not fake model progress.
- If the provider is GPT, unknown, or legacy, preserve numeric line count using `.log` if present. If `.log` is missing, return `0` instead of shell errors.

Dead progress behavior:

- If `.log` exists and is non-empty, print it exactly.
- If `.log` is missing or empty, print a diagnostic assembled from `.events.jsonl` and `.stderr`.
- The diagnostic must not be just `0` when sidecars or stderr contain useful information.

Timeout cleanup behavior:

```bash
kill -- -"$FRESHPID" 2>/dev/null || kill "$FRESHPID" 2>/dev/null || true
```

## Non-Goals

- Do not switch GPT to event-summary progress in this change.
- Do not use `--bare`.
- Do not replace the shell runner with a different public interface.
- Do not add CPU-based, process-tree-based, or stderr-line-count stall heuristics.
- Do not update end-user docs outside `README.md`.

## File Changes

- Create `tests/fresheyes-progress-test.sh`.
- Create `tests/fresheyes-claude-provider-test.sh`.
- Create `skills/fresheyes/fresheyes-claude-stream.py`.
- Modify `skills/fresheyes/fresheyes.sh`.
- Modify `skills/fresheyes/fresheyes-progress.sh`.
- Modify `skills/fresheyes/SKILL.md`.
- Modify `README.md` only if a user-facing note is still useful after implementation.

## Task 1: Add Progress Tests First

**Files:**

- Create `tests/fresheyes-progress-test.sh`.

Add a shell test script that uses `TMPDIR="$(mktemp -d)"` and synthetic active files. The test must not depend on the real `/tmp/fresheyes-logs`.

Required test cases:

1. **Alive Claude, sidecars exist, `.log` missing**
   - Start `sleep 60 &` and capture `pid`.
   - Write `$TMPDIR/fresheyes-logs/.active.$pid` pointing at a base path ending in `-$pid.log`.
   - Do not create the base `.log`.
   - Create `$base.events.jsonl` with provider-originated Claude events.
   - Expected after implementation: output contains `running`, `provider=claude`, `provider_events=`, and `final_lines=0`.
   - Expected before implementation: current script returns `0`.

2. **Alive Claude, sidecars exist, empty `.log` exists**
   - Same as case 1, but create `: > "$base"`.
   - Expected: same Claude running status.
   - This catches accidental dependency on final review content.

3. **Alive GPT with event sidecar preserves numeric progress**
   - Create live `sleep 60 &`.
   - Create `.active.$pid`, a `.log` with three lines, and a `.events.jsonl` containing `{"provider":"gpt"}`.
   - Expected: output is exactly `3`.
   - This prevents the ungated event-progress regression.

4. **Dead success returns final review text**
   - Use a definitely dead PID from a helper, not a hard-coded large PID.
   - Create `.active.$pid` and a non-empty `.log`.
   - Expected: output contains `## Files Examined` and `INDEPENDENT CODE REVIEW PASSED`.

5. **Dead crash with `.log` missing returns diagnostics**
   - Use a dead PID.
   - Write `.active.$pid` pointing at a missing `.log`.
   - Create `.events.jsonl` with an `error` severity event and `.stderr` with a short error message.
   - Expected: output contains `Fresh Eyes review failed before final output`, the error event name, and the stderr message. It must not be `0`.

6. **Dead crash with empty `.log` returns diagnostics**
   - Same as case 5, but create empty `.log`.
   - Expected: diagnostic output, not empty output.

Implementation notes for the test:

- Use a `cleanup` trap to kill live `sleep` processes.
- Use `.venv-wsl/bin/python` only if it exists and Python is needed from the test. Prefer Bash and `jq` for JSONL fixtures.
- Do not pre-create `.log` in the sidecar-only test.

Run:

```bash
bash tests/fresheyes-progress-test.sh
```

Expected before implementation: at least the sidecar-only and dead-diagnostic tests fail.

Commit:

```bash
git add tests/fresheyes-progress-test.sh
git commit -m "test: cover Fresheyes progress edge cases"
```

## Task 2: Add Claude Stream Parser Tests and Fake CLI Tests

**Files:**

- Create `tests/fresheyes-claude-provider-test.sh`.

Add a shell test using a fake `claude` executable placed at the front of `PATH`. The fake CLI should:

- Record all argv entries to a file.
- Emit valid Claude `stream-json` JSONL for manual mode.
- Emit valid Claude `stream-json` JSONL with `structured_output` for automatic mode.
- Optionally sleep briefly between events for one case so progress can be checked before final output.

Required test cases:

1. **Manual Claude invocation uses streaming flags**
   - Run `skills/fresheyes/fresheyes.sh --claude "Review README.md."`.
   - Assert argv contains:
     - `--output-format`
     - `stream-json`
     - `--verbose`
     - `--include-partial-messages`
     - `--disable-slash-commands`
   - Assert argv does not contain `--bare`.
   - Assert final stdout contains `INDEPENDENT CODE REVIEW PASSED`.
   - Assert `.events.jsonl`, `.stream.jsonl`, `.stderr`, and `.log` exist.

2. **Automatic Claude invocation extracts structured output**
   - Run `skills/fresheyes/fresheyes.sh --claude --mode automatic "Review staged changes."`.
   - Fake final event includes:

```json
{"type":"result","subtype":"success","is_error":false,"result":"Done.","structured_output":{"approve_commit":true,"issues":[]}}
```

   - Assert the automatic output file contains `{"approve_commit": true, "issues": []}`.
   - Assert stdout contains `Fresh Eyes: approved.`.

3. **Parser missing-result failure writes a concise failure log**
   - Feed JSONL with provider events but no final `result`.
   - Assert parser exits non-zero.
   - Assert `.events.jsonl` contains an error event named `missing_result`.
   - Assert `.log` exists and contains a concise failure report.

4. **Parser crash fallback is still covered by progress tests**
   - Do not rely only on the parser writing `.log`; Task 1's dead sidecar-only cases must remain.

Run:

```bash
bash tests/fresheyes-claude-provider-test.sh
```

Expected before implementation: failure because Claude is still called with `--output-format text` or `json`, and the parser does not exist.

Commit:

```bash
git add tests/fresheyes-claude-provider-test.sh
git commit -m "test: cover Claude stream-json provider behavior"
```

## Task 3: Implement the Claude Stream Parser

**Files:**

- Create `skills/fresheyes/fresheyes-claude-stream.py`.

Parser requirements:

- Read Claude `stream-json` JSONL from stdin.
- Append every raw non-empty line to `--stream-log`.
- Append normalized JSONL records to `--event-log`.
- Every normalized record must include:
  - `severity`
  - `event`
  - `provider: "claude"`
  - `ts_epoch`
- Provider-originated records must use `event: "provider_event"`.
- For provider events, record compact fields when present:
  - `type`
  - `subtype`
  - `status`
  - `session_id`
  - nested stream event type
  - tool name
  - delta type
- On final successful manual `result`, write `result` text to `--review-log` and print it to stdout.
- On final successful automatic `result`, write `structured_output` to `--automatic-output`, write the same JSON to `--review-log`, and exit `0`.
- If `structured_output` is missing in automatic mode, try parsing the `result` string as JSON. If neither works, write a concise failure `.log`, append `severity=error event=structured_output_missing`, and exit non-zero.
- If the stream ends without a final `result`, write a concise failure `.log`, append `severity=error event=missing_result`, and exit non-zero.
- If Claude emits `is_error: true`, write the error result text to `.log`, append `severity=error event=review_result`, print the error text, and exit non-zero.

The missing-result failure log should look like this:

```text
Fresh Eyes review failed before final output.

provider=claude
error=missing_result
stream_lines=<count>

See sidecar logs:
- <event log path>
- <stream log path>
```

Run:

```bash
PYTHON=".venv-wsl/bin/python"; [[ -x "$PYTHON" ]] || PYTHON="python3"
"$PYTHON" -m py_compile skills/fresheyes/fresheyes-claude-stream.py
bash tests/fresheyes-claude-provider-test.sh
```

Commit:

```bash
git add skills/fresheyes/fresheyes-claude-stream.py tests/fresheyes-claude-provider-test.sh
git commit -m "feat: parse Claude stream-json output"
```

## Task 4: Wire Claude Provider to `stream-json`

**Files:**

- Modify `skills/fresheyes/fresheyes.sh`.
- Test with `tests/fresheyes-claude-provider-test.sh`.

Implementation requirements:

- Define:

```bash
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
```

- Pre-create the Claude sidecar files when the selected provider is Claude:

```bash
if [[ "$PROVIDER" == "claude" ]]; then
  : >"$LOG_FILE"
  : >"$EVENT_LOG"
  : >"$STREAM_LOG"
  : >"$LOG_FILE.stderr"
fi
```

Pre-creating `.log` in production is acceptable and reduces races. Tests must still include the missing-`.log` sidecar case because progress must survive parser crashes and externally-created sidecars.

- Add a `log_event` helper that writes JSONL with `severity`, `event`, `provider`, `mode`, `pid`, `ts_epoch`, and optional `message`.
- Keep `log_event` available for Claude. If used for GPT too, progress must still gate event-summary output to Claude only.
- Change `run_claude_manual` to call Claude with:

```bash
--output-format stream-json
--verbose
--include-partial-messages
--disable-slash-commands
```

- Do not add `--bare`.
- Keep the existing auth environment behavior unless a separate requirement changes it.
- Pipe Claude stdout to `fresheyes-claude-stream.py`.
- Redirect Claude stderr to `$LOG_FILE.stderr`.
- Use `--` before the prompt if any variadic Claude options make argument parsing ambiguous. The local validation found `--tools` can swallow the prompt without `--`.
- Change `run_claude_automatic` the same way and pass `--json-schema "$json_schema"`.
- Remove the old Claude automatic post-processing block that expected a JSON envelope from `--output-format json`.
- Ensure parser output still reaches caller stdout for manual reviews.

Run:

```bash
bash -n skills/fresheyes/fresheyes.sh
PYTHON=".venv-wsl/bin/python"; [[ -x "$PYTHON" ]] || PYTHON="python3"
"$PYTHON" -m py_compile skills/fresheyes/fresheyes-claude-stream.py
bash tests/fresheyes-claude-provider-test.sh
```

Commit:

```bash
git add skills/fresheyes/fresheyes.sh skills/fresheyes/fresheyes-claude-stream.py tests/fresheyes-claude-provider-test.sh
git commit -m "feat: stream Claude provider progress"
```

## Task 5: Rewrite Progress Resolution and Reporting

**Files:**

- Modify `skills/fresheyes/fresheyes-progress.sh`.
- Test with `tests/fresheyes-progress-test.sh`.

Implementation requirements:

1. Replace `_find_log` with a base-path resolver.

The resolver should:

- Prefer `.active.$PID` if present.
- Return the active path if any related file exists:
  - `$base`
  - `$base.events.jsonl`
  - `$base.stream.jsonl`
  - `$base.stderr`
- Fall back to globs by PID for all related file types, normalizing sidecar paths back to the base `.log` path.

2. Add safe helper functions.

Required helpers:

- `line_count_or_zero "$base"`: print numeric line count if `.log` exists, otherwise `0`.
- `cat_if_nonempty "$base"`: print `.log` only if it exists and is non-empty.
- `event_log_provider "$base"`: read `.events.jsonl` and return the last known `provider`, ignoring malformed lines.
- `print_claude_running_status "$base"`: summarize Claude provider events only.
- `print_failure_diagnostic "$base"`: print a concise failure report from events/stderr/stream-log presence.

3. Alive behavior.

- If provider is Claude, print Claude event status.
- Otherwise print numeric `.log` line count with `line_count_or_zero`.
- Never fail with `No such file or directory` when `.log` is missing.

4. Dead behavior.

- If `.log` is non-empty, print it and remove `.active.$PID`.
- If `.log` is empty or missing, print diagnostic output and remove `.active.$PID`.
- If no base or sidecar can be found, keep the existing `0` behavior.

5. Claude status format.

Use a stable single-line format:

```text
running provider=claude provider_events=<n> last_provider_event=<name> final_lines=<n>
```

Optional fields can be appended:

- `stream_event_type=<type>`
- `tool=<name>`
- `subtype=<subtype>`
- `status=<status>`

Do not include wrapper-only heartbeat events in `provider_events`.

6. Diagnostic format.

Use a concise multi-line diagnostic:

```text
Fresh Eyes review failed before final output.

provider=claude
last_event=<event>
last_error=<event-or-message>

stderr:
<last stderr lines if any>
```

If provider cannot be determined, use `provider=unknown`.

Run:

```bash
bash -n skills/fresheyes/fresheyes-progress.sh
bash tests/fresheyes-progress-test.sh
bash tests/fresheyes-claude-provider-test.sh
```

Commit:

```bash
git add skills/fresheyes/fresheyes-progress.sh tests/fresheyes-progress-test.sh
git commit -m "fix: report Claude sidecar progress safely"
```

## Task 6: Update Skill Polling and Cleanup Instructions

**Files:**

- Modify `skills/fresheyes/SKILL.md`.

Required documentation changes:

- Replace alive numeric-only examples with both shapes:

```text
alive
running provider=claude provider_events=42 last_provider_event=tool_result final_lines=0
```

```text
alive
5270
```

- Interpret `running provider=claude ...` as active Claude provider progress.
- Interpret numeric output as GPT or legacy progress.
- Do not instruct agents to kill Claude reviews only because final `.log` line count is unchanged.
- If a review must be stopped, instruct process-group cleanup:

```bash
kill -- -$FRESHPID 2>/dev/null || kill $FRESHPID 2>/dev/null || true
```

- Remove claims that startup and heartbeat messages are captured in the final `.log`. Claude progress is in `.events.jsonl`.
- Keep the reviewer-scope and provider-selection rules unchanged.

Run:

```bash
rg -n "line count unchanged|heartbeat are captured|5270.*line count" skills/fresheyes/SKILL.md
rg -n "kill \\$FRESHPID$|kill \"\\$FRESHPID\"$" skills/fresheyes/SKILL.md
```

Expected: no stale guidance except any intentional compatibility note about numeric progress. The second command is meant to catch a positive-PID-only kill instruction; the process-group command with fallback is expected to remain.

Commit:

```bash
git add skills/fresheyes/SKILL.md
git commit -m "docs: update Fresheyes Claude polling guidance"
```

## Task 7: README Update

**Files:**

- Modify `README.md` only if there is a useful end-user-facing note.

If adding a note, place it under Manual Mode after the current sentence that mentions the reviewer operating independently. The real file uses an em dash in that sentence, so do not use an ASCII-hyphen text replacement. Search for:

```bash
rg -n "reviewer operates independently" README.md
```

Suggested note:

```markdown
Claude-provider background reviews report live progress through structured sidecar logs and still return the final review text when complete.
```

Commit if changed:

```bash
git add README.md
git commit -m "docs: note Claude background review progress"
```

## Task 8: Verification

Run all verification commands:

```bash
bash -n skills/fresheyes/fresheyes.sh
bash -n skills/fresheyes/fresheyes-progress.sh
bash -n scripts/fresheyes-pre-commit.sh
bash -n scripts/install-automatic-hook.sh
bash -n tests/fresheyes-claude-provider-test.sh
bash -n tests/fresheyes-progress-test.sh
PYTHON=".venv-wsl/bin/python"; [[ -x "$PYTHON" ]] || PYTHON="python3"
"$PYTHON" -m py_compile skills/fresheyes/fresheyes-claude-stream.py
bash tests/fresheyes-progress-test.sh
bash tests/fresheyes-claude-provider-test.sh
```

Run one live smoke test after fake CLI tests pass:

```bash
tmpdir="$(mktemp -d)"
TMPDIR="$tmpdir" timeout 180s bash skills/fresheyes/fresheyes.sh --claude "Review README.md only. Do not inspect other files."
ls "$tmpdir/fresheyes-logs"/*.events.jsonl "$tmpdir/fresheyes-logs"/*.stream.jsonl "$tmpdir/fresheyes-logs"/*.log
```

Expected:

- The live run prints a review.
- `ls` prints one `.events.jsonl`, one `.stream.jsonl`, and one `.log`.
- The event log includes Claude provider events before the final result.

Inspect the final diff:

```bash
git diff --stat
git diff -- skills/fresheyes/fresheyes.sh skills/fresheyes/fresheyes-progress.sh skills/fresheyes/fresheyes-claude-stream.py skills/fresheyes/SKILL.md README.md tests
```

Expected:

- Changes are limited to the files in this plan.
- GPT provider shell calls remain behaviorally unchanged.
- Claude provider calls use `stream-json`, not `text` or `json`.
- No Claude call uses `--bare`.
- Progress tests include missing-`.log` sidecar cases.
- Dead crash tests assert diagnostics, not `0`.

## Self-Review Checklist

- The plan no longer depends on final `.log` existence for live Claude progress.
- The progress implementation is sidecar-aware end to end, including downstream `cat` and `wc` paths.
- The tests do not mask the bug by pre-creating `.log` in the sidecar-only case.
- GPT line-count progress is preserved.
- Crash diagnostics are available through `fresheyes-progress.sh`.
- Process-group cleanup is used for timeout stops.
- `--bare` is excluded.
- `--disable-slash-commands` is included for Claude.
- Automatic mode reads `structured_output` from the final `stream-json` result.
- All repo code that logs progress uses structured JSONL with severity.
