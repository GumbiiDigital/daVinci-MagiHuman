#!/bin/bash
# phase1_watcher.sh — Watches for Phase 1 completion, runs analysis, updates HTTP server
# Run in tmux alongside phase2_batch.sh

RESULTS_DIR="$HOME/daVinci-MagiHuman/batch_output_20260325_154259"
RESULTS_FILE="$RESULTS_DIR/results_original.jsonl"

echo "[$(date)] Watcher started. Waiting for Phase 1 to reach 28 scored prompts..."

while true; do
    if [ -f "$RESULTS_FILE" ]; then
        COUNT=$(wc -l < "$RESULTS_FILE")
        echo "[$(date)] Phase 1 scores: $COUNT/28"
        if [ "$COUNT" -ge 28 ]; then
            echo "[$(date)] Phase 1 COMPLETE! Running analysis..."
            python3 ~/daVinci-MagiHuman/analyze_phase1.py
            echo "[$(date)] Analysis done. Report at $RESULTS_DIR/phase1_analysis.txt"
            break
        fi
    fi
    sleep 120
done

# Kill old HTTP server and restart with both output dirs accessible
pkill -f "python3 -m http.server 9090" 2>/dev/null || true
sleep 1

# Create a combined serve directory with symlinks
SERVE_DIR="/tmp/davinci_serve"
rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR"
ln -s "$RESULTS_DIR" "$SERVE_DIR/phase1"
ln -s "$RESULTS_DIR/phase1_analysis.txt" "$SERVE_DIR/phase1_analysis.txt"

# Phase 2 dir (will appear when phase2 starts)
PHASE2_DIR=$(ls -td ~/daVinci-MagiHuman/phase2_output_* 2>/dev/null | head -1)
if [ -n "$PHASE2_DIR" ]; then
    ln -s "$PHASE2_DIR" "$SERVE_DIR/phase2"
fi

cd "$SERVE_DIR"
echo "[$(date)] Starting HTTP server at :9090 serving $SERVE_DIR"
python3 -m http.server 9090 &

# Keep watching for Phase 2 output dir
while true; do
    PHASE2_DIR=$(ls -td ~/daVinci-MagiHuman/phase2_output_* 2>/dev/null | head -1)
    if [ -n "$PHASE2_DIR" ] && [ ! -L "$SERVE_DIR/phase2" ]; then
        ln -s "$PHASE2_DIR" "$SERVE_DIR/phase2"
        echo "[$(date)] Phase 2 output linked: $PHASE2_DIR"
    fi
    sleep 60
done
