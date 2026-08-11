# Codex Orchestration Skill

English | [繁體中文](README.zh-TW.md)

A skill for driving a fleet of Codex CLI workers from an orchestrating agent that keeps
planning, supervision, review, and shipping for itself. It covers feature work, refactors, bug
hunts, test backfills, documentation, research, and multi-file audits.

The division of labor is fixed. Workers produce code and drafts only. The orchestrator reads the
real diff, runs the tests, and writes the verdict; commits, merges, and releases stay with it.
Every task spec forbids workers from running history-rewriting git commands.

## Why delegate to Codex

**Context.** A worker explores in its own context window and returns a bounded result. In this
project's own research run, workers consumed 12.6M input tokens between them while the
orchestrator read three result files; that exploration never entered the orchestrator's context.

**Cost per unit of difficulty.** `--tier` picks reasoning depth and model together, so
mechanical work never runs at frontier depth and never sits in an expensive conversation.

**Independence.** A worker starts with no memory of the orchestrator's reasoning, so it cannot
inherit a mistaken assumption — which is what makes it usable as a second opinion.

**Durability.** Each unit of work is a thread, a run directory, and a schema-checked result. A
worker that dies is resumed; a result that must be parsed is JSON, not prose.

The cost is one review pass per worker. Managing that trade is what the rest of this skill does.

## Requirements

- Codex CLI 0.40 or newer, already logged in
- Python 3.11 or newer
- Bash

## Install

```bash
git clone https://github.com/Zakk-LLM/codex-orchestration.git
cd codex-orchestration
./install.sh
```

The default installs a symlink for every agent present on the machine. A symlink requires the
source directory to stay put; uninstall first before moving or deleting it, or use `--copy`.

```bash
./install.sh claude codex
./install.sh --copy
./install.sh --status
./install.sh --uninstall
```

| Agent | Location |
|---|---|
| Claude | `~/.claude/skills/codex` |
| Codex | `${CODEX_HOME:-~/.codex}/skills/codex` |
| OpenCode | `~/.config/opencode/skills/codex` |

## Usage

The orchestrating agent reads [SKILL.md](SKILL.md) first. Run by hand, the scripts form the
whole loop:

```bash
RUN=$(scripts/codex_new_run.sh add-auth-cache)
scripts/codex_capacity.sh medium

scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache \
  --cwd /path/to/repo --worktree --sandbox workspace-write \
  --effort high --timeout 1800 --stall 300 \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json"

scripts/codex_note.sh "$RUN" auth-cache "Token TTL is 900s."
scripts/codex_agents.sh --list
scripts/codex_dispatch.sh --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" --weight medium
scripts/codex_verify.sh "$RUN" auth-cache --check "pytest -q"
scripts/codex_wait.sh "$RUN" --handled docs
scripts/codex_status.sh "$RUN"
scripts/codex_worktrees.sh "$RUN" --diff main
```

Every script documents its options under `--help`.

`codex_dispatch.sh` takes a JSONL job list — one line per agent, naming its label, tier, and
whatever differs from the defaults — and runs the fan-out hardest-tier-first at a concurrency
derived from the machine. `--dry-run` prints the commands it would run.

The context that needs protecting is the dispatcher's. A worker's context is disposable — it is
created for one task and dies with it — so workers read whatever they need, and no task is split
or shortened to save a worker's context. Only the final report is bounded, because that is the
part that reaches the orchestrator: read `result.json` and `verify.json`, use `codex_status.sh`
as the digest, open `events.jsonl` only when something failed, and refer to artifacts by path
instead of quoting them. The single exception is `--resume`, which replays a whole thread as
input; that is a cost, not a limit.

## When fan-out is worth it

Parallel workers pay off only when the work decomposes. Breadth-first work benefits clearly:
independent modules, wide searches, one treatment applied across many files. Work with shared
context or a dependency chain does not — a controlled study reports every multi-agent topology
degrading sequential planning tasks by 39–70% against a single agent.

The limit is not worker count but review capacity: each finished agent costs one diff read and
one test run. Roughly three review-bearing agents in flight is the working default, raised only
for shallow, uniform work.

## Parallel writers and git worktrees

`--worktree` gives each write-capable agent its own checkout on branch `codex/<label>`, leaving
the main checkout untouched and moving conflicts to merge time where they are visible. Measured
background: co-active agent-authored pull requests conflict textually in 41.7% of cross-agent
pairs against 19.8% for same-agent pairs.

```bash
scripts/codex_worktrees.sh "$RUN" --list
scripts/codex_worktrees.sh "$RUN" --remove-merged main
```

`--remove-merged` deletes only worktrees whose branch already landed in the given base, so
unmerged work survives. Submodule-heavy repositories need a full clone per agent, because git
documents incomplete support for multiple superproject checkouts.

## One machine, many windows

Agents started by another orchestrator session, another terminal, or by hand share this machine
and this API quota, so they are counted before anything new is dispatched:

```bash
scripts/codex_agents.sh --list      # live agents machine-wide, with label, tier, and workspace
scripts/codex_agents.sh --slots     # free slots against CODEX_MAX_AGENTS (default 5)
```

Each agent registers itself while it runs and holds one of the slot locks, so the cap holds
across sessions that know nothing about each other; `--admission refuse` fails instead of
queuing. An idle Codex TUI, a zombie, and an unrelated program named `codex` are never counted:
liveness comes from the registry entry's pid and process start time, and the process scan
requires a real `exec` invocation.

## Never idle-wait

From the first dispatch until the last review, the orchestrator is either processing a returned
agent or doing work that does not depend on one — writing the next spec, running tests on what
already merged, verifying research sources. Waiting for the whole batch before looking at
anything is correct only when the user explicitly asked for it. A regression that can be fixed
now is fixed ahead of the queue, because a broken integration branch blocks every agent still
to be merged.

## Review one agent at a time

Finish times differ by an order of magnitude: a `low`-effort edit returns in under a minute, an
`xhigh` audit can run twenty. `codex_wait.sh` blocks until an agent finishes and prints
`<label> <state>`; review it, dispatch a fix round if needed, add it to `--handled`, and wait
again. Waiting for the whole batch is justified only when the next decision needs all results
together, such as deduplicating findings across auditors or landing modules as one change.

## Review gate

An agent's report is a claim; a command that was run is evidence. Nothing is accepted on a
claim — not a confident summary, not a reasonable-looking diff, not another agent's approval.
`codex_verify.sh` mechanizes the checkable part and returns `not-verified` whenever no
acceptance check ran or a file outside the declared `Write:` scope changed:

```bash
scripts/codex_verify.sh "$RUN" auth-cache \
  --check "pytest tests/test_auth.py -q" --check "ruff check src/"
```

It records the changed files, the out-of-scope files, and every command with its exit code and
output tail in `verify.json`. Build artifacts are separated out rather than reported as scope
violations. The remaining steps need judgment and stay manual: read the diff line by line, run
a negative control so a passing test is known to fail without the change, and look for silent
passing such as weakened assertions or swallowed exceptions. Research output is checked the
same way, by fetching a sample of the sources and confirming the quoted numbers appear there.
The protocol is in [references/review-gate.md](references/review-gate.md).

## Feeding information to a running agent

`codex exec` accepts no input after it starts: stdin is consumed to EOF at launch, and SIGINT is
the only signal it interprets. New information therefore travels through a file the worker
re-reads. The live-notes block in the task spec requires re-reading `NOTES.md` at every step,
newest entry winning.

```bash
scripts/codex_note.sh "$RUN" auth-cache "The constant in config.py is stale; fix the files already written."
```

Verified: a worker that had written two files picked up the new requirement, applied it to the
remaining file, and corrected the first two. Create `NOTES.md` before dispatching; anything
arriving after the last checkpoint is missed, so critical corrections belong in a fix round.

## Run directory

Each run gets one directory holding the plan, the specs, the event logs, the results, and the
review, so both the review and any continuation have evidence to work from. The default is
`${XDG_CACHE_HOME:-~/.cache}/codex-runs`, overridable with `CODEX_RUNS_DIR`. A tmpfs path is
unsuitable: event logs are large and vanish on reboot.

```
<run>/PLAN.md                  decomposition, write scopes, acceptance criteria
<run>/schema/<name>.json       output schemas
<run>/worktrees/<label>/       that agent's isolated checkout
<run>/agents/<label>/
    prompt.md                  task spec
    NOTES.md                   information added while the agent runs
    events.jsonl               Codex events, every command and exit code
    stderr.log                 error output
    result.json | last.txt     final answer
    verify.json                review gate: scope check and every acceptance command run
    thread.txt                 thread id, for fix rounds and continuations
    meta.json                  exit code, duration, usage, timeout and stall flags, files touched
<run>/REVIEW.md                verdict per agent
```

Raw material stays in the run directory. The orchestrator reads the digest and the diff and
expands details on demand, so its own context is not flooded by worker output.

## Permissions

The sandbox is the permission boundary and defaults to the least that can do the job.

| Sandbox | Grants | Use for |
|---|---|---|
| `read-only` | reads only | research, audits, review, planning, data collection |
| `workspace-write` | writes under `--cwd` and each `--add-dir` | all implementation work |
| `danger-full-access` | unrestricted | never without the user's explicit approval |

`--network` is added only when the task genuinely fetches or searches, `--approve-for-me` only
when a worker legitimately needs to escalate. The scripts deliberately do not expose
`--dangerously-bypass-approvals-and-sandbox`.

## Scheduling by task

Effort, timeout, and concurrency all follow the task. None is a fixed value.

| `--tier` | effort | Use for | `--timeout` |
|---|---|---|---|
| `cheap` | `low` | mechanical edits, renames, formatting, boilerplate | 300–600 |
| `standard` | `medium` | default: contained feature, documentation, tests for one module | 900–1800 |
| `deep` | `high` | changes across several files, non-obvious bugs, behavior-preserving refactors | 1800–3600 |
| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–7200 |

`--tier` sets reasoning depth and model together. Export `CODEX_TIER_<TIER>_MODEL` to bind a
tier to a model; unset tiers use the Codex config default, and `--model` or `--effort`
overrides a tier for one agent. `--effort max` remains for a problem a `frontier` agent has
already failed twice.

The timeout is a runaway guard, not a schedule: estimate the work, then roughly triple it. A
large task on a short timeout is the worst case — the worker dies mid-edit, leaving a
half-applied change and no report. `--stall` covers the other case, interrupting a worker that
has emitted no event for the configured number of seconds.

Concurrency comes from `codex_capacity.sh`, which reads cores, available memory, and load
average, weights them by workload class (`light`, `medium`, `heavy`), halves the result on a
busy machine, and accepts `--per-agent-mb`. Mixed runs are budgeted per group, with headroom
left for the orchestrator's own test runs.

## Interruption, continuation, and re-dispatch

Exit 124 or 137 means a guard stopped the worker: `meta.json` reports `timed_out` or `stalled`,
there is no result file, and the workspace keeps whatever was finished. `thread.txt` remains
usable because the thread id is recorded at the start of the run.

```bash
scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache-cont \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/auth-cache-cont/prompt.md"
```

The continuation spec states that the previous run was cut off, what the workspace contains now,
and which part remains. Verified: an agent killed after 3 of 5 files resumed at file 4 without
redoing the first three.

Continuation is not free. The whole thread is replayed as input; one follow-up on a long thread
was metered at over 300K input tokens. Worker count itself is not limited, so the decision rests
on the value of that memory: resume when the context is expensive to rebuild and still correct;
start a fresh agent with a sharper spec when the context is small, reconstructible from the
workspace, or already proven wrong, since a mistaken assumption propagates through every later
turn.

Classify retries. A semantic failure never gets the same prompt again: send the review evidence
back as a targeted repair, or re-scope and dispatch fresh.

A transport failure is different. Codex emits non-terminal `error` events shaped
`Reconnecting... n/5 (unexpected status 502 …)` and gives up after five attempts; `meta.json`
then carries `reconnects` and `transient_failure: true`, and the status table shows
`TRANSIENT`. Nothing about the task was wrong, so the spec is not rewritten and the endpoint is
not hammered again silently. Report it with the evidence — reconnect count, endpoint, provider
request ids — and let the user choose between waiting for the upstream and resuming the
preserved thread. The thread id survives in `thread.txt`, so asking costs no work.

## Base drift and atomic integration

Every agent records the commit it started from, and `--worktree` refuses a base already behind
its upstream, so no worker builds on a tree nobody is running. When the integration branch moves
while agents are still working, the drift is visible and fixable:

```bash
scripts/codex_worktrees.sh "$RUN" --drift main
scripts/codex_worktrees.sh "$RUN" --rebase main
```

`--rebase` commits pending work and moves finished branches onto the new base, and skips any
worktree whose agent is live, because rebasing underneath a running writer corrupts work in
flight. A rebased branch is re-verified, since the earlier check ran against a different tree.

Integration is atomic per branch and for the run:

```bash
scripts/codex_merge.sh --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q" --rebase        # --dry-run first
```

The target must be clean before it starts. Each branch is committed in its worktree, merged
with `--no-ff`, and verified by every `--check` before the next branch is touched; a conflict, a
failed rebase, or a failed check resets the target to the exact commit the run started from. A
branch whose recorded base is no longer an ancestor of the target is rebased or refused, never
merged silently. Checks run after every merge rather than once at the end, because two branches
that pass alone can fail together.

## Known constraints

- `codex exec` reads inherited stdin, so `codex_agent.sh` feeds it the spec file; a hand-written
  invocation needs `< /dev/null`.
- `codex exec` has no internal time limit. Every call is wrapped in `timeout` sending SIGINT
  first, which Codex turns into a graceful turn interrupt.
- All options are root options and belong before the `resume` subcommand. A resumed run inherits
  no sandbox, working directory, model, or workspace roots from the original, so the full policy
  is repeated every time.
- The CLI forwards `--output-schema` unvalidated; an invalid schema is rejected by the API only
  after the dispatch is paid for, so `codex_agent.sh` pre-checks the documented Structured
  Outputs subset.
- Two agents writing one file overwrite each other with nothing detecting it at dispatch time.
  Worktrees and file ownership in `PLAN.md` prevent it.

Other failure modes are in [references/troubleshooting.md](references/troubleshooting.md); the
measurements behind these defaults are in [references/evidence.md](references/evidence.md).

## Documentation

- [SKILL.md](SKILL.md) — the orchestration workflow
- [references/prompt-template.md](references/prompt-template.md) — task spec template
- [references/schemas.md](references/schemas.md) — implementation, findings, research schemas
- [references/worktrees.md](references/worktrees.md) — isolating parallel writers, merging, cleanup
- [references/review-gate.md](references/review-gate.md) — the anti-optimism review protocol
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and recovery
- [references/evidence.md](references/evidence.md) — measurements and sources behind the defaults

## License

MIT
