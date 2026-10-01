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
npm install -g @anthropic-ai/claude-code@latest
```

GPT-6 Sol requires Codex CLI 0.153.1 or newer; GPT-6.1 Sol (`gpt-6.1-sol`) requires 0.159.1 or newer, the release that added it to the Codex catalog (an older CLI fails later with a misleading "not supported when using Codex with a ChatGPT account" 400). Manual GPT reviews use GPT-6 Sol with Extra High reasoning by default; automatic reviews use Sol with Medium reasoning. Set `FRESHEYES_REASONING` (`low`, `medium`, `high`, or `xhigh`) to change the manual-review reasoning level for either provider; a manual review at `high` reaches the same verdicts in noticeably fewer model calls, which matters when reviews run against a metered plan. Set `FRESHEYES_CODEX_IGNORE_USER_CONFIG=1` to launch the Codex reviewer with `--ignore-user-config`, so none of your `config.toml` (hooks, plugins, service tier, model overrides) reaches the review; leave it unset if your config.toml defines the model provider the reviewer needs. Set `FRESHEYES_VERSION_PROBE_TIMEOUT` (seconds, 20 by default) to change how long the prerequisite `codex --version` / `claude --version` probe may take before the launch fails with a named error; raise it on a slow host, and note that a probe that never answers at all is usually the CLI being blocked outside itself rather than a slow one. If the default errors for you because your plan does not include GPT-6 Sol, add `export FRESHEYES_GPT_MODEL=gpt-5.6-sol` to your shell profile, or on Free or Go use `export FRESHEYES_GPT_MODEL=gpt-5.6-terra`, so both manual and automatic reviews use a GPT-5.6 model your plan includes.

Claude Opus 5.5 requires Claude Code 2.1.280 or newer. Manual Claude reviews use Opus 5.5 with Extra High reasoning by default; automatic reviews use Opus 5.5 with Medium reasoning. Set `FRESHEYES_CLAUDE_MODEL` (for example `claude-fable-5-1`) to use a different Claude model.

The Claude reviewer runs read-only: it can read files and run `git diff`, `git show`, `git log` and `git status`, and it cannot edit files or run other programs. It does not load your Claude Code settings, hooks, plugins or MCP servers, so it needs a logged-in CLI; an `apiKeyHelper` or `env` block in `settings.json` is ignored.

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
