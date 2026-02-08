---
name: fresheyes
description: Fresheyes provides code review from an independent model. Use when the user asks for fresh eyes. Commit all changes before invoking - fresheyes uses git diff and only sees committed code.
allowed-tools: Bash
timeout: 900000
---

# Fresh Eyes - Independent Code Review

Invoke an independent model to perform a code review.

## Instructions

### Step 1: Determine the review scope

{{#if args}}
Use the provided scope: {{args}}
{{else}}
Default scope: "Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
{{/if}}

The scope should be a clear, specific instruction telling the reviewer what to examine.

**Good scope examples:**
- `Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit.`
- `Review commit abc1234 using git show abc1234.`
- `Review the files in src/auth/.`
- `Review the plan in docs/plans/2025-01-03-feature.md.`
- `Review the changes between main and this branch using git diff main...HEAD.`

**Bad scope examples:**
- `check out what we just did` (the reviewer has no context for what has happened other than the repo and what you tell it)
- `review the files in src/auth/ for security issues` (NEVER describe what to look for - the reviewer has independence)

### Step 2: Choose a provider

If the user does not specify a provider, default to a **different model family** from yourself — model diversity improves review quality. If you are a Claude model, use `--gpt`. If you are a GPT/Codex model, use `--claude`. If the user explicitly requests a provider (e.g. "review with fresh eyes using gpt", "use claude for the review"), honor that and pass `--gpt` or `--claude` accordingly. The provider keyword should NOT be included in the scope text — it controls which model runs the review, not what to review.

### Step 3: Invoke the independent reviewer

Run the fresheyes script with the provider flag and scope as arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/fresheyes/fresheyes.sh" [--gpt|--claude] "<scope from step 1>"
```

If no scope is provided, it defaults to reviewing staged changes or HEAD.

**Timeout handling:** This skill has a 15-minute timeout. If the review times out, retry the command with a 30-minute timeout (1800000ms).

### Step 4: Report results

Output the review response exactly as returned.
