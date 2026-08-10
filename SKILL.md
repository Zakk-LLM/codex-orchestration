---
name: codex
description: Drive the Codex CLI as a fleet of worker agents while you stay the orchestrator and reviewer. Use when a task is large enough to split across parallel workers — feature implementation, refactors, bug hunts, test writing, README and documentation drafting, research and data collection, multi-file audits — or whenever the user asks to delegate work to Codex. You write the plan, dispatch scoped agents, supervise, review every diff yourself, and own the commit, merge, and deploy steps that Codex is never allowed to touch.
---

# Codex Orchestration

Codex writes; you plan, supervise, review, and ship. Codex agents never commit, never
push, never deploy, and never decide that their own output is acceptable.

## Preflight

Run once per session, before dispatching anything:

```sh
codex --version || echo "codex CLI not installed — stop and tell the user"
```

The scripts below assume `codex >= 0.40` with the `exec` subcommand. Set
`CODEX_SKILL=<this skill's directory>` so the examples are copy-pasteable.

## When not to use this

Do the work yourself when it is a single obvious edit, a one-file read, a question you can
answer from context, or anything needing under ~2 minutes. Dispatch costs a process launch,
a full context prime for the worker, and a review pass from you. Delegate when the task has
independent parts, needs bulk file work, or would otherwise flood your own context.

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
<run>/schema/<name>.json      output schemas
<run>/agents/<label>/prompt.md events.jsonl stderr.log result.json|last.txt thread.txt meta.json
<run>/REVIEW.md               your findings per agent, with the verdict
```

Override the base with `CODEX_RUNS_DIR`; the default is `${XDG_CACHE_HOME:-~/.cache}/codex-runs`.
Keep the run directory after finishing so the thread ids stay usable; delete stale runs when
the user asks for cleanup.

### 2. Decompose, then write PLAN.md

Split by file ownership, not by activity. Two agents editing the same file will clobber each
other, because they run as separate processes with no shared lock. Record each agent's label,
exact writable scope, sandbox, effort, and dependencies in `PLAN.md`.

Independent agents run in parallel. A dependent agent waits for the result file of the agent
it depends on. Derive the concurrency from what the agents actually do and what the machine
has free, rather than from a fixed number:

```sh
"$CODEX_SKILL/scripts/codex_capacity.sh" heavy    # light | medium | heavy
```

`light` is reading and drafting, `medium` is editing plus a targeted test, `heavy` is full
builds, whole test suites, or containers. The script reads cores, available memory, and load
average, and halves the answer on a busy machine; override its memory estimate with
`--per-agent-mb` when you know the real cost. Mixed runs are budgeted per group: three heavy
compile agents and two light readers, not five of whatever the first estimate said. Leave room
for the tests you run yourself during review — you are a workload on the same machine.

Dispatch the longest-running agents first — the `xhigh` ones, and anything reading a lot of
code — so the quick agents finish inside their runtime and you review during the wait instead
of after it.

### 3. Write the task spec

One file per agent, `<run>/agents/<label>/prompt.md`, produced from
[references/prompt-template.md](references/prompt-template.md). A spec that omits the scope
fence or the acceptance criteria produces work you will have to throw away. Always include
the prohibition block — Codex will otherwise commit, or wander into unrelated files.

Give every agent a `NOTES.md` so you can correct it while it runs (step 7), and make the spec
say when to re-read it.

### 4. Hand over the skills the worker needs

A non-interactive worker applies a skill only when the spec names it. List what Codex can see:

```sh
ls "${CODEX_HOME:-$HOME/.codex}/skills"
```

When a listed skill covers the task — a writing standard, a repository workflow, a domain
convention — put a `## Skills` block in the spec with the absolute path to its `SKILL.md` and
the instruction to read it first. Skills installed for you are not automatically installed for
Codex: if the one you rely on is missing from that directory, either paste its operative rules
into the spec, or ask the user before installing it for Codex.

Repository instruction files (`AGENTS.md`, `CLAUDE.md`) are read by the worker only if they sit
in or above its `--cwd`. When they do not, paste the rules that apply.

### 5. Pick effort, sandbox, and timeout

Effort maps to task difficulty, not to importance. Costs rise steeply.

| effort | use for |
|--------|---------|
| `low` | mechanical edits, renames, formatting, boilerplate, extracting known facts |
| `medium` | default: a contained feature, a README, tests for existing code, structured research |
| `high` | changes spanning several files, non-obvious bugs, refactors with behavior to preserve |
| `xhigh` | architecture decisions, concurrency and performance work, ambiguous requirements |
| `max` | last resort after a `xhigh` agent failed twice on the same problem |

Sandbox is the permission boundary and defaults to the most restrictive option that can do
the job:

| sandbox | grants | use for |
|---------|--------|---------|
| `read-only` | reads anywhere, no writes | research, audits, review, planning, data collection |
| `workspace-write` | writes under `--cwd` plus each `--add-dir` | all implementation work |
| `danger-full-access` | unrestricted | never without the user's explicit approval in this session |

Add `--network` only when the task genuinely fetches something; add `--approve-for-me` when a
worker legitimately needs to escalate a command instead of failing. Grant write access to the
smallest directory that contains the agent's files.

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
  --cwd /path/to/repo --sandbox workspace-write --effort high \
  --prompt-file "$RUN/agents/auth-cache/prompt.md" \
  --schema "$RUN/schema/impl.json" --timeout 1800
```

Run each dispatch as a background command so several agents progress at once, and so a stuck
agent cannot block you. The script prints a one-line JSON summary and writes `meta.json`.

For anything you must parse rather than read, pass `--schema`: Codex is then forced to answer
with JSON matching that schema, which removes prose-parsing failures. See
[references/schemas.md](references/schemas.md) for ready-made schemas.

Non-negotiable invocation rules, each learned from a real failure:

- Never let Codex inherit your stdin. The script feeds the prompt file on stdin; a raw
  `codex exec "prompt"` with an inherited terminal stdin hangs until it is killed.
- Always wrap in `timeout`. `codex exec` has no internal limit.
- `codex exec resume` accepts neither `-C` nor `-s`: the workspace is the process cwd and the
  sandbox comes from `-c sandbox_mode=…`. The script already handles this.
- Outside a git repository, `--skip-git-repo-check` is required (the script always passes it).

### 7. Supervise — handle agents one at a time, as they land

Agents finish minutes apart: a `low`-effort edit returns in under a minute while an `xhigh`
audit runs for twenty. Never block on the whole batch. Review each agent the moment it
finishes and start its fix round while the others are still working — the slowest agent then
costs nothing extra, and a spec-level mistake surfaces early enough to fix the remaining
agents' specs.

```sh
"$CODEX_SKILL/scripts/codex_wait.sh" "$RUN" --handled auth-cache,docs   # blocks, prints "<label> <state>"
"$CODEX_SKILL/scripts/codex_status.sh" "$RUN"                           # full picture when you want it
```

The loop: wait → review that one agent (step 8) → dispatch its fix round if needed → add it to
`--handled` → wait again. Agents still running show `RUNNING` in the status table. Keep the
poll interval proportional to the expected runtime; do not re-read a growing `events.jsonl`
on every tick.

Wait for everything only when the next decision genuinely needs all results together —
deduplicating findings across parallel auditors, or integrating modules that must land as one
change. Everything else is per-agent work masquerading as a batch.

Read `events.jsonl` when an agent misbehaves; it records each `command_execution` with its exit
code, so you can see exactly what the worker ran and where it went wrong.

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

Run this per agent, as soon as that agent returns. A worker's own summary is a claim, not
evidence:

1. Read the real diff (`git diff`, or read the files if the workspace is not a repository).
   Never accept `files_changed` at face value.
2. Check the diff against the acceptance criteria in `PLAN.md`, and check that nothing outside
   the declared scope was touched.
3. Run the tests, the build, and the linter yourself. Do not trust a worker's "verified".
4. Optionally take a second opinion inside a git repository:
   `codex exec review --uncommitted` — useful, still only advisory.
5. Write the verdict per agent into `<run>/REVIEW.md`: accept, fix round, or redo.

Reject silently-passing work: tests weakened to pass, exceptions swallowed, features stubbed,
files created outside scope, dependencies added that nobody asked for.

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

### 10. Ship

You perform every irreversible step: staging, commit messages, tags, PRs, merges, releases,
deploys. Confirm with the user before anything outward-facing. Report what each agent produced,
what you rejected, and what you changed yourself.

## Common task shapes

- **Feature**: one `read-only` agent maps the code, then parallel `workspace-write` agents by
  module, then you integrate and review.
- **Bug hunt**: several parallel `read-only` agents with different lenses (correctness,
  boundaries, concurrency, error paths), each returning a findings schema; you deduplicate,
  then dispatch fixes for the confirmed ones only.
- **README or docs**: a `read-only` agent collects the facts, a `workspace-write` agent drafts,
  you verify every command and claim it makes. Apply the repository's writing rules yourself —
  workers do not know them unless you paste them into the spec.
- **Research and data collection**: `read-only` plus `--network`, always with a schema, plus a
  requirement that every claim carries a source. Verify the sources; workers do fabricate them.
- **Migration or sweep**: one agent per file batch, identical spec, disjoint scopes.

## References

- [references/prompt-template.md](references/prompt-template.md) — the task spec structure
- [references/schemas.md](references/schemas.md) — output schemas for impl, findings, research
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and fixes
