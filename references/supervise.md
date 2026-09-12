# Supervising agents as they land

**Never sit idle while agents run.** This is not a preference. From the moment the first agent
is dispatched until the last one is reviewed, you are either processing a returned agent or
doing work that does not depend on one. Waiting for a batch to finish before looking at
anything is only correct when the user explicitly asked for it — "finish everything, then
review" — and that instruction has to come from them, not from you.

Agents finish minutes apart: a `low`-effort edit returns in under a minute while an `xhigh`
audit runs for twenty. Review each agent the moment it finishes and start its fix round while
the others are still working — the slowest agent then costs nothing extra, and a spec-level
mistake surfaces early enough to fix the remaining agents' specs.

Every time the integration branch moves, the agents still running are now writing against an
older base. Check for it immediately and keep it from turning into a merge surprise:

```sh
"$CODEX_SKILL/scripts/codex_worktrees.sh" "$RUN" --drift main   # who is behind, and who is live
"$CODEX_SKILL/scripts/codex_worktrees.sh" "$RUN" --rebase main  # move the finished ones up
```

`--rebase` never touches a worktree whose agent is still running, because rebasing underneath a
live writer corrupts work in flight. A running agent is told through `NOTES.md` that the base
moved and what changed, and is rebased the moment it exits — before its review, since a rebase
invalidates any check you already ran. Never let an agent finish, sit unrebased, and get merged
hours later against a tree that has moved on.

A regression you can fix now is fixed now, ahead of anything else in the queue: a broken build
or a failing test on the integration branch blocks every agent still to be merged, so it is
never left for later. Trivial fixes you can make in seconds are yours to make — do not spend a
dispatch round trip on a typo.

While no agent is waiting on you, the time still belongs to the run: write the next specs,
prepare the schemas, run the test suite on what has already merged, verify sources from a
research result, read the code the next task will touch, update `PLAN.md`. Poll on a condition,
never on a hunch, and never sleep through a window you could have used.

```sh
"$CODEX_SKILL/scripts/codex_watch.sh" "$RUN" --timeout 120   # bounded: returns work, or the window
"$CODEX_SKILL/scripts/codex_wait.sh" "$RUN" --handled auth-cache,docs   # blocks until one lands
"$CODEX_SKILL/scripts/codex_status.sh" "$RUN"                           # full picture when you want it
```

Monitoring is event-driven, not a timer. `codex_watch.sh` blocks and returns the moment
something changes; its `--interval` only sets how often it stats a few files, which costs
nothing and never costs you a turn. A timer would either wake you when nothing happened or
leave a finished agent sitting.

Waiting reads almost nothing. Liveness is the event log's mtime plus, with `--peek`, its last
event read from the final 4 KB of the file — the same answer from a 3 MB log as from a 3 KB
one, and printed only when it changes. Never `cat` an event log, dump a result, or run a full
status listing to find out whether an agent is alive: the whole point of a run directory is
that the data stays on disk until there is a reason to read it. Results are read once, at
review, and `codex_status.sh --brief` gives the table without any result bodies.

A peek line never means "act now" — it exits 1 like any other quiet window, because progress
information is not a state change.

It also watches the clock on your behalf. Each running agent records its deadline when it
starts, so the watcher reports before a guard fires rather than after:

- `EXPIRING <n>s left of <limit>s` — the agent has used 80% of its wall-clock limit
  (`--warn` changes the share)
- `QUIET <n>s without an event, stall kill at <limit>s` — it is approaching the stall guard

Both arrive once per agent. Act on them while the work still exists: send a note telling the
worker to stop exploring and write what it has (`codex_note.sh <run> <label> "Wall-clock limit
in 3 minutes. Stop now, save your work, and report what is done and what is left."`), or
prepare the continuation spec so the thread can be resumed the moment it dies. Doing nothing
means the kill discards the turn in progress, and you pay for that work twice.

An `EXPIRING` warning on a first run is also a scoping signal: the task was bigger than the
timeout you chose, so the continuation should be split rather than simply given more time.

`codex_status.sh` shows the same clock — for a running agent the TIME column is the time left,
not the time spent.

`codex_watch.sh`'s exit code decides what happens next:

| exit | meaning | what you do |
|------|---------|-------------|
| 0 | agents changed state; labels printed | handle them now — review, fix round, merge |
| 1 | nothing changed before the deadline | spend the window on work that needs no agent |
| 2 | every agent finished and was reported | close the run |
| 3 | no agents yet | dispatch something |

Exit 1 is an instruction, not a reason to call it again. Choose `--timeout` as the time until
your next useful action, not as how long an agent might take: with specs to write or tests to
run, use 60–120s and go do them; with genuinely nothing left, a longer block is fine because
blocking costs nothing while polling costs a turn.

If the host you run in can wake you — a scheduled tick, a background task that notifies on
completion, a job runner — prefer being woken over blocking, and keep a bounded watch as the
fallback so a silent failure cannot hang the run forever. The pattern is the same either way:

```sh
while out=$("$CODEX_SKILL/scripts/codex_watch.sh" "$RUN" --timeout 120); do
  handle "$out"        # exit 0 path
done                   # exit 1 -> do queued work, then loop; exit 2 -> done
```

The loop: wait → review that one agent (step 8) → dispatch its fix round if needed → add it to
`--handled` → wait again. Agents still running show `RUNNING` in the status table. Keep the
poll interval proportional to the expected runtime; do not re-read a growing `events.jsonl`
on every tick.

Wait for everything only when the next decision genuinely needs all results together —
deduplicating findings across parallel auditors, or integrating modules that must land as one
change. Everything else is per-agent work masquerading as a batch.

Read `events.jsonl` when an agent misbehaves; it records each `command_execution` with its exit
code, so you can see exactly what the worker ran and where it went wrong. A failed command
inside a run is normal exploration — only `turn.failed`, a top-level `error`, or a non-zero
process exit means the agent failed, and `meta.json` separates the two.

`meta.json` distinguishes the two guard kills: a wall-clock overrun sets `timed_out`, a silent
worker sets `stalled`. Both exit 124 or 137, so classify from the flags rather than the exit
code. Kill early instead of waiting out a worker that is not progressing: `--stall SEC`
interrupts an agent that has emitted no event for that long, which catches a hung command or a retry loop
without waiting for the full timeout. Repeated identical failing commands in `events.jsonl` are
the other early signal: the worker is stuck on something your spec cannot fix, so interrupt it
and re-scope.

#### Feeding information to a running agent

`codex exec` takes no input after it starts, so new information reaches a live worker through a
file it re-reads:

```sh
"$CODEX_SKILL/scripts/codex_note.sh" "$RUN" auth-cache "The token TTL is 900s, not 3600s — the
constant in config.py is stale. Files already written must be updated."
```

This works only when the spec carries the live-notes block from
[references/prompt-template.md](references/prompt-template.md), which tells the worker to
`cat` that path before each step and to let the newest entry win. Create `NOTES.md` before
dispatching so the first read does not fail. Verified behavior: a worker that had already
written two files re-read the notes, applied the new requirement to the remaining file, and
went back to correct the earlier two.

Use it for corrections that would otherwise waste the whole run — a wrong assumption you spot
in another agent's output, a constraint the user adds mid-run, a decision you made after
dispatching. Do not use it to renegotiate scope; a task that changed shape deserves a fresh
spec. Notes arriving after the worker's last checkpoint are simply missed, so anything critical
goes into a fix round instead.

#### Interrupted agents

Exit 124 or 137 means the wrapper killed the worker; `meta.json` reports `timed_out: true`,
there is no result file, and the workspace holds whatever was finished at that moment. Partial
edits are real edits — verify before continuing.

`thread.txt` is still written, because the thread id is recorded at the start of the run. Resume
that thread rather than starting over: the worker keeps its plan and its knowledge of the code,
so it skips the exploration you already paid for.

```sh
"$CODEX_SKILL/scripts/codex_agent.sh" --run-dir "$RUN" --label auth-cache-cont \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/auth-cache-cont/prompt.md"
```

The continuation spec states that the previous run was cut off, lists what you observed in the
workspace (`git status`, `git diff --stat`), and asks for the remainder only. Verified: an agent
killed after 3 of 5 files resumed and continued from file 4 without redoing the first three.

Same recovery for any other interruption — you cancelled it, the machine rebooted, the API
dropped. When `thread.txt` is missing because the process died before the first event,
`codex exec resume --last` from the same working directory picks the newest session; confirm
the session is the right one before sending work into it.

A repeated timeout is not a timeout-value problem. Split the remaining work and dispatch it as
separate agents, because a task that overruns twice is one task too many.
