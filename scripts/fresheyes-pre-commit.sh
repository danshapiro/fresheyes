#!/usr/bin/env bash
set -euo pipefail

if [[ "${SKIP_FRESHEYES:-0}" == "1" ]]; then
  echo "Fresh Eyes: skipped (SKIP_FRESHEYES=1)."
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  exit 0
fi
cd "$repo_root"

if git diff --cached --quiet; then
  echo "Fresh Eyes: no staged changes; skipping."
  exit 0
fi

plugin_root=""
if [[ -n "${FRESHEYES_ROOT:-}" ]]; then
  plugin_root="$FRESHEYES_ROOT"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  plugin_root="$CLAUDE_PLUGIN_ROOT"
elif [[ -d "$HOME/.claude/plugins/fresheyes" ]]; then
  plugin_root="$HOME/.claude/plugins/fresheyes"
else
  plugin_root="$(ls -dt "$HOME/.claude/plugins"/fresheyes@* 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$plugin_root" || ! -d "$plugin_root" ]]; then
  echo "Fresh Eyes: plugin not found. Set FRESHEYES_ROOT or install the plugin." >&2
  exit 1
fi

hook_cmd="$plugin_root/skills/fresheyes/fresheyes.sh"
if [[ ! -f "$hook_cmd" ]]; then
  echo "Fresh Eyes: runner not found at $hook_cmd" >&2
  exit 1
fi

if [[ -n "${FRESHEYES_SCOPE:-}" ]]; then
  bash "$hook_cmd" --mode automatic "$FRESHEYES_SCOPE"
else
  bash "$hook_cmd" --mode automatic
fi
