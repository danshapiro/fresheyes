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

### Step 4: Launch the reviewer

The script path is `fresheyes.sh` inside this skill's base directory (shown at the top of these instructions).

Run it as a plain foreground command:

```bash
bash "<base-directory>/fresheyes.sh" [--gpt|--claude] "<scope from step 2>"
```

`fresheyes.sh --help` prints the options and launches nothing. An unrecognized option or an empty scope is refused with exit 2, and nothing is launched. A scope that starts with `-` goes after `--`.

Manual reviews detach automatically, so this returns within a couple of seconds and prints exactly two lines:

```
FRESHPID=20260729-181530-a3f9c2
NEXT: bash <base-directory>/fresheyes-progress.sh --json 20260729-181530-a3f9c2   (reviews take 5-30 min; poll every 30-60s)
```

Read the value after `FRESHPID=` — an OPAQUE run handle (not a process id; do not pass it to `ps` or `kill`). Save it; it is your handle for the entire review lifecycle (polling in Step 5, result retrieval in Step 7). The `NEXT:` line is the exact poll command to run. If no `FRESHPID=` line is printed, do not proceed to Step 5 — report the command's output to the user.

Do not add `setsid`, a trailing `&`, output redirects, or `$!` — the script backgrounds itself. Run the command exactly as above and read the receipt from its output. Do not add `--foreground` preemptively: it blocks for the full review (5-30 minutes). Use it only when a poll tells you to (see the state table below) — and when you do, first make sure your harness/exec timeout for that call is longer than the review (request/configure a timeout of at least 30 minutes).

### Step 5: Poll every 30-60 seconds

Poll with the exact command from the receipt's `NEXT:` line:

```bash
bash "<base-directory>/fresheyes-progress.sh" --json <handle>
```

Do not call `fresheyes-progress.sh <handle>` without `--json` or `--result`; bare handle polling is intentionally rejected (usage errors exit 2) because stale legacy progress can look like current output.

Each poll returns one JSON line. The `state` field and the command's exit code tell you everything:

| state | exit | meaning | what you do |
|---|---|---|---|
| `launching` | 0 | the review child is starting; no heartbeat yet | poll again in ~15s |
| `running` | 0 | fresh heartbeat; review in progress | keep polling every 30-60s |
| `complete` | 0 | verdict present (`verdict`: `passed`/`failed`) | fetch the review with `--result` (Step 7) |
| `killed_at_launch` | 3 | the child never wrote its first heartbeat | do what the `message` says: re-run the SAME command with `--foreground`, with a harness/exec timeout longer than the review (5-30 min) |
| `died` | 4 | heartbeat went stale and the review process is gone, no verdict | do what the `message` says: it either points at the log as evidence, or — when the run's output could not be tied to this run — says the log must NOT be read back; optionally re-run with `--foreground` |
| `unknown_handle` | 5 | no tracker for this handle | the handle is wrong, or its trackers were removed (e.g. /tmp cleanup); re-check the receipt, else relaunch |
| `handle_mismatch` | 6 | the result carries a DIFFERENT review run's marker, or could not be tied to this run at all | do not use the text and do not read the log back for it — it is another review's. Relaunch from Step 4 and tell the user the review was refused |

`launching` and `running` are healthy states — never treat them as failures, and never abort a poll loop on them. The four failure states carry a `message` field with the observation, likely cause, and the exact remediation; relay it and follow it.

Poll exit-tolerantly: the failure states return NONZERO exit codes (3/4/5/6), so a `set -e`-style loop would abort on the very poll that carries the diagnosis. Capture the output and branch on the JSON `state` field (or the captured exit code):

    output=$(bash <base-directory>/fresheyes-progress.sh --json <handle> || true)

then read `state` from the captured JSON. Never let a nonzero poll exit kill your loop before you have read the `message`.

### Step 6: Interpret and act

The state table in Step 5 is authoritative. Acting on each of the seven states:

- **`launching` or `running`** → healthy; keep polling on the Step 5 cadence.
- **`complete` + `verdict=passed`** → the review passed. Proceed to Step 7.
- **`complete` + `verdict=failed`** → the review completed and found blocking issues. Proceed to Step 7.
- **`complete` with no `verdict`** → the review finished but emitted no PASSED/FAILED marker. This is **not** a tool failure. Run Step 7 (`--result`): it returns the review text when the log has content, or a failure diagnostic when it does not. Report exactly what `--result` returns.
- **`killed_at_launch`** → do what the `message` says: re-run the SAME launch command with `--foreground`, after making sure your harness/exec timeout for that call is longer than the review (5-30 min; request/configure at least 30 minutes).
- **`died`** → relay the `message`. When the run's result could not be tied to this run, the message says so and names the log as text NOT to read back; otherwise it leads with the log path as evidence. Optionally re-run with `--foreground` (same timeout requirement as above).
- **`unknown_handle`** → re-check the handle against the receipt's `FRESHPID=` line; if the handle is right, its trackers were removed (e.g. /tmp cleanup) — relaunch from Step 4.
- **`handle_mismatch`** → the result is not this run's review: it carries another run's marker, or it could not be tied to this run at all. `--result` refuses to print it and names the file that holds the withheld text. Do NOT go and read that file — it is exactly the text that was withheld, and it is not evidence about this run. Relaunch from Step 4, and tell the user the review was refused and why. Read the `message`: it distinguishes "carries review run X" (a replay) from "could not be tied to this run" (no marker, or the check could not be made), and only the first is an accusation.

Do not kill a Fresh Eyes process. If it appears stuck, escalate to the user with evidence instead of stopping it. Evidence should include at least two consecutive `--json` snapshots showing unchanged `line_count`, unchanged `last_log_mtime_epoch`, unchanged `provider_events` when present, and the relevant `pid_state` / `owner_pid_state` values.

Never infer failure from terminal truncation, repeated code excerpts, or a live PID alone.

### Step 7: Report results

When `state=complete`, fetch the final review text:

```bash
bash "<base-directory>/fresheyes-progress.sh" --result <handle>
```

Output the review response exactly as returned. Do not report a running review as failed unless `--json` reports one of the failure states (`killed_at_launch`, `died`, `unknown_handle`, `handle_mismatch`).

Each result is bound to its run: the reviewer is asked to end its review with a
`FRESHEYES-RUN:` line carrying this run's handle, and both the launcher and this script
check it. `--json` reports `handle_verified`. A result with no marker at all — every
result written before this check existed, and any run whose reviewer dropped the line —
is still the review and is still returned, with `handle_verified: false`; a result
carrying a DIFFERENT run's marker is refused (`handle_mismatch`, exit 6). In automatic
mode, which is a commit gate, a result that cannot be tied to the run blocks the commit;
the escape hatch there is the hook's own, `git commit --no-verify`. The binding needs a
handle to bind to, so it applies when you poll with the one from your receipt — a
no-handle poll (the legacy compatibility form) has no caller identity to check against,
and the automatic mode's result is checked by its own run rather than by this script.

One consequence worth knowing when Fresh Eyes reviews ITSELF, or any repository
whose files contain `FRESHEYES-RUN:` lines: in a TEXT review the last marker wins, so a
review that quotes one of those lines AFTER its own marker is refused as a replay. Put
the run's own marker last, which is what the prompt asks for. An automatic-mode result
is JSON and is read from its `run_handle` field, so quoting a marker there changes
nothing.

## Parallel reviews

Multiple fresheyes reviews can run simultaneously. Each invocation mints its own opaque handle and its own tracker files — they never collide. To run two reviews in parallel, save each receipt's handle under a distinct variable and poll them separately.

## Common Mistakes

- **Forgetting to commit** — The reviewer only sees committed code. Uncommitted changes are invisible.
- **Biasing the reviewer on your own initiative** — If the user just said "review src/auth/ with fresh eyes", don't editorialize the scope into "review src/auth/ for security issues." But if the user *asked* for a security review, pass that through faithfully.
- **Vague scope** — "Check our recent work" means nothing to a reviewer with no conversation context. Be specific: which commits, files, or diffs.
- **Including provider in scope** — "Review using claude the staged changes" passes "using claude" as scope text. Provider goes as a flag (`--claude`), not in the scope string.
- **Not polling** — The review takes 5-30 minutes. You must poll every 30-60 seconds until it reaches a terminal state.
- **Doing it yourself** — either use the process here, or notify the user. Do not try a different approach.
- **Killing apparent stuck reviews** — do not stop the process. Escalate with two or more `--json` snapshots that show why it appears stuck.
- **Opening the log** — Do not read, cat, tail, or grep the log file. Interact only through fresheyes-progress.sh.
