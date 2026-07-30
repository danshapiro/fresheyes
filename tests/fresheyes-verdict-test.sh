#!/usr/bin/env bash
# Tests for the shared verdict parser (fresheyes-verdict.py) and the
# single-source-of-truth guarantee: the verdict marker regex lives in exactly
# one file, and both fresheyes.sh and fresheyes-progress.sh call it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$REPO_DIR/skills/fresheyes"
PARSER="$SKILL_DIR/fresheyes-verdict.py"

TMP_DIR="$(mktemp -d /tmp/fresheyes-verdict-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1" expected_exit="$2" expected_out="$3" file="$4"
  local out exit_code
  out="$(python3 "$PARSER" "$file" 2>/dev/null)" && exit_code=0 || exit_code=$?
  if [[ "$exit_code" == "$expected_exit" && "$out" == "$expected_out" ]]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name (exit=$exit_code out='$out'; wanted exit=$expected_exit out='$expected_out')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Parser behavior ---

printf 'blah\n**INDEPENDENT CODE REVIEW PASSED**\n' > "$TMP_DIR/passed.md"
check "detects PASSED" 0 "passed" "$TMP_DIR/passed.md"

printf 'blah\n**INDEPENDENT CODE REVIEW FAILED**\n' > "$TMP_DIR/failed.md"
check "detects FAILED" 0 "failed" "$TMP_DIR/failed.md"

printf 'INDEPENDENT CODE REVIEW PASSED\nlater...\nINDEPENDENT CODE REVIEW FAILED\n' > "$TMP_DIR/last-wins.md"
check "last marker wins" 0 "failed" "$TMP_DIR/last-wins.md"

printf 'independent code review passed\n' > "$TMP_DIR/case.md"
check "case-insensitive" 0 "passed" "$TMP_DIR/case.md"

printf 'INDEPENDENT CODE REVIEW PASSEDNESS\n' > "$TMP_DIR/word-boundary.md"
check "requires word boundary" 1 "" "$TMP_DIR/word-boundary.md"

printf 'no verdict here\n' > "$TMP_DIR/none.md"
check "no marker -> exit 1" 1 "" "$TMP_DIR/none.md"

check "missing file -> exit 1" 1 "" "$TMP_DIR/does-not-exist.md"

# --- Single source of truth ---

marker_files="$(grep -rlF 'INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)' "$SKILL_DIR" || true)"
if [[ "$marker_files" == "$PARSER" ]]; then
  echo "PASS: verdict regex lives only in fresheyes-verdict.py"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: verdict regex found outside the shared parser:"
  printf '%s\n' "$marker_files"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

for script in fresheyes.sh fresheyes-progress.sh; do
  if grep -q 'fresheyes-verdict\.py' "$SKILL_DIR/$script"; then
    echo "PASS: $script calls the shared parser"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $script does not call the shared parser"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo
echo "fresheyes-verdict-test: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
