#!/bin/bash
# The Claude reviewer's `git`. fresheyes.sh puts a shim named `git` first on the
# reviewer's PATH that runs this file with the real git as its first argument.
#
# The allow rules pre-approve any argument list after `git diff`, `git show`,
# `git log` and `git status`, and some of those arguments write or run
# programs: `--output=<file>` creates or truncates a file, and `--ext-diff`,
# `--textconv` and a configured `diff.external` run external programs. This
# guard runs git only for read-only subcommands, refuses the options that write
# or run helpers, and turns the helpers off on every call it lets through.
#
# Claude Code runs a few git commands of its own through the same PATH
# (`ls-files`, `remote get-url`, `config user.name`, a short `status` and
# `log`), each with a fixed set of `-c` settings that only switch things off.
# Those are allowed by name; everything else is refused with exit 128.
#
# Remaining limit: a filter driver (`filter.<name>.clean`, e.g. git-lfs) that
# the repository's attributes assign still runs when `git diff` reads the
# working tree.

set -u

real_git="${1:-}"
shift || true

refuse() {
  printf 'fresheyes: refused: %s. The reviewer'"'"'s git runs only read-only diff, show, log and status.\n' "$*" >&2
  exit 128
}

[[ -n "$real_git" && -x "$real_git" ]] || refuse "no git found when the review started"

# Settings Claude Code itself passes with -c; each one only disables something.
cli_config_ok() {
  case "$1" in
    core.hooksPath=/dev/null|core.fsmonitor=|core.askPass=|protocol.ext.allow=never) return 0 ;;
    submodule.recurse=false|log.showSignature=false|format.pretty=medium) return 0 ;;
    gc.auto=0|maintenance.auto=false) return 0 ;;
    hook.*.enabled=false) [[ "$1" != *[!A-Za-z0-9.=_-]* ]] && return 0 ;;
  esac
  return 1
}

global=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      [[ $# -ge 2 ]] || refuse "-C without a directory"
      global+=(-C "$2"); shift 2 ;;
    -c)
      [[ $# -ge 2 ]] || refuse "-c without a setting"
      cli_config_ok "$2" || refuse "-c $2"
      global+=(-c "$2"); shift 2 ;;
    --no-optional-locks|--no-pager)
      global+=("$1"); shift ;;
    --version)
      [[ $# -eq 1 ]] || refuse "--version $2"
      exec "$real_git" --version ;;
    -*)
      refuse "git option $1" ;;
    *)
      break ;;
  esac
done

[[ $# -gt 0 ]] || refuse "git with no subcommand"
sub="$1"
shift

# Long options that write a file, run a program or read config from elsewhere.
# --remerge-diff re-runs each merge, and a merge driver the attributes name
# runs with it; --help becomes `git help <command>`, which can run a configured
# man viewer (man.<tool>.cmd) through the shell. git accepts any unambiguous abbreviation of a long option, so a
# prefix of three or more characters counts as the option itself.
forbidden_long="output ext-diff textconv show-signature config-env exec-path open-files-in-pager remerge-diff help"

# Every argument is checked, including those after `--`: an option that takes
# a value can consume the `--` itself (`-S -- --output=<file>`), so the guard
# cannot tell where git's options end. A pathspec that looks like a forbidden
# option is refused too.
check_options() {
  local arg name word value next_is_merges=0
  for arg in "$@"; do
    if [[ "$next_is_merges" == 1 ]]; then
      next_is_merges=0
      case "$arg" in r|remerge) refuse "$sub --diff-merges $arg" ;; esac
    fi
    [[ "$arg" == --?* ]] || continue
    name="${arg#--}"
    name="${name%%=*}"
    [[ ${#name} -ge 3 ]] || continue
    # An exact option name wins over an abbreviation: --text is diff's -a.
    [[ "$name" == "text" ]] && continue
    for word in $forbidden_long; do
      [[ "$word" == "$name"* ]] && refuse "$sub $arg"
    done
    # --submodule=diff runs a child git diff for each submodule. Git puts its
    # own exec directory first on that child's PATH, so the child skips this
    # guard and its helpers are back on.
    if [[ "submodule" == "$name"* && "$arg" == *=* ]]; then
      value="${arg#*=}"
      [[ "$value" == "diff" ]] && refuse "$sub $arg"
    fi
    # --diff-merges=remerge (or r) is --remerge-diff by another name.
    if [[ ${#name} -ge 6 && "diff-merges" == "$name"* ]]; then
      if [[ "$arg" == *=* ]]; then
        value="${arg#*=}"
        case "$value" in r|remerge) refuse "$sub $arg" ;; esac
      else
        next_is_merges=1
      fi
    fi
  done
  return 0
}

case "$sub" in
  diff|show|log|status)
    check_options "$@" ;;
  ls-files|rev-parse)
    check_options "$@" ;;
  remote)
    # `remote`, `remote -v`, `remote get-url <name>`: the read forms only.
    case "${1:-}" in
      ""|-v|--verbose) [[ $# -le 1 ]] || refuse "remote $*" ;;
      get-url) [[ $# -eq 2 && "$2" != -* ]] || refuse "remote $*" ;;
      *) refuse "remote $*" ;;
    esac ;;
  config)
    # `config <key>` and `config --get <key>` read; every other form can write.
    if [[ "${1:-}" == "--get" ]]; then shift; fi
    [[ $# -eq 1 && "$1" != -* ]] || refuse "config $*"
    set -- --get "$1" ;;
  *)
    refuse "git $sub" ;;
esac

# Scrub what could point git at a helper or a file to write. GIT_TRACE* with a
# path appends to that file; GIT_CONFIG_* adds settings behind the guard's back.
while IFS= read -r var; do
  case "$var" in
    GIT_TRACE*|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$var" ;;
  esac
done < <(compgen -e)
unset GIT_EXTERNAL_DIFF GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIFF_OPTS \
  GIT_EXEC_PATH GIT_PAGER PAGER GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND \
  GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_INDEX_FILE
# GIT_NO_LAZY_FETCH: in a partial clone a read of a missing object would
# otherwise start a fetch, which writes to the object store and can run
# transport and credential helpers. git 2.45.0 introduced the variable, and
# 2.45.2 added the check that also covers diff's prefetch, so with an older git
# the guard refuses to run in a partial clone at all.
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1
version_at_least() { # version_at_least <major> <minor> <patch>
  local v major minor patch
  v="$("$real_git" --version 2>/dev/null)"
  v="${v#git version }"
  IFS=. read -r major minor patch <<<"${v%% *}"
  major="${major//[!0-9]/}"; minor="${minor//[!0-9]/}"; patch="${patch//[!0-9]/}"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  (( major != $1 )) && { (( major > $1 )); return; }
  (( minor != $2 )) && { (( minor > $2 )); return; }
  (( patch >= $3 ))
}
if ! version_at_least 2 45 2; then
  if "$real_git" ${global[@]+"${global[@]}"} config --get-regexp \
      '^(extensions\.partialclone|remote\..*\.promisor)$' >/dev/null 2>&1; then
    refuse "a partial clone with git older than 2.45.2, which can fetch missing objects"
  fi
fi

# A program that does nothing, for the signature verifiers below.
no_op=/usr/bin/false
[[ -x "$no_op" ]] || no_op=/bin/false

# Applied after the caller's -c settings, so these win. A %G placeholder in a
# --format (or a configured pretty format) verifies signatures whatever
# log.showSignature says, so each verifier is replaced by a no-op and every
# signature reads as unverified. log.diffMerges keeps -m from turning into a
# remerge diff through the config, and diff.submodule keeps a configured
# inline submodule diff (see check_options) from starting. Settings given with
# -c also reach every child git through the environment.
safety=(-c core.fsmonitor=false -c core.pager=cat -c core.hooksPath=/dev/null
  -c log.showSignature=false -c log.diffMerges=separate -c diff.submodule=short
  -c gpg.program="$no_op" -c gpg.openpgp.program="$no_op"
  -c gpg.x509.program="$no_op" -c gpg.ssh.program="$no_op" --no-pager)

case "$sub" in
  diff|show|log)
    exec "$real_git" ${global[@]+"${global[@]}"} "${safety[@]}" "$sub" --no-ext-diff --no-textconv "$@" ;;
  *)
    exec "$real_git" ${global[@]+"${global[@]}"} "${safety[@]}" "$sub" "$@" ;;
esac
