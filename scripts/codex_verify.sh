#!/usr/bin/env bash
# Turn a review into evidence. Compares what the agent actually changed against the scope its
# spec declared, runs the acceptance checks, and records every command with its exit code.
# Writes <run>/agents/<label>/verify.json and prints a verdict that no check can be skipped in.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: codex_verify.sh <run-dir> <label> [--repo DIR] [--base REF] [--check "CMD"]...

  --repo DIR    repository or worktree to inspect  (default: the agent's recorded cwd)
  --base REF    compare against this ref instead of the working tree (e.g. main)
  --check CMD   acceptance command, repeatable; run inside --repo

Set VERIFY_IGNORE to colon-separated globs to treat more paths as build artifacts.

Records: files changed, files outside the spec's declared Write scope, and every check with
its exit code and output tail. Exit 0 when at least one check ran and all passed, 1 otherwise.
A review with zero checks always fails: reading a diff is not verification.
EOF
}

RUN=${1:-}; LABEL=${2:-}; shift 2 2>/dev/null || { usage >&2; exit 2; }
[ -n "$RUN" ] && [ -n "$LABEL" ] || { usage >&2; exit 2; }

REPO=; BASE=; CHECKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --check) CHECKS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="$RUN/agents/$LABEL"
[ -d "$OUT" ] || { echo "no agent $LABEL in $RUN" >&2; exit 2; }
[ -n "$REPO" ] || REPO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cwd"])' "$OUT/meta.json" 2>/dev/null)
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "cannot determine the repository; pass --repo" >&2; exit 2; }

CHANGED=$(
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$BASE" ]; then git -C "$REPO" diff --name-only "$BASE" 2>/dev/null; fi
    git -C "$REPO" diff --name-only HEAD 2>/dev/null
    git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null
  fi | sort -u
)

RESULTS="$OUT/.checks.jsonl"; : > "$RESULTS"
FAILED=0
for cmd in ${CHECKS+"${CHECKS[@]}"}; do
  echo "== check: $cmd" >&2
  LOG=$(cd "$REPO" && eval "$cmd" 2>&1); CODE=$?
  [ "$CODE" = 0 ] || FAILED=1
  CHECK_CMD=$cmd CHECK_CODE=$CODE CHECK_LOG=$LOG python3 - "$RESULTS" <<'PY'
import json, os, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"command": os.environ["CHECK_CMD"],
                        "exit_code": int(os.environ["CHECK_CODE"]),
                        "output_tail": os.environ["CHECK_LOG"][-1500:]},
                       ensure_ascii=False) + "\n")
PY
  echo "   exit=$CODE" >&2
done

CHANGED_LIST=$CHANGED python3 - "$OUT" "$LABEL" "$REPO" "$FAILED" "${#CHECKS[@]}" <<'PY'
import fnmatch, json, os, pathlib, re, sys
out = pathlib.Path(sys.argv[1]); label, repo = sys.argv[2], sys.argv[3]
failed, n_checks = int(sys.argv[4]), int(sys.argv[5])
changed = [p for p in os.environ.get("CHANGED_LIST", "").splitlines() if p.strip()]

# The spec's "Write:" line is the declared scope; anything else the agent touched is a finding.
scope = []
spec = out / "prompt.md"
if spec.exists():
    for line in spec.read_text(errors="replace").splitlines():
        m = re.match(r"\s*Write:\s*(.+)", line)
        if m:
            scope += [s.strip().strip("`,") for s in re.split(r"[,\s]+", m.group(1)) if s.strip()]

def in_scope(path):
    return any(path == s or path.startswith(s.rstrip("/") + "/") for s in scope) if scope else None

# Build and cache artifacts are produced by running the tests, not by the agent deciding to
# edit something. Reported separately so nothing is dropped silently.
ARTIFACTS = ("__pycache__/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/", "node_modules/",
             ".venv/", "target/", "dist/", "build/", ".gradle/", ".tox/", "coverage/")
ARTIFACT_SUFFIX = (".pyc", ".pyo", ".class", ".o", ".so", ".a", ".log", ".coverage")
extra = [g for g in os.environ.get("VERIFY_IGNORE", "").split(":") if g]
def is_artifact(p):
    return (any(part + "/" in p + "/" for part in (a.rstrip("/") for a in ARTIFACTS))
            or p.endswith(ARTIFACT_SUFFIX)
            or any(fnmatch.fnmatch(p, g) for g in extra))

artifacts = [p for p in changed if is_artifact(p)]
changed = [p for p in changed if p not in artifacts]
outside = [p for p in changed if in_scope(p) is False]
checks = []
cf = out / ".checks.jsonl"
if cf.exists():
    checks = [json.loads(l) for l in cf.read_text().splitlines() if l.strip()]
    cf.unlink()

verdict = "verified" if (n_checks and not failed and not outside) else "not-verified"
reasons = []
if not n_checks:
    reasons.append("no acceptance check was run")
if failed:
    reasons.append("an acceptance check failed")
if outside:
    reasons.append(f"files changed outside the declared Write scope: {outside}")

report = {"label": label, "repo": repo, "declared_write_scope": scope or None,
          "files_changed": changed, "files_outside_scope": outside,
          "build_artifacts_ignored": artifacts,
          "checks": checks, "verdict": verdict, "reasons": reasons}
(out / "verify.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"verdict": verdict, "reasons": reasons, "changed": len(changed),
                  "outside_scope": len(outside), "artifacts_ignored": len(artifacts),
                  "checks_run": n_checks}, ensure_ascii=False))
PY

python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["verdict"]=="verified" else 1)' "$OUT/verify.json"
