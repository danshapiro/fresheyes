#!/usr/bin/env bash
# Probing the launcher must never launch a review (jibot-code#ryf1): -h/--help
# prints usage, an unknown option or a blank scope is refused, and in every one
# of those cases no provider CLI runs and no log or handle is written.
# Standalone: bash tests/fresheyes-argv-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
LOGS="$TEST_TMP/logs"
CALLS="$TEST_TMP/calls"
mkdir -p "$FAKE_BIN" "$LOGS"
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Any invocation of a fake provider CLI is recorded; the tests assert none happens.
for name in codex claude; do
  cat > "$FAKE_BIN/$name" <<SH
#!/usr/bin/env bash
echo "$name \$*" >> "$CALLS"
exit 1
SH
  chmod +x "$FAKE_BIN/$name"
done

run_runner() {
  local status=0
  OUT="$(PATH="$FAKE_BIN:$PATH" FRESHEYES_GLOBAL_LOG_DIR="$LOGS" FRESHEYES_LOG_DIR="$LOGS" \
    bash "$RUNNER" "$@" 2>&1)" || status=$?
  STATUS=$status
}

assert_nothing_launched() {
  local label="$1"
  [[ ! -e "$CALLS" ]] || fail "$label: a provider CLI ran: $(cat "$CALLS")"
  [[ -z "$(ls -A "$LOGS")" ]] || fail "$label: the log dir was written: $(ls -A "$LOGS")"
  [[ "$OUT" != *"FRESHPID="[0-9]* ]] || fail "$label: printed a FRESHPID: $OUT"
}

for flag in -h --help; do
  run_runner "$flag"
  [[ "$STATUS" -eq 0 ]] || fail "$flag: exit $STATUS, want 0: $OUT"
  [[ "$OUT" == *Usage:* ]] || fail "$flag: no usage text: $OUT"
  assert_nothing_launched "$flag"
done

# Help wins wherever it appears among the options.
run_runner --claude --help 'review HEAD'
[[ "$STATUS" -eq 0 && "$OUT" == *Usage:* ]] || fail "--claude --help: exit $STATUS: $OUT"
assert_nothing_launched "--claude --help"

for args in "--version" "-x" "--gpt --verbose review HEAD" "review --bogus"; do
  # shellcheck disable=SC2086
  run_runner $args
  [[ "$STATUS" -eq 2 ]] || fail "'$args': exit $STATUS, want 2: $OUT"
  [[ "$OUT" == *"unknown option"* ]] || fail "'$args': no unknown-option error: $OUT"
  assert_nothing_launched "'$args'"
done

assert_blank_refused() {
  local label="$1"
  shift
  run_runner --claude "$@"
  [[ "$STATUS" -eq 2 ]] || fail "$label: exit $STATUS, want 2: $OUT"
  [[ "$OUT" == *"scope text is empty"* ]] || fail "$label: no empty-scope error: $OUT"
  assert_nothing_launched "$label"
}
assert_blank_refused "one empty scope" ""
assert_blank_refused "one blank scope" "   "
# Joining several blank arguments inserts a space; that is still blank.
assert_blank_refused "two empty scopes" "" ""
assert_blank_refused "two blank scopes after --" -- " " " "

# After '--', a leading dash is scope text, and it reaches the reviewer's
# prompt verbatim. A fake claude that passes the version check records the
# prompt (its last argument) and then fails the run.
cat > "$FAKE_BIN/claude" <<SH
#!/usr/bin/env bash
if [[ "\$*" == "--version" ]]; then echo "9.9.9 (Claude Code)"; exit 0; fi
printf '%s' "\${@: -1}" > "$TEST_TMP/prompt"
exit 1
SH
run_runner --claude --foreground -- '--help is the scope'
[[ "$OUT" != *"unknown option"* && "$OUT" != *Usage:* ]] \
  || fail "'-- --help ...' was parsed as an option: $OUT"
[[ -f "$TEST_TMP/prompt" ]] || fail "'-- --help ...' never reached the reviewer: $OUT"
grep -qF -- '--help is the scope' "$TEST_TMP/prompt" \
  || fail "the prompt does not carry the scope: $(cat "$TEST_TMP/prompt")"

echo "PASS: fresheyes argv"
