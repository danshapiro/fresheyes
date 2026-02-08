# Fresh Eyes

Independent code review for Claude Code using Codex CLI behind the curtain.

## Why?

Using the same model to review its own work has blind spots. Fresh Eyes sends your code to a completely independent model with no context of your conversation.

## Prerequisites

**Codex CLI** - Install the OpenAI Codex CLI:
```bash
npm install -g @openai/codex
```
and run `codex` to ensure it's properly set up.

## Manual Mode

In Claude Code, run:
```
/plugin marketplace add danshapiro/fresheyes
/plugin install fresheyes@danshapiro-fresheyes
```

In Claude Code:

- `Review this with fresh eyes` - Review staged changes (or last commit if nothing staged)
- `Review commit abc1234 with fresh eyes` - Review a specific commit
- `Review the files in src/auth/ with fresh eyes` - Review specific files

## Automatic Mode (pre-commit)

1. Install the plugin (same as above).
2. Run the installer from your repo root (using the plugin path):

```bash
cd /path/to/your/repo
bash ~/.claude/plugins/fresheyes/scripts/install-automatic-hook.sh
```

If your plugin directory is versioned, use that path instead:

```bash
cd /path/to/your/repo
bash ~/.claude/plugins/fresheyes@danshapiro-fresheyes/scripts/install-automatic-hook.sh
```

Optional overrides:
- `SKIP_FRESHEYES=1 git commit` to bypass.
- `FRESHEYES_SCOPE="Review the staged changes using git diff --cached."` to customize the scope.
- `FRESHEYES_ROOT=/path/to/plugin` if the hook cannot find the plugin.

Automatic mode uses medium reasoning effort and blocks the commit on blocking issues.

## License

MIT
