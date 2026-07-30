#!/usr/bin/env bash
# tests/manual/codex-exec-e2e.sh
# One-shot end-to-end validation under REAL codex exec. Run manually at
# least once for this change; record the transcript in the commit/PR
# description and in tests/manual/SPIKE-RESULT.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

E2E_TMP="$(mktemp -d /tmp/fresheyes-e2e.XXXXXX)"
FAKE_BIN="$E2E_TMP/bin"
mkdir -p "$FAKE_BIN"
echo "e2e tmp: $E2E_TMP"

cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys, time
if "--version" in sys.argv:
    print(os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION", "2.1.170 (Claude Code)"))
    sys.exit(0)
# FRESHEYES_FAKE_DELAY (seconds) stretches the review; both cells below set
# it to 30 and their assertions DEPEND on the review still being in flight
# when codex exec returns. Sleep AFTER the init event, BEFORE the result.
delay = float(os.environ.get("FRESHEYES_FAKE_DELAY", "0"))
print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
if delay:
    time.sleep(delay)
review = "# Review\n\nAll good.\n\nINDEPENDENT CODE REVIEW PASSED\n"
print(json.dumps({"type": "result", "subtype": "success", "result": review}), flush=True)
FAKE
chmod +x "$FAKE_BIN/claude"
# Keep this fake in sync with tests/fresheyes-detach-test.sh's make_fake_claude.

poll_until() {
  local log_dir="$1" handle="$2" want="$3" tries="${4:-120}"
  local out state
  for _ in $(seq 1 "$tries"); do
    out=$(FRESHEYES_LOG_DIR="$log_dir" FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
      bash "$PROGRESS" --json "$handle" 2>/dev/null) || true
    state=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("state",""))' "$out" 2>/dev/null || echo "")
    echo "poll: state=$state"
    [[ "$state" == "$want" ]] && { echo "$out"; return 0; }
    sleep 1
  done
  echo "TIMEOUT waiting for state=$want; last: $out"
  return 1
}

handle_from_dir() {
  local log_dir="$1" locator
  locator=$(ls "$log_dir"/.locator.* 2>/dev/null | head -1) || true
  [[ -n "$locator" ]] && basename "$locator" | sed 's/^\.locator\.//'
}

if grep -q '^PREMISE: PASS' "$ROOT_DIR/tests/manual/SPIKE-RESULT.md"; then
  echo "=== cell 1: systemd-run detach survives codex exec and completes ==="
  LOG_DIR_1="$E2E_TMP/logs-survive"
  mkdir -p "$LOG_DIR_1"
  # FRESHEYES_FAKE_DELAY=30 keeps the review in flight past codex exec's
  # return: measured, the no-delay fake review completes in ~0.5s — before
  # any turn-end kill could land, leaving the cell blind by arithmetic.
  codex exec --dangerously-bypass-approvals-and-sandbox \
    "Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: env PATH=\"$FAKE_BIN:\$PATH\" FRESHEYES_LOG_DIR=$LOG_DIR_1 FRESHEYES_GLOBAL_LOG_DIR=$LOG_DIR_1 FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash $RUNNER --claude 'review HEAD'" || true
  RETURN_TS_1=$(date +%s.%N)
  echo "codex exec returned at: $RETURN_TS_1"
  H1=$(handle_from_dir "$LOG_DIR_1")
  echo "handle: ${H1:-NONE}"
  [[ -n "$H1" ]] || { echo "cell 1 FAILED: no locator written"; exit 1; }
  # FIRST prove survival: the owner process must still be alive AFTER the
  # recorded codex exec return (the fake provider has ~30s left to run).
  BASE_1=$(tr -d '\n' < "$LOG_DIR_1/.locator.$H1")
  OWNER_1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("owner_pid",""))' \
    "$BASE_1.status.json" 2>/dev/null || echo "")
  [[ "$OWNER_1" =~ ^[0-9]+$ ]] || { echo "cell 1 FAILED: no owner_pid recorded after codex exec returned"; exit 1; }
  if kill -0 "$OWNER_1" 2>/dev/null; then
    echo "cell 1 survival proven: owner $OWNER_1 alive after codex exec return ($RETURN_TS_1)"
  else
    echo "cell 1 FAILED: owner $OWNER_1 already dead after codex exec return — the unit did not survive"
    exit 1
  fi
  # THEN poll to complete.
  poll_until "$LOG_DIR_1" "$H1" "complete" || { echo "cell 1 FAILED"; exit 1; }
  echo "cell 1 PASSED: detached review survived codex exec (owner alive post-return) and completed"
else
  echo "=== cell 1 SKIPPED: spike verdict is not PREMISE: PASS (setsid-only build) ==="
fi

echo
echo "=== cell 2: bus absent -> setsid fallback -> harness kill -> killed_at_launch ==="
LOG_DIR_2="$E2E_TMP/logs-killed"
mkdir -p "$LOG_DIR_2"
codex exec --dangerously-bypass-approvals-and-sandbox \
  "Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS PATH=\"$FAKE_BIN:\$PATH\" FRESHEYES_LOG_DIR=$LOG_DIR_2 FRESHEYES_GLOBAL_LOG_DIR=$LOG_DIR_2 FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash $RUNNER --claude 'review HEAD'" || true
H2=$(handle_from_dir "$LOG_DIR_2")
echo "handle: ${H2:-NONE}"
[[ -n "$H2" ]] || { echo "cell 2 FAILED: no locator written (parent-owned trackers must exist)"; exit 1; }
sleep 20  # past the 15s launch grace
set +e
OUT2=$(FRESHEYES_LOG_DIR="$LOG_DIR_2" FRESHEYES_GLOBAL_LOG_DIR="$LOG_DIR_2" \
  bash "$PROGRESS" --json "$H2")
RC2=$?
set -e
echo "poll output: $OUT2"
echo "poll exit: $RC2"
STATE2=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("state",""))' "$OUT2")
MSG2=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("message",""))' "$OUT2")
if [[ "$STATE2" == "killed_at_launch" && "$RC2" -eq 3 && "$MSG2" == *"--foreground"* ]]; then
  echo "cell 2 PASSED: loud killed_at_launch with remediation"
elif [[ "$STATE2" == "complete" || "$STATE2" == "running" ]]; then
  echo "cell 2 INCONCLUSIVE: the harness did not kill the setsid child on this run ($STATE2) — note it in the transcript; the killed_at_launch path is covered deterministically by tests/fresheyes-detach-test.sh"
else
  echo "cell 2 FAILED: state=$STATE2 rc=$RC2"
  exit 1
fi

echo
echo "e2e done. Record this transcript in tests/manual/SPIKE-RESULT.md and the commit body."
