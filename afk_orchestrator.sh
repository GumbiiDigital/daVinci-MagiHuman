#!/bin/bash
# afk_orchestrator.sh — Master AFK pipeline
# Monitors Phase 1, intercepts before Real-ESRGAN, launches native SR + config sweep
# Expected total runtime: ~3-4 hours

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
PHASE1_DIR=$(ls -td "$WORKDIR"/batch_output_* 2>/dev/null | head -1)
LOG="/tmp/afk_orchestrator.log"

echo "[$(date)] AFK Orchestrator started" | tee "$LOG"
echo "[$(date)] Phase 1 dir: $PHASE1_DIR" | tee -a "$LOG"

# ─── Wait for Phase 1 generation to complete ───
# Phase 1 is in v2 batch. Watch for it to finish generation (all 56 videos attempted)
# or for it to start Phase 2 (Real-ESRGAN upscaling) which we want to intercept

echo "[$(date)] Monitoring Phase 1 progress..." | tee -a "$LOG"

while true; do
    # Check if v2 batch is still running
    if ! pgrep -f "batch_generate_v2.sh" > /dev/null 2>&1; then
        echo "[$(date)] v2 batch completed (process gone)" | tee -a "$LOG"
        break
    fi

    # Check if Phase 1 generation is done (look for Phase 2 marker in v2 log)
    if grep -q "PHASE 2: Upscale to 720p" /tmp/batch_davinci_v2.log 2>/dev/null; then
        echo "[$(date)] v2 started Phase 2 (Real-ESRGAN) — intercepting!" | tee -a "$LOG"
        # Kill v2 batch before it wastes time on inferior Real-ESRGAN
        BATCH_PID=$(pgrep -f "batch_generate_v2.sh" | head -1)
        if [ -n "$BATCH_PID" ]; then
            kill "$BATCH_PID" 2>/dev/null
            sleep 2
            kill -9 "$BATCH_PID" 2>/dev/null || true
        fi
        # Also kill the tee
        pkill -f "tee /tmp/batch_davinci_v2.log" 2>/dev/null || true
        # Kill any Real-ESRGAN upscaling that may have started
        pkill -f "realesrgan" 2>/dev/null || true
        break
    fi

    # Also check Phase 1 complete marker
    if grep -q "PHASE 1 COMPLETE" /tmp/batch_davinci_v2.log 2>/dev/null; then
        echo "[$(date)] Phase 1 marked complete in log" | tee -a "$LOG"
        # Give it a moment to start Phase 2
        sleep 30
        # Then intercept
        BATCH_PID=$(pgrep -f "batch_generate_v2.sh" | head -1)
        if [ -n "$BATCH_PID" ]; then
            kill "$BATCH_PID" 2>/dev/null
            sleep 2
            kill -9 "$BATCH_PID" 2>/dev/null || true
        fi
        pkill -f "tee /tmp/batch_davinci_v2.log" 2>/dev/null || true
        break
    fi

    # Log progress every 5 minutes
    LATEST=$(tail -1 /tmp/batch_davinci_v2.log 2>/dev/null | head -c 120)
    echo "[$(date)] Still in Phase 1: $LATEST" >> "$LOG"
    sleep 60
done

# ─── Wait for any active inference to finish ───
echo "[$(date)] Waiting for GPU to free..." | tee -a "$LOG"
while pgrep -f "inference/pipeline/entry.py" > /dev/null 2>&1; do
    sleep 10
done

# ─── Count Phase 1 results ───
PHASE1_VIDEOS=$(ls "$PHASE1_DIR"/*.mp4 2>/dev/null | wc -l)
PHASE1_SCORED=$(wc -l < "$PHASE1_DIR/results_original.jsonl" 2>/dev/null || echo 0)
echo "[$(date)] Phase 1 stats: $PHASE1_VIDEOS videos, $PHASE1_SCORED scored" | tee -a "$LOG"

# ─── Launch Phase 2: Native SR + Config Sweep ───
echo "[$(date)] Launching Phase 2: Native DaVinci SR + Config Sweep" | tee -a "$LOG"
cd "$WORKDIR"
bash phase2_native_sr.sh 2>&1 | tee -a "$LOG"

echo "[$(date)] ═══ ALL AFK WORK COMPLETE ═══" | tee -a "$LOG"

# ─── Final summary ───
echo "" | tee -a "$LOG"
echo "Files generated:" | tee -a "$LOG"
echo "  Phase 1 (448x256): $(ls "$PHASE1_DIR"/*.mp4 2>/dev/null | wc -l) videos" | tee -a "$LOG"
echo "  Native SR 540p: $(ls "$PHASE1_DIR/native_sr_540p/"*.mp4 2>/dev/null | wc -l) videos" | tee -a "$LOG"
echo "  Native SR 1080p: $(ls "$PHASE1_DIR/native_sr_1080p/"*.mp4 2>/dev/null | wc -l) videos" | tee -a "$LOG"
SWEEP_DIR=$(ls -td "$WORKDIR"/config_sweep_* 2>/dev/null | head -1)
if [ -n "$SWEEP_DIR" ]; then
    echo "  Config sweep: $(find "$SWEEP_DIR" -name "*.mp4" 2>/dev/null | wc -l) videos" | tee -a "$LOG"
fi
echo "" | tee -a "$LOG"
echo "Score files:" | tee -a "$LOG"
echo "  $PHASE1_DIR/results_original.jsonl" | tee -a "$LOG"
echo "  $PHASE1_DIR/results_native_540p.jsonl" | tee -a "$LOG"
echo "  $PHASE1_DIR/results_native_1080p.jsonl" | tee -a "$LOG"
echo "  $PHASE1_DIR/cross_resolution_comparison.txt" | tee -a "$LOG"
if [ -n "$SWEEP_DIR" ]; then
    echo "  $SWEEP_DIR/comparison.txt" | tee -a "$LOG"
fi
