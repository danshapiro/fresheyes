# Fresh Eyes

Your AI coding agent is very sure it did a good job. Adorable. Maybe it's time for a second opinion?

Fresh Eyes asks a separate LLM to look at your work. The separate agent helps because ["LLM Evaluators Recognize and Favor Their Own Generations"](https://arxiv.org/abs/2404.13076). The clean slate (no prior history) helps because LLMs with history may remember the goal more clearly than the code itself.

It's pretty simple to use. `Look at this with fresheyes.`

## Install

Install the Fresh Eyes plugin in Claude Code:

```text
/plugin marketplace add danshapiro/fresheyes
/plugin install fresheyes@danshapiro-fresheyes
```

Or Codex:

```bash
git clone https://github.com/danshapiro/fresheyes.git
mkdir -p ~/.codex/skills
cp -R fresheyes/skills/fresheyes ~/.codex/skills/
```

And, Fresh Eyes needs either Claude Code or Codex CLI to work its magic. 

```bash
npm install -g @openai/codex@latest
npm install -g @anthropic-ai/claude-code
```

GPT-5.6 requires Codex CLI 0.144.0 or newer. Manual GPT reviews use GPT-5.6 Sol with Extra High reasoning by default; automatic reviews use Sol with Medium reasoning. Sol requires a Plus or higher Codex plan. On Free or Go, add `export FRESHEYES_GPT_MODEL=gpt-5.6-terra` to your shell profile so both manual and automatic reviews use the GPT-5.6 model available on those plans.

Note that Claude reviews count against your Claude overage, not your subscription _(shakes fist at universe)_.

## How to do it:

Fresh Eyes reviews what Git can show it. So:

1. Commit the work you want reviewed.
2. Ask your agent to run Fresh Eyes.

Ask in normal language:

> Review this (plan, checkin, worktree, whatever) with fresh eyes.

Review and fix:

> Review this with fresh eyes and fix anything it finds. Repeat up to three times or until it passes.

(This is magic, and I do it all the time. Be sure to give it a limit or it could get stuck and burn all the tokens.)

For a specific folder:

> Do a security review of `src/auth/` with fresh eyes.

For a finished branch:

> Review this branch with fresh eyes, fix what comes up, and stop when it passes or after 5x turns.

For a specific reviewer:

> Review this with fresh eyes using Claude.

> Review this with fresh eyes using GPT.

You usually do not need to choose a reviewer. Fresh Eyes normally picks a different kind of model from the one already helping you. 

## What Happens Next

Your agent starts the review and waits for the result. A normal review can take a few minutes. Big branches and broad requests can take an hour.

Fresh Eyes returns a review with a clear result:

- `PASSED` means there are no blocking issues.
- `FAILED` means it found something worth fixing before you move on.

If it fails, fix the issues, commit again, and run Fresh Eyes again. If it passes, stop. A reviewer can always find small cleanup ideas if you keep asking, but a pass means the blocking problems are gone.

## When It Helps

I use Fresh Eyes most often in three places.

After writing a plan, to catch issues. 

After executing a plan (or making any sort of change), to find bugs.

Before merging, it gives the branch one more independent read.

## Optional Automatic Review

You can make Fresh Eyes run before every commit. 

```bash
cd /path/to/your/repo
bash ~/.claude/plugins/fresheyes/scripts/install-automatic-hook.sh
```

To skip the automatic review for one commit:

```bash
SKIP_FRESHEYES=1 git commit
```

## License

MIT
