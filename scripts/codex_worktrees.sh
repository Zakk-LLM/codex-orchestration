#!/usr/bin/env bash
# List or clean up the git worktrees a run created.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: codex_worktrees.sh <run-dir> --list
       codex_worktrees.sh <run-dir> --diff [BASE]         (default BASE: main)
       codex_worktrees.sh <run-dir> --remove-merged BASE
       codex_worktrees.sh <run-dir> --remove-all

--remove-merged deletes only worktrees whose branch is already contained in BASE, so
unmerged work is never thrown away. --remove-all refuses while a worktree has uncommitted
changes; commit or discard them first.
EOF
}

RUN=${1:-}; ACTION=${2:-}; ARG=${3:-}
[ -n "$RUN" ] && [ -n "$ACTION" ] || { usage >&2; exit 2; }
[ -d "$RUN/worktrees" ] || { echo "no worktrees under $RUN"; exit 0; }

# Every agent records the repository it came from; take the first one that used a worktree.
REPO=$(python3 - "$RUN" <<'PY'
import json, pathlib, sys
run = pathlib.Path(sys.argv[1])
for meta in sorted((run / "agents").glob("*/meta.json")):
    m = json.loads(meta.read_text())
    if m.get("worktree_branch"):
        print(m["cwd"]); break
PY
)
[ -n "$REPO" ] || { echo "no agent in this run recorded a worktree" >&2; exit 1; }
# meta.cwd is the worktree itself; its common dir points back at the origin repository.
REPO=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')

case "$ACTION" in
  --list)
    git -C "$REPO" worktree list | grep -F "$RUN/worktrees" || echo "(none registered)"
    ;;
  --diff)
    BASE=${ARG:-main}
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      printf '\n=== codex/%s vs %s ===\n' "$name" "$BASE"
      git -C "$REPO" diff --stat "$BASE...codex/$name" 2>/dev/null || echo "(branch missing)"
      # Agents are forbidden from committing, so their work is usually still uncommitted.
      git -C "$wt" diff --stat HEAD | sed 's/^/  uncommitted: /'
      git -C "$wt" status --porcelain --untracked-files=all | grep '^??' | sed 's/^??/  untracked:/'
    done
    ;;
  --remove-merged)
    [ -n "$ARG" ] || { echo "--remove-merged needs a base branch" >&2; exit 2; }
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "keep codex/$name: uncommitted changes"; continue
      fi
      if git -C "$REPO" merge-base --is-ancestor "codex/$name" "$ARG" 2>/dev/null; then
        git -C "$REPO" worktree remove "$wt" && git -C "$REPO" branch -d "codex/$name" \
          && echo "removed codex/$name"
      else
        echo "keep codex/$name: not merged into $ARG"
      fi
    done
    ;;
  --remove-all)
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "refusing codex/$name: uncommitted changes" >&2; continue
      fi
      git -C "$REPO" worktree remove "$wt" && echo "removed worktree codex/$name"
    done
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
