# Failure modes

## The agent never returns

`codex exec` inherits stdin. With a terminal or an open pipe on stdin it prints
`Reading additional input from stdin...` and waits forever. `codex_agent.sh` feeds the prompt
file on stdin, which closes at EOF; a hand-written invocation needs `< /dev/null` when the
prompt is an argument.

`codex exec` also has no internal time limit, so every invocation is wrapped in `timeout`. Exit
code 124 or 137 means the wrapper killed it — `meta.json` reports `timed_out: true`.

A repeated timeout is a decomposition problem, not a timeout-value problem. Split the task and
re-dispatch.

## `error: unexpected argument '-C' found`

The option was placed after the `resume` subcommand. Every option is a root option and belongs
before it: `codex exec -C dir -s mode --json -o out resume <thread> -`.

The same ordering matters semantically, not just syntactically. A resumed run inherits nothing
from the original — sandbox, working directory, model, and workspace roots all come from the
new invocation — so an omitted flag silently falls back to the config default instead of the
worker's original policy. `codex_agent.sh` repeats the full policy on every resume.

## A resumed agent cost far more than expected

Resume replays the entire thread as input. A single follow-up question on a long research
thread was metered at over 300K input tokens. Continue a thread for the context it holds, not
out of habit: when the context is small or reconstructible from the workspace, a fresh agent
with a precise spec is cheaper and carries no stale assumptions.

## The agent went quiet

`--stall SEC` interrupts a worker that has emitted no event for that long, which catches a hung
command or a retry loop long before the wall-clock timeout. `meta.json` reports `stalled: true`
so it is distinguishable from a genuine overrun. Check the last `command_execution` in
`events.jsonl` to see what it hung on.

There is no supported way to send input into a running `codex exec` — stdin is consumed at
start, and SIGINT is the only signal it interprets, as a graceful turn interrupt. Corrections
travel through `NOTES.md` (see the live-notes mechanism) or a fix round.

## `not inside a trusted directory` / git repo errors

`--skip-git-repo-check` is always passed by the script. Codex may still refuse to write in a
directory the user has not trusted; the user resolves that with `codex` interactively once, or
by adding the path under `[projects]` in their Codex config. Do not work around it by escalating
the sandbox.

## The agent wrote nothing

Check in this order:

1. `meta.json` → `exit_code`, `timed_out`
2. `stderr.log` → auth, network, or config failures
3. `events.jsonl` → `command_execution` entries with non-zero exits, usually a sandbox denial
4. the sandbox: writing outside `--cwd` needs `--add-dir`; network access needs `--network`

## The result contradicts the diff

Normal and expected. A worker's summary reports intent, not outcome. Only `git diff` and the
test run are evidence. When they disagree, the summary is wrong.

## Two agents fought over one file

Overlapping write scopes, and nothing detects it at dispatch time. Recover by keeping one
version, reverting the other, and re-dispatching with disjoint scopes. Prevent it with
`--worktree` per write-capable agent, plus file ownership assigned in `PLAN.md` before anything
is dispatched. See [worktrees.md](worktrees.md).

## A worktree cannot be created

`--worktree` needs `--cwd` to be a git repository, and the branch name `codex/<name>` must be
free unless the worktree is being reused deliberately. A leftover worktree from an aborted run
blocks reuse of the same path: `codex_worktrees.sh <run> --list` shows what is registered, and
`--remove-merged <base>` removes only what has already landed.

## The worker committed anyway

The prohibition block was missing or diluted. Recover with `git reset --soft HEAD~1`, review the
staged content, and decide yourself. Never leave `git commit` unmentioned in a spec that runs
with `workspace-write`.

## Rate limits or auth failures

`stderr.log` shows them plainly. Lower concurrency to two agents, and re-dispatch the failed
labels only. The completed agents' results stay valid — never restart a whole run for one
failed agent.

## Reading the event log

`events.jsonl` is one JSON object per line:

- `thread.started` → `thread_id`, needed for `--resume`
- `item.completed` with `type: "command_execution"` → the exact command, output, and exit code
- `item.completed` with `type: "agent_message"` → intermediate narration
- `turn.completed` → `usage` token counts

Filter instead of reading the whole file:

```sh
python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    i=e.get("item",{})
    if i.get("type")=="command_execution":
        print(i.get("exit_code"), i.get("command"))' <run>/agents/<label>/events.jsonl
```

## Cost control

`codex_status.sh` totals the token usage per run. When output tokens run high for the value
returned, the usual causes are an effort level above what the task needs, a spec so vague the
worker explores the repository first, or a missing schema letting it write an essay.
