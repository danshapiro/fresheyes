# Fresh Eyes

Independent code review using a different AI model behind the curtain.

## Why?

Using the same model to review its own work has blind spots. Fresh Eyes sends your code to a completely independent model with zero context from your conversation — only the repo and the scope you give it. Model diversity improves correctness, so by default the skill picks a different model family from the one invoking it.

## Prerequisites

You need at least one of the following CLIs installed:

**Codex CLI** (for GPT provider):
```bash
npm install -g @openai/codex
```

**Claude Code CLI** (for Claude provider):
```bash
npm install -g @anthropic-ai/claude-code
```

Run `codex` or `claude` to ensure the one you chose is properly set up.

## Manual Mode

In Claude Code, run:
```
/plugin marketplace add danshapiro/fresheyes
/plugin install fresheyes@danshapiro-fresheyes
```

**Important:** The reviewer only sees committed code. Commit your changes before invoking.

In Claude Code:

- `Review this with fresh eyes` - Review staged changes (or last commit if nothing staged)
- `Review commit abc1234 with fresh eyes` - Review a specific commit
- `Review the files in src/auth/ with fresh eyes` - Review specific files
- `Do a security review of src/auth/ with fresh eyes` - Scoped review (user intent passed through faithfully)
- `Review with fresh eyes using claude` - Use Claude as the reviewer
- `Review with fresh eyes using gpt` - Use GPT as the reviewer

By default, the skill picks a different model family from the one invoking it. The reviewer operates independently — it receives only the scope you give it, with no conversation context.

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

## Configuration

| Environment Variable | Description | Default |
|---|---|---|
| `FRESHEYES_PROVIDER` | Which provider to use (`gpt` or `claude`) | `gpt` |
| `FRESHEYES_MODEL` | Override the model name | `gpt-5.3-codex` (gpt) / `opus` (claude) |
| `FRESHEYES_MODE` | Review mode (`manual` or `automatic`) | `manual` |
| `SKIP_FRESHEYES` | Set to `1` to bypass pre-commit hook | unset |
| `FRESHEYES_SCOPE` | Custom scope for pre-commit hook | unset |
| `FRESHEYES_ROOT` | Override plugin root path | auto-detected |

## License

MIT
