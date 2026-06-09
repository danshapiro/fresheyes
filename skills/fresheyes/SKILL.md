---
name: fresheyes
description: Use when the user asks for "fresh eyes", an independent review, or a second opinion on code, commits, plans, or files.
allowed-tools: Bash
timeout: 1800000
---

# Fresh Eyes - Independent Code Review

Invoke an independent model to perform a code review. The reviewer has zero context from your conversation — only the repo and the scope you give it.

## Instructions

### Step 1: Ensure changes are committed

The reviewer uses git commands and only sees committed code. Before invoking, verify all relevant changes are committed. If not, commit them first (or tell the user uncommitted changes won't be reviewed).

### Step 2: Determine the review scope

{{#if args}}
Use the provided scope: {{args}}
{{else}}
Default scope: "Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
{{/if}}

The scope should be a clear, specific instruction telling the reviewer what to examine. The reviewer has NO context from your conversation — only the repo and what you tell it.

**The user's instructions are paramount.** If the user says "do a security review of src/auth/", pass that through faithfully — the scope becomes "Review the files in src/auth/ for security issues." If the user does not scope the review, DO NOT PROVIDE INSTRUCTIONS THAT LIMIT THE SCOPE OF THE REVIEW. Do not use your judgment about what to review, only relay any opinions by the user, if any. Preserve reviewer independence; do not send instructions to the judge.

**Good scope examples:**
- `Review the staged changes using git diff --cached.`
- `Review commit abc1234 using git show abc1234.`
- `Review the files in src/auth/.`
- `Review the files in src/auth/ for security issues.` (user explicitly asked for security review)
- `Review the plan in docs/plans/2025-01-03-feature.md.`
- `Review the changes between main and this branch using git diff main...HEAD.`
- `Review the changes in the worktree at ../feature-worktree using git diff`

**Bad scope examples:**
- `check out what we just did` (reviewer has no context for "what we just did")
- `review src/auth/ again; the buffer overflow has been fixed` (don't add your own context — either say nothing, or pass through what the user asked for)

### Step 3: Choose a provider

Default to a **different model family** from yourself — model diversity improves review quality.

- **You are Claude** → use `--gpt`
- **You are GPT/Codex** → use `--claude`
- **You are neither** → use `--gpt`
- **User explicitly requests a provider** → honor it (`--gpt` or `--claude`)

The provider keyword controls which model runs the review. Do NOT include it in the scope text.

If the model you chose throws an error, try another. If that also throws an error, stop and ask the user what to do. DO NOT CONTINUE IF YOU CANNOT FOLLOW THESE INSTRUCTIONS.

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

### Step 5: Poll every 2 minutes

Every 120 seconds, poll the progress script in JSON mode:

```bash
bash "<base-directory>/fresheyes-progress.sh" --json "$FRESHPID"
```

Do not call `fresheyes-progress.sh "$FRESHPID"` without `--json` or `--result`; bare PID polling is intentionally rejected because stale legacy progress can look like current output.

The output is a single JSON object. Important fields include:

- `state`: `running`, `complete`, `failed`, or `missing`.
- `verdict`: `passed` or `failed` when a manual review has reached its final marker.
- `pid_state`: `active`, `zombie`, `missing`, or `unknown`.
- `owner_pid_state`: same values when the tracked PID was only a launcher and the real review PID is known.
- `line_count`: current final-review log line count.
- `last_log_mtime_epoch`: final-review log mtime.
- `provider_events` and `last_provider_event`: Claude-provider stream progress when available.
- `log_path`: the tracked review log.
- `result_available`: convenience boolean. `true` only when a final verdict marker **and** a non-empty log are both present. It is **not** a tool success/failure signal — a `false` value does not mean the review failed or that no text exists (a finished review can have retrievable text with `result_available=false`). Do not branch on this field; always retrieve the review with `--result` (Step 7).

Examples:

```json
{"state":"running","pid":12345,"pid_state":"active","line_count":5270,"last_log_mtime_epoch":1780376868}
```

```json
{"state":"complete","verdict":"passed","pid":12345,"pid_state":"active","line_count":4315,"result_available":true}
```

The progress script checks final review markers before process state. A review with `state=complete` is complete even if `pid_state` is still `active`.

### Step 6: Interpret and act

- **`state=complete` + `verdict=passed`** → the review passed. Proceed to Step 7.
- **`state=complete` + `verdict=failed`** → the review completed and found blocking issues. Proceed to Step 7.
- **`state=complete` with no `verdict`** → the review finished but emitted no PASSED/FAILED marker (`result_available` is `false`). This is **not** a tool failure. Run Step 7 (`--result`): it returns the review text when the log has content, or a failure diagnostic when it does not. Report exactly what `--result` returns.
- **`state=running`** → continue polling.
- **`state=failed`** → report the diagnostic evidence from the JSON and, if useful, Step 7's result command.
- **`state=missing`** → report that no tracked review output was available, including the PID and `pid_state` from the JSON.

Do not kill a Fresh Eyes process. If it appears stuck, escalate to the user with evidence instead of stopping it. Evidence should include at least two consecutive `--json` snapshots showing unchanged `line_count`, unchanged `last_log_mtime_epoch`, unchanged `provider_events` when present, and the relevant `pid_state` / `owner_pid_state` values.

Never infer failure from terminal truncation, repeated code excerpts, or a live PID alone.

### Step 7: Report results

When `state=complete`, fetch the final review text:

```bash
bash "<base-directory>/fresheyes-progress.sh" --result "$FRESHPID"
```

Output the review response exactly as returned. Do not report a running review as failed unless `--json` returns `state=failed`.

## Parallel reviews

Multiple fresheyes reviews can run simultaneously. Each invocation gets its own PID and its own `.active.$PID` file — they never collide. To run two reviews in parallel, save each `FRESHPID` under a distinct variable and poll them separately.

## Common Mistakes

- **Forgetting to commit** — The reviewer only sees committed code. Uncommitted changes are invisible.
- **Biasing the reviewer on your own initiative** — If the user just said "review src/auth/ with fresh eyes", don't editorialize the scope into "review src/auth/ for security issues." But if the user *asked* for a security review, pass that through faithfully.
- **Vague scope** — "Check our recent work" means nothing to a reviewer with no conversation context. Be specific: which commits, files, or diffs.
- **Including provider in scope** — "Review using claude the staged changes" passes "using claude" as scope text. Provider goes as a flag (`--claude`), not in the scope string.
- **Not polling** — The review takes 5-30 minutes. You must poll every 2 minutes until it completes.
- **Doing it yourself** — either use the process here, or notify the user. Do not try a different approach.
- **Killing apparent stuck reviews** — do not stop the process. Escalate with two or more `--json` snapshots that show why it appears stuck.
- **Opening the log** — Do not read, cat, tail, or grep the log file. Interact only through fresheyes-progress.sh.
