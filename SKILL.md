---
name: codex
description: Drive the Codex CLI as a fleet of worker agents while you stay the orchestrator and reviewer. Use when a task is large enough to split across parallel workers — feature implementation, refactors, bug hunts, test writing, README and documentation drafting, research and data collection, multi-file audits — or whenever the user asks to delegate work to Codex. You write the plan, dispatch scoped agents, supervise, review every diff yourself, and own the commit, merge, and deploy steps that Codex is never allowed to touch.
---

# Codex Orchestration

Codex writes; you plan, supervise, review, and ship. Codex agents never commit, never
push, never deploy, and never decide that their own output is acceptable.

## Why delegate to Codex at all

Four reasons, in the order they matter:

**Context.** A worker explores in its own context window — file reads, greps, failed commands,
dead ends — and returns a bounded result. In this skill's own research run the workers consumed
12.6M input tokens between them while the orchestrator read three result files (observed during
development; that run directory was not retained). That work would otherwise have landed in
your context and pushed out the plan you are holding.

**Cost per unit of difficulty.** Each task is dispatched at the cheapest tier that can do it,
so mechanical work does not run at frontier reasoning depth and does not sit in an expensive
conversation. A tier is chosen per task, not per session.

**Independence.** A worker starts with no memory of your reasoning. It cannot inherit your
mistaken assumption, which is exactly what makes it usable as a second opinion on code you
already looked at.

**Durability.** Each unit of work is a thread, a run directory, and a schema-checked result. A
worker that dies is resumed; a result that must be parsed is JSON, not prose.

The cost is one review pass per worker, paid by you. That is the trade this whole skill exists
to manage.

## Preflight

Run once per session, before dispatching anything:

```sh
codex --version || echo "codex CLI not installed — stop and tell the user"
"$CODEX_SKILL/scripts/codex_agents.sh" --list      # what other windows are already running
```

Agents started by another orchestrator session, another terminal, by hand, or by the sibling
opencode toolkit are all using this machine and this API quota, so the cap covers all of them.
Both wrappers lock the same slot directory and both counters read both registries and scan for
both engines' processes: `AGENT_MAX_AGENTS` (default 5) is the machine total, not 5 per engine.
A `codex exec` started by hand holds no lock — it is counted and displayed, but it can still push
the machine past the cap, so read the list rather than trusting the lock alone. An idle Codex
TUI, a zombie, and the wrapper's own child process are never counted.

Machine-local settings — the cap and the tier-to-model bindings — live in
`${XDG_CONFIG_HOME:-~/.config}/agent-orchestration.env`, sourced by both wrappers when present,
so no provider's model names live in this repository.

The scripts below assume `codex >= 0.40` with the `exec` subcommand. Set
`CODEX_SKILL=<this skill's directory>` so the examples are copy-pasteable.

## When not to use this

Do the work yourself when it is a single obvious edit, a one-file read, a question you can
answer from context, or anything needing under ~2 minutes. Dispatch costs a process launch,
a full context prime for the worker, and a review pass from you. Delegate when the task has
independent parts, needs bulk file work, or would otherwise flood your own context.

Fan out only when the work actually decomposes. Parallel agents win on breadth-first work —
independent modules, wide searches, many files with the same treatment — and lose on work with
a shared context or a dependency chain, where measured results show multi-agent topologies
performing substantially worse than a single agent on sequential planning tasks. One worker on
a well-scoped task beats three workers guessing at each other's assumptions, and it costs less
to review. Gate on decomposability, not on ambition.

Worker count is not the scarce resource; your review capacity is. Each finished agent needs a
diff read and a test run from you, so keep about three review-bearing agents in flight and
raise it only for shallow, uniform work.

Some work is never dispatched, however large the run:

- **Git mechanics** — rebase, merge, conflict resolution, commit, branch and worktree cleanup,
  stashing, cherry-picking. Every spec forbids workers from running these, so dispatching one
  contradicts itself; `codex_worktrees.sh --rebase` and `codex_merge.sh` exist so you do them
  in one command.
- **A fix you can make faster than you can specify it** — a typo, a wrong constant, a missing
  import, a one-line guard. Writing the spec, waiting, and reviewing the diff costs minutes for
  a change that costs seconds.
- **Anything you must verify line by line anyway** — a two-line change in code you are already
  reading. Review is the expensive half, and dispatch does not reduce it.
- **Running a command and reading its output** — tests, builds, linters, `git log`, a status
  check. A worker adds a process launch and a context prime to something you can run directly.

The test is not "is this tedious" but "does a worker's separate context window earn the spec
plus the review". Bulk mechanical work does — the same rename across 200 files, one worker per
batch. The same rename in three files does not.

Dispatching cheap work also costs the run twice: it occupies a slot the machine cap counts, and
it puts a review in your queue ahead of an agent that needed one.

## Workflow

### 1. Create the run directory

Every run gets one directory holding the plan, every prompt, every event log, every result,
and your review. Do not scatter artifacts into the workspace or a tmpfs path.

```sh
RUN=$("$CODEX_SKILL/scripts/codex_new_run.sh" add-auth-cache)   # prints the path
```

Layout:

```
<run>/PLAN.md                 your decomposition and acceptance criteria
<run>/jobs.jsonl              the fan-out, one job per line, for codex_dispatch.sh
<run>/schema/<name>.json      output schemas
<run>/worktrees/<label>/      that agent's isolated checkout, branch codex/<label>
<run>/logs/<label>.dispatch.log
<run>/agents/<label>/prompt.md NOTES.md events.jsonl stderr.log result.json|last.txt
                     thread.txt started.json meta.json verify.json
<run>/REVIEW.md               your findings per agent, with the verdict
```

Override the base with `CODEX_RUNS_DIR`; the default is `${XDG_CACHE_HOME:-~/.cache}/codex-runs`.
Keep the run directory after finishing so the thread ids stay usable; delete stale runs when
the user asks for cleanup.

### 2. Decompose, then write PLAN.md

Split by file ownership, not by activity. Two agents editing the same file will clobber each
other, because they run as separate processes with no shared lock. Record each agent's label,
exact writable scope, sandbox, effort, and dependencies in `PLAN.md`.

Order and atomicity are one design, not two features. The rule underneath both: work is only
ever built on a state that actually exists — a dependency's finished result, or the target's
real commit.

Independent agents run in parallel. A dependent agent is *not dispatched* until the agents it
depends on have finished successfully; declare that in `jobs.jsonl` and the dispatcher enforces
it:

```json
{"label": "api",    "tier": "deep"}
{"label": "client", "tier": "standard", "depends_on": ["api"]}
```

Dispatching a dependent task early is the expensive mistake: it works against a schema, a
signature, or a file that does not exist yet, and its whole run is thrown away. The dispatcher
therefore holds it back, skips it outright when a dependency fails, and rejects unknown
dependencies and cycles before starting anything. A failed dependency stops its own subtree
only — independent branches keep running and stay mergeable.

The same order carries into integration: branches merge in dependency order, each merge is
atomic and verified before the next begins, and any failure returns the target to the commit
the run started from (step 10). A dependent branch also records the base it was written
against, so if the target moved while it worked, it is rebased or refused rather than merged
silently. Derive the concurrency from what the agents actually do and what the machine
has free, rather than from a fixed number:

```sh
"$CODEX_SKILL/scripts/codex_capacity.sh" heavy    # light | medium | heavy
```

`light` is reading and drafting, `medium` is editing plus a targeted test, `heavy` is full
builds, whole test suites, or containers. The script reads cores, available memory, and load
average, halves the answer on a busy machine, caps it at 8 regardless of the hardware, and
never exceeds the free share of `CODEX_MAX_AGENTS`; override its memory estimate with
`--per-agent-mb` when you know the real cost. Mixed runs are budgeted per group: three heavy
compile agents and two light readers, not five of whatever the first estimate said. Leave room
for the tests you run yourself during review — you are a workload on the same machine.

Dispatch the longest-running agents first — the `xhigh` ones, and anything reading a lot of
code — so the quick agents finish inside their runtime and you review during the wait instead
of after it.

Give every write-capable agent in a fan-out its own git worktree with `--worktree`, so parallel
agents cannot overwrite each other's files and each change arrives as a reviewable branch. See
[references/worktrees.md](references/worktrees.md) for dispatch, merge order, and cleanup.

### 3. Write the task spec

One file per agent, `<run>/agents/<label>/prompt.md`, produced from
[references/prompt-template.md](references/prompt-template.md). A spec that omits the scope
fence or the acceptance criteria produces work you will have to throw away. Always include
the prohibition block — Codex will otherwise commit, or wander into unrelated files.

Give every agent a `NOTES.md` so you can correct it while it runs (step 7), and make the spec
say when to re-read it.

### 4. Hand over the skills the worker needs

Naming a skill in the spec guarantees it is used. Codex 0.147 also instructs workers to use a
skill whose description clearly matches the task, so a relevant skill may be applied without
being named — naming it is how you make that deterministic. List what Codex can see:

```sh
ls "${CODEX_HOME:-$HOME/.codex}/skills"
```

When a listed skill covers the task — a writing standard, a repository workflow, a domain
convention — put a `## Skills` block in the spec with the absolute path to its `SKILL.md` and
the instruction to read it first. Skills installed for you are not automatically installed for
Codex: if the one you rely on is missing from that directory, either paste its operative rules
into the spec, or ask the user before installing it for Codex.

Codex reads `AGENTS.override.md` and `AGENTS.md` from the worker's `--cwd` and above. It does
not read `CLAUDE.md` unless that name is added to `project_doc_fallback_filenames` in the Codex
config, so rules that live only in `CLAUDE.md` must be pasted into the spec.

### 5. Pick effort, sandbox, and timeout

Difficulty decides both the reasoning depth and the model. `--tier` sets them together, so the
cheap work stays cheap without a decision per flag:

| `--tier` | effort | use for |
|----------|--------|---------|
| `cheap` | `low` | mechanical edits, renames, formatting, boilerplate, extracting known facts |
| `standard` | `medium` | default: a contained feature, a README, tests for existing code |
| `deep` | `high` | changes spanning several files, non-obvious bugs, behavior-preserving refactors |
| `frontier` | `xhigh` | architecture decisions, concurrency and performance work, ambiguous requirements |
| `max` | `max` | one problem a `frontier` agent already failed twice; never a default |

A tier always sets the reasoning effort. It sets the model only when the matching binding
exists: export `CODEX_TIER_CHEAP_MODEL`, `CODEX_TIER_STANDARD_MODEL`, `CODEX_TIER_DEEP_MODEL`,
`CODEX_TIER_FRONTIER_MODEL`, or `CODEX_TIER_MAX_MODEL` to bind one. Without a binding every tier
runs the model from the Codex config, so the cost separation is effort-only until they are set.

Both halves of a tier are configurable, so the ladder is data rather than code: `CODEX_TIER_<TIER>_MODEL` binds the model and `CODEX_TIER_<TIER>_EFFORT` overrides the effort. Set both in the machine-local env file and no job has to carry `--effort` by hand — a ladder that needs a flag on every dispatch is a ladder that will be forgotten on one.

Both halves matter, and they divide the ladder cleanly: below `deep` the **model** changes, above
it the **effort** does. A cheap model can cost an order of magnitude less per token than a
flagship, and research is where that lands hardest — a read-only worker reads far more than it
writes, so the input price is the bill. `--model` or `--effort` overrides a tier for one agent,
and `--profile <name>` layers a Codex config profile, which is the tidier place to keep a whole
worker role: model, effort, and storage in one named file.

Rate the task, not its importance. Most work in a run is `cheap` or `standard`; a run where
everything is `deep` is a run that was never triaged. When unsure, dispatch `cheap` first: a
failed cheap attempt costs less than an unnecessary deep one, and its output usually sharpens
the spec for the retry.

Sandbox is the permission boundary and defaults to the most restrictive option that can do
the job:

| sandbox | grants | use for |
|---------|--------|---------|
| `read-only` | runs any command, but the kernel blocks every write | research, audits, review, running tests and linters |
| `workspace-write` | writes under `--cwd` plus each `--add-dir` | all implementation work |
| `danger-full-access` | unrestricted | never without the user's explicit approval in this session |

`read-only` here is stronger and more permissive at once than a permission list: a worker may
run `pytest`, a linter, or anything else, and the sandbox stops the writes rather than the
commands. That is why an auditor belongs in `read-only` on this engine — it can execute the
checks it judges by without being able to change the tree. The opencode sibling has no
equivalent and needs its `inspect` profile instead.

`--network` grants *shell* network access, and only under `workspace-write` — the read-only
sandbox has no network permission at all, so `curl` and package installers cannot work there.
Codex's built-in web search is a different thing: it is server-side, on by default, and works
in every sandbox, which is why a `read-only` research agent can still search. Add
`--approve-for-me` when a worker legitimately needs to escalate a command instead of failing,
and grant write access to the smallest directory that contains the agent's files.

`--timeout` is a runaway guard, not a schedule, and it scales with the task — not with your
patience. A big task on a short timeout is the worst combination available: the wrapper kills
the worker mid-edit, and you inherit a half-applied change with no final report.

| task shape | effort | `--timeout` |
|------------|--------|-------------|
| single-file mechanical edit, fact extraction | `low` | 300–600 |
| contained feature, README, tests for one module | `medium` | 900–1800 (default 1800) |
| change across several files, bug hunt with repro | `high` | 1800–3600 |
| architecture, concurrency, performance, vague spec | `xhigh` | 3600–7200 |
| the hardest single problem in the run | `max` | 7200+ |

Estimate from the work, then roughly triple it: a worker spends most of its wall-clock reading
the repository and running commands, not generating text. When unsure, set it high. An agent
that finishes early costs nothing, while one killed at 90% costs the whole run.

### 6. Dispatch

```sh
"$CODEX_SKILL/scripts/codex_agent.sh" \
  --run-dir "$RUN" --label auth-cache \
  --cwd /path/to/repo --sandbox workspace-write --tier deep \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json" --timeout 1800 --stall 300
```

For a whole fan-out, describe the jobs once and let the dispatcher handle ordering and
concurrency — hardest tier first, capacity from the machine:

```sh
"$CODEX_SKILL/scripts/codex_dispatch.sh" --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" \
  --weight medium --max 4        # --dry-run prints the commands without running them
```

Each job line names a label, a tier, and the flags that differ from the defaults; the spec is
read from `<run>/agents/<label>/prompt.md` unless the job says otherwise. Run either form as a
background command so several agents progress at once, and so a stuck agent cannot block you. The script prints a one-line JSON summary and writes `meta.json`.

For anything you must parse rather than read, pass `--schema`: Codex is then forced to answer
with JSON matching that schema, which removes prose-parsing failures. See
[references/schemas.md](references/schemas.md) for ready-made schemas.

Non-negotiable invocation rules, each learned from a real failure or read out of the CLI
source:

- Never let Codex inherit your stdin. The script feeds the prompt file on stdin; a raw
  `codex exec "prompt"` with an inherited terminal stdin hangs until it is killed.
- Starts are staggered, not simultaneous. Both engines keep session state in SQLite, so a
  four-way launch loses to `database is locked`; the wrapper holds a machine-wide start lock for
  `AGENT_START_STAGGER` seconds per launch and retries a lock failure with backoff, only ever
  when the run produced no events.
- Always wrap in `timeout`, sending `SIGINT` first — Codex turns it into a graceful turn
  interrupt. `codex exec` has no internal limit.
- Every option is a root option placed *before* the `resume` subcommand:
  `codex exec -C dir -s mode … resume <thread> -`. A resumed run inherits nothing from the
  original: sandbox, cwd, model, and workspace roots all come from the new invocation, so
  repeat the full policy every time.
- Outside a git repository, `--skip-git-repo-check` is required (the script always passes it).
- The CLI forwards `--output-schema` unvalidated and the rejection only arrives from the API,
  after you have paid for the dispatch. The wrapper pre-checks the documented Structured
  Outputs subset: object root, every property required, `additionalProperties: false`
  everywhere, no `allOf`/`oneOf`/`if`/`not`, at most 10 levels deep.

### 7. Supervise — handle agents one at a time, as they land

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

### 8. Review — the part you never delegate

Run this per agent, as soon as that agent returns. **An agent's report is a claim; a command you
ran is evidence. Nothing is accepted on a claim** — not because the summary says done, not
because the diff looks reasonable, not because another agent reviewed it, and not because the
task was simple. Optimism is the normal failure mode here, and it costs nothing at the moment
it happens.

1. Read the real diff (`git diff`, or read the files if the workspace is not a repository).
   Never accept `files_changed` at face value.
2. Check every changed file against the declared `Write:` scope.
3. Run each acceptance criterion yourself and keep the exit code. A criterion with no command
   behind it was never verified.
4. Run a negative control: revert or break the change and confirm the check fails, then restore.
   A test that passes both ways proves nothing, and that is how weak work usually survives.
5. For a risky change, add an independent critic with a fresh context — inside a git repository
   `codex exec review --uncommitted`, otherwise a `read-only` agent told to falsify the change
   against the acceptance criteria. Its output is a list of candidates you confirm by running
   something, never a verdict you forward.
6. Write the verdict and its evidence into `<run>/REVIEW.md`, including a line stating what was
   *not* verified.

Steps 2 and 3 are mechanized. The gate returns `not-verified` when no check ran, when a check
failed, or when a file outside the declared `Write:` scope changed — including files a check
itself created, since the inventory is taken again afterwards. It requires a git repository,
because without one there is no change inventory and a verdict would mean nothing:

```sh
"$CODEX_SKILL/scripts/codex_verify.sh" "$RUN" auth-cache \
  --check "pytest tests/test_auth.py -q" --check "ruff check src/"
```

Order matters: deterministic checks first, critics second. A test run settles in seconds what a
critic argues about for a page. Research output gets the same treatment — sources are part of
the claim, so fetch a sample yourself and confirm the quoted numbers actually appear there.
[references/review-gate.md](references/review-gate.md) has the full protocol.

Reject silently-passing work: tests weakened to pass, exceptions swallowed, features stubbed,
files created outside scope, dependencies added that nobody asked for.

Keep the raw material in the run directory and out of your own context. Read the digest and the
diff; open `events.jsonl` and full logs only when something looks wrong. A supervisor that
pastes every worker's output into its own context loses the one thing the fan-out was protecting.

### 9. Fix rounds

Feed review findings back into the same thread so the worker keeps its context:

```sh
"$CODEX_SKILL/scripts/codex_agent.sh" --run-dir "$RUN" --label auth-cache-fix2 \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high \
  --prompt-file "$RUN/agents/auth-cache-fix2/prompt.md"
```

State findings as facts with file and line, not as questions. Allow at most two fix rounds per
agent; after that, either take over yourself or re-dispatch a fresh agent with a sharper spec,
because a thread that has failed twice usually carries the wrong assumption forward.

#### Resume or start fresh

Resuming is not cheap: the whole thread is replayed as input on every continuation, so a long
research thread can cost hundreds of thousands of input tokens to answer one more question.
Agent count itself is not limited, so the choice is purely about the memory in that thread.

Resume when the accumulated context is expensive to rebuild and still correct — a worker deep
in an unfamiliar codebase, a partially finished change, findings you want extended. Start a
fresh agent when the context is small, easy to reconstruct from the workspace, or wrong: a
mistaken assumption in a thread propagates into every later turn, and a clean spec that names
the two files involved beats a resumed thread that has been wrong twice.

Retry classification matters more than retry count. A semantic failure never gets the same
prompt again: send the verifier's evidence back, or re-scope and dispatch fresh.

A transport failure is a different situation and is not yours to decide silently. Codex emits non-terminal `error` events shaped
`Reconnecting... n/5 (unexpected status 502 …)` and gives up after the configured maximum,
five by default and adjustable through `stream_max_retries`; `meta.json` then reports `reconnects` and `transient_failure: true`, and
the status table shows `TRANSIENT`. Nothing about the task was wrong, so do not rewrite the
spec, and do not quietly re-dispatch into an endpoint that is still failing.

Tell the user immediately, with the evidence — the reconnect count, the endpoint, and any
provider request id the message happens to carry, since the event only guarantees a `message`
field — and ask which they want: wait because the upstream is down, or
resume the preserved thread now and continue where the worker stopped. The thread id survives in
`thread.txt` either way, so no work is lost by asking. The same applies when the connection drops
mid-run, the machine reboots, or authentication expires.

### 10. Integrate

Every agent records the commit it started from, and `--worktree` refuses a base that is already
behind its upstream, so a worker never builds on a tree nobody is running. At merge time that
base is checked again: a branch whose base is no longer an ancestor of the target was written
against a tree that has since moved, and merging it silently would resurrect the old state.

```sh
"$CODEX_SKILL/scripts/codex_merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q" --rebase          # --dry-run first
```

The merge is atomic per branch and for the run as a whole: the target must be clean before it
starts, each branch is committed in its worktree, merged with `--no-ff`, and verified by every
`--check` before the next branch is touched. A conflict, a rebase that does not apply, or a
failed check rolls the target back to the exact commit the run started from — a half-integrated
tree is never left behind. Verify after every merge rather than once at the end, because two
branches that each pass alone can fail together, and a single failure at the end tells you
nothing about which one caused it.

This is where the full suite belongs: once per merged branch, on the integrated tree, where a
cross-branch regression can actually exist. Give `--check` the real suite here even though the
agents ran targeted subsets.

Merge in dependency order, and resolve a conflict between two branches yourself: the agent that
wrote one side cannot see why the other side exists.

### 11. Ship

You perform every irreversible step: staging, commit messages, tags, PRs, releases, deploys.
Confirm with the user before anything outward-facing. Report what each agent produced, what you
rejected, and what you changed yourself.

## Keeping your own context small

The context that needs protecting is yours, the dispatcher's. A worker's context is disposable:
it is created for one task, dies with it, and nothing is carried forward except the result file.
So let workers read whatever they need — 200 files, a full test log, three failed approaches —
and never split a task, shorten a spec, or tell a worker to "be brief" in order to save its
context. Only the final report is bounded, because that is the part that lands in you.

The one place a worker's context costs anything is `--resume`, which replays the whole thread as
input. That is a bill, not a limit, and it is the reason a fresh agent often beats continuing a
long thread.

Keep what is worth keeping. A worker you will send more work to keeps its thread, because
rebuilding its understanding of the code costs more than replaying it. Your own state lives in
the run directory rather than in your context: `PLAN.md`, the specs, `thread.txt` for every
agent, and `REVIEW.md`. After a compaction, an interruption, or a session restart, recover from
those files instead of guessing — read `PLAN.md`, run `codex_status.sh`, and pick up the agents
that are still unreviewed. Context that was written down is recoverable; context that only
existed in your head is not, which is why it gets written down as it is produced.

Rules that keep worker exploration out of your context:

- Read `result.json` and `verify.json`. Open `events.jsonl` only when something failed, and
  then filter it rather than reading it whole.
- Use `codex_status.sh` as the digest: it truncates each result to a readable head and prints
  totals. `--full` exists for the one agent you actually need in detail.
- Prefer a schema over prose. A 40-line JSON result is cheaper to hold and to compare than a
  three-page report, and it cannot bury a caveat in paragraph six.
- Refer to artifacts by path instead of quoting them. The run directory is the shared memory;
  your context is not.
- Summarize for the user from the diff and the check results, not from the worker's prose —
  otherwise its framing propagates through you unverified.
- Keep `REVIEW.md` to decisions and evidence lines. It is a record, not a transcript.

The same discipline makes the exchange with workers efficient. A spec is a contract, so it is
written once and completely; corrections go through `NOTES.md` while the agent runs; findings
go back as facts with file and line, which is why a fix-round spec is five lines and not a
restatement of the task. Every one of those keeps a round trip from happening.

## Common task shapes

- **Feature**: one `read-only` `standard` agent maps the code, then `workspace-write` agents by
  module, each in its own `--worktree`, then you merge with `codex_merge.sh` and review.
- **Bug hunt**: parallel `read-only` agents with different lenses (correctness, boundaries,
  concurrency, error paths), each returning a findings schema; you deduplicate, then dispatch
  `cheap` or `standard` fixes for the confirmed ones only.
- **README or docs**: a `read-only` agent collects the facts, a `workspace-write` agent drafts,
  you verify every command and claim it makes. Apply the repository's writing rules yourself —
  workers do not know them unless you paste them into the spec.
- **Research and data collection**: `read-only` plus `--network`, always with a schema, plus a
  requirement that every claim carries a source. Verify the sources; workers do fabricate them.
- **Migration or sweep**: one `cheap` agent per file batch, identical spec, disjoint scopes,
  one worktree each; merge in batches so a failure never rolls back the whole sweep.
- **Auditing this or another skill**: `read-only` agents that must demonstrate each finding by
  running something, with a schema that requires a failure scenario and a fix per finding.

## References

- [references/prompt-template.md](references/prompt-template.md) — the task spec structure
- [references/schemas.md](references/schemas.md) — output schemas for impl, findings, research
- [references/worktrees.md](references/worktrees.md) — isolating parallel writers, merging, cleanup
- [references/review-gate.md](references/review-gate.md) — the anti-optimism review protocol
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and fixes
- [references/evidence.md](references/evidence.md) — the measurements behind these defaults
