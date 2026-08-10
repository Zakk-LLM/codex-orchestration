# Codex Orchestration Skill

English | [繁體中文](README.zh-TW.md)

A skill that lets an orchestrating agent drive a fleet of Codex CLI workers while keeping
planning, supervision, review, and shipping for itself. Use it for feature work, refactors,
bug hunts, test backfills, README and documentation drafting, research, and multi-file audits.

The division of labor is fixed: Codex writes code and drafts, the orchestrator reads the real
diff, runs the tests, and writes the verdict. Commits, merges, and releases stay with the
orchestrator, and every task spec forbids workers from running history-rewriting git commands.

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

The default installs a symlink for every agent present on the machine. A symlink install
requires the source directory to stay put; uninstall first if you need to move or delete it,
or use `--copy`.

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

The orchestrator reads [SKILL.md](SKILL.md) first. Run by hand, the scripts form the whole
loop:

```bash
RUN=$(scripts/codex_new_run.sh add-auth-cache)
scripts/codex_capacity.sh medium

scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 1800 \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json"

scripts/codex_note.sh "$RUN" auth-cache "Token TTL is 900s, not 3600s."
scripts/codex_wait.sh "$RUN" --handled docs
scripts/codex_status.sh "$RUN"
```

Every script documents its options under `--help`.

## Review one agent at a time

Finish times differ by an order of magnitude: a `low`-effort edit returns in under a minute
while an `xhigh` audit runs for twenty. `codex_wait.sh` blocks until an agent finishes and
prints `<label> <state>`; review that one, dispatch its fix round if needed, add it to
`--handled`, and wait again. Wait for the whole batch only when the next decision genuinely
needs all results together, such as deduplicating findings across parallel auditors or landing
modules as a single change.

## Feeding information to a running agent

`codex exec` accepts no input once it starts, so new information reaches a live worker through
a file it re-reads. The live-notes block in the task spec tells the worker to re-read
`NOTES.md` at every step, newest entry winning:

```bash
scripts/codex_note.sh "$RUN" auth-cache "The constant in config.py is stale; fix the files you already wrote."
```

Verified: a worker that had already written two files picked up the new requirement, applied it
to the remaining file, and went back to correct the first two. Create `NOTES.md` before
dispatching, and remember that anything arriving after the worker's last checkpoint is missed —
critical corrections belong in a fix round.

## Run directory

Each run gets one directory holding the plan, the specs, the event logs, the results, and your
review, so both the review and any later continuation have evidence to work from. The default
is `${XDG_CACHE_HOME:-~/.cache}/codex-runs`, overridable with `CODEX_RUNS_DIR`. Do not point it
at a tmpfs path: event logs are large and would vanish on reboot.

```
<run>/PLAN.md                  decomposition, write scopes, acceptance criteria
<run>/schema/<name>.json       output schemas
<run>/agents/<label>/
    prompt.md                  task spec
    NOTES.md                   information added while the agent runs
    events.jsonl               Codex events, every command and exit code
    stderr.log                 error output
    result.json | last.txt     the agent's final answer
    thread.txt                 thread id, for fix rounds and continuations
    meta.json                  exit code, duration, token usage, timeout flag
<run>/REVIEW.md                your verdict per agent
```

## Permissions

The sandbox is the permission boundary and defaults to the least that can do the job.

| Sandbox | Grants | Use for |
|---|---|---|
| `read-only` | reads only | research, audits, review, planning, data collection |
| `workspace-write` | writes under `--cwd` and each `--add-dir` | all implementation work |
| `danger-full-access` | unrestricted | never without the user's explicit approval |

Add `--network` only when the task really fetches something, and `--approve-for-me` only when a
worker legitimately needs to escalate. The scripts deliberately do not expose
`--dangerously-bypass-approvals-and-sandbox`.

## Scheduling by task

Effort, timeout, and concurrency all follow the task. None of them is a fixed value.

| Effort | Use for | `--timeout` |
|---|---|---|
| `low` | mechanical edits, renames, formatting, boilerplate | 300–600 |
| `medium` | default: contained feature, README, tests for one module | 900–1800 |
| `high` | changes across several files, non-obvious bugs, refactors | 1800–3600 |
| `xhigh` | architecture, concurrency, performance, vague requirements | 3600–7200 |
| `max` | last resort after `xhigh` failed twice on the same problem | 7200+ |

The timeout is a runaway guard, not a schedule: estimate the work, then roughly triple it. A
large task on a short timeout is the worst case — the worker dies mid-edit, leaving a
half-applied change and no report.

Concurrency comes from `codex_capacity.sh`, which reads cores, available memory, and load
average, weights them by what the agents do (`light`, `medium`, `heavy`), halves the result on
a busy machine, and takes `--per-agent-mb` when you know the real cost. Budget mixed runs per
group, and leave headroom for the tests you run yourself during review.

## Interruption and continuation

Exit 124 or 137 means the timeout guard killed the worker: `meta.json` reports
`timed_out: true`, there is no result file, and the workspace keeps whatever was finished.
`thread.txt` is still usable because the thread id is recorded at the start of the run, so
continue that thread instead of starting over — the worker keeps its plan and its knowledge of
the code:

```bash
scripts/codex_agent.sh --run-dir "$RUN" --label auth-cache-cont \
  --resume "$(cat "$RUN/agents/auth-cache/thread.txt")" \
  --cwd /path/to/repo --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/auth-cache-cont/prompt.md"
```

The continuation spec states that the previous run was cut off, what the workspace actually
contains now, and which part remains. Verified: an agent killed after 3 of 5 files resumed at
file 4 without redoing the first three. The same recovery covers a cancelled run, a reboot, or
a dropped connection; when `thread.txt` is missing, `codex exec resume --last` from the same
working directory picks the newest session.

A task that times out twice is not a timeout-value problem — split the remainder into separate
agents.

## Known constraints

- `codex exec` reads inherited stdin, so `codex_agent.sh` feeds it the spec file. A hand-written
  invocation needs `< /dev/null`, or it waits forever.
- `codex exec` has no internal time limit, so every call is wrapped in `timeout`.
- `codex exec resume` accepts neither `-C` nor `-s`: the workspace is the process working
  directory and the sandbox comes from `-c sandbox_mode=`.
- Two agents writing one file overwrite each other with nothing detecting it at dispatch time,
  so file ownership is assigned in `PLAN.md` first.

Other failure modes are covered in [references/troubleshooting.md](references/troubleshooting.md).

## Documentation

- [SKILL.md](SKILL.md) — the orchestrator's full workflow
- [references/prompt-template.md](references/prompt-template.md) — task spec template
- [references/schemas.md](references/schemas.md) — implementation, findings, research schemas
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and recovery

## License

MIT
