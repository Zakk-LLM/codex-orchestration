#!/usr/bin/env bash
# Append a note to an agent's NOTES.md. A spec that carries the live-notes block makes the
# worker re-read that file at each checkpoint, so this is how new information reaches an agent
# that is already running.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex_note.sh <run-dir> <label> "note text"
       codex_note.sh <run-dir> <label> --file NOTE_FILE
       codex_note.sh <run-dir> <label> --show

Appends a timestamped entry to <run-dir>/agents/<label>/NOTES.md.
Create the file before dispatching (an empty one is fine) so the worker's first read succeeds.
EOF
}

RUN=${1:-}; LABEL=${2:-}; shift 2 || { usage >&2; exit 2; }
[ -n "$RUN" ] && [ -n "$LABEL" ] || { usage >&2; exit 2; }

DIR="$RUN/agents/$LABEL"
NOTES="$DIR/NOTES.md"
mkdir -p "$DIR"

case "${1:-}" in
  --show) cat "$NOTES" 2>/dev/null || echo "(no notes)"; exit 0 ;;
  --file) [ -n "${2:-}" ] || { usage >&2; exit 2; }; BODY=$(cat "$2") ;;
  -h|--help|"") usage; exit 0 ;;
  *) BODY=$* ;;
esac

[ -s "$NOTES" ] || printf '# Live notes\n\nRead the whole file each time; later entries override earlier ones.\n' > "$NOTES"
printf '\n## %s\n%s\n' "$(date +%H:%M:%S)" "$BODY" >> "$NOTES"
printf 'appended to %s\n' "$NOTES"
