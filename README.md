# Fresh Eyes

Independent code review for Claude Code using a different model (Codex).

## Why?

Using the same model to review its own work has blind spots. Fresh Eyes sends your code to a completely independent model with no context of your conversation.

## Prerequisites

1. **Codex CLI** - Install the OpenAI Codex CLI:
   ```bash
   npm install -g @openai/codex
   ```

2. **OpenAI API Key** - Get a key from https://platform.openai.com/api-keys and set it:
   ```bash
   export OPENAI_API_KEY='your-key-here'
   ```
   Add this to your shell profile (~/.bashrc, ~/.zshrc) to persist it.

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
