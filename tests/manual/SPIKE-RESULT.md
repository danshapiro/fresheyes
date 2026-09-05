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

## Outcome

Task 8 pre-ship check (2026-07-29): real detached review via `FRESHEYES_DETACH=systemd-run` from a plain terminal reached `state=complete` with a verdict (handle 20260729-225607-5b2d64, provider gpt, detach_method=systemd-run) — no --setenv gaps; a first attempt with --claude ran the full mechanism (unit launched, CLI found, authenticated, API reached) but the account's weekly Claude rate limit returned 429 ("weekly limit · resets 6am"), so the gpt provider closed the authenticated-review residual instead.

## End-to-end transcript (Task 9)

```
e2e tmp: /tmp/fresheyes-e2e.9RpBJI
=== cell 1: systemd-run detach survives codex exec and completes ===
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
session id: 019fb1ac-4ec2-71e1-ab23-cf432af0d135
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: env PATH="/tmp/fresheyes-e2e.9RpBJI/bin:$PATH" FRESHEYES_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-survive FRESHEYES_GLOBAL_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-survive FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes.sh --claude 'review HEAD'
exec
/bin/bash -lc 'env PATH="/tmp/fresheyes-e2e.9RpBJI/bin:$PATH" FRESHEYES_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-survive FRESHEYES_GLOBAL_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-survive FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes.sh --claude '"'review HEAD'" in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 3177ms:
FRESHPID=20260729-231819-1acd4f
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231819-1acd4f   (reviews take 5-30 min; poll every 30-60s)

codex
FRESHPID=20260729-231819-1acd4f
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231819-1acd4f   (reviews take 5-30 min; poll every 30-60s)
tokens used
20,503
FRESHPID=20260729-231819-1acd4f
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231819-1acd4f   (reviews take 5-30 min; poll every 30-60s)
codex exec returned at: 1785392303.863622347
handle: 20260729-231819-1acd4f
cell 1 survival proven: owner 1489553 alive after codex exec return (1785392303.863622347)
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=running
poll: state=complete
{"detach_method":"systemd-run","exit_code":0,"handle":"20260729-231819-1acd4f","heartbeat_at":1785392330.1650968,"last_log_mtime_epoch":1785392330,"last_provider_event":"result","launched_at":1785392299.0,"line_count":5,"log_path":"/tmp/fresheyes-e2e.9RpBJI/logs-survive/fresheyes-20260729-231819-1acd4f.log","mode":"manual","owner_pid":1489553,"owner_pid_state":"missing","pid":"20260729-231819-1acd4f","pid_state":"unknown","provider":"claude","provider_events":2,"result_available":true,"runner_state":"complete","state":"complete","status_path":"/tmp/fresheyes-e2e.9RpBJI/logs-survive/fresheyes-20260729-231819-1acd4f.log.status.json","updated_at_epoch":1785392330.1650965,"verdict":"passed"}
cell 1 PASSED: detached review survived codex exec (owner alive post-return) and completed

=== cell 2: bus absent -> setsid fallback -> harness kill -> killed_at_launch ===
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
session id: 019fb1ac-fc2b-7470-9bc2-ac67697fcd6f
--------
user
Run exactly this shell command with your shell tool and nothing else, then print its stdout verbatim: env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS PATH="/tmp/fresheyes-e2e.9RpBJI/bin:$PATH" FRESHEYES_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-killed FRESHEYES_GLOBAL_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-killed FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes.sh --claude 'review HEAD'
exec
/bin/bash -lc 'env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS PATH="/tmp/fresheyes-e2e.9RpBJI/bin:$PATH" FRESHEYES_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-killed FRESHEYES_GLOBAL_LOG_DIR=/tmp/fresheyes-e2e.9RpBJI/logs-killed FRESHEYES_FAKE_DELAY=30 FRESHEYES_CLAUDE_MODEL= FRESHEYES_GPT_MODEL= FRESHEYES_MODEL= bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes.sh --claude '"'review HEAD'" in /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics
 succeeded in 4512ms:
FRESHPID=20260729-231906-07847d
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231906-07847d   (reviews take 5-30 min; poll every 30-60s)

codex
FRESHPID=20260729-231906-07847d
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231906-07847d   (reviews take 5-30 min; poll every 30-60s)
tokens used
20,478
FRESHPID=20260729-231906-07847d
NEXT: bash /home/dan/code/fresheyes/.worktrees/detached-review-ergonomics/skills/fresheyes/fresheyes-progress.sh --json 20260729-231906-07847d   (reviews take 5-30 min; poll every 30-60s)
handle: 20260729-231906-07847d
poll output: {"detach_method":"setsid","handle":"20260729-231906-07847d","launched_at":1785392346.0,"line_count":0,"log_path":"/tmp/fresheyes-e2e.9RpBJI/logs-killed/fresheyes-20260729-231906-07847d.log","message":"the review child never wrote its first heartbeat \u2014 commonly because the calling harness kills or reaps detached processes when the launch command exits; re-run the same command with --foreground (works regardless of cause)","mode":"manual","pid":"20260729-231906-07847d","pid_state":"unknown","provider":"claude","result_available":false,"runner_state":"launching","state":"killed_at_launch","status_path":"/tmp/fresheyes-e2e.9RpBJI/logs-killed/fresheyes-20260729-231906-07847d.log.status.json","updated_at_epoch":1785392346.3309557}
poll exit: 3
cell 2 PASSED: loud killed_at_launch with remediation

e2e done. Record this transcript in tests/manual/SPIKE-RESULT.md and the commit body.
E2E_EXIT=0
```

## End-to-end re-run (2026-09-04, post model bump)

Re-run after the Fable 5.1 / GPT-6 Astra default bump (the fake Claude version
in codex-exec-e2e.sh was updated to 2.1.261 ahead of this run; a fresheyes
review of the bump caught the stale 2.1.170 value, which made both cells fail
at the new version gate before any locator was written).

Machine: garageserver (Ubuntu 24.04), Codex CLI 0.153.4, model gpt-6-astra,
reasoning effort xhigh.

- cell 1 (systemd-run detach survives codex exec and completes): PASSED —
  FRESHPID=20260904-202803-d5a914, owner 2009391 alive after codex exec
  returned at 1788578890.33, polled to state=complete with verdict=passed.
- cell 2 (bus absent -> setsid fallback -> harness kill -> killed_at_launch):
  INCONCLUSIVE — the harness did not kill the setsid child on this run
  (state=running at poll time). The killed_at_launch path remains covered
  deterministically by tests/fresheyes-detach-test.sh (which passed in the
  same change), and this cell deterministically exercised the setsid fallback
  with FRESHEYES_CLAUDE_MODEL cleared (proving the new default clears the
  2.1.257 gate).
