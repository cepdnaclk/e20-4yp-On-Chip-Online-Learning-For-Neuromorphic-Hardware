#!/bin/bash
# Run a simulation and archive it under runs/<timestamp>_<name>/
#
#   tools/run_and_archive.sh <name> <vvp-file> [files-to-snapshot...]
#
# Produces runs/YYYY-MM-DD_HHMMSS_<name>/ containing
#   INFO.txt   date, git commit, headline result
#   run.log    full simulation output
#   *.vh       the config the run actually used
set -u
NAME="$1"; shift
VVP_FILE="$1"; shift

STAMP=$(date +%Y-%m-%d_%H%M%S)
DIR="runs/${STAMP}_${NAME}"
mkdir -p "$DIR"

{
  echo "run       : $NAME"
  echo "date      : $(date -Iseconds)"
  echo "git commit: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo "host      : $(uname -sm)"
} > "$DIR/INFO.txt"

for f in "$@"; do
  [ -f "$f" ] && cp "$f" "$DIR/"
done

echo "=== running $NAME -> $DIR/run.log ==="
START=$(date +%s)
vvp "$VVP_FILE" 2>&1 | tee "$DIR/run.log"
END=$(date +%s)

{
  echo "duration  : $(( (END-START)/60 )) min $(( (END-START)%60 )) s"
  echo ""
  echo "--- headline ---"
  grep -E "ACCURACY|Correct|neurons that responded|RESULTS|Health" "$DIR/run.log" | head -8
} >> "$DIR/INFO.txt"

echo ""
echo "archived: $DIR"
