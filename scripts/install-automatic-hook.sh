#!/usr/bin/env bash
set -euo pipefail

force=0

for arg in "$@"; do
  case "$arg" in
    --force)
      force=1
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--force]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $(basename "$0") [--force]" >&2
      exit 1
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
  echo "Fresh Eyes automatic install: no git repository detected."
  echo "Current directory: $(pwd)"
  echo "Tip: cd into your repo and re-run this installer."
  exit 1
fi

cd "$repo_root"

hooks_path="$(git config --get core.hooksPath || true)"
if [[ -n "$hooks_path" ]]; then
  if [[ "$hooks_path" = /* ]]; then
    hooks_dir="$hooks_path"
  else
    hooks_dir="$repo_root/$hooks_path"
  fi
else
  hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null || true)"
fi

if [[ -z "${hooks_dir:-}" ]]; then
  echo "Fresh Eyes automatic install: unable to locate hooks directory."
  echo "Tip: run 'git rev-parse --git-path hooks' to debug."
  exit 1
fi

if [[ -f "$hooks_dir" ]]; then
  echo "Fresh Eyes automatic install: hooks path points to a file:"
  echo "  $hooks_dir"
  echo "Tip: remove it or set core.hooksPath to a directory."
  exit 1
fi

if ! mkdir -p "$hooks_dir"; then
  echo "Fresh Eyes automatic install: unable to create hooks directory."
  echo "  $hooks_dir"
  exit 1
fi

hook_file="$hooks_dir/pre-commit"
if [[ -e "$hook_file" && "$force" -ne 1 ]]; then
  echo "Fresh Eyes automatic install: pre-commit hook already exists:"
  echo "  $hook_file"
  echo "Re-run with --force to overwrite."
  exit 1
fi

cat >"$hook_file" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${SKIP_FRESHEYES:-0}" == "1" ]]; then
  echo "Fresh Eyes: skipped (SKIP_FRESHEYES=1)."
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

runner="$plugin_root/scripts/fresheyes-pre-commit.sh"
if [[ ! -f "$runner" ]]; then
  echo "Fresh Eyes: runner not found at $runner" >&2
  exit 1
fi

FRESHEYES_ROOT="$plugin_root" exec bash "$runner"
SH

chmod +x "$hook_file"

echo "Fresh Eyes automatic install: pre-commit hook installed."
echo "Hook: $hook_file"
echo "Bypass: SKIP_FRESHEYES=1 git commit"
