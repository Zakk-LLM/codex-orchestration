#!/usr/bin/env bash
# Dispatch one Codex agent non-interactively and persist every artifact under the run
# directory. Always exits 0..N with the codex exit code; never blocks on stdin.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: codex_agent.sh --run-dir DIR --label NAME (--prompt-file FILE | --prompt TEXT) [options]

Required:
  --run-dir DIR      run directory created by the orchestrator
  --label NAME       agent label; artifacts land in <run-dir>/agents/<label>/
  --prompt-file F    task spec file (preferred)
  --prompt TEXT      inline task spec

Options:
  --cwd DIR          workspace root for the agent            (default: $PWD)
  --effort LEVEL     low|medium|high|xhigh|max               (default: medium)
  --sandbox MODE     read-only|workspace-write|danger-full-access (default: read-only)
  --schema FILE      JSON Schema; agent must answer with matching JSON
  --model NAME       model override
  --timeout SEC      hard wall-clock limit                   (default: 1800)
  --resume THREAD    continue an existing thread id (fix round)
  --add-dir DIR      extra writable dir (repeatable)
  --network          allow network access in the sandbox
  --approve-for-me   auto-review escalation requests instead of failing them

Artifacts: prompt.md events.jsonl stderr.log thread.txt meta.json
           result.json (with --schema) or last.txt (without)
EOF
}

RUN_DIR=; LABEL=; PROMPT_FILE=; PROMPT_TEXT=; CWD=$PWD
EFFORT=medium; SANDBOX=read-only; SCHEMA=; MODEL=; TIMEOUT=1800; RESUME=
NETWORK=0; APPROVE=0; ADD_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --prompt-file) PROMPT_FILE=$2; shift 2 ;;
    --prompt) PROMPT_TEXT=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --effort) EFFORT=$2; shift 2 ;;
    --sandbox) SANDBOX=$2; shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --add-dir) ADD_DIRS+=("$2"); shift 2 ;;
    --network) NETWORK=1; shift ;;
    --approve-for-me) APPROVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$RUN_DIR" ] && [ -n "$LABEL" ] || { echo "--run-dir and --label are required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] || [ -n "$PROMPT_TEXT" ] || { echo "--prompt-file or --prompt is required" >&2; exit 2; }
case "$EFFORT" in low|medium|high|xhigh|max) ;; *) echo "bad --effort: $EFFORT" >&2; exit 2 ;; esac
case "$SANDBOX" in read-only|workspace-write|danger-full-access) ;; *) echo "bad --sandbox: $SANDBOX" >&2; exit 2 ;; esac

CWD=$(cd "$CWD" && pwd) || exit 2
OUT="$RUN_DIR/agents/$LABEL"
mkdir -p "$OUT" || exit 2

if [ -n "$PROMPT_FILE" ]; then
  # The orchestrator usually writes the spec straight into the agent directory.
  [ "$PROMPT_FILE" -ef "$OUT/prompt.md" ] || cp "$PROMPT_FILE" "$OUT/prompt.md" || exit 2
else
  printf '%s\n' "$PROMPT_TEXT" > "$OUT/prompt.md"
fi

if [ -n "$SCHEMA" ]; then RESULT="$OUT/result.json"; else RESULT="$OUT/last.txt"; fi
rm -f "$RESULT" "$OUT/thread.txt"

# `codex exec resume` accepts neither -C nor -s: the workspace comes from the process cwd
# and the sandbox has to be set through the config override.
ARGS=(exec)
[ -n "$RESUME" ] && ARGS+=(resume "$RESUME")
ARGS+=(--json --skip-git-repo-check -o "$RESULT")
ARGS+=(-c "model_reasoning_effort=$EFFORT")
if [ -n "$RESUME" ]; then
  ARGS+=(-c "sandbox_mode=$SANDBOX")
else
  ARGS+=(-s "$SANDBOX" -C "$CWD")
  for d in ${ADD_DIRS+"${ADD_DIRS[@]}"}; do ARGS+=(--add-dir "$d"); done
fi
[ "$NETWORK" = 1 ] && ARGS+=(-c "sandbox_workspace_write.network_access=true")
[ "$APPROVE" = 1 ] && ARGS+=(--approve-for-me)
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
[ -n "$SCHEMA" ] && ARGS+=(--output-schema "$SCHEMA")
ARGS+=(-)   # prompt arrives on stdin, so no shell quoting can corrupt it

START=$(date +%s)
# stdin is the prompt file and nothing else: an inherited terminal stdin makes codex wait forever.
( cd "$CWD" && timeout --signal=INT --kill-after=30 "$TIMEOUT" \
    codex "${ARGS[@]}" < "$OUT/prompt.md" > "$OUT/events.jsonl" 2> "$OUT/stderr.log" )
CODE=$?
END=$(date +%s)

python3 - "$OUT" "$LABEL" "$CWD" "$EFFORT" "$SANDBOX" "$CODE" "$((END - START))" "$RESUME" <<'PY'
import json, sys, pathlib
out, label, cwd, effort, sandbox, code, dur, resume = sys.argv[1:9]
out = pathlib.Path(out)
thread, usage, errors = None, {}, []
for line in (out / "events.jsonl").read_text(errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("thread_id"):
        thread = ev["thread_id"]
    if ev.get("type") == "turn.completed":
        usage = ev.get("usage", {})
    if ev.get("type") in ("turn.failed", "error"):
        errors.append(ev)
if thread:
    (out / "thread.txt").write_text(thread + "\n")
result = out / "result.json" if (out / "result.json").exists() else out / "last.txt"
meta = {
    "label": label, "cwd": cwd, "effort": effort, "sandbox": sandbox,
    "resumed_from": resume or None, "exit_code": int(code), "duration_s": int(dur),
    "thread_id": thread, "usage": usage,
    "result_file": str(result) if result.exists() else None,
    "result_bytes": result.stat().st_size if result.exists() else 0,
    "errors": errors[:5],
    "timed_out": int(code) in (124, 137),
}
(out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({k: meta[k] for k in
      ("label", "exit_code", "duration_s", "thread_id", "result_file", "timed_out")},
      ensure_ascii=False))
PY

exit $CODE
