#!/bin/bash
# batch_generate_and_score.sh — AFK pipeline for DaVinci-MagiHuman
# Generates ~56 videos (28 prompts × 2 seeds each), scores pairs via spark2
# Expected runtime: ~3.5-4 hours at ~4min per 256p video
#
# Usage: nohup bash batch_generate_and_score.sh > /tmp/batch_davinci.log 2>&1 &

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
OUTDIR="$WORKDIR/batch_output_$(date +%Y%m%d_%H%M%S)"
PROMPTS="$WORKDIR/batch_prompts.json"
FACE="$HOME/projects/real_face_test/face.jpg"
SCORER="http://192.168.250.11:8540"
RESULTS="$OUTDIR/results.jsonl"
SUMMARY="$OUTDIR/summary.txt"
LOG="$OUTDIR/generation.log"

# Required env vars (from example/distill/run.sh — missing these caused ModuleNotFoundError)
export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$OUTDIR"

# Check prerequisites
if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
    echo "ERROR: Video scorer not responding at $SCORER" | tee -a "$LOG"
    echo "Attempting to start scorer on spark2..."
    ssh gumbiidigital@192.168.250.11 "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &"
    sleep 10
    if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
        echo "FATAL: Cannot start scorer. Aborting." | tee -a "$LOG"
        exit 1
    fi
fi

if [ ! -f "$FACE" ]; then
    echo "FATAL: Face image not found at $FACE" | tee -a "$LOG"
    exit 1
fi

# Wait for any current generation to finish (GPU busy)
echo "[$(date)] Waiting for current GPU job to finish..." | tee -a "$LOG"
while pgrep -f "inference/pipeline/entry.py" > /dev/null 2>&1; do
    echo "[$(date)] GPU busy, waiting 30s..." >> "$LOG"
    sleep 30
done
echo "[$(date)] GPU free. Starting batch generation." | tee -a "$LOG"

# Parse prompts and generate
NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$PROMPTS'))))")
echo "[$(date)] Loaded $NUM_PROMPTS prompts. Will generate 2 seeds each = $((NUM_PROMPTS * 2)) videos." | tee -a "$LOG"

TOTAL=0
SUCCESSES=0
FAILURES=0
SCORED=0

# Two seeds per prompt for pairwise comparison
SEEDS=(42 137)

for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")
    PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['prompt'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['seconds'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        OUTPATH="$OUTDIR/$VIDNAME"

        echo "[$(date)] [$((TOTAL + 1))/$((NUM_PROMPTS * 2))] Generating: $VIDNAME (${SECONDS_VAL}s)" | tee -a "$LOG"
        START_TIME=$(date +%s)

        # Run DaVinci generation (256p, distilled, 8 steps)
        cd "$WORKDIR"
        timeout 600 torchrun \
            --nnodes=1 --node_rank=0 --nproc_per_node=1 \
            --rdzv-backend=c10d --rdzv-endpoint=localhost:6020 \
            inference/pipeline/entry.py \
            --config-load-path example/distill/config.json \
            --prompt "$PROMPT_TEXT" \
            --image_path "$FACE" \
            --seconds "$SECONDS_VAL" \
            --br_width 448 --br_height 256 \
            --seed "$SEED" \
            --output_path "$OUTPATH" \
            >> "$LOG" 2>&1
        RC=$?

        END_TIME=$(date +%s)
        ELAPSED=$((END_TIME - START_TIME))
        TOTAL=$((TOTAL + 1))

        # Find the output file (DaVinci appends resolution info)
        OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

        if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
            FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
            echo "[$(date)] SUCCESS: $VIDNAME (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
            SUCCESSES=$((SUCCESSES + 1))
        else
            echo "[$(date)] FAILED: $VIDNAME (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
            FAILURES=$((FAILURES + 1))
        fi
    done

    # After both seeds for this prompt, score the pair
    VID_A=$(ls -t "${OUTDIR}/${PROMPT_ID}_seed${SEEDS[0]}"*.mp4 2>/dev/null | head -1)
    VID_B=$(ls -t "${OUTDIR}/${PROMPT_ID}_seed${SEEDS[1]}"*.mp4 2>/dev/null | head -1)

    if [ -n "$VID_A" ] && [ -f "$VID_A" ] && [ -n "$VID_B" ] && [ -f "$VID_B" ]; then
        echo "[$(date)] Scoring pair: $PROMPT_ID" | tee -a "$LOG"

        # Copy both videos to spark2 for scoring
        scp -q "$VID_A" "gumbiidigital@192.168.250.11:/tmp/score_ref.mp4" 2>/dev/null
        scp -q "$VID_B" "gumbiidigital@192.168.250.11:/tmp/score_prod.mp4" 2>/dev/null

        # Score via API
        SCORE_RESULT=$(curl -s --max-time 120 -X POST "$SCORER/compare" \
            -H "Content-Type: application/json" \
            -d '{"reference_path": "/tmp/score_ref.mp4", "produced_path": "/tmp/score_prod.mp4"}' 2>/dev/null)

        if echo "$SCORE_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            echo "{\"prompt_id\": \"$PROMPT_ID\", \"seed_a\": ${SEEDS[0]}, \"seed_b\": ${SEEDS[1]}, \"score\": $SCORE_RESULT}" >> "$RESULTS"
            SCORE_VAL=$(echo "$SCORE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('score', 'N/A'))" 2>/dev/null)
            echo "[$(date)] Score for $PROMPT_ID: $SCORE_VAL" | tee -a "$LOG"
            SCORED=$((SCORED + 1))
        else
            echo "[$(date)] Scoring failed for $PROMPT_ID: $SCORE_RESULT" | tee -a "$LOG"
        fi
    else
        echo "[$(date)] Cannot score $PROMPT_ID — missing videos" | tee -a "$LOG"
    fi
done

# Write summary
echo "========================================" | tee -a "$LOG" "$SUMMARY"
echo "BATCH COMPLETE: $(date)" | tee -a "$LOG" "$SUMMARY"
echo "Total generated: $TOTAL" | tee -a "$LOG" "$SUMMARY"
echo "Successes: $SUCCESSES" | tee -a "$LOG" "$SUMMARY"
echo "Failures: $FAILURES" | tee -a "$LOG" "$SUMMARY"
echo "Pairs scored: $SCORED / $NUM_PROMPTS" | tee -a "$LOG" "$SUMMARY"
echo "Output directory: $OUTDIR" | tee -a "$LOG" "$SUMMARY"
echo "========================================" | tee -a "$LOG" "$SUMMARY"

# Quick stats on scores
if [ -f "$RESULTS" ]; then
    echo "" >> "$SUMMARY"
    echo "Score distribution:" >> "$SUMMARY"
    python3 -c "
import json
scores = []
with open('$RESULTS') as f:
    for line in f:
        data = json.loads(line)
        s = data.get('score', {})
        if isinstance(s, dict):
            val = s.get('score', s.get('total_score', 0))
        else:
            val = float(s) if s != 'N/A' else 0
        scores.append((data['prompt_id'], val))
scores.sort(key=lambda x: x[1], reverse=True)
print(f'  Mean: {sum(s for _,s in scores)/len(scores):.1f}')
print(f'  Min:  {min(s for _,s in scores):.1f} ({min(scores, key=lambda x:x[1])[0]})')
print(f'  Max:  {max(s for _,s in scores):.1f} ({max(scores, key=lambda x:x[1])[0]})')
print()
print('  Per-prompt scores:')
for pid, val in scores:
    print(f'    {pid}: {val:.1f}')
" >> "$SUMMARY" 2>/dev/null
    cat "$SUMMARY"
fi

echo "[$(date)] Done. Results at $OUTDIR" | tee -a "$LOG"
