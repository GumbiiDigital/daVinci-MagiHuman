#!/bin/bash
# phase2_native_sr.sh — Use DaVinci's native SR models instead of Real-ESRGAN
# Regenerates Phase 1 videos at 540p and 1080p using built-in super-resolution
# Then runs config_sweep.sh for comprehensive comparison

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
PROMPTS="$WORKDIR/batch_prompts.json"
FACE="$HOME/projects/real_face_test/face.jpg"
SCORER="http://192.168.250.11:8540"
RDZV_PORT=6020

# Find Phase 1 output dir
PHASE1_DIR=$(ls -td "$WORKDIR"/batch_output_* 2>/dev/null | head -1)
if [ -z "$PHASE1_DIR" ]; then
    echo "FATAL: No Phase 1 output found"
    exit 1
fi

SR540_DIR="$PHASE1_DIR/native_sr_540p"
SR1080_DIR="$PHASE1_DIR/native_sr_1080p"
LOG="$PHASE1_DIR/phase2_sr.log"
RESULTS_540="$PHASE1_DIR/results_native_540p.jsonl"
RESULTS_1080="$PHASE1_DIR/results_native_1080p.jsonl"

export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$SR540_DIR" "$SR1080_DIR"

# ─── Helpers ───
cleanup_rdzv() {
    pkill -9 -f "inference/pipeline/entry.py" 2>/dev/null || true
    pkill -9 -f "torchrun.*entry.py" 2>/dev/null || true
    fuser -k ${RDZV_PORT}/tcp 2>/dev/null || true
    sleep 3
}

full_gpu_cleanup() {
    echo "[$(date)] CIRCUIT BREAKER: Full cleanup." | tee -a "$LOG"
    cleanup_rdzv
    pkill -9 -f "python3.*inference" 2>/dev/null || true
    sleep 10
}

score_pair() {
    local VID_A="$1" VID_B="$2" PROMPT_ID="$3" RESULTS_FILE="$4" STAGE="$5"

    if [ ! -f "$VID_A" ] || [ ! -f "$VID_B" ]; then
        echo "[$(date)] Cannot score $PROMPT_ID ($STAGE) — missing videos" | tee -a "$LOG"
        return 1
    fi

    scp -q "$VID_A" "gumbiidigital@192.168.250.11:/tmp/score_ref.mp4" 2>/dev/null
    scp -q "$VID_B" "gumbiidigital@192.168.250.11:/tmp/score_prod.mp4" 2>/dev/null

    SCORE_RESULT=$(curl -s --max-time 120 -X POST "$SCORER/compare" \
        -H "Content-Type: application/json" \
        -d '{"reference_path": "/tmp/score_ref.mp4", "produced_path": "/tmp/score_prod.mp4"}' 2>/dev/null)

    if echo "$SCORE_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        SCORE_VAL=$(echo "$SCORE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('score', 'N/A'))" 2>/dev/null)
        echo "{\"prompt_id\": \"$PROMPT_ID\", \"stage\": \"$STAGE\", \"seed_a\": 42, \"seed_b\": 137, \"score\": $SCORE_RESULT}" >> "$RESULTS_FILE"
        echo "[$(date)] Score $PROMPT_ID ($STAGE): $SCORE_VAL" | tee -a "$LOG"
        return 0
    fi
    echo "[$(date)] Scoring failed for $PROMPT_ID ($STAGE)" | tee -a "$LOG"
    return 1
}

# ─── Check scorer ───
if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
    ssh gumbiidigital@192.168.250.11 "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &"
    sleep 10
fi

NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$PROMPTS'))))")
SEEDS=(42 137)
CONSECUTIVE_FAILS=0

# ═══════════════════════════════════════════════════════════════
# PHASE 2A: Native DaVinci SR to 540p
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ PHASE 2A: DaVinci Native SR → 540p ═══" | tee -a "$LOG"

TOTAL=0
SUCCESS=0
SCORED=0

for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")
    PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['prompt'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['seconds'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        OUTPATH="$SR540_DIR/$VIDNAME"
        TOTAL=$((TOTAL + 1))

        # Skip if exists
        EXISTING=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)
        if [ -n "$EXISTING" ] && [ -f "$EXISTING" ]; then
            FILESIZE=$(stat -c%s "$EXISTING" 2>/dev/null || echo 0)
            if [ "$FILESIZE" -gt 10000 ]; then
                echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] SKIP (exists): $VIDNAME ($(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
                SUCCESS=$((SUCCESS + 1))
                CONSECUTIVE_FAILS=0
                continue
            fi
        fi

        cleanup_rdzv

        echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] Generating 540p: $VIDNAME (${SECONDS_VAL}s)" | tee -a "$LOG"
        START_TIME=$(date +%s)

        cd "$WORKDIR"
        timeout 900 torchrun \
            --nnodes=1 --node_rank=0 --nproc_per_node=1 \
            --rdzv-backend=c10d --rdzv-endpoint=localhost:${RDZV_PORT} \
            inference/pipeline/entry.py \
            --config-load-path "$WORKDIR/example/distill_sr_540p/config.json" \
            --prompt "$PROMPT_TEXT" \
            --image_path "$FACE" \
            --seconds "$SECONDS_VAL" \
            --br_width 448 --br_height 256 \
            --seed "$SEED" \
            --output_path "$OUTPATH" \
            >> "$LOG" 2>&1
        RC=$?

        ELAPSED=$(( $(date +%s) - START_TIME ))
        OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

        if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
            FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
            echo "[$(date)] SUCCESS: $VIDNAME 540p (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
            SUCCESS=$((SUCCESS + 1))
            CONSECUTIVE_FAILS=0
        else
            echo "[$(date)] FAILED: $VIDNAME 540p (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            if [ $CONSECUTIVE_FAILS -ge 2 ]; then
                full_gpu_cleanup
                CONSECUTIVE_FAILS=0
            fi
        fi
    done

    # Score the 540p pair
    VID_A=$(ls -t "$SR540_DIR/${PROMPT_ID}_seed${SEEDS[0]}"*.mp4 2>/dev/null | head -1)
    VID_B=$(ls -t "$SR540_DIR/${PROMPT_ID}_seed${SEEDS[1]}"*.mp4 2>/dev/null | head -1)

    if ! grep -q "\"$PROMPT_ID\"" "$RESULTS_540" 2>/dev/null; then
        if score_pair "${VID_A:-}" "${VID_B:-}" "$PROMPT_ID" "$RESULTS_540" "native_sr_540p"; then
            SCORED=$((SCORED + 1))
        fi
    fi
done

echo "[$(date)] ═══ PHASE 2A COMPLETE: $SUCCESS/$TOTAL success, $SCORED scored ═══" | tee -a "$LOG"

# ═══════════════════════════════════════════════════════════════
# PHASE 2B: Native DaVinci SR to 1080p
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ PHASE 2B: DaVinci Native SR → 1080p ═══" | tee -a "$LOG"

TOTAL=0
SUCCESS=0
SCORED=0
CONSECUTIVE_FAILS=0

for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")
    PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['prompt'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['seconds'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        OUTPATH="$SR1080_DIR/$VIDNAME"
        TOTAL=$((TOTAL + 1))

        # Skip if exists
        EXISTING=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)
        if [ -n "$EXISTING" ] && [ -f "$EXISTING" ]; then
            FILESIZE=$(stat -c%s "$EXISTING" 2>/dev/null || echo 0)
            if [ "$FILESIZE" -gt 10000 ]; then
                echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] SKIP (exists): $VIDNAME ($(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
                SUCCESS=$((SUCCESS + 1))
                CONSECUTIVE_FAILS=0
                continue
            fi
        fi

        cleanup_rdzv

        echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] Generating 1080p: $VIDNAME (${SECONDS_VAL}s)" | tee -a "$LOG"
        START_TIME=$(date +%s)

        cd "$WORKDIR"
        timeout 1200 torchrun \
            --nnodes=1 --node_rank=0 --nproc_per_node=1 \
            --rdzv-backend=c10d --rdzv-endpoint=localhost:${RDZV_PORT} \
            inference/pipeline/entry.py \
            --config-load-path "$WORKDIR/example/distill_sr_1080p/config.json" \
            --prompt "$PROMPT_TEXT" \
            --image_path "$FACE" \
            --seconds "$SECONDS_VAL" \
            --br_width 448 --br_height 256 \
            --seed "$SEED" \
            --output_path "$OUTPATH" \
            >> "$LOG" 2>&1
        RC=$?

        ELAPSED=$(( $(date +%s) - START_TIME ))
        OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

        if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
            FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
            echo "[$(date)] SUCCESS: $VIDNAME 1080p (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
            SUCCESS=$((SUCCESS + 1))
            CONSECUTIVE_FAILS=0
        else
            echo "[$(date)] FAILED: $VIDNAME 1080p (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            if [ $CONSECUTIVE_FAILS -ge 2 ]; then
                full_gpu_cleanup
                CONSECUTIVE_FAILS=0
            fi
        fi
    done

    # Score the 1080p pair
    VID_A=$(ls -t "$SR1080_DIR/${PROMPT_ID}_seed${SEEDS[0]}"*.mp4 2>/dev/null | head -1)
    VID_B=$(ls -t "$SR1080_DIR/${PROMPT_ID}_seed${SEEDS[1]}"*.mp4 2>/dev/null | head -1)

    if ! grep -q "\"$PROMPT_ID\"" "$RESULTS_1080" 2>/dev/null; then
        if score_pair "${VID_A:-}" "${VID_B:-}" "$PROMPT_ID" "$RESULTS_1080" "native_sr_1080p"; then
            SCORED=$((SCORED + 1))
        fi
    fi
done

echo "[$(date)] ═══ PHASE 2B COMPLETE: $SUCCESS/$TOTAL success, $SCORED scored ═══" | tee -a "$LOG"

# ═══════════════════════════════════════════════════════════════
# PHASE 3: Cross-resolution comparison
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ CROSS-RESOLUTION COMPARISON ═══" | tee -a "$LOG"

python3 -c "
import json, os

stages = {
    'original_448x256': '$PHASE1_DIR/results_original.jsonl',
    'native_sr_540p': '$RESULTS_540',
    'native_sr_1080p': '$RESULTS_1080',
}

all_scores = {}
for stage, path in stages.items():
    if not os.path.exists(path): continue
    with open(path) as f:
        for line in f:
            d = json.loads(line)
            pid = d['prompt_id']
            s = d.get('score', {})
            val = s.get('score', 0) if isinstance(s, dict) else float(s)
            all_scores.setdefault(pid, {})[stage] = val

print()
print(f'{\"Prompt\":<35} {\"Original\":>10} {\"540p SR\":>10} {\"1080p SR\":>10}')
print('-' * 70)

for pid in sorted(all_scores.keys()):
    s = all_scores[pid]
    print(f'{pid:<35} {s.get(\"original_448x256\",0):>10.1f} {s.get(\"native_sr_540p\",0):>10.1f} {s.get(\"native_sr_1080p\",0):>10.1f}')

print('-' * 70)
for stage in stages:
    vals = [s.get(stage, 0) for s in all_scores.values() if stage in s]
    if vals:
        print(f'Mean {stage}: {sum(vals)/len(vals):.1f}')
" 2>&1 | tee -a "$LOG" "$PHASE1_DIR/cross_resolution_comparison.txt"

# ═══════════════════════════════════════════════════════════════
# PHASE 4: Config sweep (different step counts, resolutions)
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ Starting config sweep... ═══" | tee -a "$LOG"
cd "$WORKDIR"
bash config_sweep.sh 2>&1 | tee -a "$LOG"

echo "[$(date)] ═══ ALL PHASES COMPLETE ═══" | tee -a "$LOG"
