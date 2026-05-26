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

`setsid` detaches the review from this call's process group so harness timeouts don't kill it. All output is written to the log file — you interact only through `fresheyes-progress.sh` and `kill -0`.

Save `$FRESHPID`. This is your handle for the entire review lifecycle.

### Step 5: Poll every 2 minutes

Every 120 seconds, run ONE bash call that checks liveness and progress:

```bash
# Liveness check
if kill -0 FRESHPID 2>/dev/null; then
  echo "alive"
else
  wait FRESHPID 2>/dev/null
  echo "dead EXIT=$?"
fi
# Progress / results (line count if alive, full review if dead)
bash "<base-directory>/fresheyes-progress.sh" FRESHPID
```

The output is:

**While the review is running:**
```
alive
5270        ← line count from fresheyes-progress.sh
```

**When the review has finished (success or crash):**
```
dead EXIT=0   ← 0 = success, non-zero = failure
[full review text from fresheyes-progress.sh]
```

### Step 6: Interpret and act

- **`alive` + line count growing** → review is progressing. Keep polling every 2 minutes.
- **`alive` + line count unchanged for 3 consecutive polls** → review may be stalled. Poll one more cycle. If still stalled, kill the process (`kill FRESHPID`) and report the partial results from the progress script.
- **`dead EXIT=0`** → review completed successfully. The text following `dead EXIT=0` is the review. Proceed to Step 7.
- **`dead EXIT=non-zero`** → review failed (error, crash, no scope match). The text following the exit line describes what went wrong. Report the failure.
- **`FRESHPID` is empty or `fresheyes-progress.sh` returns only `0`** → the review never started. The launch likely failed silently. Check stderr from the launch call.

### Step 7: Report results

Output the review response exactly as returned.

## Parallel reviews

Multiple fresheyes reviews can run simultaneously. Each invocation gets its own PID and its own `.active.$PID` file — they never collide. To run two reviews in parallel, save each `FRESHPID` under a distinct variable and poll them separately.

## Common Mistakes

- **Forgetting to commit** — The reviewer only sees committed code. Uncommitted changes are invisible.
- **Biasing the reviewer on your own initiative** — If the user just said "review src/auth/ with fresh eyes", don't editorialize the scope into "review src/auth/ for security issues." But if the user *asked* for a security review, pass that through faithfully.
- **Vague scope** — "Check our recent work" means nothing to a reviewer with no conversation context. Be specific: which commits, files, or diffs.
- **Including provider in scope** — "Review using claude the staged changes" passes "using claude" as scope text. Provider goes as a flag (`--claude`), not in the scope string.
- **Not polling** — The review takes 5-30 minutes. You must poll every 2 minutes until it completes.
- **Doing it yourself** — either use the process here, or notify the user. Do not try a different approach.
- **Opening the log** — Do not read, cat, tail, or grep the log file. Interact only through fresheyes-progress.sh and kill -0.
