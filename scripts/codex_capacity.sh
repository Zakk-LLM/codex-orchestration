#!/usr/bin/env bash
# Suggest how many agents of a given weight this machine can run at once. Nothing here is a
# fixed constant: the answer follows the current cores, free memory, and what the agents do.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex_capacity.sh [light|medium|heavy] [--per-agent-mb N]

  light   read-only reading, search, drafting            (~400 MB/agent)
  medium  edits plus a test file or a linter run         (~1200 MB/agent)
  heavy   full builds, whole test suites, containers     (~4000 MB/agent)

Prints the suggested concurrency and the numbers it came from. Override the memory estimate
with --per-agent-mb when you know what the workload actually costs.
EOF
}

WEIGHT=${1:-medium}
case "$WEIGHT" in
  light) PER=400; CPU_DIV=1 ;;
  medium) PER=1200; CPU_DIV=2 ;;
  heavy) PER=4000; CPU_DIV=4 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown weight: $WEIGHT" >&2; usage >&2; exit 2 ;;
esac
[ "${2:-}" = "--per-agent-mb" ] && PER=${3:?--per-agent-mb needs a value}

CORES=$(nproc 2>/dev/null || echo 4)
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

# Keep a core and 15% of free memory for the orchestrator, the editor, and the tests it runs.
BY_CPU=$(( (CORES - 1) / CPU_DIV ))
BY_MEM=$(( AVAIL_MB * 85 / 100 / PER ))
BUSY=$(awk -v l="$LOAD" -v c="$CORES" 'BEGIN {print (l > c * 0.7) ? 1 : 0}')

N=$BY_CPU
[ "$BY_MEM" -lt "$N" ] && N=$BY_MEM
[ "$BUSY" = 1 ] && N=$(( N / 2 ))
[ "$N" -lt 1 ] && N=1
# Beyond a handful the API queues anyway and the event logs stop being reviewable.
[ "$N" -gt 8 ] && N=8

printf '%s\n' "$N"
printf 'weight=%s per-agent=%sMB cores=%s avail=%sMB load=%s cpu-cap=%s mem-cap=%s%s\n' \
  "$WEIGHT" "$PER" "$CORES" "$AVAIL_MB" "$LOAD" "$BY_CPU" "$BY_MEM" \
  "$([ "$BUSY" = 1 ] && echo ' (machine busy: halved)')" >&2
