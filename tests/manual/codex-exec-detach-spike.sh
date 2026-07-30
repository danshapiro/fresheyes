#!/usr/bin/env bash
# tests/manual/codex-exec-detach-spike.sh
#
# Empirical validation of the load-bearing premise behind the systemd-run
# detach path: a child of the systemd user manager (via D-Bus) is outside
# the codex exec harness's process group / session / cgroup / descendant
# tree, so it should survive the tree-kill that fires when the foreground
# exec command exits.
#
# Falsification-proofed design:
# - The detached child appends `HB <epoch>` every 1s for >=60s, traps
#   SIGTERM/SIGHUP/SIGINT (appends `SIGNAL <name> <epoch>` before dying),
#   and appends `DONE <epoch>` on completion — survival is judged from
#   lifetime-spanning heartbeats, not a fixed sleep.
# - Every codex exec start/return is timestamped (date +%s.%N) so heartbeat
#   epochs are compared against the recorded return time.
# - The shell command the agent runs writes a nonce fingerprint that the
#   outer script validates — a paraphrasing agent or a sandbox-blocked bus
#   INVALIDATES the run (rerun it) instead of corrupting the verdict.
# - Each cell runs N>=3 times; the verdict is differential and unanimous.
#
# Run manually: bash tests/manual/codex-exec-detach-spike.sh
# Requires: real `codex` CLI on PATH, authenticated, danger-full-access config.
# Always pass --dangerously-bypass-approvals-and-sandbox explicitly — never
# rely on config.toml (a future config edit could silently re-sandbox /tmp).
# Record the full transcript and the verdict in tests/manual/SPIKE-RESULT.md.
set -euo pipefail

SPIKE_DIR="$(mktemp -d /tmp/fresheyes-spike.XXXXXX)"
echo "spike dir: $SPIKE_DIR"
N_RUNS="${SPIKE_RUNS:-3}"   # N>=3 per cell; unanimity required for PASS

# Instrumented long-lived child: 1s heartbeats for >=60s, signal traps,
# DONE marker, plus its own pid/pgid/sid + cgroup records.
cat > "$SPIKE_DIR/instrumented-child.sh" <<'CHILD'
#!/usr/bin/env bash
MARKER="$1"
ps -o pid,pgid,sid -p $$ > "$MARKER.child-ids" 2>&1
cat /proc/self/cgroup > "$MARKER.child-cgroup" 2>&1
trap 'echo "SIGNAL SIGTERM $(date +%s)" >> "$MARKER"; exit 1' TERM
trap 'echo "SIGNAL SIGHUP $(date +%s)" >> "$MARKER"; exit 1' HUP
trap 'echo "SIGNAL SIGINT $(date +%s)" >> "$MARKER"; exit 1' INT
for _ in $(seq 1 60); do
  echo "HB $(date +%s)" >> "$MARKER"
  sleep 1
done
echo "DONE $(date +%s)" >> "$MARKER"
CHILD
chmod +x "$SPIKE_DIR/instrumented-child.sh"

# Inner launcher A: current production mechanism (setsid + &). Records the
# launcher's own pid/pgid/sid + cgroup so the kill domain is reconstructable.
cat > "$SPIKE_DIR/launch-setsid.sh" <<EOF
#!/usr/bin/env bash
RUN_ID="\$1"
ps -o pid,pgid,sid -p \$\$ > "$SPIKE_DIR/launcher-setsid-\$RUN_ID.ids" 2>&1
cat /proc/self/cgroup > "$SPIKE_DIR/launcher-setsid-\$RUN_ID.cgroup" 2>&1
setsid bash "$SPIKE_DIR/instrumented-child.sh" "$SPIKE_DIR/marker-setsid-\$RUN_ID" </dev/null >/dev/null 2>&1 &
echo "launched setsid child: \$!"
EOF

# Inner launcher B: proposed mechanism, with the exact properties production
# will use (WorkingDirectory + StandardError=append + StandardOutput=null).
cat > "$SPIKE_DIR/launch-systemd-run.sh" <<EOF
#!/usr/bin/env bash
RUN_ID="\$1"
ps -o pid,pgid,sid -p \$\$ > "$SPIKE_DIR/launcher-sdrun-\$RUN_ID.ids" 2>&1
cat /proc/self/cgroup > "$SPIKE_DIR/launcher-sdrun-\$RUN_ID.cgroup" 2>&1
systemd-run --user --collect --quiet \\
  --property=WorkingDirectory="$SPIKE_DIR" \\
  --property=StandardOutput=null \\
  --property=StandardError=append:"$SPIKE_DIR/sdrun.stderr" \\
  /bin/bash "$SPIKE_DIR/instrumented-child.sh" "$SPIKE_DIR/marker-systemd-run-\$RUN_ID"
echo "systemd-run launch exit: \$?"
EOF

# Fingerprinted agent execution: the command the agent is told to run writes
# a per-run nonce fingerprint (nonce, pwd, uid, cgroup, bus reachability);
# we validate it AFTER codex exec returns. Missing/wrong fingerprint means
# the agent paraphrased the command or the sandbox blocked the bus — the
# run is INVALID (rerun it), never counted for or against the premise.
run_cell() {
  # run_cell <cell-name> <launcher-script> <marker-file> <run-id>
  local cell="$1" launcher="$2" marker="$3" run_id="$4"
  local fingerprint="$SPIKE_DIR/fingerprint-$cell-$run_id"
  rm -f "$marker" "$fingerprint"   # a rerun of an invalid attempt starts clean
  local nonce
  nonce="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  local start_ts return_ts
  start_ts=$(date +%s.%N)
  codex exec --dangerously-bypass-approvals-and-sandbox \
    "Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo $nonce; pwd; id -u; cat /proc/self/cgroup; test -S \"\$XDG_RUNTIME_DIR/bus\" && echo BUS_OK || echo BUS_MISSING; } > $fingerprint 2>&1; bash $launcher $run_id" || true
  return_ts=$(date +%s.%N)
  printf '%s %s\n' "$start_ts" "$return_ts" > "$SPIKE_DIR/codex-times-$cell-$run_id"
  echo "codex exec [$cell run $run_id]: start=$start_ts return=$return_ts"
  if ! grep -q "$nonce" "$fingerprint" 2>/dev/null; then
    echo "INVALID RUN [$cell run $run_id]: fingerprint missing or wrong nonce (agent paraphrased the command?)"
    return 1
  fi
  if ! grep -q '^BUS_OK$' "$fingerprint"; then
    echo "INVALID RUN [$cell run $run_id]: BUS_MISSING (sandbox blocked the user bus)"
    return 1
  fi
  return 0
}

for run in $(seq 1 "$N_RUNS"); do
  echo
  echo "=== cell A run $run/$N_RUNS: setsid under real codex exec ==="
  until run_cell A "$SPIKE_DIR/launch-setsid.sh" "$SPIKE_DIR/marker-setsid-$run" "$run"; do
    echo "cell A run $run invalid — draining any stale child (60s window), then rerunning"
    sleep 70
  done
  echo
  echo "=== cell B run $run/$N_RUNS: systemd-run under real codex exec (THE load-bearing premise) ==="
  until run_cell B "$SPIKE_DIR/launch-systemd-run.sh" "$SPIKE_DIR/marker-systemd-run-$run" "$run"; do
    echo "cell B run $run invalid — draining any stale child (60s window), then rerunning"
    sleep 70
  done
done

echo
echo "waiting 70s for the final run's children to finish their >=60s heartbeat windows..."
sleep 70

# Differential verdict. Per run:
# - cell A KILLED: no DONE line AND last HB <= codex-exec-return + margin
#   (the setsid child provably died with the session).
# - cell B SURVIVED: DONE line present AND HB epochs strictly after the
#   recorded codex exec return (the unit child provably outlived the session).
# PASS requires BOTH, unanimously across all N runs. Cell A surviving in ANY
# run makes the verdict INCONCLUSIVE (the tree-kill diagnosis itself is in
# question), never PASS.
python3 - "$SPIKE_DIR" "$N_RUNS" <<'PY'
import pathlib, sys
spike = pathlib.Path(sys.argv[1]); n = int(sys.argv[2])
MARGIN = 5.0  # seconds of slack past the recorded codex exec return

def parse(marker):
    hbs, done, signals = [], None, []
    try:
        for line in marker.read_text().splitlines():
            parts = line.split()
            if parts and parts[0] == "HB": hbs.append(float(parts[1]))
            elif parts and parts[0] == "DONE": done = float(parts[1])
            elif parts and parts[0] == "SIGNAL": signals.append(line)
    except FileNotFoundError:
        pass
    return hbs, done, signals

a_killed = b_survived = 0
a_survived_any = False
for run in range(1, n + 1):
    a_ret = float((spike / f"codex-times-A-{run}").read_text().split()[1])
    b_ret = float((spike / f"codex-times-B-{run}").read_text().split()[1])
    a_hbs, a_done, a_sig = parse(spike / f"marker-setsid-{run}")
    b_hbs, b_done, _ = parse(spike / f"marker-systemd-run-{run}")
    a_kill = a_done is None and (not a_hbs or max(a_hbs) <= a_ret + MARGIN)
    b_surv = b_done is not None and bool(b_hbs) and max(b_hbs) > b_ret
    print(f"run {run}: cellA killed={a_kill} (hbs={len(a_hbs)} done={a_done} signals={a_sig or 'none'}) "
          f"cellB survived={b_surv} (hbs={len(b_hbs)} done={b_done})")
    a_killed += int(a_kill); b_survived += int(b_surv)
    if not a_kill: a_survived_any = True

if a_survived_any:
    print("PREMISE: INCONCLUSIVE")
elif a_killed == n and b_survived == n:
    print("PREMISE: PASS")
else:
    print("PREMISE: FAIL")
print(f"RUNS: {a_killed}/{n} cellA-killed, {b_survived}/{n} cellB-survived")
PY

echo
echo "=== cell C: user bus unreachable -> runtime probe must fail cleanly ==="
if env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
     systemd-run --user --collect --quiet --wait /bin/true >/dev/null 2>&1; then
  echo "cell C result: UNEXPECTED — probe succeeded without a bus (note it; probe is still required)"
else
  echo "cell C result: probe fails without a bus, as expected (setsid fallback will engage)"
fi

echo
echo "=== cell D: env is NOT inherited inside a unit (verifies the --setenv requirement) ==="
SPIKE_SENTINEL="spike-$$" systemd-run --user --collect --quiet --wait \
  --property=StandardOutput=append:"$SPIKE_DIR/env-probe.out" \
  /bin/bash -c 'echo "SENTINEL=${SPIKE_SENTINEL:-UNSET} PATH=$PATH"' || true
cat "$SPIKE_DIR/env-probe.out" 2>/dev/null || echo "(no env-probe output)"
echo "expected: SENTINEL=UNSET and a PATH without nvm dirs — every needed var must be forwarded via --setenv"

echo
echo "Now record the verdict: edit tests/manual/SPIKE-RESULT.md, copy the analyzer's"
echo "literal 'PREMISE: ...' and 'RUNS: ...' lines verbatim (PASS / FAIL / INCONCLUSIVE),"
echo "and paste this full transcript into the file."
