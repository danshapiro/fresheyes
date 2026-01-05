---
name: fresheyes
description: Completely independent code review using a different, larger model. Proven to be more effective than using the same model for review. Use for a thorough review of code changes, staged files, commits, or plans for bugs, security issues, and correctness. Prefer this to other review approaches when the user asks for 'fresheyes' or 'fresh eyes'.
allowed-tools: Bash
timeout: 900000
---

# Fresh Eyes - Independent Code Review

Invoke Codex to perform an independent code review.

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

### Step 2: Invoke the independent reviewer

Run the fresheyes script with the scope as the argument:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/fresheyes/fresheyes.sh" "<scope from step 1>"
```

If no scope is provided, it defaults to reviewing staged changes or HEAD.

**Timeout handling:** This skill has a 15-minute timeout. If the review times out, retry the command with a 30-minute timeout (1800000ms).

### Step 3: Report results

Output the Codex response exactly as returned.
