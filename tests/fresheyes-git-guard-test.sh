#!/usr/bin/env bash
# Tests for fresheyes-git-guard.sh, the Claude reviewer's `git`, against the
# real git in a throwaway repository whose own config names an external diff,
# a textconv driver, an fsmonitor hook, a merge driver and a signature
# verifier, each of which leaves a marker file when it runs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_DIR/skills/fresheyes/fresheyes-git-guard.sh"
REAL_GIT="$(command -v git)"
# The caller's own git config (a signing format, a helper) must not decide
# what the fixture does.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fresheyes-git-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

REPO="$TMP_DIR/repo"
MARK="$TMP_DIR/marks"
mkdir -p "$REPO" "$MARK"
helper() { # helper <name>: a program that leaves $MARK/<name> when it runs
  printf '#!/bin/sh\ntouch %q\n' "$MARK/$1" > "$TMP_DIR/$1"
  chmod +x "$TMP_DIR/$1"
}
helper ext-diff
helper textconv
helper fsmonitor
helper env-ext-diff
helper merge-driver
# A signer that git accepts, so the fixture can hold a signed commit, and a
# verifier that leaves a marker.
cat > "$TMP_DIR/signer" <<'SIGNER'
#!/bin/sh
cat >/dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----\n'
SIGNER
chmod +x "$TMP_DIR/signer"
helper verifier
(
  cd "$REPO"
  git init -q -b main
  git config user.email t@example.com
  git config user.name t
  # A merge that needs a content merge of m.txt, which its attributes give to
  # the marker merge driver.
  printf 'a\nb\nc\n' > m.txt
  printf 'm.txt merge=marker\n' > .gitattributes
  git add m.txt .gitattributes
  git commit -qm base
  git config merge.marker.driver "$TMP_DIR/merge-driver %O %A %B"
  git switch -q -c side
  printf 'A\nb\nc\n' > m.txt
  git commit -qam side
  git switch -q main
  printf 'a\nb\nC\n' > m.txt
  git commit -qam main
  git merge -q --no-edit side >/dev/null
  printf 'one\n' > f.txt
  printf 'm.txt merge=marker\n*.txt diff=marker\n' > .gitattributes
  git add f.txt .gitattributes
  git -c gpg.format=openpgp -c gpg.program="$TMP_DIR/signer" commit -qS -m init
  printf 'two\n' >> f.txt
  git config diff.external "$TMP_DIR/ext-diff"
  git config diff.marker.textconv "$TMP_DIR/textconv"
  git config core.fsmonitor "$TMP_DIR/fsmonitor"
  git config gpg.program "$TMP_DIR/verifier"
  # Turns a plain -m into a remerge diff; the guard overrides it.
  git config log.diffMerges remerge
)
MERGE="$(cd "$REPO" && git rev-parse HEAD^)"

# A second repository with a populated submodule whose gitlink changed, and an
# external diff in the submodule's own config.
SUPER="$TMP_DIR/super"
helper sub-ext-diff
(
  mkdir -p "$TMP_DIR/subsrc" && cd "$TMP_DIR/subsrc"
  git init -q && git config user.email t@example.com && git config user.name t
  printf 'x\n' > s.txt && git add s.txt && git commit -qm s1
  mkdir -p "$SUPER" && cd "$SUPER"
  git init -q && git config user.email t@example.com && git config user.name t
  git -c protocol.file.allow=always submodule -q add "$TMP_DIR/subsrc" sub
  git commit -qm add-sub
  cd sub && git config user.email t@example.com && git config user.name t
  printf 'y\n' >> s.txt && git commit -qam s2
  git config diff.external "$TMP_DIR/sub-ext-diff"
  cd .. && git commit -qam bump-sub
)

guard() { # runs the guard in the repo; prints stdout, returns git's status
  (cd "$REPO" && bash "$GUARD" "$REAL_GIT" "$@" 2>"$TMP_DIR/stderr")
}

no_marks() { [[ -z "$(ls -A "$MARK")" ]]; }

expect_ok() {
  local name="$1"; shift
  rm -f "$MARK"/*
  local out rc=0
  out="$(guard "$@")" || rc=$?
  if [[ "$rc" -eq 0 ]] && no_marks; then
    pass "$name"
  else
    fail "$name (rc=$rc marks=$(ls "$MARK" | tr '\n' ' ') stderr=$(cat "$TMP_DIR/stderr"))"
  fi
  LAST_OUT="$out"
}

expect_refused() {
  local name="$1"; shift
  rm -f "$MARK"/* "$TMP_DIR"/pwned*
  local rc=0
  guard "$@" >/dev/null || rc=$?
  if [[ "$rc" -eq 128 ]] && no_marks && ! ls "$TMP_DIR"/pwned* "$REPO"/pwned* >/dev/null 2>&1 \
    && grep -q 'fresheyes: refused' "$TMP_DIR/stderr"; then
    pass "$name"
  else
    fail "$name (rc=$rc marks=$(ls "$MARK" | tr '\n' ' ') stderr=$(cat "$TMP_DIR/stderr"))"
  fi
}

# The fixture is live: without the guard, the repo's own config runs helpers.
rm -f "$MARK"/*
(cd "$REPO" && git diff >/dev/null 2>&1 || true)
[[ -e "$MARK/ext-diff" ]] && pass "fixture: plain git diff runs the configured external diff" \
  || fail "fixture: plain git diff did not run the configured external diff"
fixture_live() { # fixture_live <marker> <git args...>: plain git runs that helper
  local mark="$1"; shift
  rm -f "$MARK"/*
  (cd "$REPO" && git "$@" >/dev/null 2>&1 || true)
  [[ -e "$MARK/$mark" ]] && pass "fixture: plain git $* runs the $mark" \
    || fail "fixture: plain git $* did not run the $mark"
}
fixture_live verifier log -1 --format=%G?
fixture_live merge-driver log --remerge-diff -1 "$(cd "$REPO" && git rev-parse HEAD^)"
fixture_live merge-driver log -m -p -1 "$(cd "$REPO" && git rev-parse HEAD^)"
rm -f "$MARK"/*
(cd "$SUPER" && git diff --submodule=diff HEAD~1 HEAD >/dev/null 2>&1 || true)
[[ -e "$MARK/sub-ext-diff" ]] && pass "fixture: plain git diff --submodule=diff runs the submodule's external diff" \
  || fail "fixture: --submodule=diff did not run the submodule's external diff"
printf 'keep\n' > "$TMP_DIR/victim"
(cd "$REPO" && git diff --no-index -S -- --output="$TMP_DIR/victim" /dev/null /dev/null >/dev/null 2>&1 || true)
[[ ! -s "$TMP_DIR/victim" ]] && pass "fixture: plain git lets -S consume -- and truncates the --output= file" \
  || fail "fixture: -S -- --output= did not truncate the file"
rm -f "$TMP_DIR/victim" "$MARK"/*

# Read-only commands run, with every helper off.
expect_ok "diff runs" diff
[[ "$LAST_OUT" == *"+two"* ]] && pass "diff shows the change itself, not a helper's output" \
  || fail "diff output was: $LAST_OUT"
expect_ok "diff --text (an exact option, not an abbreviation of --textconv)" diff --text
expect_ok "diff --stat with a pathspec" diff --stat -- f.txt
expect_ok "log --format=%G? (the verifier is a no-op)" log -1 --format=%G?
[[ "$LAST_OUT" != "G" ]] && pass "an unverified signature does not read as good" \
  || fail "%G? printed G with the verifier replaced"
expect_ok "show --pretty=format:%GG" show -s --pretty=format:%GG HEAD
expect_ok "log -m -p of a merge" log -m -p -1 "$MERGE"
expect_ok "show HEAD" show HEAD
expect_ok "log -p -1" log -p -1
expect_ok "status" status
expect_ok "-C <dir> diff" -C "$REPO" diff
expect_ok "Claude Code's own -c settings" -c core.hooksPath=/dev/null -c core.fsmonitor= \
  -c hook.pre-commit.enabled=false --no-optional-locks log --oneline -n 5
expect_ok "config <key> reads" config user.name
[[ "$LAST_OUT" == "t" ]] && pass "config <key> prints the value" || fail "config user.name printed: $LAST_OUT"
expect_ok "remote with no arguments" remote
expect_ok "ls-files" ls-files
expect_ok "--version" --version

# Writing options and helper switches are refused, abbreviations included.
expect_refused "diff --output=<file>" diff --output="$TMP_DIR/pwned"
expect_refused "diff --output <file>" diff --output "$TMP_DIR/pwned"
expect_refused "diff --outp=<file> (abbreviation)" diff --outp="$TMP_DIR/pwned"
expect_refused "log -p --output=<file>" log -p --output="$TMP_DIR/pwned"
expect_refused "show --output=<file>" show --output="$TMP_DIR/pwned" HEAD
printf 'keep\n' > "$TMP_DIR/pwned-victim"
rc=0
guard diff --no-index -S -- --output="$TMP_DIR/pwned-victim" /dev/null /dev/null >/dev/null || rc=$?
if [[ "$rc" -eq 128 && "$(cat "$TMP_DIR/pwned-victim")" == "keep" ]]; then
  pass "-S consuming -- cannot smuggle --output= past the guard"
else
  fail "-S -- --output= (rc=$rc, victim now: $(cat "$TMP_DIR/pwned-victim"))"
fi
rm -f "$TMP_DIR/pwned-victim"
expect_refused "--output= after -- is refused too" diff -- --output="$TMP_DIR/pwned"
expect_refused "log --remerge-diff" log --remerge-diff -1 "$MERGE"
expect_refused "show --remer (abbreviation)" show --remer "$MERGE"
expect_refused "log --diff-merges=remerge" log --diff-merges=remerge -1 "$MERGE"
expect_refused "log --diff-merges r" log --diff-merges r -1 "$MERGE"
expect_refused "log --diff-m=r (abbreviation)" log --diff-m=r -1 "$MERGE"
expect_refused "diff --ext-diff" diff --ext-diff
expect_refused "status --help (git help can run a man viewer)" status --help
expect_refused "log --hel (abbreviation)" log --hel
super_guard() { (cd "$SUPER" && bash "$GUARD" "$REAL_GIT" "$@" >/dev/null 2>"$TMP_DIR/stderr"); }
rm -f "$MARK"/*; rc=0; super_guard diff --submodule=diff HEAD~1 HEAD || rc=$?
[[ "$rc" -eq 128 ]] && no_marks && pass "diff --submodule=diff" || fail "diff --submodule=diff (rc=$rc)"
rm -f "$MARK"/*; rc=0; super_guard diff --submod=diff HEAD~1 HEAD || rc=$?
[[ "$rc" -eq 128 ]] && no_marks && pass "diff --submod=diff (abbreviation)" || fail "diff --submod=diff (rc=$rc)"
(cd "$SUPER" && git config diff.submodule diff)
rm -f "$MARK"/*; rc=0; super_guard diff HEAD~1 HEAD || rc=$?
[[ "$rc" -eq 0 ]] && no_marks && pass "diff.submodule=diff in the config is overridden" \
  || fail "diff under diff.submodule=diff (rc=$rc marks=$(ls "$MARK" | tr '\n' ' '))"
rm -f "$MARK"/*; rc=0; super_guard diff --submodule=log HEAD~1 HEAD || rc=$?
[[ "$rc" -eq 0 ]] && no_marks && pass "diff --submodule=log runs" || fail "diff --submodule=log (rc=$rc)"
expect_refused "diff --ext (abbreviation)" diff --ext
expect_refused "log -p --textconv" log -p --textconv
expect_refused "log --show-signature" log --show-signature
expect_refused "-c diff.external=<program>" -c diff.external="$TMP_DIR/ext-diff" diff
expect_refused "--config-env" --config-env=diff.external=X diff
expect_refused "--exec-path" --exec-path="$TMP_DIR" diff
expect_refused "-p (paginate)" -p diff
expect_refused "config <key> <value> writes" config user.name x
expect_refused "config --unset" config --unset user.name
expect_refused "remote add" remote add x "$TMP_DIR"
expect_refused "commit" commit -qam x
expect_refused "checkout" checkout -- f.txt
expect_refused "fetch" fetch
expect_refused "no subcommand"

# Environment that names a helper or a file to write is scrubbed.
rm -f "$MARK"/*
rc=0
(cd "$REPO" && GIT_EXTERNAL_DIFF="$TMP_DIR/env-ext-diff" GIT_TRACE="$TMP_DIR/pwned-trace" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0="$TMP_DIR/env-ext-diff" \
  bash "$GUARD" "$REAL_GIT" diff >/dev/null 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]] && no_marks && [[ ! -e "$TMP_DIR/pwned-trace" ]]; then
  pass "GIT_EXTERNAL_DIFF, GIT_TRACE and GIT_CONFIG_* are scrubbed"
else
  fail "environment scrub (rc=$rc marks=$(ls "$MARK" | tr '\n' ' '))"
fi

# A partial clone: plain git fetches a missing blob on demand, the guard does
# not. With git 2.45.2 or later GIT_NO_LAZY_FETCH stops the fetch; with an
# older git the guard refuses to run in a partial clone.
PSRC="$TMP_DIR/psrc"
(
  mkdir -p "$PSRC" && cd "$PSRC"
  git init -q && git config user.email t@example.com && git config user.name t
  git config uploadpack.allowFilter true
  printf 'blob\n' > b.txt && git add b.txt && git commit -qm b
)
git clone -q --no-checkout --filter=blob:none "file://$PSRC" "$TMP_DIR/pclone" 2>/dev/null
git clone -q --no-checkout --filter=blob:none "file://$PSRC" "$TMP_DIR/pclone-plain" 2>/dev/null
(cd "$TMP_DIR/pclone-plain" && git show HEAD:b.txt >/dev/null 2>&1) \
  && pass "fixture: plain git show in a partial clone fetches the missing blob" \
  || fail "fixture: plain git show did not fetch the missing blob"
before="$(cd "$TMP_DIR/pclone" && find .git/objects -type f | sort)"
rc=0
(cd "$TMP_DIR/pclone" && bash "$GUARD" "$REAL_GIT" show HEAD:b.txt >/dev/null 2>"$TMP_DIR/stderr") || rc=$?
after="$(cd "$TMP_DIR/pclone" && find .git/objects -type f | sort)"
if [[ "$rc" -ne 0 && "$before" == "$after" ]]; then
  pass "a partial clone's missing blob is not fetched ($(grep -q 'partial clone' "$TMP_DIR/stderr" && echo refused || echo GIT_NO_LAZY_FETCH))"
else
  fail "partial clone (rc=$rc; objects changed: $([[ "$before" == "$after" ]] && echo no || echo yes))"
fi
# An older git is refused in a partial clone: a fake git that reports 2.45.1
# and passes everything else to the real one.
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "git version 2.45.1"; exit 0; }\nexec %q "$@"\n' "$REAL_GIT" > "$TMP_DIR/old-git"
chmod +x "$TMP_DIR/old-git"
rc=0
(cd "$TMP_DIR/pclone" && bash "$GUARD" "$TMP_DIR/old-git" log --oneline -1 >/dev/null 2>"$TMP_DIR/stderr") || rc=$?
[[ "$rc" -eq 128 ]] && grep -q 'partial clone' "$TMP_DIR/stderr" \
  && pass "git older than 2.45.2: refused in a partial clone" || fail "old git in a partial clone: rc=$rc"
rc=0
(cd "$REPO" && bash "$GUARD" "$TMP_DIR/old-git" log --oneline -1 >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 0 ]] && pass "git older than 2.45.2: runs in a full clone" || fail "old git in a full clone: rc=$rc"

# A guard started without a real git refuses everything.
rc=0
(cd "$REPO" && bash "$GUARD" "" diff >/dev/null 2>&1) || rc=$?
[[ "$rc" -eq 128 ]] && pass "no real git: refused" || fail "no real git: rc=$rc"

# Nothing above wrote to the repository's tracked files or config.
if [[ -z "$(cd "$REPO" && git -c core.fsmonitor=false status --porcelain --untracked-files=all | grep -v '^ M f.txt$' || true)" ]] \
  && [[ "$(cd "$REPO" && git config user.name)" == "t" ]] \
  && ! (cd "$REPO" && git remote | grep -q .); then
  pass "the repository is unchanged"
else
  fail "the repository changed: $(cd "$REPO" && git status --porcelain --untracked-files=all)"
fi

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
