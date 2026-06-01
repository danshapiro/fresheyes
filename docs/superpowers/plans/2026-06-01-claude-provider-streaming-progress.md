# Claude Provider Streaming Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Fresheyes' Claude provider report real progress and clean up correctly by using Claude Code's supported `stream-json` output for all Claude review modes.

**Architecture:** Keep the current shell runner as the public entrypoint, but add a small Python stream parser dedicated to Claude JSONL events. The runner writes final review output to the existing `.log` file and structured progress events to a `.events.jsonl` sidecar; `fresheyes-progress.sh` reads the sidecar while the process is alive and still returns the final review when the process is dead.

**Tech Stack:** Bash, Python 3 standard library, Claude Code CLI `2.1.159+`, Codex CLI unchanged, `jq` for tests.

---

## Scope

This plan fixes the Claude provider generally, covering both Fresheyes modes:

- `provider=claude, mode=manual`: human-readable markdown review.
- `provider=claude, mode=automatic`: pre-commit JSON review.

This plan does not change the GPT provider's behavior except preserving compatibility in `fresheyes-progress.sh`.

## File Structure

- Create: `tests/fresheyes-claude-provider-test.sh`
  - End-to-end shell tests using a fake `claude` executable.
  - Proves Claude is invoked with `stream-json`, `--disable-slash-commands`, and no `--bare`.
  - Proves manual and automatic Claude results are extracted from the stream.

- Create: `tests/fresheyes-progress-test.sh`
  - Unit-style shell tests for progress behavior using synthetic log/event files.
  - Proves alive Claude reviews return event progress instead of `0`.
  - Proves dead reviews still return the final review text.

- Create: `skills/fresheyes/fresheyes-claude-stream.py`
  - Reads Claude `stream-json` JSONL from stdin.
  - Writes raw stream lines to `.stream.jsonl`.
  - Writes structured JSONL progress records to `.events.jsonl`.
  - Writes final manual review text to `.log`.
  - Writes final automatic structured output to `fresheyes-automatic-*.json`.

- Modify: `skills/fresheyes/fresheyes.sh`
  - Add structured event log paths.
  - Add JSONL event logging for startup, heartbeat, provider start, provider exit, and failures.
  - Change all Claude provider calls to `--output-format stream-json --verbose --include-partial-messages --disable-slash-commands`.
  - Keep Claude auth behavior unchanged by not using `--bare`.

- Modify: `skills/fresheyes/fresheyes-progress.sh`
  - Read `.events.jsonl` for alive Claude reviews.
  - Preserve current dead-process behavior of returning the final `.log`.
  - Preserve line-count fallback for GPT and older logs.

- Modify: `skills/fresheyes/SKILL.md`
  - Replace line-count polling guidance with progress-status polling.
  - Remove the unchanged-line-count stall kill rule for Claude.
  - Use process-group cleanup: `kill -- -$FRESHPID`.

- Modify: `README.md`
  - No interface change is required.
  - Add one short line to configuration docs noting that Claude progress uses structured sidecar logs if the runner is launched in the background.

## Task 1: Add Claude Provider End-to-End Tests

**Files:**
- Create: `tests/fresheyes-claude-provider-test.sh`

- [ ] **Step 1: Write the failing test script**

Create `tests/fresheyes-claude-provider-test.sh` with this complete content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "expected $file not to contain: $pattern"
  fi
}

make_fake_claude() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"${CLAUDE_ARGS_FILE:?}"

case "${CLAUDE_FAKE_MODE:?}" in
  manual)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-session","model":"fake-opus","tools":["Bash","Read","Glob","Grep"],"slash_commands":[],"skills":[]}
{"type":"system","subtype":"status","status":"requesting","session_id":"fake-session"}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_fake","name":"Bash","input":{"command":"git diff --stat"},"caller":{"type":"direct"}}},"session_id":"fake-session"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_fake","type":"tool_result","content":" README.md | 1 +","is_error":false}]},"session_id":"fake-session","tool_use_result":{"stdout":" README.md | 1 +","stderr":"","interrupted":false}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1250,"num_turns":2,"result":"## Files Examined\n- README.md\n\n## Issues Found\nNone\n\n## Summary\nFake review passed.\n\n---\n**INDEPENDENT CODE REVIEW PASSED**","session_id":"fake-session","terminal_reason":"completed"}
JSON
    ;;
  automatic)
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"fake-session","model":"fake-opus","tools":["Bash","Read","Glob","Grep","StructuredOutput"],"slash_commands":[],"skills":[]}
{"type":"system","subtype":"status","status":"requesting","session_id":"fake-session"}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_structured","name":"StructuredOutput","input":{"approve_commit":true,"issues":[]},"caller":{"type":"direct"}}},"session_id":"fake-session"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_structured","type":"tool_result","content":"Structured output provided successfully"}]},"session_id":"fake-session","tool_use_result":"Structured output provided successfully"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"num_turns":2,"result":"Done - returned structured output.","structured_output":{"approve_commit":true,"issues":[]},"session_id":"fake-session","terminal_reason":"completed"}
JSON
    ;;
  *)
    echo "unknown CLAUDE_FAKE_MODE: ${CLAUDE_FAKE_MODE}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$bin_dir/claude"
}

run_manual_test() {
  local tmp
  tmp="$(mktemp -d)"
  make_fake_claude "$tmp/bin"

  PATH="$tmp/bin:$PATH" \
  TMPDIR="$tmp" \
  CLAUDE_ARGS_FILE="$tmp/claude-args.txt" \
  CLAUDE_FAKE_MODE=manual \
    bash "$ROOT_DIR/skills/fresheyes/fresheyes.sh" --claude "Review README.md." >"$tmp/stdout.txt"

  local log_file
  log_file="$(ls "$tmp/fresheyes-logs"/fresheyes-*.log)"
  local event_log="$log_file.events.jsonl"
  local stream_log="$log_file.stream.jsonl"

  assert_contains "$tmp/stdout.txt" "**INDEPENDENT CODE REVIEW PASSED**"
  assert_contains "$log_file" "## Files Examined"
  test -s "$event_log" || fail "expected non-empty event log"
  test -s "$stream_log" || fail "expected non-empty raw stream log"

  assert_contains "$tmp/claude-args.txt" "--output-format"
  assert_contains "$tmp/claude-args.txt" "stream-json"
  assert_contains "$tmp/claude-args.txt" "--verbose"
  assert_contains "$tmp/claude-args.txt" "--include-partial-messages"
  assert_contains "$tmp/claude-args.txt" "--disable-slash-commands"
  assert_not_contains "$tmp/claude-args.txt" "--bare"

  jq -e 'select(.severity == "info" and .event == "provider_event" and .provider == "claude")' "$event_log" >/dev/null
  jq -e 'select(.severity == "info" and .event == "review_result" and .provider == "claude")' "$event_log" >/dev/null
}

run_automatic_test() {
  local tmp
  tmp="$(mktemp -d)"
  make_fake_claude "$tmp/bin"

  PATH="$tmp/bin:$PATH" \
  TMPDIR="$tmp" \
  CLAUDE_ARGS_FILE="$tmp/claude-args.txt" \
  CLAUDE_FAKE_MODE=automatic \
    bash "$ROOT_DIR/skills/fresheyes/fresheyes.sh" --claude --mode automatic "Review staged changes." >"$tmp/stdout.txt"

  local log_file
  log_file="$(ls "$tmp/fresheyes-logs"/fresheyes-*.log)"
  local output_file
  output_file="$(ls "$tmp/fresheyes-logs"/fresheyes-automatic-*.json)"

  assert_contains "$tmp/stdout.txt" "Fresh Eyes: approved."
  jq -e '.approve_commit == true and (.issues | length) == 0' "$output_file" >/dev/null
  jq -e 'select(.event == "structured_output" and .provider == "claude")' "$log_file.events.jsonl" >/dev/null

  assert_contains "$tmp/claude-args.txt" "--json-schema"
  assert_contains "$tmp/claude-args.txt" "--output-format"
  assert_contains "$tmp/claude-args.txt" "stream-json"
  assert_contains "$tmp/claude-args.txt" "--disable-slash-commands"
}

run_manual_test
run_automatic_test
echo "fresheyes Claude provider tests passed"
```

- [ ] **Step 2: Run the test and verify it fails before implementation**

Run:

```bash
bash tests/fresheyes-claude-provider-test.sh
```

Expected before implementation: failure mentioning either the missing `.events.jsonl` file or missing `stream-json` Claude argument.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/fresheyes-claude-provider-test.sh
git commit -m "test: cover Claude provider streaming progress"
```

## Task 2: Add Progress Script Tests

**Files:**
- Create: `tests/fresheyes-progress-test.sh`

- [ ] **Step 1: Write the failing progress tests**

Create `tests/fresheyes-progress-test.sh` with this complete content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains_text() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]] || fail "expected output to contain: $expected; got: $text"
}

run_alive_claude_progress_test() {
  local tmp
  tmp="$(mktemp -d)"
  local log_dir="$tmp/fresheyes-logs"
  mkdir -p "$log_dir"

  sleep 60 &
  local pid=$!
  trap 'kill "$pid" 2>/dev/null || true' RETURN

  local log_file="$log_dir/fresheyes-20260601-000000-$pid.log"
  : >"$log_file"
  printf '%s\n' "$log_file" >"$log_dir/.active.$pid"

  cat >"$log_file.events.jsonl" <<JSONL
{"severity":"info","event":"review_started","provider":"claude","pid":$pid}
{"severity":"info","event":"provider_event","provider":"claude","type":"system","subtype":"status","status":"requesting"}
{"severity":"info","event":"provider_event","provider":"claude","type":"stream_event","stream_event_type":"content_block_start","tool":"Bash"}
JSONL

  local output
  output="$(TMPDIR="$tmp" bash "$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh" "$pid")"
  assert_contains_text "$output" "running"
  assert_contains_text "$output" "provider=claude"
  assert_contains_text "$output" "events=3"
  assert_contains_text "$output" "last_event=provider_event"
  assert_contains_text "$output" "final_lines=0"
}

run_dead_review_returns_final_log_test() {
  local tmp
  tmp="$(mktemp -d)"
  local log_dir="$tmp/fresheyes-logs"
  mkdir -p "$log_dir"

  local pid=999999
  local log_file="$log_dir/fresheyes-20260601-000000-$pid.log"
  cat >"$log_file" <<'LOG'
## Files Examined
- README.md

## Issues Found
None

---
**INDEPENDENT CODE REVIEW PASSED**
LOG
  printf '%s\n' "$log_file" >"$log_dir/.active.$pid"

  local output
  output="$(TMPDIR="$tmp" bash "$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh" "$pid")"
  assert_contains_text "$output" "## Files Examined"
  assert_contains_text "$output" "**INDEPENDENT CODE REVIEW PASSED**"
}

run_alive_claude_progress_test
run_dead_review_returns_final_log_test
echo "fresheyes progress tests passed"
```

- [ ] **Step 2: Run the test and verify it fails before implementation**

Run:

```bash
bash tests/fresheyes-progress-test.sh
```

Expected before implementation: `run_alive_claude_progress_test` fails because `fresheyes-progress.sh` returns `0` instead of `running provider=claude events=3 ...`.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/fresheyes-progress-test.sh
git commit -m "test: cover Claude progress sidecar status"
```

## Task 3: Add the Claude Stream Parser

**Files:**
- Create: `skills/fresheyes/fresheyes-claude-stream.py`
- Test: `tests/fresheyes-claude-provider-test.sh`

- [ ] **Step 1: Create the parser**

Create `skills/fresheyes/fresheyes-claude-stream.py` with this complete content:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Parse Claude Code stream-json output for Fresheyes.")
    parser.add_argument("--mode", choices=("manual", "automatic"), required=True)
    parser.add_argument("--review-log", required=True)
    parser.add_argument("--event-log", required=True)
    parser.add_argument("--stream-log", required=True)
    parser.add_argument("--automatic-output")
    return parser.parse_args()


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    record.setdefault("ts_epoch", time.time())
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
        handle.write("\n")


def append_event(path: Path, severity: str, event: str, **fields: Any) -> None:
    record: dict[str, Any] = {
        "severity": severity,
        "event": event,
        "provider": "claude",
    }
    record.update(fields)
    append_jsonl(path, record)


def summarize_provider_event(record: dict[str, Any]) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "type": record.get("type", "unknown"),
    }
    if "subtype" in record:
        summary["subtype"] = record["subtype"]
    if "status" in record:
        summary["status"] = record["status"]
    if "session_id" in record:
        summary["session_id"] = record["session_id"]

    nested = record.get("event")
    if isinstance(nested, dict):
        nested_type = nested.get("type")
        if nested_type:
            summary["stream_event_type"] = nested_type
        content_block = nested.get("content_block")
        if isinstance(content_block, dict):
            block_type = content_block.get("type")
            if block_type:
                summary["content_block_type"] = block_type
            tool_name = content_block.get("name")
            if tool_name:
                summary["tool"] = tool_name
        delta = nested.get("delta")
        if isinstance(delta, dict):
            delta_type = delta.get("type")
            if delta_type:
                summary["delta_type"] = delta_type

    if record.get("type") == "user" and "tool_use_result" in record:
        summary["stream_event_type"] = "tool_result"

    return summary


def extract_structured_from_result(result: dict[str, Any]) -> dict[str, Any]:
    structured = result.get("structured_output")
    if isinstance(structured, dict):
        return structured

    result_text = result.get("result")
    if isinstance(result_text, str):
        try:
            parsed = json.loads(result_text)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            return parsed

    raise ValueError("Claude stream result did not include structured_output or JSON result text")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    if text and not text.endswith("\n"):
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\n")


def main() -> int:
    args = parse_args()
    review_log = Path(args.review_log)
    event_log = Path(args.event_log)
    stream_log = Path(args.stream_log)
    automatic_output = Path(args.automatic_output) if args.automatic_output else None

    append_event(event_log, "info", "stream_parser_started", mode=args.mode)

    final_result: dict[str, Any] | None = None
    line_count = 0

    with stream_log.open("a", encoding="utf-8") as raw_handle:
        for raw_line in sys.stdin:
            if not raw_line.strip():
                continue
            line_count += 1
            raw_handle.write(raw_line)
            raw_handle.flush()

            try:
                record = json.loads(raw_line)
            except json.JSONDecodeError as exc:
                append_event(
                    event_log,
                    "warn",
                    "provider_unparseable_line",
                    line=line_count,
                    error=str(exc),
                )
                continue

            summary = summarize_provider_event(record)
            summary["line"] = line_count
            append_event(event_log, "info", "provider_event", **summary)

            if record.get("type") == "result":
                final_result = record

    if final_result is None:
        append_event(event_log, "error", "missing_result", lines=line_count)
        return 2

    if final_result.get("is_error") is True:
        result_text = str(final_result.get("result", "Claude returned an error without result text."))
        write_text(review_log, result_text)
        append_event(
            event_log,
            "error",
            "review_result",
            is_error=True,
            terminal_reason=final_result.get("terminal_reason"),
            stop_reason=final_result.get("stop_reason"),
        )
        print(result_text)
        return 1

    if args.mode == "manual":
        result_text = str(final_result.get("result", ""))
        write_text(review_log, result_text)
        append_event(
            event_log,
            "info",
            "review_result",
            is_error=False,
            terminal_reason=final_result.get("terminal_reason"),
            stop_reason=final_result.get("stop_reason"),
            duration_ms=final_result.get("duration_ms"),
            num_turns=final_result.get("num_turns"),
        )
        print(result_text)
        return 0

    if automatic_output is None:
        append_event(event_log, "error", "missing_automatic_output_path")
        return 2

    try:
        structured = extract_structured_from_result(final_result)
    except ValueError as exc:
        append_event(event_log, "error", "structured_output_missing", error=str(exc))
        return 2

    automatic_output.write_text(json.dumps(structured, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_text(review_log, json.dumps(structured, indent=2, sort_keys=True))
    append_event(
        event_log,
        "info",
        "structured_output",
        approve_commit=structured.get("approve_commit"),
        issue_count=len(structured.get("issues", [])) if isinstance(structured.get("issues"), list) else None,
    )
    append_event(
        event_log,
        "info",
        "review_result",
        is_error=False,
        terminal_reason=final_result.get("terminal_reason"),
        stop_reason=final_result.get("stop_reason"),
        duration_ms=final_result.get("duration_ms"),
        num_turns=final_result.get("num_turns"),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Make the parser executable**

Run:

```bash
chmod +x skills/fresheyes/fresheyes-claude-stream.py
```

Expected: command exits with status `0`.

- [ ] **Step 3: Run syntax validation**

Run:

```bash
python3 -m py_compile skills/fresheyes/fresheyes-claude-stream.py
```

Expected: command exits with status `0`.

- [ ] **Step 4: Commit the parser**

```bash
git add skills/fresheyes/fresheyes-claude-stream.py
git commit -m "feat: parse Claude stream-json progress"
```

## Task 4: Wire Claude Provider to Stream JSON

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh`
- Test: `tests/fresheyes-claude-provider-test.sh`

- [ ] **Step 1: Add stream log paths and structured runner events**

In `skills/fresheyes/fresheyes.sh`, immediately after `LOG_FILE="$LOG_DIR/fresheyes-$(date +%Y%m%d-%H%M%S)-$$.log"`, add:

```bash
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
```

After the `.active.$$` write, add this complete helper:

```bash
log_event() {
  local severity="$1"
  local event="$2"
  local message="${3:-}"
  python3 - "$EVENT_LOG" "$severity" "$event" "$PROVIDER" "$MODE" "$$" "$message" <<'PY'
import json
import sys
import time

path, severity, event, provider, mode, pid, message = sys.argv[1:]
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
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
    handle.write("\n")
PY
}
```

Replace the current startup `echo "Fresh Eyes [$$]: review starting..." >&2` block with:

```bash
log_event "info" "review_started" "Fresh Eyes review starting."
echo "Fresh Eyes [$$]: review starting. This may take up to 30 minutes, please wait patiently." >&2
```

- [ ] **Step 2: Add heartbeat events**

Replace `_start_heartbeat()` in `skills/fresheyes/fresheyes.sh` with:

```bash
_start_heartbeat() {
  (
    while true; do
      sleep 300
      log_event "info" "heartbeat" "Fresh Eyes review in progress."
      echo "Fresh Eyes [$$]: review in progress..." >&2
    done
  ) &
  HEARTBEAT_PID=$!
}
```

- [ ] **Step 3: Replace `run_claude_manual`**

Replace the full `run_claude_manual()` function with:

```bash
run_claude_manual() {
  log_event "info" "provider_started" "Starting Claude provider in stream-json mode."
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT claude -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>"$LOG_FILE.stderr" \
    | python3 "$SCRIPT_DIR/fresheyes-claude-stream.py" \
      --mode manual \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG"; then
    log_event "error" "provider_failed" "Claude provider failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. See log: $LOG_FILE" >&2
    [[ -s "$LOG_FILE.stderr" ]] && cat "$LOG_FILE.stderr" >&2
    exit 1
  fi
  log_event "info" "provider_completed" "Claude provider completed."
}
```

- [ ] **Step 4: Replace `run_claude_automatic`**

Replace the full `run_claude_automatic()` function with:

```bash
run_claude_automatic() {
  local output_file="$1"
  local json_schema
  json_schema=$(cat "$SCHEMA_FILE")

  log_event "info" "provider_started" "Starting Claude provider in stream-json automatic mode."
  if ! env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_ENTRYPOINT claude -p \
    --model "$MODEL" \
    --effort "$REASONING_EFFORT" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --disable-slash-commands \
    --json-schema "$json_schema" \
    --allowedTools "$CLAUDE_TOOLS" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>"$LOG_FILE.stderr" \
    | python3 "$SCRIPT_DIR/fresheyes-claude-stream.py" \
      --mode automatic \
      --review-log "$LOG_FILE" \
      --event-log "$EVENT_LOG" \
      --stream-log "$STREAM_LOG" \
      --automatic-output "$output_file"; then
    log_event "error" "provider_failed" "Claude provider failed."
    echo "Fresh Eyes: $PROVIDER_LABEL failed. Commit blocked." >&2
    echo "Full log: $LOG_FILE" >&2
    [[ -s "$LOG_FILE.stderr" ]] && cat "$LOG_FILE.stderr" >&2
    exit 1
  fi
  log_event "info" "provider_completed" "Claude provider completed."
}
```

Remove the old Python post-processing block from `run_claude_automatic`; the new parser writes `"$output_file"` directly.

- [ ] **Step 5: Run syntax checks**

Run:

```bash
bash -n skills/fresheyes/fresheyes.sh
python3 -m py_compile skills/fresheyes/fresheyes-claude-stream.py
```

Expected: both commands exit with status `0`.

- [ ] **Step 6: Run Claude provider tests**

Run:

```bash
bash tests/fresheyes-claude-provider-test.sh
```

Expected: `fresheyes Claude provider tests passed`.

- [ ] **Step 7: Commit the Claude wiring**

```bash
git add skills/fresheyes/fresheyes.sh skills/fresheyes/fresheyes-claude-stream.py tests/fresheyes-claude-provider-test.sh
git commit -m "feat: stream Claude provider progress"
```

## Task 5: Update Progress Reporting

**Files:**
- Modify: `skills/fresheyes/fresheyes-progress.sh`
- Test: `tests/fresheyes-progress-test.sh`

- [ ] **Step 1: Add event-log progress reporting**

In `skills/fresheyes/fresheyes-progress.sh`, replace the final line:

```bash
wc -l < "$LOG_FILE"
```

with this complete block:

```bash
EVENT_LOG="$LOG_FILE.events.jsonl"

if [[ -f "$EVENT_LOG" ]]; then
  python3 - "$LOG_FILE" "$EVENT_LOG" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

log_file = Path(sys.argv[1])
event_log = Path(sys.argv[2])

events = []
with event_log.open("r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

final_lines = 0
if log_file.exists():
    with log_file.open("r", encoding="utf-8") as handle:
        final_lines = sum(1 for _ in handle)

last = events[-1] if events else {}
provider = last.get("provider", "unknown")
last_event = last.get("event", "none")
parts = [
    "running",
    f"provider={provider}",
    f"events={len(events)}",
    f"last_event={last_event}",
    f"final_lines={final_lines}",
]

stream_event_type = last.get("stream_event_type")
if stream_event_type:
    parts.append(f"stream_event_type={stream_event_type}")

tool = last.get("tool")
if tool:
    parts.append(f"tool={tool}")

subtype = last.get("subtype")
if subtype:
    parts.append(f"subtype={subtype}")

print(" ".join(parts))
PY
  exit 0
fi

wc -l < "$LOG_FILE"
```

- [ ] **Step 2: Run progress tests**

Run:

```bash
bash tests/fresheyes-progress-test.sh
```

Expected: `fresheyes progress tests passed`.

- [ ] **Step 3: Run Claude provider tests again**

Run:

```bash
bash tests/fresheyes-claude-provider-test.sh
```

Expected: `fresheyes Claude provider tests passed`.

- [ ] **Step 4: Commit progress reporting**

```bash
git add skills/fresheyes/fresheyes-progress.sh tests/fresheyes-progress-test.sh
git commit -m "feat: report Claude event progress"
```

## Task 6: Fix Skill Polling and Cleanup Instructions

**Files:**
- Modify: `skills/fresheyes/SKILL.md`

- [ ] **Step 1: Replace the output description**

In `skills/fresheyes/SKILL.md`, replace the current "While the review is running" example with:

```markdown
**While the review is running:**
```
```text
alive
running provider=claude events=42 last_event=provider_event final_lines=0 stream_event_type=tool_result
```
```markdown

For GPT or older logs, `fresheyes-progress.sh` may still return a numeric line count while the process is alive.
```

- [ ] **Step 2: Replace the interpretation rules**

Replace the four bullets under "Step 6: Interpret and act" with:

```markdown
- **`alive` + `running ...` status** -> review is active. Keep polling every 2 minutes.
- **`alive` + numeric line count** -> legacy/GPT progress. Keep polling every 2 minutes.
- **`dead` + review text** -> review completed. The text is the review. Proceed to Step 7.
- **`dead` + `0` only** -> the review never started or crashed before producing output. Check for a log file directly with `ls "/tmp/fresheyes-logs/fresheyes-*-$FRESHPID.log"` and read the last lines for an error message.
```

- [ ] **Step 3: Add process-group cleanup**

Add this paragraph immediately after the interpretation rules:

```markdown
If you must stop a running review, kill the detached process group, not only the wrapper PID:

```bash
kill -- -$FRESHPID
```

Do not kill a Claude review only because final output line count is unchanged. Claude reviews stream progress into `.events.jsonl` and may write the final `.log` only at completion.
```

- [ ] **Step 4: Remove incorrect heartbeat claim**

Replace this sentence:

```markdown
`setsid` detaches the review from this call's process group so harness timeouts don't kill it. All output is written to the log file accessible via `fresheyes-progress.sh`. Startup messages and the heartbeat are captured in the log.
```

with:

```markdown
`setsid` detaches the review from this call's process group so harness timeouts don't kill it. Final review output is written to the `.log` file, and Claude progress is written to a structured `.events.jsonl` sidecar consumed by `fresheyes-progress.sh`.
```

- [ ] **Step 5: Run markdown sanity checks**

Run:

```bash
rg -n "line count unchanged|kill \\$FRESHPID|heartbeat are captured|5270" skills/fresheyes/SKILL.md
```

Expected: no output.

- [ ] **Step 6: Commit skill instruction updates**

```bash
git add skills/fresheyes/SKILL.md
git commit -m "docs: update Fresheyes polling semantics"
```

## Task 7: Add README Note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add one user-facing note**

In `README.md`, under "Manual Mode", after this sentence:

```markdown
By default, the skill picks a different model family from the one invoking it. The reviewer operates independently - it receives only the scope you give it, with no conversation context.
```

add:

```markdown
When launched in the background, Claude-provider reviews write live progress to structured sidecar logs and return the final review when complete.
```

- [ ] **Step 2: Commit README update**

```bash
git add README.md
git commit -m "docs: note Claude background progress logs"
```

## Task 8: Final Verification

**Files:**
- Verify: `skills/fresheyes/fresheyes.sh`
- Verify: `skills/fresheyes/fresheyes-progress.sh`
- Verify: `skills/fresheyes/fresheyes-claude-stream.py`
- Verify: `tests/fresheyes-claude-provider-test.sh`
- Verify: `tests/fresheyes-progress-test.sh`
- Verify: `skills/fresheyes/SKILL.md`

- [ ] **Step 1: Run shell syntax checks**

Run:

```bash
bash -n skills/fresheyes/fresheyes.sh
bash -n skills/fresheyes/fresheyes-progress.sh
bash -n scripts/fresheyes-pre-commit.sh
bash -n scripts/install-automatic-hook.sh
bash -n tests/fresheyes-claude-provider-test.sh
bash -n tests/fresheyes-progress-test.sh
```

Expected: every command exits with status `0`.

- [ ] **Step 2: Run Python syntax checks**

Run:

```bash
python3 -m py_compile skills/fresheyes/fresheyes-claude-stream.py
```

Expected: command exits with status `0`.

- [ ] **Step 3: Run all tests**

Run:

```bash
bash tests/fresheyes-claude-provider-test.sh
bash tests/fresheyes-progress-test.sh
```

Expected:

```text
fresheyes Claude provider tests passed
fresheyes progress tests passed
```

- [ ] **Step 4: Run a live low-risk Claude smoke test**

Run this only after the fake-CLI tests pass:

```bash
tmpdir="$(mktemp -d)"
TMPDIR="$tmpdir" timeout 180s bash skills/fresheyes/fresheyes.sh --claude "Review README.md only. Do not inspect other files."
ls "$tmpdir/fresheyes-logs"/*.events.jsonl "$tmpdir/fresheyes-logs"/*.stream.jsonl "$tmpdir/fresheyes-logs"/*.log
```

Expected:

```text
## Files Examined
...
```

and the `ls` command prints one `.events.jsonl`, one `.stream.jsonl`, and one `.log` path.

- [ ] **Step 5: Verify progress during a fake long-running review**

Run:

```bash
bash tests/fresheyes-progress-test.sh
```

Expected:

```text
fresheyes progress tests passed
```

- [ ] **Step 6: Inspect final diff**

Run:

```bash
git diff --stat HEAD~7..HEAD
git diff HEAD~7..HEAD -- skills/fresheyes/fresheyes.sh skills/fresheyes/fresheyes-progress.sh skills/fresheyes/fresheyes-claude-stream.py skills/fresheyes/SKILL.md README.md tests
```

Expected: changes are limited to the files named in this plan.

- [ ] **Step 7: Final commit if execution was batched**

If the executor batched tasks instead of committing per task, make one final commit:

```bash
git add README.md skills/fresheyes tests
git commit -m "fix: stream Claude progress in Fresheyes"
```

Expected: commit succeeds.

## Self-Review

- Spec coverage: The plan fixes Claude generally by changing both `run_claude_manual` and `run_claude_automatic` to `stream-json`. It updates progress semantics, process cleanup instructions, ambient slash-command loading, and tests.
- Placeholder scan: The plan uses concrete file paths, commands, expected outputs, and full code blocks for new files and replacement functions.
- Type consistency: The parser writes `.events.jsonl` and `.stream.jsonl`; the runner uses the same paths; the progress script reads `.events.jsonl`; the tests assert those same names.
