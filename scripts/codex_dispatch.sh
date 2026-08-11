#!/usr/bin/env bash
# Dispatch a whole fan-out from a job list: hardest first, concurrency derived from the
# machine, everything else delegated to codex_agent.sh. One command instead of N background
# invocations the orchestrator has to track by hand.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: codex_dispatch.sh --run-dir DIR --jobs FILE [--weight light|medium|heavy] [--max N]
                         [--common "ARGS"] [--dry-run]

FILE is JSONL, one job per line. Recognized keys, all optional except label:

  {"label":"cache", "tier":"deep", "cwd":"/repo", "sandbox":"workspace-write",
   "worktree":true, "timeout":3600, "stall":300, "schema":"/path/schema.json",
   "network":false, "prompt_file":"/path/prompt.md", "effort":"high", "model":"...",
   "add_dir":["/other"], "profile":"..."}

prompt_file defaults to <run-dir>/agents/<label>/prompt.md. Jobs run hardest-tier-first, so
the long ones start while there is still capacity. Concurrency is min(--max, codex_capacity.sh
--weight). Each job's exit status is reported; the script waits for all of them.
EOF
}

RUN=; JOBS=; WEIGHT=medium; MAX=0; COMMON=; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    --weight) WEIGHT=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    --common) COMMON=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] && [ -n "$JOBS" ] || { usage >&2; exit 2; }
[ -f "$JOBS" ] || { echo "no such job file: $JOBS" >&2; exit 2; }

CAP=$("$HERE/codex_capacity.sh" "$WEIGHT" 2>/dev/null) || CAP=3
[ "$MAX" -gt 0 ] 2>/dev/null && [ "$MAX" -lt "$CAP" ] && CAP=$MAX
echo "dispatching with concurrency $CAP (weight $WEIGHT)" >&2

# Expand each job into a complete codex_agent.sh argument line, hardest tier first.
CMDS=$(RUN_DIR="$RUN" python3 - "$JOBS" <<'PY'
import json, os, shlex, sys
order = {"frontier": 0, "deep": 1, "standard": 2, "cheap": 3}
run = os.environ["RUN_DIR"]
jobs = []
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    try:
        j = json.loads(line)
    except json.JSONDecodeError as e:
        sys.exit(f"job file line {n}: {e}")
    if "label" not in j:
        sys.exit(f"job file line {n}: missing label")
    jobs.append(j)

for j in sorted(jobs, key=lambda j: order.get(j.get("tier", "standard"), 2)):
    label = j["label"]
    a = ["--run-dir", run, "--label", label]
    a += ["--prompt-file", j.get("prompt_file", f"{run}/agents/{label}/prompt.md")]
    for key, flag in (("tier", "--tier"), ("effort", "--effort"), ("model", "--model"),
                      ("profile", "--profile"), ("cwd", "--cwd"), ("sandbox", "--sandbox"),
                      ("schema", "--schema"), ("timeout", "--timeout"), ("stall", "--stall"),
                      ("worktree_base", "--worktree-base")):
        if j.get(key) is not None:
            a += [flag, str(j[key])]
    for d in j.get("add_dir", []) or []:
        a += ["--add-dir", str(d)]
    if j.get("worktree"):
        a += ["--worktree"] if j["worktree"] is True else ["--worktree", str(j["worktree"])]
    if j.get("network"):
        a += ["--network"]
    if j.get("approve_for_me"):
        a += ["--approve-for-me"]
    print(label + "\t" + " ".join(shlex.quote(x) for x in a))
PY
) || exit 2

[ -n "$CMDS" ] || { echo "no jobs found in $JOBS" >&2; exit 2; }

if [ "$DRY" = 1 ]; then
  printf '%s\n' "$CMDS" | while IFS=$'\t' read -r label args; do
    printf '%s: codex_agent.sh %s %s\n' "$label" "$args" "$COMMON"
  done
  exit 0
fi

PIDS=(); LABELS=()
while IFS=$'\t' read -r label args; do
  # Throttle to the computed capacity; a finished slot is reused immediately.
  while [ "$(jobs -pr | wc -l)" -ge "$CAP" ]; do sleep 2; done
  echo "start $label" >&2
  # Logs live outside agents/, which holds one directory per agent and nothing else.
  mkdir -p "$RUN/logs"
  eval "\"$HERE/codex_agent.sh\" $args $COMMON" > "$RUN/logs/$label.dispatch.log" 2>&1 &
  PIDS+=($!); LABELS+=("$label")
done <<< "$CMDS"

FAIL=0
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}"; code=$?
  [ "$code" = 0 ] || FAIL=1
  printf '%s exit=%s\n' "${LABELS[$i]}" "$code" >&2
done

"$HERE/codex_status.sh" "$RUN" 2>/dev/null | head -n $(( ${#PIDS[@]} + 4 ))
exit $FAIL
