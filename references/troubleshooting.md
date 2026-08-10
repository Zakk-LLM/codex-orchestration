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

`codex exec resume` takes neither `-C` nor `-s`. The workspace is the process working
directory, and the sandbox comes from `-c sandbox_mode=<mode>`. `codex_agent.sh` switches
automatically when `--resume` is given.

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
version, reverting the other, and re-dispatching with disjoint scopes. Prevent it by assigning
file ownership in `PLAN.md` before dispatching anything.

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
