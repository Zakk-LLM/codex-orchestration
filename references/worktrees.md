# Parallel agents on one repository

Two agents writing one checkout overwrite each other, and nothing detects it at dispatch time.
A git worktree gives each write-capable agent its own working files, HEAD, and index while
sharing the object store, so the conflict moves from the filesystem to merge time where it is
visible and reviewable.

Measured context: a study of co-active agent-authored pull requests found textual conflicts in
41.7% of cross-agent pairs against 19.8% for same-agent pairs, and roughly 42% of conflicted
files carried structural conflicts. Isolation does not remove that; it converts silent
clobbering into a merge you can inspect.

## Dispatching into worktrees

```sh
"$CODEX_SKILL/scripts/codex_agent.sh" --run-dir "$RUN" --label cache \
  --cwd /path/to/repo --worktree --worktree-base main \
  --sandbox workspace-write --effort high --timeout 3600 \
  --prompt-file "$RUN/agents/cache/prompt.md"
```

`--worktree` creates `<run>/worktrees/<label>` on branch `codex/<label>` from
`--worktree-base` (default `HEAD`), runs the agent there, and records the branch and base SHA
in `meta.json`. `--worktree NAME` shares one worktree between several agents that must build on
each other — a fix round inherits its parent's worktree by passing the same name.

The agent's spec still declares its write scope. The worktree stops cross-agent clobbering; it
does not stop an agent from editing files that belong to someone else's task.

## When to use it

Use a worktree for every write-capable agent in a fan-out of two or more, and whenever an agent
runs long enough that you want to keep working in the main checkout meanwhile.

Skip it for read-only agents, for a single writer with nothing else running, and when the build
is so expensive that a fresh checkout costs more than serializing the work — each worktree needs
its own dependency install and build output.

## Merging

Review each branch on its own, then integrate deliberately:

```sh
git -C /path/to/repo diff main...codex/cache        # what this agent actually changed
git -C /path/to/repo merge --no-ff codex/cache      # you merge, never the agent
```

Merge in dependency order, run the tests after each merge rather than only at the end, and when
two branches touch one file, resolve it yourself instead of asking an agent to "fix the
conflict" — the agent that wrote one side cannot see why the other side exists.

## Cleanup

Worktrees, branches, and their build output persist until removed:

```sh
"$CODEX_SKILL/scripts/codex_worktrees.sh" "$RUN" --list
"$CODEX_SKILL/scripts/codex_worktrees.sh" "$RUN" --remove-merged main
```

Remove them once the work is merged or abandoned. A run directory full of stale worktrees is
a disk problem on any machine and a snapshot problem on filesystems that snapshot the home
directory.

## Sandbox interaction

A worktree lives under the run directory, not under the repository, so `workspace-write` grants
writes there because the agent's `--cwd` is the worktree itself. The main checkout stays outside
the sandbox boundary — which is the point. An agent needing to read the main checkout as well
gets `--add-dir /path/to/repo` and a spec that says read-only for that path.

Submodules are the known exception: git documents incomplete support for multiple superproject
checkouts, so a submodule-heavy repository needs a plain clone per agent instead.
