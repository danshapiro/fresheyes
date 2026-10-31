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

# --- Files Examined: --no-files-examined exits 0 only when the review's own
# list is present and names no file ---

check_none() {
  local name="$1" expected_exit="$2" file="$3"
  local exit_code
  python3 "$PARSER" --no-files-examined "$file" >/dev/null 2>&1 && exit_code=0 || exit_code=$?
  if [[ "$exit_code" == "$expected_exit" ]]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name (exit=$exit_code; wanted exit=$expected_exit)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

printf '## Files Examined\nNone. All three read attempts failed with `timed out negotiating with the code-mode host`;\nno repository commands ran.\n\n## Issues Found\n- **BLOCKER - review unavailable:** I could not read anything.\n\n---\n**INDEPENDENT CODE REVIEW FAILED**\n' > "$TMP_DIR/none-prose.md"
check_none "prose 'None.' under the heading" 0 "$TMP_DIR/none-prose.md"

printf '## Files Examined\n\n- None (every read failed)\n\n## Issues Found\n' > "$TMP_DIR/none-bullet.md"
check_none "a 'None' bullet" 0 "$TMP_DIR/none-bullet.md"

printf '## Files Examined\n\n## Issues Found\n- x\n' > "$TMP_DIR/none-empty.md"
check_none "an empty section" 0 "$TMP_DIR/none-empty.md"

printf '### Files examined:\n- n/a\n---\n' > "$TMP_DIR/none-na.md"
check_none "'n/a' under a level-3 heading with a colon" 0 "$TMP_DIR/none-na.md"

printf '## Files Examined\nNone.\n- All read attempts failed with permission denied.\n- No repository command ran.\n\n## Issues Found\n' > "$TMP_DIR/none-then-reasons.md"
check_none "'None.' followed by bullets that explain it" 0 "$TMP_DIR/none-then-reasons.md"

printf '## Files Examined\n- **None.**\n' > "$TMP_DIR/none-bold.md"
check_none "a bold '**None.**' bullet" 0 "$TMP_DIR/none-bold.md"

printf '## Files Examined\n- No files were examined because access was denied.\n' > "$TMP_DIR/no-files-because.md"
check_none "'No files were examined because ...'" 0 "$TMP_DIR/no-files-because.md"

printf '## Files Examined\nNothing was read: every command timed out.\n' > "$TMP_DIR/nothing-read.md"
check_none "'Nothing was read: ...'" 0 "$TMP_DIR/nothing-read.md"

printf '## Files Examined\n- `none.py`\n' > "$TMP_DIR/none-py.md"
check_none "a file named none.py" 1 "$TMP_DIR/none-py.md"

printf '## Files Examined\nNone of these were modified, only read:\n- src/a.py\n' > "$TMP_DIR/none-of.md"
check_none "'None of ...' prose before a file list" 1 "$TMP_DIR/none-of.md"

printf '## Files Examined   \n- README.md\n\n## Issues Found\n' > "$TMP_DIR/one-file.md"
check_none "one file listed" 1 "$TMP_DIR/one-file.md"

printf '## Files Examined\n1. `src/a.py`\n2. `src/b.py`\n' > "$TMP_DIR/numbered.md"
check_none "a numbered list" 1 "$TMP_DIR/numbered.md"

printf '## Files Examined\n- README.md\n\n## Issues Found\n- A quote:\n\n## Files Examined\n\nINDEPENDENT CODE REVIEW PASSED\n' > "$TMP_DIR/quoted-heading.md"
check_none "a later quoted heading does not replace the review's own list" 1 "$TMP_DIR/quoted-heading.md"

printf 'INDEPENDENT CODE REVIEW PASSED\n' > "$TMP_DIR/no-heading.md"
check_none "no Files Examined heading" 1 "$TMP_DIR/no-heading.md"

check_none "missing file" 1 "$TMP_DIR/does-not-exist.md"

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
