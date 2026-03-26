#!/usr/bin/env bash
# rank_faces.sh — Fetch scores from spark2, run ranking, save output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.score_cache"
SPARK2="gumbiidigital@192.168.250.11"
OUTPUT="$SCRIPT_DIR/face_rankings.txt"
SERVE_DIR="/tmp/davinci_serve"

mkdir -p "$CACHE_DIR" "$SERVE_DIR"

echo "=== Fetching scores from spark2 ==="

# Phase 1
echo "  Phase 1..."
scp -q "$SPARK2:/tmp/score_all/phase1/ugc_scores.jsonl" "$CACHE_DIR/phase1_ugc_scores.jsonl" 2>/dev/null \
    && echo "    $(wc -l < "$CACHE_DIR/phase1_ugc_scores.jsonl") entries" \
    || echo "    WARNING: Phase 1 fetch failed"

# Phase 2
echo "  Phase 2..."
scp -q "$SPARK2:/tmp/score_all/phase2/ugc_scores.jsonl" "$CACHE_DIR/phase2_ugc_scores.jsonl" 2>/dev/null \
    && echo "    $(wc -l < "$CACHE_DIR/phase2_ugc_scores.jsonl") entries" \
    || echo "    WARNING: Phase 2 fetch failed"

# Phase 3: also cache if not already local
PHASE3_LOCAL=$(ls -d "$SCRIPT_DIR"/phase3_output_*/ugc_scores.jsonl 2>/dev/null | tail -1 || true)
if [[ -n "$PHASE3_LOCAL" ]]; then
    cp "$PHASE3_LOCAL" "$CACHE_DIR/phase3_ugc_scores.jsonl"
    echo "  Phase 3: $(wc -l < "$PHASE3_LOCAL") entries (local)"
else
    echo "  Phase 3: no local phase3 output found"
fi

echo ""
echo "=== Running face ranking ==="
python3 "$SCRIPT_DIR/rank_faces.py" 2>&1 | tee "$OUTPUT"

# Copy to serve dir
cp "$OUTPUT" "$SERVE_DIR/face_rankings.txt"
echo ""
echo "Saved to: $OUTPUT"
echo "Served at: $SERVE_DIR/face_rankings.txt"
