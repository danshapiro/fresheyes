# Fresh Eyes

Independent code review for Claude Code using a different model (Codex) to catch issues your current model might miss.

## Why?

Using the same model to review its own work has blind spots. Fresh Eyes sends your code to a completely independent model with no context of your conversation, providing genuinely fresh perspective on bugs, security issues, and correctness.

## Requirements

- [Claude Code](https://claude.com/claude-code)
- [Codex CLI](https://github.com/openai/codex) with access to `gpt-5.2-codex`

## Installation

Add the marketplace and install the plugin:

```
/plugin marketplace add danshapiro/fresheyes
/plugin install fresheyes@danshapiro-fresheyes
```

## Usage

In Claude Code, say:

- `/fresheyes` - Review staged changes (or last commit if nothing staged)
- `/fresheyes Review commit abc1234` - Review a specific commit
- `/fresheyes Review the files in src/auth/` - Review specific files
- `/fresheyes Review changes between main and HEAD` - Review branch changes

## What It Reviews

- Correctness bugs and logic errors
- Security issues (injection, XSS, auth bypasses)
- Missing edge cases and error handling
- Test coverage gaps
- Commit message accuracy

## Output

Returns a structured review with:
- List of files examined
- Issues found (critical/major/minor/nit)
- **PASSED** or **FAILED** verdict

## License

MIT
