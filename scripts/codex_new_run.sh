#!/usr/bin/env bash
# Create a run directory on disk and print its path. Never use a tmpfs path: runs must
# survive a reboot and can hold large event logs.
set -euo pipefail

SLUG=${1:-run}
SLUG=$(printf '%s' "$SLUG" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//')
[ -n "$SLUG" ] || SLUG=run
BASE=${CODEX_RUNS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-runs}
RUN="$BASE/$(date +%Y%m%d-%H%M%S)-$SLUG"

mkdir -p "$RUN/agents" "$RUN/schema"
cat > "$RUN/PLAN.md" <<EOF
# Run: $SLUG

Created: $(date -Iseconds)
Goal:
Workspace:
Acceptance criteria:

## Agents

| label | scope (files/dirs) | sandbox | effort | depends on |
|-------|--------------------|---------|--------|------------|
EOF
printf '%s\n' "$RUN"
