#!/bin/bash
# phase2_batch.sh — Multi-face 9:16 portrait batch
# 20 videos: top 5 prompts × 4 faces (2M/2F), 256x448 portrait
#
# Usage: bash phase2_batch.sh 2>&1 | tee /tmp/phase2_batch.log

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
OUTDIR="$WORKDIR/phase2_output_$(date +%Y%m%d_%H%M%S)"
PROMPTS="$WORKDIR/phase2_prompts.json"
FACEDIR="$HOME/projects/real_face_test"
SCORER="http://192.168.250.11:8540"
RESULTS="$OUTDIR/results.jsonl"
SUMMARY="$OUTDIR/summary.txt"
LOG="$OUTDIR/generation.log"

export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$OUTDIR"

# Copy prompts into output dir for preservation
cp "$PROMPTS" "$OUTDIR/phase2_prompts.json"

# Check prerequisites
if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
    echo "[$(date)] ERROR: Video scorer not responding at $SCORER" | tee -a "$LOG"
    ssh gumbiidigital@192.168.250.11 "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &"
    sleep 10
    if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
        echo "[$(date)] FATAL: Cannot start scorer. Aborting." | tee -a "$LOG"
        exit 1
    fi
fi

# Wait for GPU to be free (Phase 1 may still be running)
echo "[$(date)] Waiting for GPU to be free..." | tee -a "$LOG"
while pgrep -f "inference/pipeline/entry.py" > /dev/null 2>&1; do
    echo "[$(date)] GPU busy (Phase 1 still running), waiting 60s..." | tee -a "$LOG"
    sleep 60
done
echo "[$(date)] GPU free. Starting Phase 2 batch generation." | tee -a "$LOG"

NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$PROMPTS'))))")
echo "[$(date)] Phase 2: $NUM_PROMPTS videos (4 faces × 5 prompts, 9:16 portrait)" | tee -a "$LOG"

TOTAL=0
SUCCESSES=0
FAILURES=0

SEED=42  # Single seed for Phase 2 (comparing faces, not seeds)

for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")
    PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['prompt'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['seconds'])")
    FACE_FILE=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['face'])")
    FACE_PATH="$FACEDIR/$FACE_FILE"

    if [ ! -f "$FACE_PATH" ]; then
        echo "[$(date)] SKIP: Face image not found: $FACE_PATH" | tee -a "$LOG"
        continue
    fi

    VIDNAME="${PROMPT_ID}_seed${SEED}"
    OUTPATH="$OUTDIR/$VIDNAME"
    TOTAL=$((TOTAL + 1))

    echo "[$(date)] [$TOTAL/$NUM_PROMPTS] Generating: $VIDNAME (${SECONDS_VAL}s, face=$FACE_FILE, 256x448 portrait)" | tee -a "$LOG"
    START_TIME=$(date +%s)

    cd "$WORKDIR"
    timeout 600 torchrun \
        --nnodes=1 --node_rank=0 --nproc_per_node=1 \
        --rdzv-backend=c10d --rdzv-endpoint=localhost:6020 \
        inference/pipeline/entry.py \
        --config-load-path example/distill/config.json \
        --prompt "$PROMPT_TEXT" \
        --image_path "$FACE_PATH" \
        --seconds "$SECONDS_VAL" \
        --br_width 256 --br_height 448 \
        --seed "$SEED" \
        --output_path "$OUTPATH" \
        >> "$LOG" 2>&1
    RC=$?

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

    if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
        FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
        echo "[$(date)] SUCCESS: $VIDNAME (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
        SUCCESSES=$((SUCCESSES + 1))

        # Score each video against itself (quality assessment)
        echo "[$(date)] Scoring: $VIDNAME" | tee -a "$LOG"
        scp -q "$OUTFILE" "gumbiidigital@192.168.250.11:/tmp/score_ref.mp4" 2>/dev/null
        scp -q "$OUTFILE" "gumbiidigital@192.168.250.11:/tmp/score_prod.mp4" 2>/dev/null

        SCORE_RESULT=$(curl -s --max-time 120 -X POST "$SCORER/compare" \
            -H "Content-Type: application/json" \
            -d '{"reference_path": "/tmp/score_ref.mp4", "produced_path": "/tmp/score_prod.mp4"}' 2>/dev/null)

        if echo "$SCORE_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            SCORE_VAL=$(echo "$SCORE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('score', 'N/A'))" 2>/dev/null)
            echo "{\"prompt_id\": \"$PROMPT_ID\", \"face\": \"$FACE_FILE\", \"seed\": $SEED, \"score\": $SCORE_RESULT}" >> "$RESULTS"
            echo "[$(date)] Score: $VIDNAME = $SCORE_VAL" | tee -a "$LOG"
        else
            echo "[$(date)] Scoring failed for $VIDNAME" | tee -a "$LOG"
        fi
    else
        echo "[$(date)] FAILED: $VIDNAME (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
        FAILURES=$((FAILURES + 1))
    fi
done

# Summary
echo "========================================" | tee -a "$LOG" "$SUMMARY"
echo "PHASE 2 COMPLETE: $(date)" | tee -a "$LOG" "$SUMMARY"
echo "Total: $TOTAL | Success: $SUCCESSES | Failed: $FAILURES" | tee -a "$LOG" "$SUMMARY"
echo "Output: $OUTDIR" | tee -a "$LOG" "$SUMMARY"
echo "Resolution: 256x448 (9:16 portrait)" | tee -a "$LOG" "$SUMMARY"
echo "========================================" | tee -a "$LOG" "$SUMMARY"

if [ -f "$RESULTS" ]; then
    python3 -c "
import json
scores = []
with open('$RESULTS') as f:
    for line in f:
        data = json.loads(line)
        s = data.get('score', {})
        val = s.get('score', 0) if isinstance(s, dict) else float(s)
        scores.append((data['prompt_id'], data.get('face','?'), val))
scores.sort(key=lambda x: -x[2])
print('\nPhase 2 Results (ranked):')
for pid, face, val in scores:
    print(f'  {pid:<50} {face:<30} {val:.1f}')
print(f'\nMean: {sum(v for _,_,v in scores)/len(scores):.1f}')
" | tee -a "$SUMMARY"
fi

echo "[$(date)] Phase 2 done. Results at $OUTDIR" | tee -a "$LOG"
