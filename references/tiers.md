# Picking effort, sandbox, and timeout

Difficulty decides both the reasoning depth and the model. `--tier` sets them together, so the
cheap work stays cheap without a decision per flag (the tier table itself stays in
`SKILL.md`, step 5, where the contract check reads it):

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
the job (the profile table is in `SKILL.md`, step 5):

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

Estimate from the work, then roughly triple it, up to the ceiling: a worker spends most of its wall-clock reading
the repository and running commands, not generating text.

**Hard ceiling: 5400 seconds (90 minutes) for any worker.** A worker still running past that is treated as suspect, non-essential work — repeated full gate runs, ablation of every hunk, a sixth version of the report — and is killed on sight, not waited for; every extra round re-reads the whole context and burns tokens by the hour. You finish from what is in its worktree: commit by theme, push, let CI be the gate. Cap the verification in the spec itself: one full gate run, two or three ablations of the hunks that matter, one report, and the sentence "do not repeat a full round".

