# Fresh Eyes

Independent code review for Claude Code using a different model (Codex).

## Why?

Using the same model to review its own work has blind spots. Fresh Eyes sends your code to a completely independent model with no context of your conversation.

## Requirements

- [Claude Code](https://claude.ai/code)
- [Codex CLI](https://github.com/openai/codex) with access to `gpt-5.2-codex`

## Installation

```
/plugin marketplace add danshapiro/fresheyes
/plugin install fresheyes@danshapiro-fresheyes
```

## Usage

In Claude Code:

- `/fresheyes` - Review staged changes (or last commit if nothing staged)
- `/fresheyes Review commit abc1234` - Review a specific commit
- `/fresheyes Review the files in src/auth/` - Review specific files

## License

MIT
