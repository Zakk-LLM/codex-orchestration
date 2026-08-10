#!/usr/bin/env bash
# Dispatch one Codex agent non-interactively and persist every artifact under the run
# directory. Never blocks on stdin; always writes meta.json, even when killed.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: codex_agent.sh --run-dir DIR --label NAME (--prompt-file FILE | --prompt TEXT) [options]

Required:
  --run-dir DIR      run directory created by codex_new_run.sh
  --label NAME       agent label; artifacts land in <run-dir>/agents/<label>/
  --prompt-file F    task spec file (preferred)
  --prompt TEXT      inline task spec

Workspace:
  --cwd DIR          workspace root for the agent            (default: $PWD)
  --add-dir DIR      extra writable dir (repeatable)
  --worktree [NAME]  run in a dedicated git worktree of --cwd, branch codex/<name>
  --worktree-base B  branch or commit the worktree starts from  (default: HEAD)

Model and limits:
  --effort LEVEL     low|medium|high|xhigh|max               (default: medium)
  --sandbox MODE     read-only|workspace-write|danger-full-access (default: read-only)
  --model NAME       model override
  --profile NAME     Codex config profile ($CODEX_HOME/<name>.config.toml)
  --timeout SEC      hard wall-clock limit                   (default: 1800)
  --stall SEC        kill when no event arrives for this long (default: off)

Behavior:
  --schema FILE      JSON Schema; the final message must match it
  --resume THREAD    continue an existing thread id
  --network          allow network access and web search
  --approve-for-me   auto-review escalation requests instead of failing them

Artifacts: prompt.md events.jsonl stderr.log thread.txt meta.json
           result.json (with --schema) or last.txt (without)
EOF
}

RUN_DIR=; LABEL=; PROMPT_FILE=; PROMPT_TEXT=; CWD=$PWD
EFFORT=medium; SANDBOX=read-only; SCHEMA=; MODEL=; PROFILE=; TIMEOUT=1800; STALL=0; RESUME=
NETWORK=0; APPROVE=0; ADD_DIRS=(); WORKTREE=; WORKTREE_BASE=HEAD

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --prompt-file) PROMPT_FILE=$2; shift 2 ;;
    --prompt) PROMPT_TEXT=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --add-dir) ADD_DIRS+=("$2"); shift 2 ;;
    --worktree)
      if [ $# -ge 2 ] && case "$2" in --*) false ;; *) true ;; esac; then WORKTREE=$2; shift 2
      else WORKTREE=@label; shift; fi ;;
    --worktree-base) WORKTREE_BASE=$2; shift 2 ;;
    --effort) EFFORT=$2; shift 2 ;;
    --sandbox) SANDBOX=$2; shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --profile) PROFILE=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --stall) STALL=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
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

# Structured Outputs rejects a schema the CLI happily forwards, and the rejection costs a
# whole dispatch, so check the documented subset here.
if [ -n "$SCHEMA" ]; then
  python3 - "$SCHEMA" <<'PY' || exit 2
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"schema is not valid JSON: {e}")
bad = {"allOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas",
       "patternProperties", "oneOf"}
problems, depth_seen = [], 0
def walk(node, path="$", depth=0):
    global depth_seen
    depth_seen = max(depth_seen, depth)
    if not isinstance(node, dict):
        return
    for k in node.keys() & bad:
        problems.append(f"{path}: unsupported keyword {k!r}")
    if node.get("type") == "object":
        props = node.get("properties", {})
        if node.get("additionalProperties") is not False:
            problems.append(f'{path}: needs "additionalProperties": false')
        missing = set(props) - set(node.get("required", []))
        if missing:
            problems.append(f"{path}: every property must be required, missing {sorted(missing)}")
        for name, sub in props.items():
            walk(sub, f"{path}.{name}", depth + 1)
    if "items" in node:
        walk(node["items"], f"{path}[]", depth + 1)
    for sub in node.get("anyOf", []):
        walk(sub, f"{path}|", depth + 1)
    for name, sub in node.get("$defs", {}).items():
        walk(sub, f"$defs.{name}", depth)
if s.get("type") != "object":
    problems.append("$: root must be an object")
walk(s)
if depth_seen > 10:
    problems.append(f"$: nesting depth {depth_seen} exceeds the documented limit of 10")
if problems:
    sys.exit("schema rejected before dispatch:\n  " + "\n  ".join(problems))
PY
fi

# A git worktree gives a write-capable agent its own checkout, so parallel agents cannot
# overwrite each other's files. Conflicts move to merge time, where they are visible.
WORKTREE_PATH=; WORKTREE_BRANCH=; WORKTREE_BASE_SHA=
if [ -n "$WORKTREE" ]; then
  [ "$WORKTREE" = "@label" ] && WORKTREE=$LABEL
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || { echo "--worktree needs $CWD to be a git repository" >&2; exit 2; }
  WORKTREE_BRANCH="codex/$WORKTREE"
  WORKTREE_PATH="$RUN_DIR/worktrees/$WORKTREE"
  WORKTREE_BASE_SHA=$(git -C "$CWD" rev-parse --verify "$WORKTREE_BASE" 2>/dev/null)
  if [ ! -d "$WORKTREE_PATH" ]; then
    mkdir -p "$RUN_DIR/worktrees"
    if git -C "$CWD" show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
      git -C "$CWD" worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH" >&2 || exit 2
    else
      git -C "$CWD" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$WORKTREE_BASE" >&2 || exit 2
    fi
  fi
  CWD=$(cd "$WORKTREE_PATH" && pwd)
fi

if [ -n "$SCHEMA" ]; then RESULT="$OUT/result.json"; else RESULT="$OUT/last.txt"; fi
rm -f "$RESULT" "$OUT/thread.txt"

# Every option is a root option placed before the `resume` subcommand: resume does not inherit
# sandbox, cwd, model, or workspace roots from the original run, and its own parser rejects
# -C and -s outright.
ARGS=(exec --json --skip-git-repo-check -C "$CWD" -s "$SANDBOX" -o "$RESULT")
ARGS+=(-c "model_reasoning_effort=$EFFORT")
for d in ${ADD_DIRS+"${ADD_DIRS[@]}"}; do ARGS+=(--add-dir "$d"); done
if [ "$NETWORK" = 1 ]; then
  # This key has moved between versions; unknown keys are ignored without --strict-config.
  ARGS+=(-c "sandbox_workspace_write.network_access=true")
  ARGS+=(-c 'network_access="enabled"')
  ARGS+=(-c "tools.web_search=true")
fi
[ "$APPROVE" = 1 ] && ARGS+=(--approve-for-me)
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
[ -n "$PROFILE" ] && ARGS+=(-p "$PROFILE")
[ -n "$SCHEMA" ] && ARGS+=(--output-schema "$SCHEMA")
[ -n "$RESUME" ] && ARGS+=(resume "$RESUME")
ARGS+=(-)   # prompt arrives on stdin, so no shell quoting can corrupt it

START=$(date +%s)
# stdin is the prompt file and nothing else: an inherited terminal stdin makes codex wait
# forever. SIGINT first, because Codex turns it into a graceful turn interrupt.
( cd "$CWD" && timeout --signal=INT --kill-after=30 "$TIMEOUT" \
    codex "${ARGS[@]}" < "$OUT/prompt.md" > "$OUT/events.jsonl" 2> "$OUT/stderr.log" ) &
CODEX_PID=$!

STALLED=0
if [ "$STALL" -gt 0 ] 2>/dev/null; then
  ( while kill -0 "$CODEX_PID" 2>/dev/null; do
      sleep 30
      LAST=$(stat -c %Y "$OUT/events.jsonl" 2>/dev/null || echo 0)
      NOW=$(date +%s)
      if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -ge "$STALL" ]; then
        echo "stall: no event for $((NOW - LAST))s, interrupting" >> "$OUT/stderr.log"
        touch "$OUT/.stalled"
        kill -INT "$CODEX_PID" 2>/dev/null
        sleep 20; kill -KILL "$CODEX_PID" 2>/dev/null
        exit 0
      fi
    done ) &
  WATCHER=$!
fi

wait "$CODEX_PID"; CODE=$?
[ -n "${WATCHER:-}" ] && kill "$WATCHER" 2>/dev/null
[ -f "$OUT/.stalled" ] && { STALLED=1; rm -f "$OUT/.stalled"; }
END=$(date +%s)

python3 - "$OUT" "$LABEL" "$CWD" "$EFFORT" "$SANDBOX" "$CODE" "$((END - START))" \
         "$RESUME" "$STALLED" "$WORKTREE_BRANCH" "$WORKTREE_BASE_SHA" <<'PY'
import json, sys, pathlib
out, label, cwd, effort, sandbox, code, dur, resume, stalled, branch, base_sha = sys.argv[1:12]
out = pathlib.Path(out)
thread, usage, errors, failed_cmds, files = None, {}, [], 0, set()
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
    # A failed command item is normal exploration; only a turn-level failure is terminal.
    if ev.get("type") in ("turn.failed", "error"):
        errors.append(ev)
    item = ev.get("item") or {}
    if item.get("type") == "command_execution" and item.get("exit_code") not in (0, None):
        failed_cmds += 1
    if item.get("type") == "file_change":
        for ch in item.get("changes", []) or []:
            if isinstance(ch, dict) and ch.get("path"):
                files.add(ch["path"])
if thread:
    (out / "thread.txt").write_text(thread + "\n")
result = out / "result.json" if (out / "result.json").exists() else out / "last.txt"
code = int(code)
meta = {
    "label": label, "cwd": cwd, "effort": effort, "sandbox": sandbox,
    "resumed_from": resume or None, "exit_code": code, "duration_s": int(dur),
    "thread_id": thread, "usage": usage,
    "result_file": str(result) if result.exists() else None,
    "result_bytes": result.stat().st_size if result.exists() else 0,
    "failed_commands": failed_cmds,
    "files_touched": sorted(files),
    "errors": errors[:5],
    "timed_out": code in (124, 137) and stalled != "1",
    "stalled": stalled == "1",
    "worktree_branch": branch or None,
    "worktree_base": base_sha or None,
}
(out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({k: meta[k] for k in
      ("label", "exit_code", "duration_s", "thread_id", "result_file",
       "timed_out", "stalled", "worktree_branch")}, ensure_ascii=False))
PY

exit $CODE
