#!/bin/bash
# phase3_generate.sh — Robust multi-face generation with GPU memory management
# Fixes the rc=137 OOM issue from Phase 2 by:
#   1. Waiting for GPU memory to be actually free before each generation
#   2. Skipping self-scoring (use UGC Scorer v3 instead)
#   3. Adding explicit cleanup between runs
#
# Usage:
#   bash phase3_generate.sh                    # Generate all prompts × all faces
#   bash phase3_generate.sh --faces 4          # Only first 4 faces
#   bash phase3_generate.sh --prompts top5     # Only top 5 prompts
#   bash phase3_generate.sh --resume           # Resume from last successful

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
FACEDIR="$HOME/projects/real_face_test"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="$WORKDIR/phase3_output_${TIMESTAMP}"
LOG="$OUTDIR/generation.log"
RESULTS="$OUTDIR/results.jsonl"
TRACKER="$OUTDIR/completed.txt"

export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export NCCL_ALGO="^NVLS"
export TORCH_COMPILE_DISABLE=1

# Parse args
MAX_FACES=20
PROMPT_SET="all"
RESUME=false
SEED=42

for arg in "$@"; do
    case $arg in
        --faces) shift; MAX_FACES=$1; shift ;;
        --prompts) shift; PROMPT_SET=$1; shift ;;
        --resume) RESUME=true; shift ;;
        --seed) shift; SEED=$1; shift ;;
    esac
done

mkdir -p "$OUTDIR"
touch "$TRACKER"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

wait_for_gpu() {
    # Wait until no python/torchrun processes are using the GPU
    local max_wait=120
    local waited=0
    while pgrep -f "torchrun\|inference/pipeline/entry.py" > /dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            log "WARNING: GPU still busy after ${max_wait}s, killing stale processes"
            pkill -9 -f "torchrun\|inference/pipeline/entry.py" 2>/dev/null || true
            sleep 5
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done

    # Kill any stale rendezvous/torch processes
    pkill -f "torch.distributed.run" 2>/dev/null || true

    # Extra wait for kernel to reclaim GPU memory
    sleep 5

    # Sync filesystem to release any buffered I/O
    sync

    return 0
}

generate_video() {
    local prompt_text="$1"
    local face_path="$2"
    local seconds="$3"
    local vid_name="$4"
    local outpath="$OUTDIR/$vid_name"

    log "Generating: $vid_name (${seconds}s, face=$(basename "$face_path"), 256x448)"

    local start_time=$(date +%s)

    cd "$WORKDIR"
    # Use random port to avoid rendezvous conflicts from prior crashed runs
    local rdzv_port=$((6020 + RANDOM % 1000))
    timeout 600 torchrun \
        --nnodes=1 --node_rank=0 --nproc_per_node=1 \
        --rdzv-backend=c10d --rdzv-endpoint=localhost:${rdzv_port} \
        inference/pipeline/entry.py \
        --config-load-path example/distill/config.json \
        --prompt "$prompt_text" \
        --image_path "$face_path" \
        --seconds "$seconds" \
        --br_width 256 --br_height 448 \
        --seed "$SEED" \
        --output_path "$outpath" \
        >> "$LOG" 2>&1
    local rc=$?

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    local outfile=$(ls -t "${outpath}"*.mp4 2>/dev/null | head -1)

    if [ $rc -eq 0 ] && [ -n "$outfile" ] && [ -f "$outfile" ]; then
        local filesize=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        log "SUCCESS: $vid_name (${elapsed}s, $((filesize / 1024))KB)"
        echo "$vid_name" >> "$TRACKER"

        # Record result
        echo "{\"prompt_id\":\"$vid_name\",\"face\":\"$(basename "$face_path")\",\"seed\":$SEED,\"seconds\":$seconds,\"elapsed\":$elapsed,\"file\":\"$outfile\",\"size\":$filesize,\"status\":\"success\"}" >> "$RESULTS"
        return 0
    else
        log "FAILED: $vid_name (rc=$rc, ${elapsed}s)"
        echo "{\"prompt_id\":\"$vid_name\",\"face\":\"$(basename "$face_path")\",\"seed\":$SEED,\"seconds\":$seconds,\"elapsed\":$elapsed,\"status\":\"failed\",\"rc\":$rc}" >> "$RESULTS"

        if [ $rc -eq 137 ]; then
            log "OOM detected (rc=137). Waiting 10s for GPU memory cleanup..."
            sleep 10
        fi
        return 1
    fi
}

# ============================================================
# BUILD PROMPT × FACE MATRIX
# ============================================================

log "============================================"
log "=== PHASE 3 GENERATION — STARTED ==="
log "============================================"
log "Output: $OUTDIR"
log "Faces: $MAX_FACES | Prompts: $PROMPT_SET | Seed: $SEED"

# Get faces (sorted for reproducibility)
# Exclude face.jpg (old default/test face)
FACES=($(ls "$FACEDIR"/*.jpg 2>/dev/null | grep -v '/face\.jpg$' | sort | head -$MAX_FACES))
log "Faces found: ${#FACES[@]}"

if [ ${#FACES[@]} -eq 0 ]; then
    log "FATAL: No face images found in $FACEDIR"
    exit 1
fi

# Build prompt list
python3 -c "
import json, sys
prompts = json.load(open('$WORKDIR/batch_prompts.json'))

# Top prompts from Phase 1 analysis
top5 = ['testimonial_vulnerable', 'testimonial_angry', 'testimonial_relapse_honest',
        'testimonial_relieved', 'testimonial_hopeful']

prompt_set = '$PROMPT_SET'
if prompt_set == 'top5':
    prompts = [p for p in prompts if p['id'] in top5]
elif prompt_set == 'top10':
    top10 = top5 + ['testimonial_determined', 'testimonial_money', 'education_health',
                     'testimonial_confessional', 'comparison_after']
    prompts = [p for p in prompts if p['id'] in top10]
# else: all prompts

# Output as simple JSON array
json.dump(prompts, sys.stdout)
" > "$OUTDIR/prompts.json"

NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$OUTDIR/prompts.json'))))")
TOTAL_VIDEOS=$((NUM_PROMPTS * ${#FACES[@]}))

log "Prompts: $NUM_PROMPTS | Faces: ${#FACES[@]} | Total videos: $TOTAL_VIDEOS"

# ============================================================
# GENERATION LOOP
# ============================================================

GENERATED=0
FAILED=0
SKIPPED=0

for FACE_PATH in "${FACES[@]}"; do
    FACE_NAME=$(basename "$FACE_PATH" .jpg)

    for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
        PROMPT_ID=$(python3 -c "import json; print(json.load(open('$OUTDIR/prompts.json'))[$IDX]['id'])")
        PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$OUTDIR/prompts.json'))[$IDX]['prompt'])")
        SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$OUTDIR/prompts.json'))[$IDX]['seconds'])")

        VID_NAME="${PROMPT_ID}__${FACE_NAME}_seed${SEED}"

        # Resume support: skip if already completed
        if $RESUME && grep -qF "$VID_NAME" "$TRACKER" 2>/dev/null; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Wait for GPU to be free
        wait_for_gpu

        TOTAL_DONE=$((GENERATED + FAILED + SKIPPED))
        REMAINING=$((TOTAL_VIDEOS - TOTAL_DONE))
        log "[$((TOTAL_DONE + 1))/$TOTAL_VIDEOS] (ok=$GENERATED fail=$FAILED skip=$SKIPPED remain=$REMAINING)"

        if generate_video "$PROMPT_TEXT" "$FACE_PATH" "$SECONDS_VAL" "$VID_NAME"; then
            GENERATED=$((GENERATED + 1))
        else
            FAILED=$((FAILED + 1))

            # If 3 OOMs in a row, something is really wrong
            RECENT_FAILS=$(tail -3 "$RESULTS" 2>/dev/null | grep -c '"failed"')
            if [ "$RECENT_FAILS" -ge 3 ]; then
                log "ERROR: 3 consecutive failures. Pausing 30s for GPU recovery..."
                sleep 30
            fi
        fi
    done
done

# ============================================================
# SUMMARY
# ============================================================

log ""
log "============================================"
log "=== PHASE 3 GENERATION COMPLETE ==="
log "  Total: $TOTAL_VIDEOS"
log "  Generated: $GENERATED"
log "  Failed: $FAILED"
log "  Skipped: $SKIPPED"
log "  Output: $OUTDIR"
log "============================================"

# Generate summary
echo "========================================" > "$OUTDIR/summary.txt"
echo "PHASE 3 COMPLETE: $(date)" >> "$OUTDIR/summary.txt"
echo "Total: $TOTAL_VIDEOS | Success: $GENERATED | Failed: $FAILED | Skipped: $SKIPPED" >> "$OUTDIR/summary.txt"
echo "Output: $OUTDIR" >> "$OUTDIR/summary.txt"
echo "Resolution: 256x448 (9:16 portrait)" >> "$OUTDIR/summary.txt"
echo "Faces: ${#FACES[@]} | Prompts: $NUM_PROMPTS" >> "$OUTDIR/summary.txt"
echo "========================================" >> "$OUTDIR/summary.txt"
