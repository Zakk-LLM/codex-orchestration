#!/usr/bin/env bash
# A bounded wait that always returns something actionable. Blocks until an agent finishes,
# stalls, or dies, or until the deadline — then prints what changed since the last call. The
# point is that an orchestrator never sleeps for an unknown length of time and never polls
# blindly: it either gets work back, or gets told the window is free for other work.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: codex_watch.sh <run-dir> [--timeout SEC] [--interval SEC] [--state FILE]

  --timeout SEC   maximum block, default 300. Pick it as the time until your next useful
                  action, not as how long the agents might take.
  --interval SEC  poll interval, default 10
  --state FILE    where the seen-set lives, default <run-dir>/.watch-state
  --warn PCT      warn when a running agent has used this share of its wall-clock limit,
                  default 80. Reported once per agent as "<label> EXPIRING <seconds> left".

Exit codes:
  0  something changed — labels and states are printed, act on them now
  1  nothing changed before the deadline — spend the window on work that needs no agent
  2  every agent in the run has finished
  3  the run has no agents yet
EOF
}

RUN=${1:-}; shift 2>/dev/null
[ -n "$RUN" ] || { usage >&2; exit 3; }
case "$RUN" in -h|--help) usage; exit 0 ;; esac

TIMEOUT=300; INTERVAL=10; STATE=; WARN=80
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --state) STATE=$2; shift 2 ;;
    --warn) WARN=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done
[ -n "$STATE" ] || STATE="$RUN/.watch-state"
[ -d "$RUN/agents" ] || { echo "no agents under $RUN" >&2; exit 3; }

WAITED=0
while :; do
  # Two orchestrators watching one run must not both claim the same completion, so the
  # read-modify-write of the seen-set happens under a lock.
  OUT=$(flock "$STATE.lock" env RUN_DIR="$RUN" STATE_FILE="$STATE" WARN_PCT="$WARN" python3 <<'PY'
import json, os, pathlib, sys, time

run = pathlib.Path(os.environ["RUN_DIR"])
state_file = pathlib.Path(os.environ["STATE_FILE"])
try:
    seen = json.loads(state_file.read_text())
except (OSError, json.JSONDecodeError):
    seen = {}

agents = [a for a in sorted((run / "agents").glob("*")) if a.is_dir()]
# A directory holding only a prepared spec has not been dispatched: events.jsonl appears when
# the worker actually starts. Counting it as running would hide "nothing was dispatched".
dispatched = [a for a in agents if (a / "events.jsonl").exists() or (a / "meta.json").exists()]
if not dispatched:
    sys.exit(3)

now = time.time()
warn_pct = int(os.environ.get("WARN_PCT", "80"))
changed, running, done = [], 0, 0
for a in dispatched:
    meta = a / "meta.json"
    if not meta.exists():
        running += 1
        # A guard kill destroys the turn's work, so the warning has to arrive before it, not
        # after: an expiring agent can still be told to stop and report what it has.
        try:
            s = json.loads((a / "started.json").read_text())
        except (OSError, json.JSONDecodeError):
            continue
        left = int(s.get("deadline", 0) - now)
        limit = int(s.get("timeout_s") or 0)
        if limit and left <= limit * (100 - warn_pct) / 100:
            key = f"{a.name}#expiring"
            if key not in seen:
                seen[key] = "EXPIRING"
                changed.append((a.name, f"EXPIRING {max(left, 0)}s left of {limit}s", "", ""))
        stall = int(s.get("stall_s") or 0)
        events = a / "events.jsonl"
        if stall and events.exists():
            quiet = int(now - events.stat().st_mtime)
            if quiet >= stall * warn_pct / 100:
                key = f"{a.name}#quiet"
                if key not in seen:
                    seen[key] = "QUIET"
                    changed.append((a.name, f"QUIET {quiet}s without an event, stall kill at {stall}s",
                                    "", ""))
        continue
    try:
        m = json.loads(meta.read_text())
    except (json.JSONDecodeError, OSError):
        # A meta file being written right now is not a finished agent.
        running += 1
        continue
    done += 1
    if m.get("exit_code") == 0:
        state = "OK"
    elif m.get("transient_failure"):
        state = "TRANSIENT"
    elif m.get("stalled"):
        state = "STALLED"
    elif m.get("timed_out"):
        state = "TIMEOUT"
    else:
        state = f"FAIL({m.get('exit_code')})"
    if seen.get(a.name) != state:
        changed.append((a.name, state, m.get("result_file") or "",
                        m.get("thread_id") or ""))
        seen[a.name] = state

if changed:
    state_file.write_text(json.dumps(seen))
    for name, state, result, thread in changed:
        print(f"{name}\t{state}\t{result}\t{thread}")
    print(f"# {running} still running, {done} finished", file=sys.stderr)
    sys.exit(0)

# Nothing new. Distinguish "all finished and already handled" from "still working".
sys.exit(2 if running == 0 else 1)
PY
)
  CODE=$?
  case "$CODE" in
    0) printf '%s\n' "$OUT"; exit 0 ;;
    2) echo "all agents finished and already reported" >&2; exit 2 ;;
    3) exit 3 ;;
  esac
  [ "$WAITED" -ge "$TIMEOUT" ] && {
    echo "nothing changed in ${TIMEOUT}s — use the window for work that needs no agent" >&2
    exit 1
  }
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done
