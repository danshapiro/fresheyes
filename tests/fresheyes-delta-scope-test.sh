#!/usr/bin/env bash
# --since <commit> (a delta scope against the last reviewed head) and
# --rebuttals <file> (findings the caller declined, with its reasons).
# Upstream issue #19.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS_SCRIPT="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
REPO="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$REPO"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "$FAKE_BIN/codex" <<'PY'
#!/usr/bin/env python3
import os
import re
import sys

if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.153.4")
    raise SystemExit(0)

if not sys.stdin.isatty():
    sys.stdin.read()

prompt = sys.argv[-1]
with open(os.environ["FRESHEYES_FAKE_ARGV"], "w", encoding="utf-8") as handle:
    handle.write(prompt)

found = re.search(r"FRESHEYES-RUN:\s*([A-Za-z0-9][A-Za-z0-9._-]*)", prompt)
output_path = sys.argv[sys.argv.index("-o") + 1]
with open(output_path, "w", encoding="utf-8") as handle:
    handle.write("## Files Examined\n- a.txt\n")
    handle.write("INDEPENDENT CODE REVIEW PASSED\n")
    if found:
        handle.write("FRESHEYES-RUN: %s\n" % found.group(1))
PY
chmod +x "$FAKE_BIN/codex"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'one\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm first
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'two\n' >> "$REPO/a.txt"
git -C "$REPO" commit -qam second
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# run_review <name> <args...>: runs the runner in the repo with the fake codex,
# detaching (when the args do) through $RUN_DETACH, setsid by default. Leaves the exit status in $status and the files named
# for <name> under $TEST_TMP.
run_review() {
  local name="$1"
  shift
  rm -f "$TEST_TMP/$name.prompt"
  set +e
  (
    cd "$REPO" &&
      PATH="$FAKE_BIN:$PATH" \
      FRESHEYES_FAKE_ARGV="$TEST_TMP/$name.prompt" \
      FRESHEYES_LOG_DIR="$TEST_TMP/$name-logs" \
      FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/$name-global-logs" \
      FRESHEYES_GPT_MODEL= \
      FRESHEYES_MODEL= \
      FRESHEYES_REASONING= \
      FRESHEYES_PROVIDER= \
      FRESHEYES_MODE= \
      FRESHEYES_DETACH="${RUN_DETACH:-setsid}" \
      timeout 30s bash "$RUNNER" "$@" </dev/null
  ) >"$TEST_TMP/$name.stdout" 2>"$TEST_TMP/$name.stderr"
  status=$?
  set -e
}

status_file_of() {
  local name="$1"
  ls "$TEST_TMP/$name-logs"/fresheyes-*.log.status.json 2>/dev/null | head -n 1
}

# --- 1. --since builds a two-dot delta scope from full commit ids ---
run_review since --foreground --gpt --since HEAD~1
[[ "$status" -eq 0 ]] || { cat "$TEST_TMP/since.stderr" >&2; fail "--since run exited $status"; }
[[ -s "$TEST_TMP/since.prompt" ]] || fail "--since run never launched the reviewer"
grep -Fq "git diff $BASE..$HEAD_SHA" "$TEST_TMP/since.prompt" \
  || fail "--since prompt does not name the two-dot diff git diff $BASE..$HEAD_SHA"
if grep -Fq "$BASE...$HEAD_SHA" "$TEST_TMP/since.prompt"; then
  fail "--since prompt uses a three-dot diff"
fi
if grep -Fq "Review the staged changes" "$TEST_TMP/since.prompt"; then
  fail "--since prompt still carries the default staged-changes scope"
fi
if grep -Fq "### Standing Rebuttals" "$TEST_TMP/since.prompt"; then
  fail "a run without --rebuttals carries a rebuttals section"
fi

# --- 2. the run records what it reviewed, and the poller reports it ---
since_status="$(status_file_of since)"
[[ -n "$since_status" ]] || fail "--since run wrote no status file"
python3 - "$since_status" "$BASE" "$HEAD_SHA" <<'PY'
import json
import sys

path, base, head = sys.argv[1:4]
record = json.load(open(path, encoding="utf-8"))
if record.get("reviewed_base") != base:
    raise SystemExit(f"FAIL: status reviewed_base {record.get('reviewed_base')!r}, want {base!r}")
if record.get("reviewed_head") != head:
    raise SystemExit(f"FAIL: status reviewed_head {record.get('reviewed_head')!r}, want {head!r}")
PY
since_handle="$(basename "$since_status")"
since_handle="${since_handle#fresheyes-}"
since_handle="${since_handle%.log.status.json}"
set +e
poll="$(FRESHEYES_LOG_DIR="$TEST_TMP/since-logs" FRESHEYES_GLOBAL_LOG_DIR="$TEST_TMP/since-global-logs" \
  bash "$PROGRESS_SCRIPT" --json "$since_handle")"
set -e
python3 - "$poll" "$HEAD_SHA" <<'PY'
import json
import sys

record = json.loads(sys.argv[1])
if record.get("reviewed_head") != sys.argv[2]:
    raise SystemExit(f"FAIL: --json does not report reviewed_head: {record!r}")
PY

# A run without --since claims no reviewed head.
run_review plain --foreground --gpt "Review a.txt."
[[ "$status" -eq 0 ]] || fail "plain run exited $status"
if grep -q reviewed_head "$(status_file_of plain)"; then
  fail "a run without --since recorded a reviewed_head"
fi

# --- 3. --since refusals: each exits non-zero and launches nothing ---
expect_refusal() {
  local name="$1" needle="$2"
  shift 2
  run_review "$name" "$@"
  [[ "$status" -ne 0 ]] || fail "$name: expected a refusal, got exit 0"
  [[ ! -e "$TEST_TMP/$name.prompt" ]] || fail "$name: the reviewer was launched"
  grep -Fq -- "$needle" "$TEST_TMP/$name.stderr" \
    || { cat "$TEST_TMP/$name.stderr" >&2; fail "$name: stderr does not say: $needle"; }
}

expect_refusal since-no-value "--since requires a commit" --foreground --gpt --since
# An empty value is a caller whose variable was unset, not a request for the
# default scope.
expect_refusal since-empty-value "--since requires a commit" --foreground --gpt --since "" "Review a.txt."
expect_refusal since-bad-ref "is not a commit" --foreground --gpt --since no-such-ref
expect_refusal since-empty "nothing to review" --foreground --gpt --since HEAD
expect_refusal since-with-scope "builds the scope itself" --foreground --gpt --since HEAD~1 "Review a.txt."
expect_refusal since-automatic "manual reviews only" --gpt --automatic --since HEAD~1

# --- 4. --rebuttals puts the file into the prompt as standing rebuttals ---
REBUTTALS="$TEST_TMP/rebuttals.md"
cat > "$REBUTTALS" <<'EOF'
- Finding: a.txt has two lines. Rebuttal: it is meant to; see the README.
- Literal placeholders stay literal: {{REVIEW_SCOPE}} {{RUN_HANDLE}}
EOF
run_review rebut --foreground --gpt --since HEAD~1 --rebuttals "$REBUTTALS"
[[ "$status" -eq 0 ]] || { cat "$TEST_TMP/rebut.stderr" >&2; fail "--rebuttals run exited $status"; }
grep -Fq "### Standing Rebuttals" "$TEST_TMP/rebut.prompt" || fail "no rebuttals section in the prompt"
grep -Fq "Rebuttal: it is meant to; see the README." "$TEST_TMP/rebut.prompt" \
  || fail "the rebuttals file's text is not in the prompt"
grep -Fq "new evidence" "$TEST_TMP/rebut.prompt" || fail "the prompt does not ask for new evidence"
# The file is substituted in one pass: placeholders inside it are not expanded.
grep -Fq "Literal placeholders stay literal: {{REVIEW_SCOPE}} {{RUN_HANDLE}}" "$TEST_TMP/rebut.prompt" \
  || fail "placeholders inside the rebuttals file were expanded"
grep -Fq "git diff $BASE..$HEAD_SHA" "$TEST_TMP/rebut.prompt" || fail "--rebuttals lost the --since scope"

# --rebuttals works with an ordinary scope too.
run_review rebut-scope --foreground --gpt --rebuttals "$REBUTTALS" "Review a.txt."
[[ "$status" -eq 0 ]] || fail "--rebuttals with a scope exited $status"
grep -Fq "Review a.txt." "$TEST_TMP/rebut-scope.prompt" || fail "--rebuttals dropped the scope text"
grep -Fq "Rebuttal: it is meant to" "$TEST_TMP/rebut-scope.prompt" || fail "--rebuttals with a scope lost the file"

: > "$TEST_TMP/empty.md"
expect_refusal rebut-no-value "--rebuttals requires a file" --foreground --gpt --rebuttals
expect_refusal rebut-empty-value "--rebuttals requires a file" --foreground --gpt --rebuttals "" "Review a.txt."
expect_refusal rebut-missing "cannot read the rebuttals file" --foreground --gpt --rebuttals "$TEST_TMP/missing.md" "Review a.txt."
expect_refusal rebut-empty "is empty" --foreground --gpt --rebuttals "$TEST_TMP/empty.md" "Review a.txt."
expect_refusal rebut-automatic "manual reviews only" --gpt --automatic --rebuttals "$REBUTTALS"

# --- 5. a detached review keeps the commits the parent resolved ---
# A fake git holds a detached child at its first git call until the test has
# moved HEAD. A child that re-resolves --since therefore sees the new HEAD,
# every time; a child that takes the parent's commits never calls git.
REAL_GIT="$(command -v git)"
RELEASE="$TEST_TMP/release-child-git"
cat > "$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\${FRESHEYES_DAEMONIZED:-0}" == "1" ]]; then
  for _ in \$(seq 1 100); do
    [[ -e "$RELEASE" ]] && break
    sleep 0.1
  done
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKE_BIN/git"

# A fake systemd-run: runs the unit's command in the background with only the
# --setenv environment, as a transient unit would.
cat > "$FAKE_BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
child_env=()
cmd=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setenv) child_env+=("$2"); shift 2 ;;
    --user|--collect|--quiet|--wait|--property=*) shift ;;
    *) cmd+=("$1"); shift ;;
  esac
done
[[ ${#cmd[@]} -gt 0 ]] || exit 1
env -i "${child_env[@]}" "${cmd[@]}" </dev/null >/dev/null 2>&1 &
exit 0
EOF
chmod +x "$FAKE_BIN/systemd-run"

check_detached_pin() {
  local method="$1"
  local name="detached-$method"
  local base head handle
  base="$(git -C "$REPO" rev-parse HEAD~1)"
  head="$(git -C "$REPO" rev-parse HEAD)"
  rm -f "$RELEASE"
  RUN_DETACH="$method" run_review "$name" --gpt --since HEAD~1 --rebuttals "$REBUTTALS"
  [[ "$status" -eq 0 ]] || { cat "$TEST_TMP/$name.stderr" >&2; fail "$name: launch exited $status"; }
  handle="$(sed -n 's/^FRESHPID=//p' "$TEST_TMP/$name.stdout")"
  [[ -n "$handle" ]] || fail "$name: no FRESHPID"
  printf '%s\n' "$method" >> "$REPO/a.txt"
  git -C "$REPO" commit -qam "moved during $method"
  : > "$RELEASE"
  for _ in $(seq 1 150); do
    grep -q '"state":"complete"' "$TEST_TMP/$name-logs/fresheyes-$handle.log.status.json" 2>/dev/null && break
    sleep 0.1
  done
  [[ -s "$TEST_TMP/$name.prompt" ]] || fail "$name: the detached review never launched the reviewer"
  grep -Fq "git diff $base..$head" "$TEST_TMP/$name.prompt" \
    || fail "$name: the detached child did not review the commits the parent resolved ($base..$head)"
  grep -Fq "Rebuttal: it is meant to" "$TEST_TMP/$name.prompt" || fail "$name: the detached child lost the rebuttals"
  grep -q "\"reviewed_head\":\"$head\"" "$TEST_TMP/$name-logs/fresheyes-$handle.log.status.json" \
    || fail "$name: status.json does not record the parent's reviewed_head"
}

if command -v setsid >/dev/null 2>&1; then
  check_detached_pin setsid
else
  printf 'skip: detached --since check through setsid (no setsid)\n'
fi
check_detached_pin systemd-run

printf 'fresheyes delta scope tests passed\n'
