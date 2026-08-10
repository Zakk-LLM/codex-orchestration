#!/usr/bin/env bash
# Summarize every agent in a run directory: state, cost, thread id, result head.
set -uo pipefail

RUN_DIR=${1:-}
[ -n "$RUN_DIR" ] || { echo "usage: codex_status.sh <run-dir> [--full]" >&2; exit 2; }
FULL=${2:-}

python3 - "$RUN_DIR" "$FULL" <<'PY'
import json, pathlib, sys
run = pathlib.Path(sys.argv[1])
full = sys.argv[2] == "--full"
agents = sorted((run / "agents").glob("*")) if (run / "agents").is_dir() else []
if not agents:
    print(f"no agents under {run}")
    raise SystemExit(1)

rows, tin, tout = [], 0, 0
for a in agents:
    meta_file = a / "meta.json"
    if not meta_file.exists():
        rows.append((a.name, "RUNNING", "-", "-", "-", ""))
        continue
    m = json.loads(meta_file.read_text())
    u = m.get("usage") or {}
    tin += u.get("input_tokens", 0)
    tout += u.get("output_tokens", 0)
    state = "OK" if m["exit_code"] == 0 else ("TIMEOUT" if m.get("timed_out") else f"FAIL({m['exit_code']})")
    if m["exit_code"] == 0 and not m.get("result_file"):
        state = "NO-RESULT"
    rows.append((a.name, state, f"{m['duration_s']}s",
                 f"{u.get('output_tokens', 0)}", m.get("thread_id") or "-",
                 m.get("result_file") or ""))

w = max(len(r[0]) for r in rows)
print(f"{'AGENT'.ljust(w)}  STATE      TIME    OUT-TOK")
for name, state, dur, out, _, _ in rows:
    print(f"{name.ljust(w)}  {state:<9}  {dur:>5}  {out:>7}")
print(f"\ntotal input {tin} / output {tout} tokens across {len(rows)} agents")

for name, state, _, _, thread, path in rows:
    # Thread ids share a timestamp prefix, so print them in full for --resume.
    print(f"\n--- {name} [{state}] thread {thread}")
    if not path:
        continue
    text = pathlib.Path(path).read_text(errors="replace").strip()
    body = text if full else text[:700] + ("\n… (truncated, read the file)" if len(text) > 700 else "")
    print(f"{path}\n{body}")
PY
