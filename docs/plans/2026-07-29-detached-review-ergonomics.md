# Fresheyes Detached-Review Ergonomics Redesign — Implementation Plan

> **For agentic workers:** This plan is executed task-by-task by the
> workflow's execute stage: a fresh implementer per task, with a spec +
> quality review after each task. Steps use checkbox (`- [ ]`) syntax
> for tracking.

**Goal:** Make fresheyes detached reviews fail LOUD with exact remediation, key all tracking off a parent-minted opaque handle (never a PID), and — if empirically proven to survive the codex exec harness kill — detach via `systemd-run --user`.

**Architecture:** The foreground parent mints an opaque run handle, writes the locator and an initial `launching` status.json BEFORE detaching, and hands identity to the child via env vars. The child records its real PID as `owner_pid` and touches a `heartbeat_at` field every ~20s. `fresheyes-progress.sh` becomes a strictly read-only synthesizer of six explicit states (`launching`, `running`, `complete`, `killed_at_launch`, `died`, `unknown_handle`) with per-state exit codes and remediation messages. A one-shot spike under REAL `codex exec` decides whether the `systemd-run` detach path ships at all.

**Tech Stack:** bash (`set -euo pipefail` in fresheyes.sh; no strict mode in fresheyes-progress.sh — keep it that way), python3 heredocs for JSON, util-linux `setsid`, optionally `systemd-run --user`, plain-bash test scripts with runtime-generated fake `claude`/`codex` binaries (no API tokens).

## Global Constraints

- Change ONLY this repo. Copies of the skill at `~/.codex/skills/fresheyes` are synced separately — never write there.
- Item 6 of the design (launch-time warning based on prior-run state) is CUT by owner decision. Do not implement any launch-time warning.
- The launch receipt is EXACTLY two lines (Task 3 ships line 1; Task 6 adds line 2 — final state is two lines): `FRESHPID=<handle>` then the `NEXT:` line. No NOTE/warning line. Never print the status-file path in the receipt.
- Item 2 (binary-path forwarding) is plumbing only. Do NOT describe it anywhere (code comments, SKILL.md, commit messages) as shrinking or fixing the kill window.
- The legacy `missing` state is DELETED, not supplemented — replaced by `unknown_handle`. No output path may emit `state=missing` after Task 5.
- `fresheyes-progress.sh` must never create/modify/delete any file (strictly read-only after Task 2).
- Heartbeat period: 20s (`FRESHEYES_HEARTBEAT_SECS` override). Staleness threshold: 60s (`FRESHEYES_HEARTBEAT_STALE_SECS` override). Launch grace: 15s (`FRESHEYES_LAUNCH_GRACE_SECS` override). Env overrides exist for tests/tuning; defaults are the spec values.
- Handle format: `<yyyymmdd-HHMMSS>-<6 hex from /dev/urandom>`, regex `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` (unchanged), plus: the 6-hex suffix always contains at least one `[a-f]` by construction (all-digit suffixes collide with the legacy filename-pid fallback). Opaque to callers — NOT a pid.
- Old numeric-pid handles from previous fresheyes versions must still resolve via their existing `.locator.<pid>` files.
- `--json` polling exit codes: `launching`/`running`/`complete` → 0; `killed_at_launch` → 3; `died` → 4; `unknown_handle` → 5; usage errors stay 2.
- Automatic mode and existing `--foreground` semantics are otherwise unchanged (automatic mode never detaches; `--foreground` streams synchronously).
- Tests: standalone `bash tests/<file>.sh`, `set -euo pipefail`, fake providers via PATH-prepended `$TEST_TMP/bin`, every runner call wrapped in `timeout 30s`, success = trailing `... tests passed`. All four existing test files must pass at every commit.
- README.md stays the only end-user markdown doc. `tests/manual/SPIKE-RESULT.md` and this plan are working/agent docs (allowed). SKILL.md is part of the product UI (required by spec).
- Line numbers cited below (e.g. `fresheyes.sh:220`) are from the pre-change tree at commit `c354a9d`. Verify each anchor by its quoted content before editing; later tasks shift lines.
- The load-bearing systemd-run premise MUST be validated under REAL `codex exec` (Task 1: differential cells, N>=3 fingerprint-validated runs each, unanimity required) before Task 8 is built. Only the literal `PREMISE: PASS` ships the systemd-run path; `PREMISE: FAIL` and `PREMISE: INCONCLUSIVE` (cell A survived — the tree-kill diagnosis itself unproven) both count as FAIL and reduce Task 8 to its documented fallback-only variant — items 1, 4, 5 ship regardless.

---

### Task 1: systemd-run survival spike under real `codex exec` (decision gate)

**Files:**
- Create: `tests/manual/codex-exec-detach-spike.sh`
- Create: `tests/manual/SPIKE-RESULT.md`

**Interfaces:**
- Consumes: nothing from other tasks (runs first).
- Produces: `tests/manual/SPIKE-RESULT.md` containing exactly one literal line `PREMISE: PASS`, `PREMISE: FAIL`, or `PREMISE: INCONCLUSIVE`, plus a `RUNS: <k>/<N> ...` counts line. Task 8 greps exactly the PREMISE line to decide whether the systemd-run detach path ships — anything other than the literal `PREMISE: PASS` is treated as FAIL. Task 9's e2e script reuses the same codex-exec invocation shape.

This is an experiment, not TDD. It must be run for real on this machine (codex is installed and configured with danger-full-access). A simulated killer proves nothing.

Note (validation recon): there is counter-evidence that cell A may SURVIVE — codex-rs kill paths are process-group-scoped (`killpg` + PDEATHSIG), and github.com/openai/codex issue #10860 reports setsid children surviving the turn-end kill, while the only preserved field-death artifacts on this machine were provider RATE-LIMIT deaths. Cell A survival is therefore a live outcome with defined consequences — verdict `PREMISE: INCONCLUSIVE` (the tree-kill diagnosis itself is in question, so cell B's survival proves nothing about escaping it) plus the hedged `killed_at_launch` wording in Task 5 — not a fluke to "investigate".

- [ ] **Step 1: Write the spike script**

```bash
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
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n tests/manual/codex-exec-detach-spike.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Run the spike for real**

Run: `bash tests/manual/codex-exec-detach-spike.sh 2>&1 | tee /tmp/spike-transcript.txt`
Expected: N>=3 timestamped `codex exec [cell run]: start=... return=...` lines per cell, each run fingerprint-validated (any `INVALID RUN` is rerun automatically after a 70s drain — it never counts for or against the premise); the analyzer then prints one per-run line (`run N: cellA killed=... cellB survived=...`), exactly one literal verdict line `PREMISE: PASS` / `PREMISE: FAIL` / `PREMISE: INCONCLUSIVE`, and a `RUNS: <k>/<N> cellA-killed, <m>/<N> cellB-survived` counts line; cell C prints `probe fails without a bus`, cell D prints `SENTINEL=UNSET`. This takes a while (2×N real codex exec sessions plus heartbeat-drain waits). If `codex exec` errors out entirely (auth, config), STOP and report — do not fabricate a verdict.

- [ ] **Step 4: Record the verdict**

Write `tests/manual/SPIKE-RESULT.md` with exactly this structure (fill in the real values):

```markdown
# systemd-run survival spike result

Date: <date -u output>
Machine: WSL2 (see uname -a below)

PREMISE: PASS   <!-- or: PREMISE: FAIL / PREMISE: INCONCLUSIVE — copy the analyzer's literal verdict line; Task 8 greps exactly this -->
RUNS: <k>/<N> cellA-killed, <m>/<N> cellB-survived   <!-- copy the analyzer's counts line -->

- cell A (setsid under codex exec, N runs): KILLED k/N — per-run last-HB vs codex-exec-return timestamps below
- cell B (systemd-run under codex exec, N runs): SURVIVED m/N — HB after recorded return + DONE reached
- fingerprint checks: every accepted run nonce-validated with BUS_OK (list any INVALID RUN reruns here)
- cell C (bus-absent probe): FAILED CLEANLY / UNEXPECTED SUCCESS
- cell D (env inheritance): SENTINEL=UNSET (confirmed --setenv requirement)

Decision: Task 8 ships the systemd-run detach path.   <!-- PASS only. FAIL or INCONCLUSIVE: Task 8 ships fallback-only; setsid remains the sole detach path. -->

## Per-run timestamps

<paste the `codex exec [cell run]: start=... return=...` lines and the analyzer's per-run `run N: ...` lines verbatim>

## Full transcript

<paste /tmp/spike-transcript.txt verbatim>
```

- [ ] **Step 5: Commit**

```bash
git add tests/manual/codex-exec-detach-spike.sh tests/manual/SPIKE-RESULT.md
git commit -m "test: spike systemd-run survival under real codex exec

Differential design: N>=3 fingerprint-validated runs per cell, 1s heartbeat
markers with signal traps, codex exec return timestamps. Transcript and the
PASS/FAIL/INCONCLUSIVE verdict recorded in tests/manual/SPIKE-RESULT.md;
only the literal 'PREMISE: PASS' ships the systemd-run detach path."
```

---

### Task 2: progress script accepts opaque handles, drops `.parent`, becomes read-only

**Files:**
- Modify: `skills/fresheyes/fresheyes-progress.sh` (anchors: `:77-94` `_process_state`, `:161-170` `.parent` fallback, `:224` owner-pid lookup, `:645` owner-pid lookup, `:698-700` `rm -f`)
- Test: `tests/fresheyes-progress-test.sh`

**Interfaces:**
- Consumes: current tracker conventions (`.active.<key>`, `.locator.<key>` files containing the log base path; `status.json` with fields `state`, `pid`, `provider`, `mode`, `exit_code`, `verdict`).
- Produces: `_process_state <pid>` → prints `unknown` for empty OR non-numeric input (unchanged values otherwise: `missing`/`zombie`/`active`); `_owner_pid_for_base <base>` → prints the owner pid from status.json `owner_pid`, else status.json `pid`, else the legacy `-(\d+).log$` filename parse, else nothing (return 1). The positional argument (internal var `PID`) is now an opaque locator key. Task 3's handles resolve through `.locator.<handle>`/`.active.<handle>` with zero further changes here. The script performs no filesystem writes.

- [ ] **Step 1: Write the failing tests**

Add these test functions to `tests/fresheyes-progress-test.sh` (before the registration list at the bottom; reuse the existing helpers `fail`, `assert_contains`, `assert_json_field_equals`, `json_field`, `write_locator_alias`, `write_claude_events`, `run_progress`, and the existing `LOG_DIR` var). Also add a `snapshot_dir` helper next to the other helpers:

```bash
snapshot_dir() {
  # Stable fingerprint of every file's path, size, and mtime under a dir.
  find "$1" -mindepth 1 -printf '%p %s %T@\n' 2>/dev/null | sort
}

test_opaque_handle_resolves_via_locator() {
  local handle="20260729-120000-ab12cd"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  printf 'review output line\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual","owner_pid":%s}\n' "$$" \
    > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"

  local output
  output=$(run_progress --json "$handle")
  assert_json_field_equals "$output" "state" "running" "opaque handle state"
  assert_json_field_equals "$output" "log_path" "$log_file" "opaque handle log_path"
}

test_owner_pid_read_from_status_json() {
  # Log filename carries NO numeric pid suffix; liveness must come from
  # status.json owner_pid (a live pid -> running).
  local handle="20260729-120001-ff00aa"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  sleep 60 &
  local live_pid=$!
  LIVE_PIDS+=("$live_pid")
  printf 'in progress\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual","owner_pid":%s}\n' "$live_pid" \
    > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"

  local output
  output=$(run_progress --json "$handle")
  assert_json_field_equals "$output" "state" "running" "owner_pid liveness from status.json"
  assert_json_field_equals "$output" "owner_pid" "$live_pid" "owner_pid surfaced"
}

test_parent_alias_no_longer_resolves() {
  # .parent.<pid> trackers are dead: a handle whose ONLY tracker is a
  # .parent file must not resolve.
  local dead_pid
  dead_pid=$(bash -c 'echo $$')   # already-reaped pid
  local log_file="$LOG_DIR/fresheyes-20260729-120002-1234ab.log"
  printf 'orphan review\n' > "$log_file"
  printf '%s\n' "$log_file" > "$LOG_DIR/.parent.$dead_pid"

  local output
  output=$(run_progress --json "$dead_pid" || true)
  local state
  state=$(json_field "$output" "state")
  if [[ "$state" != "missing" && "$state" != "unknown_handle" ]]; then
    fail "expected unresolved state for .parent-only tracker, got: $state"
  fi
}

test_progress_is_read_only() {
  local handle="20260729-120003-c0ffee"
  local log_file="$LOG_DIR/fresheyes-$handle.log"
  printf 'some output\n' > "$log_file"
  printf '{"state":"running","provider":"gpt","mode":"manual"}\n' > "$log_file.status.json"
  write_locator_alias "$handle" "$log_file"
  # Also plant the legacy-text failed-state bait that used to trigger rm -f .active.*
  local dead_pid
  dead_pid=$(bash -c 'echo $$')
  local dead_log="$LOG_DIR/fresheyes-20260101-000000-$dead_pid.log"
  printf 'stale\n' > "$dead_log"
  printf '%s\n' "$dead_log" > "$LOG_DIR/.active.$dead_pid"

  local before after
  before=$(snapshot_dir "$LOG_DIR")
  run_progress --json "$handle" >/dev/null || true
  run_progress --result "$handle" >/dev/null 2>&1 || true
  run_progress --json "$dead_pid" >/dev/null || true
  run_progress --result "$dead_pid" >/dev/null 2>&1 || true
  FRESHEYES_ALLOW_LEGACY_PROGRESS=1 run_progress "$dead_pid" >/dev/null 2>&1 || true
  after=$(snapshot_dir "$LOG_DIR")
  if [[ "$before" != "$after" ]]; then
    fail "progress script mutated the log dir:
--- before ---
$before
--- after ---
$after"
  fi
}
```

Note: `write_locator_alias` in this test file takes `(pid, log_file, [dir])` — check its signature at `tests/fresheyes-progress-test.sh:130-136` and match the existing call convention. If `run_progress` does not accept a leading env override, invoke the legacy call as `FRESHEYES_ALLOW_LEGACY_PROGRESS=1 bash "$PROGRESS_SCRIPT" "$dead_pid"` with the same `FRESHEYES_LOG_DIR`/`FRESHEYES_GLOBAL_LOG_DIR` env the helper sets — read the helper at `:59-65` and mirror it. Register the four new functions in the list at the bottom of the file (currently `:492-508`).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash tests/fresheyes-progress-test.sh`
Expected: FAIL. `test_opaque_handle_resolves_via_locator` dies first — the non-numeric handle hits `ps -p` garbage and/or resolves but reports `state=failed` (owner pid unresolvable, `_review_is_running` false). `test_progress_is_read_only` would fail on the `rm -f .active.$dead_pid`.

- [ ] **Step 3: Implement**

In `skills/fresheyes/fresheyes-progress.sh`:

3a. Guard `_process_state` (function at `:77-94`) against non-numeric input — replace the empty-check at `:81` with:

```bash
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
```

3b. Delete the `.parent` fallback block, lines `161-170` (the block beginning `if [[ $(_process_state "$pid") != "active" ]]; then` / `tracker_file="$dir/.parent.$pid"` inside `_find_base_for_pid_in_dir`). Delete the whole block; the `.active`/`.locator` loop above and the glob fallback below remain.

3c. Add an owner-pid helper (place it right after `_pid_from_base`, currently `:67-75`):

```bash
# Owner pid of a run: status.json owner_pid (new), then status.json pid
# (legacy), then the legacy numeric filename suffix. Prints nothing and
# returns 1 when no owner is recorded.
_owner_pid_for_base() {
  local base="$1"
  local owner=""
  owner=$(status_file_field "$base" "owner_pid" 2>/dev/null || true)
  if [[ -z "$owner" ]]; then
    owner=$(status_file_field "$base" "pid" 2>/dev/null || true)
  fi
  if [[ -z "$owner" ]]; then
    owner=$(_pid_from_base "$base" 2>/dev/null || true)
  fi
  if [[ -z "$owner" || ! "$owner" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$owner"
}
```

(`status_file_field` is defined later in the file at `:308-333`; bash resolves functions at call time, so definition order is fine.)

3d. Use it at both owner-pid lookups: replace `owner_pid=$(_pid_from_base "$base" 2>/dev/null || true)` at `:224` (inside `_review_is_running`) and `OWNER_PID=$(_pid_from_base "$LOG_FILE" 2>/dev/null || true)` at `:645` with the `_owner_pid_for_base` equivalent (same variable names).

3e. Make the script read-only: delete the `rm -f "$LOG_DIR/.active.$PID"` line at `:699` (keep the surrounding `if [[ "$REVIEW_STATE" == "failed" && -n "$PID" ]]` branch's diagnostic output).

3f. Update the usage comment at the top of the file (lines 1-10) to say the positional argument is an opaque review handle (a `FRESHPID=` receipt value — historically a pid, now an opaque key) and that the script is strictly read-only.

- [ ] **Step 4: Run the tests**

Run: `bash tests/fresheyes-progress-test.sh`
Expected: PASS (`fresheyes-progress tests passed`). Two pre-existing tests exercise the `.parent` mechanism and will now fail: `test_dead_launcher_alias_to_live_owner_reports_running` (`:412-424`) and `test_dead_launcher_alias_to_finished_owner_returns_review` (`:426-443`), plus `test_global_parent_alias_ignores_external_log_by_default` (`:445-467`). Delete all three functions and their registration entries — the mechanism they test is removed by design (failure 3: `.parent.$PPID` always recorded the WSL subreaper `/init`; handles replace it). Keep `test_global_locator_ignores_external_log_by_default` (`:469-490`) unchanged.

- [ ] **Step 5: Run the full suite**

Run: `bash tests/fresheyes-progress-test.sh && bash tests/fresheyes-claude-provider-test.sh && bash tests/fresheyes-gpt-provider-test.sh && bash tests/fresheyes-prompt-contract-test.sh`
Expected: all four print their `... tests passed` line. NOTE: `tests/fresheyes-claude-provider-test.sh:324-361` (`test_compound_launch_parent_pid_recovers_review`) exercises `.parent` end-to-end and will fail. Delete that test function and its registration entry now (Task 3 adds the handle-based replacement that covers the same field failure).

- [ ] **Step 6: Commit**

```bash
git add skills/fresheyes/fresheyes-progress.sh tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh
git commit -m "feat: progress script takes opaque handles, drops .parent, is read-only

- non-numeric handles resolve via .locator files; ps -p guarded
- owner liveness now comes from status.json owner_pid (legacy fallbacks kept)
- .parent.* reader deleted (always recorded the WSL subreaper /init)
- the rm -f .active.* mutation is gone: status checks are read-only"
```

---

### Task 3: parent-owned identity in fresheyes.sh

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (anchors: `:207-223` detach block, `:233-241` log setup, `:250` `.active`, `:252-258` `write_tracker_alias`, `:260-265` locator/parent writes, `:298-330` `write_status`, `:341` cleanup rm)
- Modify: `tests/fresheyes-claude-provider-test.sh`, `tests/fresheyes-gpt-provider-test.sh`
- Test: `tests/fresheyes-detach-test.sh` (new)

**Interfaces:**
- Consumes: Task 2's opaque-handle resolution (`.locator.<handle>` → base) and `_owner_pid_for_base` (reads status.json `owner_pid`).
- Produces:
  - `mint_handle()` → prints `<yyyymmdd-HHMMSS>-<6 hex>`; the 6-hex suffix always contains at least one `[a-f]` by construction (all-digit suffixes collide with the legacy filename-pid fallback).
  - Env contract to the child: `FRESHEYES_DAEMONIZED=1`, `FRESHEYES_HANDLE=<handle>`, `FRESHEYES_LOG_FILE=<abs log path>`.
  - status.json gains fields: `owner_pid` (int, child only), `launched_at` (float epoch, set once), `detach_method` (string), `heartbeat_at` (float epoch, set on every non-`launching` write). Existing fields (`severity`, `state`, `provider`, `mode`, `pid`, `log_path`, `updated_at_epoch`, `exit_code`, `verdict`) keep their names; `pid` mirrors `owner_pid` for legacy readers.
  - `write_status <state> <exit_code> <verdict>` — same call signature as today; reads globals `STATUS_FILE`, `PROVIDER`, `MODE`, `LOG_FILE`, `OWNER_PID`, `LAUNCHED_AT_EPOCH`, `DETACH_METHOD`. Read-modify-write, atomic replace. `DETACH_METHOD` overwrites; `launched_at` is set-once.
  - Receipt line 1: `FRESHPID=<handle>` (line 2 arrives in Task 6).
  - Child stderr at launch: appended to `<LOG_FILE>.launch.stderr` (never `/dev/null`).
  - Tasks 4/5/7/8 rely on: `HANDLE`, `LOG_FILE`, `STATUS_FILE`, `LAUNCH_STDERR`, `OWNER_PID`, `DETACH_METHOD` globals and `write_status` exactly as defined here.

- [ ] **Step 1: Write the failing test file**

Create `tests/fresheyes-detach-test.sh`:

```bash
#!/usr/bin/env bash
# Detach/tracking harness matrix for the parent-owned-identity redesign.
# Standalone: bash tests/fresheyes-detach-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/skills/fresheyes/fresheyes.sh"
PROGRESS="$ROOT_DIR/skills/fresheyes/fresheyes-progress.sh"

TEST_TMP="$(mktemp -d)"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
cleanup() {
  pkill -f "fresheyes-detach-test-marker" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$label: expected to find '$needle' in:
$haystack"
  fi
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
record = json.loads(sys.argv[1])
value = record
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

snapshot_dir() {
  find "$1" -mindepth 1 -printf '%p %s %T@\n' 2>/dev/null | sort
}

# Fake claude provider: emits a minimal valid stream and a PASSED verdict.
# FRESHEYES_FAKE_DELAY (seconds) stretches the review for liveness tests.
make_fake_claude() {
  cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env python3
# fresheyes-detach-test-marker
import json, os, sys, time
if "--version" in sys.argv:
    print(os.environ.get("FRESHEYES_FAKE_CLAUDE_VERSION", "2.1.170 (Claude Code)"))
    sys.exit(0)
delay = float(os.environ.get("FRESHEYES_FAKE_DELAY", "0"))
print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
if delay:
    time.sleep(delay)
review = "# Review\n\nAll good.\n\nINDEPENDENT CODE REVIEW PASSED\n"
print(json.dumps({"type": "result", "subtype": "success", "result": review}), flush=True)
FAKE
  chmod +x "$FAKE_BIN/claude"
}

# Launch wrapper: isolated log dir per test, fake provider on PATH.
# Pins FRESHEYES_DETACH=setsid for determinism (overridable by env prefix);
# harmless before Task 8 introduces the variable, load-bearing after.
launch() {
  local log_dir="$1"; shift
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" \
  FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  FRESHEYES_DETACH="${FRESHEYES_DETACH:-setsid}" \
  FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
  PATH="$FAKE_BIN:$PATH" \
  timeout 30s bash "$@"
}

poll_json() {
  local log_dir="$1" handle="$2"
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" \
  FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  timeout 30s bash "$PROGRESS" --json "$handle"
}

wait_for_state() {
  local log_dir="$1" handle="$2" want="$3" label="$4"
  local output state
  for _ in $(seq 1 100); do
    output=$(poll_json "$log_dir" "$handle" || true)
    state=$(json_field "$output" "state" 2>/dev/null || echo "")
    if [[ "$state" == "$want" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 0.2
  done
  fail "$label: never reached state=$want; last: $output"
}

parse_handle() {
  # $1 = captured launch stdout. Prints the handle.
  local handle
  handle=$(sed -n 's/^FRESHPID=//p' <<<"$1" | tr -d '[:space:]')
  [[ "$handle" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] \
    || fail "receipt handle is not an opaque handle: '$handle' (stdout: $1)"
  printf '%s\n' "$handle"
}

# --- (a) plain bash launch: receipt + trackers at parent exit, resolves to complete
test_plain_launch_trackers_and_completion() {
  local log_dir="$TEST_TMP/logs-a"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")

  # Trackers must exist the moment the parent has exited (created BEFORE detach).
  [[ -f "$log_dir/.locator.$handle" ]] || fail "no .locator.$handle at parent exit"
  local log_file
  log_file=$(tr -d '\n' < "$log_dir/.locator.$handle")
  [[ -f "$log_file.status.json" ]] || fail "no status.json at parent exit"
  assert_contains "$(cat "$log_file.status.json")" '"detach_method"' "initial status has detach_method"
  assert_contains "$(cat "$log_file.status.json")" '"launched_at"' "initial status has launched_at"

  # No .parent.* files, ever.
  if compgen -G "$log_dir/.parent.*" > /dev/null; then
    fail ".parent.* tracker written; that mechanism is deleted"
  fi

  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "plain launch")
  [[ "$(json_field "$output" "verdict")" == "passed" ]] || fail "plain launch verdict"
}

# --- (b) amplifier-style launch: monitor mode makes the backgrounded setsid
# process a process-group leader, so util-linux setsid FORKS and $! diverges
# from the child pid. The printed handle must resolve anyway (regression for
# field failure 2).
test_monitor_mode_launch_handle_still_resolves() {
  local log_dir="$TEST_TMP/logs-b"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(launch "$log_dir" -m "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  wait_for_state "$log_dir" "$handle" "complete" "monitor-mode launch" >/dev/null
}

# --- handle minting: the 6-hex suffix must always contain >=1 [a-f].
# All-digit suffixes match the retained legacy filename-pid regex
# -([0-9]+)\.log$ and (leading zeros stripped) can resolve to always-live
# low pids, permanently masking killed_at_launch/died — guarded at mint time.
test_mint_handle_suffix_always_has_hex_letter() {
  local fn
  fn=$(sed -n '/^mint_handle()/,/^}/p' "$RUNNER")
  [[ -n "$fn" ]] || fail "mint_handle not found in runner"
  local i handle suffix
  for i in $(seq 1 50); do
    handle=$(bash -c "$fn; mint_handle")
    [[ "$handle" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] \
      || fail "minted handle malformed: $handle"
    suffix="${handle##*-}"
    [[ "$suffix" =~ [a-f] ]] \
      || fail "all-digit suffix minted (collides with legacy filename-pid fallback): $handle"
  done
}

make_fake_claude
test_plain_launch_trackers_and_completion
test_monitor_mode_launch_handle_still_resolves
test_mint_handle_suffix_always_has_hex_letter

printf 'fresheyes-detach tests passed\n'
```

(The fake claude must match what `fresheyes-claude-stream.py` accepts. Before finalizing, compare against the richer fake at `tests/fresheyes-claude-provider-test.sh:41-119` — if the parser requires the `assistant`/`user` events or specific `result` fields that fake emits, copy those emissions verbatim into `make_fake_claude` here. The verdict line `INDEPENDENT CODE REVIEW PASSED` and `--version` handling are the load-bearing parts.)

- [ ] **Step 2: Run new test to verify it fails**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL at `parse_handle` — current receipt payload is a bare numeric pid, not an opaque handle.

- [ ] **Step 3: Implement parent-owned identity in fresheyes.sh**

3a. **Move + extend the identity block.** Delete lines `233-241` (the `GLOBAL_LOG_DIR`/`LOG_DIR`/`LOG_FILE`/sidecar-name block) from their current position and insert the following block immediately BEFORE the detach block (currently `:207`), i.e. after prompt/schema resolution ends at `:205`:

```bash
GLOBAL_LOG_DIR="${FRESHEYES_GLOBAL_LOG_DIR:-/tmp/fresheyes-logs}"
LOG_DIR="${FRESHEYES_LOG_DIR:-$GLOBAL_LOG_DIR}"
mkdir -p "$LOG_DIR"

# Opaque run handle: parent-minted, never a pid. The 6-hex suffix must
# contain at least one [a-f]: all-digit suffixes (probability (10/16)^6
# ≈ 6%) match the retained legacy filename-pid regex `-([0-9]+)\.log$`,
# and with leading zeros stripped a suffix like 000002 resolves to an
# always-live low pid — permanently masking killed_at_launch/died during
# the ownerless launching window (proven by repro).
mint_handle() {
  local suffix
  while :; do
    suffix="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    [[ "$suffix" =~ [a-f] ]] && break
  done
  printf '%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$suffix"
}

if [[ -n "${FRESHEYES_HANDLE:-}" && -n "${FRESHEYES_LOG_FILE:-}" ]]; then
  # Detached child: identity was minted by the parent and arrives via env.
  HANDLE="$FRESHEYES_HANDLE"
  LOG_FILE="$FRESHEYES_LOG_FILE"
else
  # Foreground / automatic / direct runs mint locally.
  HANDLE="$(mint_handle)"
  LOG_FILE="$LOG_DIR/fresheyes-$HANDLE.log"
fi
RESULT_FILE="$LOG_FILE.result.md"
EVENT_LOG="$LOG_FILE.events.jsonl"
STREAM_LOG="$LOG_FILE.stream.jsonl"
STDERR_LOG="$LOG_FILE.stderr"
STATUS_FILE="$LOG_FILE.status.json"
LAUNCH_STDERR="$LOG_FILE.launch.stderr"
# The detached child must record the parent's ACTUAL detach method:
# write_status overwrites detach_method on every write, so a child that
# hardcoded "setsid" would clobber a systemd-run launch's method on its
# first "running" write. The parent forwards FRESHEYES_DETACH_METHOD in
# both launch paths (Task 3 setsid prefix; Task 8 --setenv).
DETACH_METHOD="${FRESHEYES_DETACH_METHOD:-setsid}"
LAUNCHED_AT_EPOCH="$(date +%s)"
OWNER_PID=""
```

3b. **Move `write_tracker_alias` (currently `:252-258`) and `write_status` (currently `:298-330`)** so both are defined immediately after the identity block above (they must exist before the detach block calls them). Rewrite `write_status` as:

```bash
# Atomic status.json writer. Read-modify-write so parent-written fields
# (launched_at) survive child updates. Call shape unchanged:
#   write_status <state> <exit_code> <verdict>
write_status() {
  local state="$1"
  local exit_code="${2:-}"
  local verdict="${3:-}"
  python3 - "$STATUS_FILE" "$state" "$PROVIDER" "$MODE" "$LOG_FILE" \
    "$exit_code" "$verdict" "${OWNER_PID:-}" "${LAUNCHED_AT_EPOCH:-}" \
    "${DETACH_METHOD:-}" <<'PY' || true
import json, os, sys, time

(path, state, provider, mode, log_path,
 exit_code, verdict, owner_pid, launched_at, detach_method) = sys.argv[1:11]

record = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except Exception:
        record = {}

record["severity"] = "error" if state == "failed" else "info"
record["state"] = state
record["provider"] = provider
record["mode"] = mode
record["log_path"] = log_path
record["updated_at_epoch"] = time.time()
if state != "launching":
    record["heartbeat_at"] = time.time()
if exit_code:
    record["exit_code"] = int(exit_code)
if verdict:
    record["verdict"] = verdict
if owner_pid:
    record["owner_pid"] = int(owner_pid)
    record["pid"] = int(owner_pid)  # legacy readers
if launched_at:
    record.setdefault("launched_at", float(launched_at))
if detach_method:
    record["detach_method"] = detach_method

tmp_path = f"{path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    # Keep the current writer's exact serialization (compact separators +
    # sorted keys + trailing newline): the provider tests assert compact
    # substrings like '"state":"complete"' against this file.
    json.dump(record, handle, separators=(",", ":"), sort_keys=True)
    handle.write("\n")
os.replace(tmp_path, path)
PY
}
```

3c. **Replace the detach block** (currently `:207-223`, the block quoted below) —

old:
```bash
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  if ! command -v setsid &> /dev/null; then
    echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
    exit 2
  fi
  FRESHEYES_DAEMONIZED=1 setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>&1 &
  echo "FRESHPID=$!"
  exit 0
fi
```

new:
```bash
if [[ "$MODE" == "manual" && "$FOREGROUND" != "1" && "${FRESHEYES_DAEMONIZED:-0}" != "1" ]]; then
  if ! command -v setsid &> /dev/null; then
    echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
    exit 2
  fi
  # Parent-owned identity: locator + initial status exist BEFORE the child
  # runs, so a child killed at launch still leaves a loud, diagnosable trail.
  write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
  if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
    write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
  fi
  write_status "launching" "" ""
  FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="$HANDLE" FRESHEYES_LOG_FILE="$LOG_FILE" \
  FRESHEYES_DETACH_METHOD="$DETACH_METHOD" \
    setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>>"$LAUNCH_STDERR" &
  echo "FRESHPID=$HANDLE"
  exit 0
fi
```

3d. **Child/foreground side.** At the old tracker-write site (`:250-265`), now after the detach block:
- `OWNER_PID=$$` on its own line before the first `write_status`/tracker call in the post-detach section (and before the `write_status "running" "" ""` at old `:379`).
- `.active` keyed by handle: `echo "$LOG_FILE" > "$LOG_DIR/.active.$HANDLE"` (old `:250`), and in `_cleanup` (old `:341`): `rm -f "$LOG_DIR/.active.$HANDLE"`.
- Locator writes keyed by handle (idempotent re-write of what the parent wrote, and the only write for foreground runs):

```bash
write_tracker_alias "$LOG_DIR" ".locator.$HANDLE"
if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
  write_tracker_alias "$GLOBAL_LOG_DIR" ".locator.$HANDLE"
fi
```
- DELETE both `.parent.$PPID` writes (old `:261` and `:264`) — the writer half of the atomic writer+reader deletion (reader went in Task 2).

3e. Anything else referencing the moved names still works because the variables are globals defined earlier now; run `bash -n skills/fresheyes/fresheyes.sh` and `grep -n 'active\.\$\$\|locator\.\$\$\|parent\.\$PPID' skills/fresheyes/fresheyes.sh` (expect no matches) to confirm nothing was missed.

- [ ] **Step 4: Run the new test**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS (`fresheyes-detach tests passed`). Both legs (a) and (b) green — leg (b) passes precisely because the handle is parent-minted, so setsid forking is irrelevant.

- [ ] **Step 5: Update the provider tests that encode the old receipt**

In `tests/fresheyes-claude-provider-test.sh`:
- `:390` — replace the numeric guard `[[ "$fresh_pid" =~ ^[0-9]+$ ]]` with `[[ "$fresh_pid" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]` (keep the `sed -n 's/^FRESHPID=//p'` parse at `:389`).
- `:399-412` (inside `test_manual_detaches_by_default_and_completes`) — the old assertion compared `$fresh_pid` to the detached session id. Replace: resolve the log base from `"$log_dir/.locator.$fresh_pid"`, poll until `<base>.status.json` contains `"owner_pid"`, extract it with python3, then assert the detach property against the OWNER pid:

```bash
locator="$log_dir/.locator.$fresh_pid"
[[ -f "$locator" ]] || fail "no locator for handle $fresh_pid"
base=$(tr -d '\n' < "$locator")
owner_pid=""
for _ in $(seq 1 100); do
  owner_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("owner_pid",""))' \
    "$base.status.json" 2>/dev/null || true)
  [[ -n "$owner_pid" ]] && break
  sleep 0.1
done
[[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "status.json never recorded owner_pid"
child_sid=$(ps -o sess= -p "$owner_pid" | tr -d '[:space:]' || true)
launcher_sid=$(ps -o sess= -p "$$" | tr -d '[:space:]')
if [[ -n "$child_sid" && "$child_sid" == "$launcher_sid" ]]; then
  fail "detached review shares the launcher's session"
fi
```
(Adjust to the surrounding test's variable names — it already has the log dir and a `FRESHEYES_FAKE_DELAY=2` slow provider so the child stays alive long enough to inspect. If the review finishes before `ps` sees the owner, an empty `child_sid` is acceptable — the assertion above only fails on a MATCHING session.)

In `tests/fresheyes-gpt-provider-test.sh`:
- `:208-211` — replace the numeric guard on the detached launch with the same handle regex `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`.

Also scan both files for other assumptions: `grep -n 'FRESHPID\|locator\|\.parent\|-\$\$\.log\|[0-9]\+\\.log' tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh` and fix any remaining pid-suffix filename expectations (log files are now named `fresheyes-<handle>.log`; `read_latest_file` at `claude:121-128` matches by glob and needs no change).

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do bash "$t" || exit 1; done`
Expected: five `... tests passed` lines.

- [ ] **Step 7: Commit**

```bash
git add skills/fresheyes/fresheyes.sh tests/fresheyes-detach-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh
git commit -m "feat: parent-owned opaque run handles

The foreground parent mints <ts>-<hex> handles, writes .locator.<handle>
and an initial launching status.json BEFORE detaching, and passes identity
to the child via FRESHEYES_HANDLE/FRESHEYES_LOG_FILE. The child derives
nothing from \$\$ and records its real pid as owner_pid. Child launch stderr
is captured to <log>.launch.stderr. .parent.\$PPID writer deleted."
```

---

### Task 4: real file-based heartbeat

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (anchors: `_start_heartbeat`/`_stop_heartbeat` — old `:492-509`; `_cleanup` — old `:332-347`; terminal `write_status` calls — old `:589`, `:591`, `:607`)
- Test: `tests/fresheyes-detach-test.sh`

**Interfaces:**
- Consumes: `STATUS_FILE`, `write_status`, `HEARTBEAT_PID` global, Task 3's status.json shape.
- Produces: `touch_heartbeat()` — atomically updates only `heartbeat_at` in status.json, and exits WITHOUT writing when the record is already in a terminal state (`complete`/`failed` — the exact terminal set Task 5 consumes); a background loop calls it every `${FRESHEYES_HEARTBEAT_SECS:-20}` seconds for the life of the review and self-terminates when the owner pid is gone (`kill -0` check each iteration — a SIGKILLed owner must not leave an orphan heartbeat masking `died`); `_stop_heartbeat` is called before EVERY terminal `write_status` so a stale heartbeat write can never clobber a terminal state. Task 5's `died` detection reads `heartbeat_at`.

- [ ] **Step 1: Write the failing test**

Add to `tests/fresheyes-detach-test.sh` (before the final `printf`), and add `test_heartbeat_advances` and `test_heartbeat_never_overwrites_terminal_state` to the call list:

```bash
# Heartbeat: with a slowed fake provider and a 1s heartbeat period, the
# status.json heartbeat_at field must advance while the review runs.
test_heartbeat_advances() {
  local log_dir="$TEST_TMP/logs-hb"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(FRESHEYES_HEARTBEAT_SECS=1 FRESHEYES_FAKE_DELAY=6 \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local base=""
  for _ in $(seq 1 50); do
    [[ -f "$log_dir/.locator.$handle" ]] && base=$(tr -d '\n' < "$log_dir/.locator.$handle") && break
    sleep 0.1
  done
  [[ -n "$base" ]] || fail "heartbeat test: locator never appeared"

  hb_at() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("heartbeat_at",0))' \
      "$base.status.json" 2>/dev/null || echo 0
  }
  local first="0"
  for _ in $(seq 1 50); do
    first=$(hb_at)
    [[ "$first" != "0" ]] && break
    sleep 0.1
  done
  [[ "$first" != "0" ]] || fail "heartbeat_at never written"
  sleep 2.5
  local second
  second=$(hb_at)
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) > float(sys.argv[1]) else 1)' \
    "$first" "$second" || fail "heartbeat_at did not advance ($first -> $second)"
  wait_for_state "$log_dir" "$handle" "complete" "heartbeat run completes" >/dev/null
}

# Terminal-state precedence: a stale touch_heartbeat must never resurrect
# state=running over a terminal record (the orphaned-python interleaving —
# kill $HEARTBEAT_PID covers only the subshell). Exercise the writer
# directly against a completed run's status.json.
test_heartbeat_never_overwrites_terminal_state() {
  local log_dir="$TEST_TMP/logs-hbterm"
  mkdir -p "$log_dir"
  local stdout handle base
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  handle=$(parse_handle "$stdout")
  wait_for_state "$log_dir" "$handle" "complete" "terminal-guard run completes" >/dev/null
  base=$(tr -d '\n' < "$log_dir/.locator.$handle")
  local fn
  fn=$(sed -n '/^touch_heartbeat()/,/^}/p' "$RUNNER")
  [[ -n "$fn" ]] || fail "touch_heartbeat not found in runner"
  local before after
  before=$(cat "$base.status.json")
  bash -c "STATUS_FILE='$base.status.json'; $fn; touch_heartbeat"
  after=$(cat "$base.status.json")
  [[ "$before" == "$after" ]] || fail "touch_heartbeat wrote over a terminal state:
before: $before
after:  $after"
}
```

Note: the fake claude in this file sleeps BEFORE emitting its result when `FRESHEYES_FAKE_DELAY` is set, keeping the review alive ~6s. If `env -u ANTHROPIC_API_KEY ... claude` invocation strips `FRESHEYES_FAKE_DELAY`, export it in `launch` the same way the model vars are passed.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL with `heartbeat_at did not advance` (Task 3's `write_status` sets `heartbeat_at` only on state writes; nothing updates it periodically — the old "heartbeat" is a 300s echo to a /dev/null stderr).

- [ ] **Step 3: Implement**

Replace `_start_heartbeat`/`_stop_heartbeat` (old `:492-509`) with:

```bash
# Liveness heartbeat: touch status.json's heartbeat_at every ~20s so the
# progress script can distinguish a live review from a dead one. Replaces
# the old 300s stderr echo, which was invisible when detached.
touch_heartbeat() {
  python3 - "$STATUS_FILE" <<'PY' || true
import json, os, sys, time
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        record = json.load(handle)
except Exception:
    record = {}
# Terminal-state precedence: `kill $HEARTBEAT_PID` covers only the subshell —
# an already-forked python can commit a whole stale record AFTER the terminal
# write, resurrecting state=running (later misread as died). Never write over
# a terminal state.
if record.get("state") in ("complete", "failed"):
    sys.exit(0)
record["heartbeat_at"] = time.time()
tmp_path = f"{path}.tmp.hb.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
os.replace(tmp_path, path)
PY
}

_start_heartbeat() {
  (
    while true; do
      sleep "${FRESHEYES_HEARTBEAT_SECS:-20}"
      # Self-terminate when the owner is gone: a SIGKILLed owner never runs
      # _stop_heartbeat, and an orphan loop beating status.json forever would
      # mask `died` permanently.
      kill -0 "${OWNER_PID:-$$}" 2>/dev/null || exit 0
      touch_heartbeat
    done
  ) &
  HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}
```

Then order every terminal write after a heartbeat stop (the heartbeat's read-modify-write must never race a terminal state):
- Insert `_stop_heartbeat` immediately before the automatic-mode terminal writes (old `:588-592` block).
- Insert `_stop_heartbeat` immediately before the manual-mode terminal write (old `:607`).
- In `_cleanup` (old `:332-347`): move the heartbeat kill (old `:342-345`) so it runs BEFORE the trap's `write_status` calls (old `:334-339`) — i.e. `_stop_heartbeat` is the first action in `_cleanup` after capturing `local status=$?`. Replace the inline kill with a `_stop_heartbeat` call.

`_start_heartbeat` stays invoked where it is today (old `:513`, after the initial `write_status "running"`).

- [ ] **Step 4: Run the tests**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `for t in tests/*.sh; do case "$t" in */manual/*) continue;; esac; bash "$t" || exit 1; done`
Expected: five `... tests passed` lines (glob does not descend into `tests/manual/`; the `case` guard is belt-and-braces).

- [ ] **Step 6: Commit**

```bash
git add skills/fresheyes/fresheyes.sh tests/fresheyes-detach-test.sh
git commit -m "feat: file-based heartbeat every 20s

The detached child touches status.json heartbeat_at from a background
loop (FRESHEYES_HEARTBEAT_SECS, default 20). Heartbeat stops before any
terminal status write, never writes over a terminal state (a mid-flight
python outlives the subshell kill), and the loop self-terminates when
the owner pid dies (a SIGKILLed owner can't leave an orphan beat masking
died). Replaces the inert 300s stderr echo."
```

---

### Task 5: six-state model in fresheyes-progress.sh (the heart of fail-loud)

**Files:**
- Modify: `skills/fresheyes/fresheyes-progress.sh` (anchors: `missing` emissions `:615-643`; state synthesis `:645-678`; output dispatch `:680-712`; `print_json_status` `:359-466`; `print_result_or_pending` `:592-613`)
- Test: `tests/fresheyes-detach-test.sh`, `tests/fresheyes-progress-test.sh`

**Interfaces:**
- Consumes: Task 3's status.json fields (`state` incl. `launching`, `owner_pid`, `launched_at`, `heartbeat_at`, `detach_method`, `exit_code`, `verdict`), `<base>.launch.stderr`, Task 2's `_owner_pid_for_base`/guarded `_process_state`.
- Produces: exactly six caller-visible states with exit codes — `launching` (0), `running` (0), `complete` (0), `killed_at_launch` (3), `died` (4), `unknown_handle` (5). A child-recorded `state=failed` maps to `died` with the recorded `exit_code` quoted in the message (six states exactly; "failed" is no longer a caller-visible state). JSON gains always-present `handle`, plus passthrough `detach_method`, `heartbeat_at`, `launched_at` when present in status.json. `state=missing` no longer exists anywhere. Task 6's SKILL.md documents exactly this table.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fresheyes-detach-test.sh` (register all in the call list at the bottom):

```bash
# --- (c) killed at launch: a fake setsid that launches NOTHING simulates the
# harness killing the child before its first write (parent-side artifacts
# only), exactly like the codex exec field failure.
make_noop_setsid() {
  cat > "$FAKE_BIN/setsid" <<'FAKE'
#!/usr/bin/env bash
# Swallow the child: simulates the harness tree-kill landing before the
# child's first write. Consumes stdin/stdout silently.
exit 0
FAKE
  chmod +x "$FAKE_BIN/setsid"
}

make_crashing_setsid() {
  cat > "$FAKE_BIN/setsid" <<'FAKE'
#!/usr/bin/env bash
echo "boom: provider exploded during startup" >&2
exit 1
FAKE
  chmod +x "$FAKE_BIN/setsid"
}

remove_fake_setsid() {
  rm -f "$FAKE_BIN/setsid"
}

test_killed_at_launch_harness_variant() {
  local log_dir="$TEST_TMP/logs-c1"
  mkdir -p "$log_dir"
  make_noop_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  remove_fake_setsid
  local handle
  handle=$(parse_handle "$stdout")

  sleep 2  # exceed the (overridden) launch grace
  local output rc
  set +e
  output=$(FRESHEYES_LAUNCH_GRACE_SECS=1 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 3 ]] || fail "killed_at_launch exit code: got $rc, want 3"
  [[ "$(json_field "$output" "state")" == "killed_at_launch" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "never wrote its first heartbeat" "killed_at_launch observation"
  assert_contains "$message" "kills or reaps detached processes" "killed_at_launch likely cause (hedged)"
  assert_contains "$message" "--foreground" "killed_at_launch remediation"
}

test_killed_at_launch_crashed_variant() {
  local log_dir="$TEST_TMP/logs-c2"
  mkdir -p "$log_dir"
  make_crashing_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  remove_fake_setsid
  local handle
  handle=$(parse_handle "$stdout")

  sleep 2
  local output rc
  set +e
  output=$(FRESHEYES_LAUNCH_GRACE_SECS=1 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 3 ]] || fail "crashed-at-launch exit code: got $rc, want 3"
  [[ "$(json_field "$output" "state")" == "killed_at_launch" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "crashed" "crashed variant names the crash"
  assert_contains "$message" "launch.stderr" "crashed variant points at stderr file"
}

# --- (d) died mid-review: kill the whole review session, heartbeat goes stale.
test_died_midreview() {
  local log_dir="$TEST_TMP/logs-d"
  mkdir -p "$log_dir"
  local stdout
  stdout=$(FRESHEYES_HEARTBEAT_SECS=1 FRESHEYES_FAKE_DELAY=20 \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local output
  output=$(wait_for_state "$log_dir" "$handle" "running" "died-test reaches running")
  local owner_pid
  owner_pid=$(json_field "$output" "owner_pid")
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || fail "no owner_pid while running: $output"
  # Kill the whole detached session (child + heartbeat + provider).
  pkill -9 -s "$owner_pid" 2>/dev/null || kill -9 "$owner_pid" 2>/dev/null || true
  sleep 3   # > 2x the 1s heartbeat; we poll with a 2s staleness override

  local rc
  set +e
  output=$(FRESHEYES_HEARTBEAT_STALE_SECS=2 poll_json "$log_dir" "$handle")
  rc=$?
  set -e
  [[ "$rc" -eq 4 ]] || fail "died exit code: got $rc, want 4 (output: $output)"
  [[ "$(json_field "$output" "state")" == "died" ]] || fail "state: $output"
  local message log_path
  message=$(json_field "$output" "message")
  log_path=$(json_field "$output" "log_path")
  assert_contains "$message" "$log_path" "died message leads with log path"
  assert_contains "$message" "--foreground" "died message offers foreground re-run"
  assert_contains "$message" "Last sign of life" "died message includes time of death"
}

# --- (e) unknown handle
test_unknown_handle() {
  local log_dir="$TEST_TMP/logs-e"
  mkdir -p "$log_dir"
  local output rc
  set +e
  output=$(poll_json "$log_dir" "20990101-000000-deadbe")
  rc=$?
  set -e
  [[ "$rc" -eq 5 ]] || fail "unknown_handle exit code: got $rc, want 5"
  [[ "$(json_field "$output" "state")" == "unknown_handle" ]] || fail "state: $output"
  local message
  message=$(json_field "$output" "message")
  assert_contains "$message" "no tracker for this handle" "unknown_handle observation"
  assert_contains "$message" "trackers were removed" "unknown_handle hedged cause"
}

# --- launching state right after a (stalled) launch
test_launching_state_is_calm() {
  local log_dir="$TEST_TMP/logs-l"
  mkdir -p "$log_dir"
  make_noop_setsid
  local stdout
  stdout=$(launch "$log_dir" "$RUNNER" --claude "review HEAD")
  remove_fake_setsid
  local handle
  handle=$(parse_handle "$stdout")
  # Within the 15s default grace: launching, exit 0, calm message.
  local output
  output=$(poll_json "$log_dir" "$handle") || fail "launching poll must exit 0"
  [[ "$(json_field "$output" "state")" == "launching" ]] || fail "state: $output"
  assert_contains "$(json_field "$output" "message")" "poll again in ~15s" "launching message"
}

# --- (f) progress never writes, across every state
test_progress_read_only_all_states() {
  for dir in "$TEST_TMP"/logs-*; do
    [[ -d "$dir" ]] || continue
    local before after
    before=$(snapshot_dir "$dir")
    for locator in "$dir"/.locator.*; do
      [[ -e "$locator" ]] || continue
      local handle="${locator##*/.locator.}"
      FRESHEYES_LAUNCH_GRACE_SECS=1 FRESHEYES_HEARTBEAT_STALE_SECS=2 \
        poll_json "$dir" "$handle" >/dev/null 2>&1 || true
      TMPDIR="$TEST_TMP" FRESHEYES_LOG_DIR="$dir" FRESHEYES_GLOBAL_LOG_DIR="$dir" \
        timeout 30s bash "$PROGRESS" --result "$handle" >/dev/null 2>&1 || true
    done
    poll_json "$dir" "20990101-000000-deadbe" >/dev/null 2>&1 || true
    after=$(snapshot_dir "$dir")
    [[ "$before" == "$after" ]] || fail "progress mutated $dir:
--- before ---
$before
--- after ---
$after"
  done
}
```

Order the calls so `test_progress_read_only_all_states` runs LAST (it sweeps the dirs the earlier tests created).

`FRESHEYES_LAUNCH_GRACE_SECS` / `FRESHEYES_HEARTBEAT_STALE_SECS` env overrides must be forwarded by `poll_json` — extend `poll_json` to pass them through:

```bash
poll_json() {
  local log_dir="$1" handle="$2"
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" \
  FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  FRESHEYES_LAUNCH_GRACE_SECS="${FRESHEYES_LAUNCH_GRACE_SECS:-15}" \
  FRESHEYES_HEARTBEAT_STALE_SECS="${FRESHEYES_HEARTBEAT_STALE_SECS:-60}" \
  timeout 30s bash "$PROGRESS" --json "$handle"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL — current script emits `state=missing`/`failed` with exit 0 everywhere in `--json` mode; none of the six-state assertions hold.

- [ ] **Step 3: Implement the state machine**

In `skills/fresheyes/fresheyes-progress.sh`:

3a. **Replace both `missing` emissions with `unknown_handle`.** The main block currently at `:615-643`: keep the resolution flow, but when `LOG_FILE` is empty emit the new state. Replace the PID-path branch (old `:617-627`) with:

```bash
  if [[ -z "$LOG_FILE" ]]; then
    UNKNOWN_MSG="no tracker for this handle in $LOG_DIR"
    if [[ "$GLOBAL_LOG_DIR" != "$LOG_DIR" ]]; then
      UNKNOWN_MSG="$UNKNOWN_MSG or $GLOBAL_LOG_DIR"
    fi
    UNKNOWN_MSG="$UNKNOWN_MSG — the handle is wrong, or its trackers were removed (e.g. /tmp cleanup)"
    if [[ "$OUTPUT_MODE" == "json" ]]; then
      print_json_status "unknown_handle" "" "$PID" "" "$(_process_state "$PID")" "" "" "$UNKNOWN_MSG"
      exit 5
    fi
    if [[ "$OUTPUT_MODE" == "result" ]]; then
      printf '%s\n' "$UNKNOWN_MSG"
      exit 5
    fi
    printf '%s\n' "$UNKNOWN_MSG"
    exit 5
  fi
```

and the legacy no-PID branch (old `:631-641`) equivalently (message `"no active Fresh Eyes review found in $LOG_DIR — the handle is wrong, or its trackers were removed (e.g. /tmp cleanup)"`, same exit 5 in all modes). Delete the words `missing` from both. Grep check afterwards: `grep -n '"missing"' skills/fresheyes/fresheyes-progress.sh` must show ONLY the `_process_state` pid-state value at old `:87-88` (process-level `pid_state=missing` is a different field and stays).

3b. **Replace the state synthesis** (old `:645-678`) with:

```bash
OWNER_PID=$(_owner_pid_for_base "$LOG_FILE" 2>/dev/null || true)
REQUESTED_PID_STATE=$(_process_state "$PID")
OWNER_PID_STATE=""
if [[ -n "$OWNER_PID" && "$OWNER_PID" != "$PID" ]]; then
  OWNER_PID_STATE=$(_process_state "$OWNER_PID")
fi

STATUS_STATE=$(status_file_field "$LOG_FILE" "state" 2>/dev/null || true)
STATUS_VERDICT=$(status_file_field "$LOG_FILE" "verdict" 2>/dev/null || true)
STATUS_EXIT_CODE=$(status_file_field "$LOG_FILE" "exit_code" 2>/dev/null || true)
HEARTBEAT_AT=$(status_file_field "$LOG_FILE" "heartbeat_at" 2>/dev/null || true)
LAUNCHED_AT=$(status_file_field "$LOG_FILE" "launched_at" 2>/dev/null || true)
NOW_EPOCH=$(date +%s)
STALE_SECS="${FRESHEYES_HEARTBEAT_STALE_SECS:-60}"
LAUNCH_GRACE_SECS="${FRESHEYES_LAUNCH_GRACE_SECS:-15}"

_owner_alive() {
  [[ -n "$OWNER_PID" ]] || return 1
  [[ "$(_process_state "$OWNER_PID")" == "active" ]]
}

_epoch_within() {
  # _epoch_within <epoch> <window_secs> : true when now - epoch < window
  local epoch="$1" window="$2"
  [[ -n "$epoch" ]] || return 1
  python3 - "$epoch" "$NOW_EPOCH" "$window" <<'PY'
import sys
epoch, now, window = (float(a) for a in sys.argv[1:4])
sys.exit(0 if now - epoch < window else 1)
PY
}

# Verdict extraction: status.json wins over raw-log regex (Codex logs can
# contain verdict-shaped examples).
VERDICT=""
if [[ -n "$STATUS_STATE" ]]; then
  if [[ "$STATUS_STATE" == "complete" && "$STATUS_VERDICT" =~ ^(passed|failed)$ ]]; then
    VERDICT="$STATUS_VERDICT"
  fi
else
  VERDICT=$(detect_manual_verdict "$LOG_FILE" 2>/dev/null || true)
fi

MESSAGE=""
STATE_EXIT_CODE=0
if [[ "$STATUS_STATE" == "complete" || -n "$VERDICT" ]]; then
  REVIEW_STATE="complete"
elif [[ "$STATUS_STATE" == "launching" ]]; then
  if _owner_alive || _epoch_within "$LAUNCHED_AT" "$LAUNCH_GRACE_SECS"; then
    REVIEW_STATE="launching"
    MESSAGE="review starting — poll again in ~15s"
  else
    REVIEW_STATE="killed_at_launch"
    STATE_EXIT_CODE=3
    MESSAGE=$(_killed_at_launch_message "$LOG_FILE")
  fi
elif [[ "$STATUS_STATE" == "failed" ]]; then
  # Terminal child-recorded failure: report immediately. This branch MUST
  # precede the heartbeat-freshness check — the runner stamps heartbeat_at
  # on the terminal "failed" write too, so freshness-first would mask a
  # recorded failure as healthy "running" for up to STALE_SECS.
  REVIEW_STATE="died"
  STATE_EXIT_CODE=4
  MESSAGE=$(_died_message "$LOG_FILE")
elif _epoch_within "$HEARTBEAT_AT" "$STALE_SECS" || _owner_alive; then
  REVIEW_STATE="running"
elif [[ -z "$STATUS_STATE" && ! -s "$LOG_FILE" && -n "$PID" ]] && ! _owner_alive; then
  # Resolvable handle but nothing was ever written and nobody is alive:
  # the child never started (e.g. killed between the parent's two writes).
  REVIEW_STATE="killed_at_launch"
  STATE_EXIT_CODE=3
  MESSAGE=$(_killed_at_launch_message "$LOG_FILE")
elif [[ -z "$PID" ]]; then
  # Legacy no-handle invocation has no liveness signal; preserve old default.
  REVIEW_STATE="running"
else
  REVIEW_STATE="died"
  STATE_EXIT_CODE=4
  MESSAGE=$(_died_message "$LOG_FILE")
fi
```

3c. **Add the two message builders** (near the other helpers, e.g. after `_owner_pid_for_base`):

```bash
# Message discipline for failure states: observation + likely cause +
# certain action, conditioned on captured evidence.
_killed_at_launch_message() {
  local base="$1"
  local launch_stderr="$base.launch.stderr"
  if [[ -s "$launch_stderr" ]]; then
    printf 'the review child crashed during launch — it wrote errors before dying (see %s; last lines: %s). Re-run the same command with --foreground to see the failure directly.' \
      "$launch_stderr" \
      "$(tail -n 3 "$launch_stderr" | tr '\n' ' ' | cut -c1-300)"
  else
    printf 'the review child never wrote its first heartbeat — commonly because the calling harness kills or reaps detached processes when the launch command exits; re-run the same command with --foreground (works regardless of cause)'
  fi
}

_died_message() {
  local base="$1"
  local died_epoch="${HEARTBEAT_AT:-$LAUNCHED_AT}"
  local died_human="unknown"
  if [[ -n "$died_epoch" ]]; then
    died_human=$(date -d "@${died_epoch%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$died_epoch")
  fi
  local recorded=""
  if [[ "$STATUS_STATE" == "failed" ]]; then
    recorded=" The runner recorded state=failed${STATUS_EXIT_CODE:+ (exit_code=$STATUS_EXIT_CODE)}."
  fi
  printf 'review died before producing a verdict — inspect the log at %s for evidence.%s Last sign of life: %s. To retry synchronously, re-run the same command with --foreground.' \
    "$base" "$recorded" "$died_human"
}
```

Note on the causal wording in `_killed_at_launch_message`: the harness-kill diagnosis is hedged deliberately ("commonly because ... kills or reaps"), never asserted as fact. If Task 1's verdict is `PREMISE: INCONCLUSIVE` (cell A survived — the tree-kill diagnosis itself unproven), the message must NOT assert the harness-kill diagnosis as established; keep the hedged wording above or weaken it further. The state machine and the `--foreground` remediation are unchanged either way.

3d. **Output dispatch** (old `:680-712`):
- `--json` (old `:681-682`): pass `"$MESSAGE"` as the 8th arg to `print_json_status`, then `exit "$STATE_EXIT_CODE"` instead of `exit 0`.
- `--result` (old `:685-688`): `complete` keeps today's behavior via `print_result_or_pending`. Before that dispatch, add:

```bash
if [[ "$REVIEW_STATE" == "killed_at_launch" || "$REVIEW_STATE" == "died" ]]; then
  printf '%s\n' "$MESSAGE"
  print_failure_diagnostic "$LOG_FILE"
  exit "$STATE_EXIT_CODE"
fi
```
- Legacy text mode: replace the old `failed` branch (old `:698-704`, whose `rm` already died in Task 2) with the same message+diagnostic+`exit "$STATE_EXIT_CODE"` for the two failure states; `launching` prints its message and exits 0; `complete`/`running` branches unchanged.
- Inside `print_result_or_pending` (old `:592-613`): the `failed` case (old `:604-606`) is unreachable now (state `failed` no longer synthesized) — delete it; the "not complete yet" fallthrough (old `:608-610`) still covers `running`/`launching` with exit 1 (unchanged `--result` contract for in-flight reviews).

3e. **`print_json_status` additions** (old `:359-466`): always set `record["handle"] = requested_pid` using the RAW string argument (before the `int()` coercion at old `:381` — keep the int-coerced `pid` field alongside for legacy readers); extend the status.json copy list at old `:448-450` from `("provider","mode","exit_code","updated_at_epoch")` to also copy `"detach_method"`, `"heartbeat_at"`, `"launched_at"`, `"owner_pid"` (skip any already in the record — same guard as today).

- [ ] **Step 4: Run the detach tests**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS — all of legs (c) both variants, (d), (e), the launching test, and the read-only sweep (f).

- [ ] **Step 5: Update the progress tests that encode old states**

Run: `bash tests/fresheyes-progress-test.sh` — expect failures where assertions encode the deleted states. Apply these mappings (find each by its assertion line):
- Fixtures with a dead pid and NO terminal status.json that previously asserted `state=failed`: now `died` when the log has content, `killed_at_launch` when the log is missing/empty. Update the expected values accordingly and add `FRESHEYES_HEARTBEAT_STALE_SECS`/`FRESHEYES_LAUNCH_GRACE_SECS` overrides only if a test would otherwise wait.
- The fixture with `{"state":"failed",...,"exit_code":1}` (`:318` area): expect `state=died` and assert the message contains `exit_code=1`. IMPORTANT: also add a FRESH `"heartbeat_at"` to this fixture (write it at test runtime, e.g. `"heartbeat_at": $(date +%s)`), because the real runner stamps `heartbeat_at` on the terminal `failed` write; without it the test passes vacuously and would not catch a state machine that checks heartbeat freshness before the `failed` branch (which would misreport the failure as `running` for up to `FRESHEYES_HEARTBEAT_STALE_SECS`).
- `test_global_locator_ignores_external_log_by_default` (old `:485`): expected state changes `missing` → `unknown_handle`; the recovery leg via `FRESHEYES_ALLOW_LEGACY_PROGRESS=1 --result` is unchanged.
- Any test asserting `--json` always exits 0 for these fixtures: expect 3/4/5 per the table.
- Tests asserting `state=running` for live-pid fixtures keep passing (owner alive → running).

Also update the two example-JSON expectations if any test string-matches full payloads (the new `handle` field changes sorted-key output).

- [ ] **Step 6: Run the full suite**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do bash "$t" || exit 1; done`
Expected: five `... tests passed` lines. (The gpt detached-poll test asserts `runner_state`, which is a passthrough and unaffected.)

- [ ] **Step 7: Commit**

```bash
git add skills/fresheyes/fresheyes-progress.sh tests/fresheyes-detach-test.sh tests/fresheyes-progress-test.sh
git commit -m "feat: explicit six-state progress model with loud remediation

States: launching(0) running(0) complete(0) killed_at_launch(3) died(4)
unknown_handle(5). killed_at_launch conditions its message on the captured
launch.stderr; died leads with the log path and time of death. The legacy
'missing' state is deleted. Child-recorded failures surface as died with
the recorded exit_code."
```

---

### Task 6: two-line self-instructing receipt + SKILL.md (the UI ships with the behavior)

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (the receipt echo added in Task 3)
- Modify: `skills/fresheyes/SKILL.md` (anchors: Step 4 `:56-74`, Step 5 `:76-108`, Step 6 `:110-121`)
- Test: `tests/fresheyes-detach-test.sh`

**Interfaces:**
- Consumes: Task 3's `SCRIPT_DIR` (defined at fresheyes.sh old `:176`), `HANDLE`; Task 5's state table.
- Produces: the final launch receipt, exactly two lines:

```
FRESHPID=<handle>
NEXT: bash <script-dir>/fresheyes-progress.sh --json <handle>   (reviews take 5-30 min; poll every 30-60s)
```

- [ ] **Step 1: Write the failing test**

Add to `tests/fresheyes-detach-test.sh` and register it:

```bash
test_receipt_is_exactly_two_lines() {
  local log_dir="$TEST_TMP/logs-receipt"
  mkdir -p "$log_dir"
  local stdout_file="$TEST_TMP/receipt-stdout.txt"
  launch "$log_dir" "$RUNNER" --claude "review HEAD" > "$stdout_file"
  local lines
  lines=$(wc -l < "$stdout_file")
  [[ "$lines" -eq 2 ]] || fail "receipt must be exactly 2 lines, got $lines:
$(cat "$stdout_file")"
  local handle
  handle=$(parse_handle "$(cat "$stdout_file")")
  local second
  second=$(sed -n '2p' "$stdout_file")
  assert_contains "$second" "NEXT: bash " "receipt line 2 prefix"
  assert_contains "$second" "/fresheyes-progress.sh --json $handle" "receipt line 2 poll command"
  assert_contains "$second" "reviews take 5-30 min; poll every 30-60s" "receipt line 2 cadence"
  # Guardrails: no NOTE/warning line, no status-file path.
  if grep -qi 'NOTE\|warning' "$stdout_file"; then
    fail "receipt must not contain a NOTE/warning line"
  fi
  if grep -q 'status\.json' "$stdout_file"; then
    fail "receipt must not print the status-file path"
  fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL with `receipt must be exactly 2 lines, got 1`.

- [ ] **Step 3: Implement the receipt**

In the detach block (Task 3's version), replace `echo "FRESHPID=$HANDLE"` with:

```bash
  echo "FRESHPID=$HANDLE"
  echo "NEXT: bash $SCRIPT_DIR/fresheyes-progress.sh --json $HANDLE   (reviews take 5-30 min; poll every 30-60s)"
```

(`SCRIPT_DIR` is absolute — defined before the detach block at old `:176`. If Task 3's restructure left `SCRIPT_DIR` defined after the identity block, verify it precedes the detach block; move it earlier if needed.)

- [ ] **Step 4: Run the tests**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS. Also run `bash tests/fresheyes-claude-provider-test.sh` and `bash tests/fresheyes-gpt-provider-test.sh` — if either asserts the receipt stdout contains ONLY the FRESHPID line or parses stdout line-count, relax it to "contains the FRESHPID line" (the `sed -n 's/^FRESHPID=//p'` parses are line-anchored and tolerate the second line already).

- [ ] **Step 5: Rewrite SKILL.md**

Replace Step 4's receipt block (old `:66-74`) with:

```markdown
Manual reviews detach automatically, so this returns within a couple of seconds and prints exactly two lines:

```
FRESHPID=20260729-181530-a3f9c2
NEXT: bash <base-directory>/fresheyes-progress.sh --json 20260729-181530-a3f9c2   (reviews take 5-30 min; poll every 30-60s)
```

Read the value after `FRESHPID=` — an OPAQUE run handle (not a process id; do not pass it to `ps` or `kill`). Save it; it is your handle for the entire review lifecycle (polling in Step 5, result retrieval in Step 7). The `NEXT:` line is the exact poll command to run. If no `FRESHPID=` line is printed, do not proceed to Step 5 — report the command's output to the user.

Do not add `setsid`, a trailing `&`, output redirects, or `$!` — the script backgrounds itself. Run the command exactly as above and read the receipt from its output. Do not add `--foreground` preemptively: it blocks for the full review (5-30 minutes). Use it only when a poll tells you to (see the state table below) — and when you do, first make sure your harness/exec timeout for that call is longer than the review (request/configure a timeout of at least 30 minutes).
```

Replace Step 5's poll cadence + field docs (old `:76-108`) so that: the poll command is the receipt's `NEXT:` line, the cadence is every 30-60 seconds, and the states table reads:

```markdown
Each poll returns one JSON line. The `state` field and the command's exit code tell you everything:

| state | exit | meaning | what you do |
|---|---|---|---|
| `launching` | 0 | the review child is starting; no heartbeat yet | poll again in ~15s |
| `running` | 0 | fresh heartbeat; review in progress | keep polling every 30-60s |
| `complete` | 0 | verdict present (`verdict`: `passed`/`failed`) | fetch the review with `--result` (Step 7) |
| `killed_at_launch` | 3 | the child never wrote its first heartbeat | do what the `message` says: re-run the SAME command with `--foreground`, with a harness/exec timeout longer than the review (5-30 min) |
| `died` | 4 | heartbeat went stale and the review process is gone, no verdict | inspect the log at the path in `message` first (evidence); optionally re-run with `--foreground` |
| `unknown_handle` | 5 | no tracker for this handle | the handle is wrong, or its trackers were removed (e.g. /tmp cleanup); re-check the receipt, else relaunch |

`launching` and `running` are healthy states — never treat them as failures, and never abort a poll loop on them. The three failure states carry a `message` field with the observation, likely cause, and the exact remediation; relay it and follow it.

Poll exit-tolerantly: the failure states return NONZERO exit codes (3/4/5), so a `set -e`-style loop would abort on the very poll that carries the diagnosis. Capture the output and branch on the JSON `state` field (or the captured exit code):

    output=$(bash <base-directory>/fresheyes-progress.sh --json <handle> || true)

then read `state` from the captured JSON. Never let a nonzero poll exit kill your loop before you have read the `message`.
```

(The receipt latency wording is deliberately "a couple of seconds", not "<1 second" — the auto-path runtime probe's worst case is its hard 2s timeout. The exit-code table plus the exit-tolerant polling instruction matter beyond this repo: the `~/.codex/skills/fresheyes` copy syncs separately as a unit, so this SKILL.md text is what self-heals the polling contract for agents at rollout.)

Update Step 6 (old `:110-121`): map the actions to the six states (delete the `missing` line at old `:117`); keep the "never kill a review" and stall-escalation guidance. Keep Step 7 (`--result`), Parallel reviews, and Common Mistakes sections, updating any `missing`/digit-parsing/120s references. Keep the frontmatter untouched. Do NOT document `detach_method` internals beyond the state table, and do not tell callers to read status.json directly (old `:146`'s "never read the log directly" rule stays).

- [ ] **Step 6: Verify SKILL.md consistency**

Run: `grep -n 'missing\|digits\|120 seconds\|every 2 minutes' skills/fresheyes/SKILL.md`
Expected: no output (or only benign matches you can justify — e.g. none).
Run: `grep -c 'killed_at_launch' skills/fresheyes/SKILL.md`
Expected: at least 1.

- [ ] **Step 7: Run the full suite and commit**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do bash "$t" || exit 1; done`
Expected: five `... tests passed` lines.

```bash
git add skills/fresheyes/fresheyes.sh skills/fresheyes/SKILL.md tests/fresheyes-detach-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh
git commit -m "feat: self-instructing two-line receipt; SKILL.md documents the six states

Receipt is exactly FRESHPID=<handle> plus the NEXT: poll command (no NOTE
line, no status path). SKILL.md now documents all six states with exit
codes and caller actions, and gives honest --foreground guidance: it is
the remediation for killed_at_launch and requires a harness timeout
longer than the review."
```

---

### Task 7: provider binary-path plumbing (item 2 — plumbing only, no safety claims)

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (anchors: codex validation `:109-132`, claude validation `:135-161`, provider run functions old `:397-490`, detach env prefix from Task 3)
- Test: `tests/fresheyes-detach-test.sh`

**Interfaces:**
- Consumes: Task 3's detach env-prefix line.
- Produces: parent resolves `CODEX_BIN="$(command -v codex)"` / `CLAUDE_BIN="$(command -v claude)"` during validation and forwards them to the child as `FRESHEYES_CODEX_BIN` / `FRESHEYES_CLAUDE_BIN`. The daemonized child, when a forwarded bin is present, verifies it is executable (cheap re-check) and SKIPS the full `command -v` + version re-parsing; provider run functions invoke `"$CODEX_BIN"` / `"$CLAUDE_BIN"` instead of bare names. Critical for Task 8, where the systemd-run unit does not inherit the caller's PATH (codex/claude live under nvm).

- [ ] **Step 1: Write the failing test**

Add to `tests/fresheyes-detach-test.sh` and register:

```bash
test_forwarded_bin_cheap_recheck() {
  local log_dir="$TEST_TMP/logs-bin"
  mkdir -p "$log_dir"
  # Daemonized child with a bogus forwarded binary must fail loudly.
  local rc
  set +e
  FRESHEYES_DAEMONIZED=1 FRESHEYES_CLAUDE_BIN="$TEST_TMP/does-not-exist" \
    launch "$log_dir" "$RUNNER" --claude "review HEAD" >/dev/null 2>"$TEST_TMP/bin-err.txt"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "bogus forwarded binary must fail"
  assert_contains "$(cat "$TEST_TMP/bin-err.txt")" "not executable" "cheap re-check message"

  # A valid forwarded binary is used directly: strip the fake bin from PATH
  # and rely solely on FRESHEYES_CLAUDE_BIN. Version re-parsing is skipped.
  TMPDIR="$TEST_TMP" \
  FRESHEYES_LOG_DIR="$log_dir" FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
  FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
  FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="20260729-130000-abcdef" \
  FRESHEYES_LOG_FILE="$log_dir/fresheyes-20260729-130000-abcdef.log" \
  FRESHEYES_CLAUDE_BIN="$FAKE_BIN/claude" \
    timeout 30s bash "$RUNNER" --claude "review HEAD" >/dev/null \
    || fail "forwarded valid binary should run the review without PATH"
  local status="$log_dir/fresheyes-20260729-130000-abcdef.log.status.json"
  local final_state
  final_state=$(json_field "$(cat "$status")" "state")
  [[ "$final_state" == "complete" ]] || fail "forwarded-bin review state: $final_state"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL — currently the child always re-runs `command -v claude`, which fails with the fake bin off PATH, and no "not executable" message exists.

- [ ] **Step 3: Implement**

3a. In the codex validation section (old `:109-132`), wrap it:

```bash
if [[ "${FRESHEYES_DAEMONIZED:-0}" == "1" && -n "${FRESHEYES_CODEX_BIN:-}" ]]; then
  # Parent already validated the CLI + version; cheap re-check only.
  if [[ ! -x "$FRESHEYES_CODEX_BIN" ]]; then
    echo "Error: forwarded codex binary '$FRESHEYES_CODEX_BIN' is not executable." >&2
    exit 1
  fi
  CODEX_BIN="$FRESHEYES_CODEX_BIN"
else
  # ... existing command -v + version checks, unchanged ...
  CODEX_BIN="$(command -v codex)"
fi
```

Apply the same shape to the claude section (old `:135-161`) with `CLAUDE_BIN`/`FRESHEYES_CLAUDE_BIN`. The wrapping goes around the provider-specific branch that already exists (only the active provider is validated — keep that behavior; set the BIN var only for the active provider).

3b. In the provider run functions: replace bare `codex` invocations (old `:398`, `:419` — the `if ! codex exec \` lines) with `"$CODEX_BIN"` and bare `claude` in the `env -u ... claude` invocations (old `:436`, `:466`) with `"$CLAUDE_BIN"`.

Note: two codex binaries exist on this dev machine (nvm npm 0.145.0 vs `~/.local/bin` standalone 0.146.0); `command -v` resolution follows the caller's PATH order, and forwarding whatever the parent resolved is the intended behavior.

3c. In the detach env prefix (Task 3's line), add the forwards:

```bash
  FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="$HANDLE" FRESHEYES_LOG_FILE="$LOG_FILE" \
  FRESHEYES_DETACH_METHOD="$DETACH_METHOD" \
  FRESHEYES_CODEX_BIN="${CODEX_BIN:-}" FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-}" \
    setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>>"$LAUNCH_STDERR" &
```

(Guard with `${VAR:-}` — only the active provider's BIN is set under `set -u`. The `FRESHEYES_DETACH_METHOD` forward is Task 3's line, kept as-is.)

- [ ] **Step 4: Run the tests**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite and commit**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do bash "$t" || exit 1; done`
Expected: five passes.

```bash
git add skills/fresheyes/fresheyes.sh tests/fresheyes-detach-test.sh
git commit -m "feat: forward absolute provider binary paths to the detached child

Parent resolves codex/claude via command -v once and forwards
FRESHEYES_CODEX_BIN/FRESHEYES_CLAUDE_BIN; the daemonized child does a
cheap is-executable re-check instead of full version re-parsing. Plumbing
needed because systemd-run units do not inherit the caller's PATH."
```

---

### Task 8: systemd-run detach path (GATED on Task 1's verdict)

**Files:**
- Modify: `skills/fresheyes/fresheyes.sh` (detach block from Tasks 3/6/7)
- Test: `tests/fresheyes-detach-test.sh`

**Interfaces:**
- Consumes: `tests/manual/SPIKE-RESULT.md` (`PREMISE: PASS` / `PREMISE: FAIL` / `PREMISE: INCONCLUSIVE`); Task 3's `DETACH_METHOD` global (child inherits the parent's method via `FRESHEYES_DETACH_METHOD`) and `write_status` (which overwrites `detach_method`); Task 7's `FRESHEYES_*_BIN` forwarding.
- Produces: `_probe_systemd_run()` (runtime probe with a hard 2s timeout, by launching a trivial unit — never `command -v` alone); `launch_via_systemd_run()`; env override `FRESHEYES_DETACH=auto|setsid|systemd-run` (default `auto`); `detach_method` recorded in status.json (`systemd-run` or `setsid`); caller-facing receipt IDENTICAL on both paths.

- [ ] **Step 0: Read the gate**

Run: `grep '^PREMISE:' tests/manual/SPIKE-RESULT.md`
- Anything other than the literal `PREMISE: PASS` (i.e. `PREMISE: FAIL`, `PREMISE: INCONCLUSIVE`, or a missing/mangled line) is treated as FAIL: do NOT build the systemd-run mechanism. This task reduces to: (a) confirm `detach_method` is always `setsid` in status.json (already true from Task 3); (b) append a short section to `tests/manual/SPIKE-RESULT.md` titled `## Outcome` stating "systemd-run detach dropped per spike (verdict: FAIL or INCONCLUSIVE — quote it); setsid remains the only detach path; the shipped product is the loud killed_at_launch detection + remediation"; (c) commit that note (`git commit -m "docs: record systemd-run premise failure; detach stays setsid-only"`) and mark the remaining steps of this task complete. Items 1, 4, 5 stand fully regardless.
- If the line is exactly `PREMISE: PASS`: proceed with all steps below.

- [ ] **Step 1: Write the failing tests**

Add to `tests/fresheyes-detach-test.sh` and register:

```bash
# Fake systemd-run: records its argv, then execs the wrapped command with
# the --setenv environment applied (simulating the unit's clean env).
make_fake_systemd_run() {
  cat > "$FAKE_BIN/systemd-run" <<'FAKE'
#!/usr/bin/env bash
argv_log="${FRESHEYES_TEST_SDRUN_ARGV:?}"
printf '%s\n' "$@" > "$argv_log"
declare -a child_env=() cmd=()
seen_cmd=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setenv)      child_env+=("$2"); shift 2 ;;
    --user|--collect|--quiet|--wait) shift ;;
    --property=*)  shift ;;
    *)             cmd+=("$1"); seen_cmd=1; shift ;;
  esac
done
if [[ "$seen_cmd" -eq 0 ]]; then exit 1; fi
# Run detached-ish: background with a clean env (unit semantics).
env -i "${child_env[@]}" "${cmd[@]}" &
exit 0
FAKE
  chmod +x "$FAKE_BIN/systemd-run"
}

test_systemd_run_detach_forwards_env_and_records_method() {
  local log_dir="$TEST_TMP/logs-sdrun"
  mkdir -p "$log_dir"
  make_fake_systemd_run
  local argv_log="$TEST_TMP/sdrun-argv.txt"
  local stdout
  stdout=$(FRESHEYES_DETACH=systemd-run FRESHEYES_TEST_SDRUN_ARGV="$argv_log" \
    launch "$log_dir" "$RUNNER" --claude "review HEAD")
  rm -f "$FAKE_BIN/systemd-run"
  local handle
  handle=$(parse_handle "$stdout")
  # Receipt shape identical to the setsid path (2 lines incl. NEXT).
  [[ "$(wc -l <<<"$stdout")" -eq 2 ]] || fail "systemd-run receipt not 2 lines: $stdout"

  local argv
  argv=$(cat "$argv_log")
  assert_contains "$argv" "--user" "sdrun argv --user"
  assert_contains "$argv" "--collect" "sdrun argv --collect"
  assert_contains "$argv" "FRESHEYES_DAEMONIZED=1" "sdrun forwards daemonize sentinel"
  assert_contains "$argv" "FRESHEYES_HANDLE=$handle" "sdrun forwards handle"
  assert_contains "$argv" "FRESHEYES_LOG_FILE=" "sdrun forwards log file"
  assert_contains "$argv" "FRESHEYES_DETACH_METHOD=systemd-run" "sdrun forwards detach method"
  assert_contains "$argv" "FRESHEYES_CLAUDE_BIN=" "sdrun forwards provider bin"
  assert_contains "$argv" "PATH=" "sdrun forwards PATH"
  assert_contains "$argv" "WorkingDirectory=" "sdrun sets working directory"
  assert_contains "$argv" "StandardError=append:" "sdrun captures launch stderr"

  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "systemd-run detach")
  [[ "$(json_field "$output" "detach_method")" == "systemd-run" ]] \
    || fail "detach_method not recorded: $output"
}

test_bus_absent_probe_falls_back_to_setsid() {
  local log_dir="$TEST_TMP/logs-nobus"
  mkdir -p "$log_dir"
  # No fake systemd-run on PATH; unset the bus env so the REAL probe (if
  # systemd-run exists) fails, engaging the setsid fallback.
  local stdout
  stdout=$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
    TMPDIR="$TEST_TMP" \
    FRESHEYES_LOG_DIR="$log_dir" FRESHEYES_GLOBAL_LOG_DIR="$log_dir" \
    FRESHEYES_CLAUDE_MODEL="" FRESHEYES_GPT_MODEL="" FRESHEYES_MODEL="" \
    PATH="$FAKE_BIN:$PATH" \
    timeout 60s bash "$RUNNER" --claude "review HEAD")
  local handle
  handle=$(parse_handle "$stdout")
  local output
  output=$(wait_for_state "$log_dir" "$handle" "complete" "bus-absent fallback")
  [[ "$(json_field "$output" "detach_method")" == "setsid" ]] \
    || fail "bus-absent launch should fall back to setsid: $output"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: FAIL — `FRESHEYES_DETACH` is unrecognized (launch uses setsid; `detach_method` stays `setsid` in the first test).

- [ ] **Step 3: Implement**

In `skills/fresheyes/fresheyes.sh`, add above the detach block:

```bash
# Runtime probe: systemd-run being installed is NOT enough (the user bus can
# be unreachable in some harnesses). Prove it by launching a trivial unit.
_probe_systemd_run() {
  command -v systemd-run &> /dev/null || return 1
  # Hard 2s cap (measured): healthy-bus probe is 0.02-0.28s, but a half-up
  # (accepting-but-mute) bus socket blocks the probe >40s in the sd-bus auth
  # handshake — dead/absent sockets fail in 0.01s, only the half-up case hangs.
  timeout 2s systemd-run --user --collect --quiet --wait /bin/true >/dev/null 2>&1
}

launch_via_systemd_run() {
  local script_abs="$SCRIPT_DIR/$(basename -- "$0")"
  local -a setenv_args=(
    --setenv "FRESHEYES_DAEMONIZED=1"
    --setenv "FRESHEYES_HANDLE=$HANDLE"
    --setenv "FRESHEYES_LOG_FILE=$LOG_FILE"
    --setenv "FRESHEYES_DETACH_METHOD=systemd-run"
    --setenv "PATH=$PATH"
    --setenv "HOME=$HOME"
  )
  # The unit inherits NOTHING from the caller: forward every var the child
  # needs explicitly (verified live: nvm-installed CLIs vanish otherwise).
  local var
  for var in FRESHEYES_LOG_DIR FRESHEYES_GLOBAL_LOG_DIR FRESHEYES_MODE \
             FRESHEYES_PROVIDER FRESHEYES_GPT_MODEL FRESHEYES_CLAUDE_MODEL \
             FRESHEYES_MODEL FRESHEYES_CODEX_BIN FRESHEYES_CLAUDE_BIN \
             FRESHEYES_HEARTBEAT_SECS TMPDIR \
             FRESHEYES_FAKE_ARGV FRESHEYES_FAKE_DELAY \
             FRESHEYES_FAKE_CLAUDE_VERSION FRESHEYES_FAKE_CLAUDE_VERSION_PROBE \
             FRESHEYES_FAKE_VERSION FRESHEYES_FAKE_VERSION_PROBE; do
    if [[ -n "${!var:-}" ]]; then
      setenv_args+=(--setenv "$var=${!var}")
    fi
  done
  FRESHEYES_CODEX_BIN="${CODEX_BIN:-}" FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-}" \
  systemd-run --user --collect --quiet \
    --property=WorkingDirectory="$PWD" \
    --property=StandardOutput=null \
    --property=StandardError="append:$LAUNCH_STDERR" \
    "${setenv_args[@]}" \
    /usr/bin/env bash "$script_abs" "${ORIG_ARGS[@]}" >/dev/null 2>>"$LAUNCH_STDERR"
}
```

(Note: `FRESHEYES_CODEX_BIN`/`FRESHEYES_CLAUDE_BIN` must be in the environment before the `for` loop reads them — set them from `CODEX_BIN`/`CLAUDE_BIN` right before building `setenv_args`: `FRESHEYES_CODEX_BIN="${CODEX_BIN:-${FRESHEYES_CODEX_BIN:-}}"` and likewise for claude, as plain assignments at the top of the function.)

Replace the launch portion of the detach block (after the tracker/status writes) with:

```bash
  DETACH_METHOD="setsid"
  case "${FRESHEYES_DETACH:-auto}" in
    systemd-run) DETACH_METHOD="systemd-run" ;;
    setsid)      DETACH_METHOD="setsid" ;;
    auto)        if _probe_systemd_run; then DETACH_METHOD="systemd-run"; fi ;;
    *)           echo "Error: FRESHEYES_DETACH must be auto, setsid, or systemd-run." >&2; exit 1 ;;
  esac

  # Status must carry the final detach_method BEFORE the child launches.
  # write_status overwrites detach_method, so the fallback rewrite below is
  # safe — and for the same reason the child MUST inherit the chosen method
  # via FRESHEYES_DETACH_METHOD (setsid env prefix / --setenv above): its
  # own writes would otherwise clobber the field back to "setsid".
  write_status "launching" "" ""
  if [[ "$DETACH_METHOD" == "systemd-run" ]]; then
    if ! launch_via_systemd_run; then
      DETACH_METHOD="setsid"
      write_status "launching" "" ""
    fi
  fi
  if [[ "$DETACH_METHOD" == "setsid" ]]; then
    if ! command -v setsid &> /dev/null; then
      echo "Error: cannot detach the review: setsid (util-linux) not found. Re-run with --foreground to run synchronously." >&2
      exit 2
    fi
    FRESHEYES_DAEMONIZED=1 FRESHEYES_HANDLE="$HANDLE" FRESHEYES_LOG_FILE="$LOG_FILE" \
    FRESHEYES_DETACH_METHOD="$DETACH_METHOD" \
    FRESHEYES_CODEX_BIN="${CODEX_BIN:-}" FRESHEYES_CLAUDE_BIN="${CLAUDE_BIN:-}" \
      setsid bash "$0" "${ORIG_ARGS[@]}" </dev/null >/dev/null 2>>"$LAUNCH_STDERR" &
  fi
  echo "FRESHPID=$HANDLE"
  echo "NEXT: bash $SCRIPT_DIR/fresheyes-progress.sh --json $HANDLE   (reviews take 5-30 min; poll every 30-60s)"
  exit 0
```

Ordering rules this preserves: `.locator` writes (Task 3) come first; method selection runs before the single authoritative `write_status "launching"`; `write_status` runs before ANY child exists; on systemd-run launch failure the status is re-written with `detach_method=setsid` before the setsid child launches. Remove Task 3's now-duplicated `write_status "launching"` call from earlier in the block (there must be exactly one launching write per method decision). The setsid-missing error now fires only when the setsid path is actually taken.

- [ ] **Step 4: Run the tests**

Run: `bash tests/fresheyes-detach-test.sh`
Expected: PASS. (`test_bus_absent_probe_falls_back_to_setsid` also passes on machines WITHOUT systemd-run: `_probe_systemd_run` fails at `command -v`, fallback engages.)

- [ ] **Step 5: Run the full suite and commit**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do bash "$t" || exit 1; done`
Expected: five passes. NOTE: on this dev machine `auto` may now select systemd-run for OTHER tests' detached launches — that is by design (caller-facing output identical). If any existing test breaks under systemd-run because the fake provider env is missing from the forward list, add the missing `FRESHEYES_FAKE_*` var to the `for` list in `launch_via_systemd_run` (test-only vars are forwarded like everything else; the unit inherits nothing).

```bash
git add skills/fresheyes/fresheyes.sh tests/fresheyes-detach-test.sh
git commit -m "feat: systemd-run --user detach with runtime probe and setsid fallback

Premise validated under real codex exec (tests/manual/SPIKE-RESULT.md):
a unit child of the user manager survives the harness tree-kill. Probe
launches a trivial unit at runtime (bus can be absent even when the
binary exists); every needed env var and absolute provider binary path
is forwarded via --setenv. detach_method recorded in status.json;
receipt identical on both paths. FRESHEYES_DETACH=auto|setsid|systemd-run."
```

- [ ] **Step 6: PASS-path pre-ship check — one REAL-provider detached review**

Clean-env bootstrap of both CLIs (PATH/HOME/TMPDIR only) is already verified, including inside a `--setenv` transient unit; this step closes only the remaining authenticated-review residual (auth/network paths a `--version` probe never exercises).

Run ONE real-provider detached review via systemd-run outside any harness — a plain terminal, normal product use, e.g.:

```bash
FRESHEYES_DETACH=systemd-run bash skills/fresheyes/fresheyes.sh --claude "review HEAD"
# then poll the printed NEXT: command until state=complete
```

Expected: the review reaches `complete` with a verdict. On failure: capture the transient unit's environment (`systemctl --user show -p Environment <unit>`, or log it from inside the unit) and close the gap with additional `--setenv` entries / `--property=EnvironmentFile=` — that is the designed fix path; do not fall back to forwarding the whole caller env. Note the outcome (one line) in `tests/manual/SPIKE-RESULT.md` under `## Outcome` and amend/commit.

---

### Task 9: real `codex exec` end-to-end leg + final verification

**Files:**
- Create: `tests/manual/codex-exec-e2e.sh`
- Modify: `tests/manual/SPIKE-RESULT.md` (append the e2e transcript)

**Interfaces:**
- Consumes: everything shipped in Tasks 2-8; Task 1's spike verdict; the real `codex` CLI.
- Produces: recorded proof (transcript in the commit message body and in `tests/manual/SPIKE-RESULT.md`) that (i) with `PREMISE: PASS`, a systemd-run-detached review launched INSIDE `codex exec` — slowed by `FRESHEYES_FAKE_DELAY=30` so it is still in flight when codex exec returns — has its owner process provably alive AFTER the recorded return time and then completes with a fake provider, and (ii) with the user bus absent, the probe fails, setsid fallback engages, the harness kills it, and polling reports `killed_at_launch` with the remediation text. With any non-PASS verdict, cell 1 is skipped and cell 2 is the whole product proof.

- [ ] **Step 1: Write the e2e script**

```bash
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
```

- [ ] **Step 2: Syntax-check and run for real**

Run: `bash -n tests/manual/codex-exec-e2e.sh && bash tests/manual/codex-exec-e2e.sh 2>&1 | tee /tmp/e2e-transcript.txt`
Expected: cell 1 prints `survival proven: owner <pid> alive after codex exec return` and then `cell 1 PASSED` (when premise PASS; both cells use FRESHEYES_FAKE_DELAY=30 so the review is still in flight when codex exec returns — without it the no-delay fake completes in ~0.5s and the cell is blind by arithmetic), and `cell 2 PASSED` (or the explicitly-noted INCONCLUSIVE variant if the harness happens not to kill on that run — the deterministic simulation in `tests/fresheyes-detach-test.sh` covers the state machine either way; in cell 2 the delay keeps the child mid-review long enough that a kill lands before completion). If cell 1 FAILS with premise PASS, STOP: the systemd-run path does not actually survive when carrying the full fresheyes child — investigate (most likely a missing `--setenv`) before proceeding; do not paper over it.

- [ ] **Step 3: Append the transcript**

Append to `tests/manual/SPIKE-RESULT.md`:

```markdown
## End-to-end transcript (Task 9)

<paste /tmp/e2e-transcript.txt verbatim>
```

- [ ] **Step 4: Final full-suite run**

Run: `for t in tests/fresheyes-progress-test.sh tests/fresheyes-claude-provider-test.sh tests/fresheyes-gpt-provider-test.sh tests/fresheyes-prompt-contract-test.sh tests/fresheyes-detach-test.sh; do echo "== $t"; bash "$t" || exit 1; done && bash -n skills/fresheyes/fresheyes.sh && bash -n skills/fresheyes/fresheyes-progress.sh && echo ALL GREEN`
Expected: five `... tests passed` lines then `ALL GREEN`.

- [ ] **Step 5: Commit (transcript in the body)**

```bash
git add tests/manual/codex-exec-e2e.sh tests/manual/SPIKE-RESULT.md
git commit -F- <<'MSG'
test: real codex exec e2e leg for detach survival and killed_at_launch

Cell 1: systemd-run-detached review launched inside real codex exec,
slowed by FRESHEYES_FAKE_DELAY=30 so it is still in flight at turn end;
its owner process is proven alive AFTER the recorded codex exec return,
then the review completes with the fake provider.
Cell 2: with the user bus absent the probe fails, setsid fallback
engages, the harness kill lands, and polling reports killed_at_launch
(exit 3) with the --foreground remediation.

Transcript:
<paste /tmp/e2e-transcript.txt here before committing>
MSG
```

---

## Verification checklist (maps spec requirement → covering task)

- Item 1 parent-owned identity, opaque handle, pre-detach locator+status, env handoff, owner_pid, `FRESHPID=<handle>` line, non-numeric `ps -p` guard, old numeric handles resolve → Tasks 2, 3.
- `.parent.$PPID` writer+reader deleted atomically → Task 2 (reader) + Task 3 (writer); interim window is safe because the reader deletion only removes a fallback.
- Item 2 plumbing (bin forwarding, cheap re-check, no safety claims) → Task 7.
- Item 3 systemd-run gated on the real-codex-exec spike (differential, N>=3 fingerprint-validated runs; only the literal `PREMISE: PASS` ships — FAIL/INCONCLUSIVE reduce to fallback-only); runtime probe with a hard 2s timeout (not `command -v` alone); explicit `--setenv` forwarding; PASS-path pre-ship real-provider detached review; `detach_method` recorded; identical receipt; setsid fallback → Tasks 1, 8.
- Item 4 six states with exit codes; killed_at_launch message conditioned on `<LOG_FILE>.launch.stderr` (empty → hedged kills-or-reaps wording + `--foreground`; non-empty → crashed + points at it); died leads with log path + time of death; `missing` deleted (both emission sites); heartbeat 20s via status.json touch replacing the 300s stderr echo; 60s staleness (≥2x period); progress strictly read-only (`rm -f .active.*` removed) → Tasks 2, 3 (stderr capture), 4, 5.
- Item 5 exactly-two-line receipt, no NOTE line, no status path → Tasks 3, 6.
- Item 6 → CUT; no task implements a launch-time warning.
- SKILL.md ships in the same change: new receipt, six states with exit codes and caller actions, honest `--foreground` guidance (remediation for killed_at_launch; requires harness timeout > 5-30 min and how to request it) → Task 6.
- Test matrix (a) plain launch → Task 3; (b) monitor-mode/setsid-fork regression → Task 3; (c) killed-child both variants → Task 5; (d) died mid-review → Task 5; (e) unknown handle → Task 5; (f) read-only sweep → Tasks 2, 5; (g) real codex exec leg + bus-absent cell, run at least once with transcript recorded → Tasks 1, 9.
- All four existing test files pass at every task boundary → each task's full-suite step.
