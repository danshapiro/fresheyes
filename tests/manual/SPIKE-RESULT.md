# systemd-run survival spike result

Date: Thu Jul 30 03:54:16 AM UTC 2026
Machine: WSL2 (see uname -a below)
uname -a: Linux DANDESKTOP 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun  5 18:30:46 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux

PREMISE: PASS   <!-- copied verbatim from the analyzer; Task 8 greps exactly this -->
RUNS: 3/3 cellA-killed, 3/3 cellB-survived   <!-- copied verbatim from the analyzer -->

- cell A (setsid under codex exec, 3 runs): KILLED 3/3 — per-run last-HB vs codex-exec-return timestamps below. In all 3 runs the setsid child died before writing a single heartbeat, ids file, or trap line (hbs=0, done=None, signals=none — consistent with an untrappable SIGKILL of the whole tree at/near launch).
- cell B (systemd-run under codex exec, 3 runs): SURVIVED 3/3 — 60 HBs per run, HB epochs after the recorded codex exec return, and DONE reached in every run (DONE at 1785383436.0 / 1785383475.0 / 1785383514.0 vs codex returns 1785383381.58 / 1785383416.51 / 1785383457.22).
- fingerprint checks: every accepted run nonce-validated with BUS_OK; zero INVALID RUN reruns occurred (all 6 codex exec runs accepted on first attempt).
- cell C (bus-absent probe): FAILED CLEANLY (probe fails without a bus, as expected — setsid fallback will engage)
- cell D (env inheritance): SENTINEL=UNSET (confirmed --setenv requirement; unit PATH was the bare system default with no nvm dirs)

Decision: Task 8 ships the systemd-run detach path.

## Per-run timestamps

codex exec [A run 1]: start=1785383328.848649301 return=1785383362.226820088
codex exec [B run 1]: start=1785383362.242227776 return=1785383381.580226705
codex exec [A run 2]: start=1785383381.615898250 return=1785383398.990674702
codex exec [B run 2]: start=1785383399.024302603 return=1785383416.506666765
codex exec [A run 3]: start=1785383416.528664162 return=1785383433.154917852
codex exec [B run 3]: start=1785383433.170645626 return=1785383457.215282205
run 1: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383436.0)
run 2: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383475.0)
run 3: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383514.0)

## Full transcript

```
spike dir: /tmp/fresheyes-spike.nGtFsU

=== cell A run 1/3: setsid under real codex exec ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb123-e87b-7590-a28a-e3db4acf045a
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo efc9b9165d700fe9; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-1 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 1
exec
/bin/bash -lc '{ echo efc9b9165d700fe9; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-1 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 1' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 2378ms:
launched setsid child: 2988940

codex
launched setsid child: 2988940
tokens used
20,172
launched setsid child: 2988940
codex exec [A run 1]: start=1785383328.848649301 return=1785383362.226820088

=== cell B run 1/3: systemd-run under real codex exec (THE load-bearing premise) ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb124-209f-70d1-aa60-227c4d6c885d
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo 72eb4f0f2ee0b8a4; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-1 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 1
exec
/bin/bash -lc '{ echo 72eb4f0f2ee0b8a4; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-1 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 1' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 5465ms:
systemd-run launch exit: 0

codex
systemd-run launch exit: 0
tokens used
20,174
systemd-run launch exit: 0
codex exec [B run 1]: start=1785383362.242227776 return=1785383381.580226705

=== cell A run 2/3: setsid under real codex exec ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb124-6d67-7a92-a9e9-f81534ccc067
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo 9aba1ab75aad1c18; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-2 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 2
exec
/bin/bash -lc '{ echo 9aba1ab75aad1c18; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-2 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 2' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 6879ms:
launched setsid child: 3014607

codex
launched setsid child: 3014607
tokens used
20,150
launched setsid child: 3014607
codex exec [A run 2]: start=1785383381.615898250 return=1785383398.990674702

=== cell B run 2/3: systemd-run under real codex exec (THE load-bearing premise) ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb124-b17f-7191-82bc-fc769ef858b5
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo 2b1af9a41bab0d2f; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-2 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 2
exec
/bin/bash -lc '{ echo 2b1af9a41bab0d2f; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-2 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 2' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 5760ms:
systemd-run launch exit: 0

codex
systemd-run launch exit: 0
tokens used
20,147
systemd-run launch exit: 0
codex exec [B run 2]: start=1785383399.024302603 return=1785383416.506666765

=== cell A run 3/3: setsid under real codex exec ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb124-f531-7ed3-b5e2-21f0652bfc88
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo c0c5188998d82a5d; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-3 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 3
exec
/bin/bash -lc '{ echo c0c5188998d82a5d; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-A-3 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-setsid.sh 3' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 6083ms:
launched setsid child: 3035262

codex
launched setsid child: 3035262
tokens used
2,028
launched setsid child: 3035262
codex exec [A run 3]: start=1785383416.528664162 return=1785383433.154917852

=== cell B run 3/3: systemd-run under real codex exec (THE load-bearing premise) ===
Reading additional input from stdin...
OpenAI Codex v0.146.0
--------
workdir: /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 019fb125-37b6-7843-85b7-c1a397410335
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: { echo 6077b0ac88a6dcae; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-3 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 3
exec
/bin/bash -lc '{ echo 6077b0ac88a6dcae; pwd; id -u; cat /proc/self/cgroup; test -S "$XDG_RUNTIME_DIR/bus" && echo BUS_OK || echo BUS_MISSING; } > /tmp/fresheyes-spike.nGtFsU/fingerprint-B-3 2>&1; bash /tmp/fresheyes-spike.nGtFsU/launch-systemd-run.sh 3' in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 6054ms:
systemd-run launch exit: 0

codex
systemd-run launch exit: 0
tokens used
20,174
systemd-run launch exit: 0
codex exec [B run 3]: start=1785383433.170645626 return=1785383457.215282205

waiting 70s for the final run's children to finish their >=60s heartbeat windows...
run 1: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383436.0)
run 2: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383475.0)
run 3: cellA killed=True (hbs=0 done=None signals=none) cellB survived=True (hbs=60 done=1785383514.0)
PREMISE: PASS
RUNS: 3/3 cellA-killed, 3/3 cellB-survived

=== cell C: user bus unreachable -> runtime probe must fail cleanly ===
cell C result: probe fails without a bus, as expected (setsid fallback will engage)

=== cell D: env is NOT inherited inside a unit (verifies the --setenv requirement) ===
SENTINEL=UNSET PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin
expected: SENTINEL=UNSET and a PATH without nvm dirs — every needed var must be forwarded via --setenv

Now record the verdict: edit tests/manual/SPIKE-RESULT.md, copy the analyzer's
literal 'PREMISE: ...' and 'RUNS: ...' lines verbatim (PASS / FAIL / INCONCLUSIVE),
and paste this full transcript into the file.
SPIKE_EXIT=0
```
