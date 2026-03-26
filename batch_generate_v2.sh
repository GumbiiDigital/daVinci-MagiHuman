#!/bin/bash
# batch_generate_v2.sh — Resilient AFK pipeline for DaVinci-MagiHuman
# Improvements over v1:
#   - rdzv cleanup before each generation (prevents cascading TCPStore failures)
#   - 2-consecutive-failure circuit breaker with full GPU/process cleanup
#   - Resume support: skips already-completed videos
#   - 3-stage scoring: original 448x256, upscaled 720p, upscaled 1080p
#
# Usage: bash batch_generate_v2.sh [--outdir /path/to/existing/output]

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
PROMPTS="$WORKDIR/batch_prompts.json"
FACE="$HOME/projects/real_face_test/face.jpg"
SCORER="http://192.168.250.11:8540"
RDZV_PORT=6020

# Allow resuming into an existing output dir
if [[ "${1:-}" == "--outdir" ]] && [[ -n "${2:-}" ]]; then
    OUTDIR="$2"
else
    OUTDIR="$WORKDIR/batch_output_$(date +%Y%m%d_%H%M%S)"
fi

RESULTS="$OUTDIR/results_original.jsonl"
RESULTS_720="$OUTDIR/results_720p.jsonl"
RESULTS_1080="$OUTDIR/results_1080p.jsonl"
SUMMARY="$OUTDIR/summary.txt"
LOG="$OUTDIR/generation.log"
UPSCALE_DIR_720="$OUTDIR/upscaled_720p"
UPSCALE_DIR_1080="$OUTDIR/upscaled_1080p"

# Required env vars
export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$OUTDIR" "$UPSCALE_DIR_720" "$UPSCALE_DIR_1080"

# ─── Helper: kill stale torchrun/c10d processes ───
cleanup_rdzv() {
    # Kill any orphaned torchrun or inference processes
    pkill -9 -f "inference/pipeline/entry.py" 2>/dev/null || true
    pkill -9 -f "torchrun.*entry.py" 2>/dev/null || true
    # Free the rdzv port
    fuser -k ${RDZV_PORT}/tcp 2>/dev/null || true
    # Give GPU a moment to release memory
    sleep 3
}

# ─── Helper: full GPU reset after consecutive failures ───
full_gpu_cleanup() {
    echo "[$(date)] CIRCUIT BREAKER: 2 consecutive failures. Full cleanup." | tee -a "$LOG"
    cleanup_rdzv
    # Kill ALL python GPU processes (except this script)
    pkill -9 -f "python3.*inference" 2>/dev/null || true
    pkill -9 -f "python3.*torchrun" 2>/dev/null || true
    # Wait for GPU memory to fully release
    sleep 10
    # Verify GPU is free
    GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    echo "[$(date)] GPU utilization after cleanup: ${GPU_UTIL}%" | tee -a "$LOG"
}

# ─── Helper: score a video pair ───
score_pair() {
    local VID_A="$1"
    local VID_B="$2"
    local PROMPT_ID="$3"
    local RESULTS_FILE="$4"
    local STAGE="$5"

    if [ ! -f "$VID_A" ] || [ ! -f "$VID_B" ]; then
        echo "[$(date)] Cannot score $PROMPT_ID ($STAGE) — missing videos" | tee -a "$LOG"
        return 1
    fi

    echo "[$(date)] Scoring pair: $PROMPT_ID ($STAGE)" | tee -a "$LOG"

    scp -q "$VID_A" "gumbiidigital@192.168.250.11:/tmp/score_ref.mp4" 2>/dev/null
    scp -q "$VID_B" "gumbiidigital@192.168.250.11:/tmp/score_prod.mp4" 2>/dev/null

    SCORE_RESULT=$(curl -s --max-time 120 -X POST "$SCORER/compare" \
        -H "Content-Type: application/json" \
        -d '{"reference_path": "/tmp/score_ref.mp4", "produced_path": "/tmp/score_prod.mp4"}' 2>/dev/null)

    if echo "$SCORE_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "{\"prompt_id\": \"$PROMPT_ID\", \"stage\": \"$STAGE\", \"seed_a\": 42, \"seed_b\": 137, \"score\": $SCORE_RESULT}" >> "$RESULTS_FILE"
        SCORE_VAL=$(echo "$SCORE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('score', 'N/A'))" 2>/dev/null)
        echo "[$(date)] Score for $PROMPT_ID ($STAGE): $SCORE_VAL" | tee -a "$LOG"
        return 0
    else
        echo "[$(date)] Scoring failed for $PROMPT_ID ($STAGE): $SCORE_RESULT" | tee -a "$LOG"
        return 1
    fi
}

# ─── Helper: upscale a video with Real-ESRGAN ───
upscale_video() {
    local INPUT="$1"
    local OUTPUT="$2"
    local TARGET_HEIGHT="$3"
    local BASENAME=$(basename "$INPUT")

    if [ -f "$OUTPUT" ]; then
        echo "[$(date)] Already upscaled: $BASENAME → $(basename "$OUTPUT")" >> "$LOG"
        return 0
    fi

    echo "[$(date)] Upscaling: $BASENAME → ${TARGET_HEIGHT}p" | tee -a "$LOG"

    # Extract frames, upscale, reassemble
    local TMPDIR=$(mktemp -d)
    local FPS=$(ffprobe -v 0 -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$INPUT" 2>/dev/null | head -1)
    FPS=${FPS:-"24/1"}

    # Extract frames
    ffmpeg -y -i "$INPUT" -qscale:v 2 "$TMPDIR/frame_%06d.png" >> "$LOG" 2>&1

    # Upscale each frame with Real-ESRGAN
    if python3 -c "
import glob, os, sys
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer
import cv2
import numpy as np

model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
upsampler = RealESRGANer(scale=4, model_path=None, dni_weight=None, model=model, half=True, device='cuda')

# Download model weights if needed
import urllib.request
model_url = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'
model_path = os.path.expanduser('~/.cache/realesrgan/RealESRGAN_x4plus.pth')
os.makedirs(os.path.dirname(model_path), exist_ok=True)
if not os.path.exists(model_path):
    print(f'Downloading Real-ESRGAN model...', file=sys.stderr)
    urllib.request.urlretrieve(model_url, model_path)

upsampler = RealESRGANer(scale=4, model_path=model_path, dni_weight=None, model=model, half=True, device='cuda')

frames = sorted(glob.glob('$TMPDIR/frame_*.png'))
target_h = $TARGET_HEIGHT
for i, fpath in enumerate(frames):
    img = cv2.imread(fpath, cv2.IMREAD_UNCHANGED)
    output, _ = upsampler.enhance(img, outscale=4)
    # Resize to exact target
    h, w = output.shape[:2]
    target_w = int(w * target_h / h)
    # Make width even for codec
    target_w = target_w + (target_w % 2)
    output = cv2.resize(output, (target_w, target_h), interpolation=cv2.INTER_LANCZOS4)
    cv2.imwrite(fpath, output)
    if (i+1) % 20 == 0:
        print(f'  Upscaled {i+1}/{len(frames)} frames', file=sys.stderr)
print(f'  Upscaled all {len(frames)} frames', file=sys.stderr)
" >> "$LOG" 2>&1; then
        # Reassemble with audio
        ffmpeg -y -framerate "$FPS" -i "$TMPDIR/frame_%06d.png" \
            -i "$INPUT" -map 0:v -map 1:a? \
            -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
            -c:a copy \
            "$OUTPUT" >> "$LOG" 2>&1
        RC=$?
    else
        echo "[$(date)] Real-ESRGAN failed, falling back to ffmpeg lanczos" | tee -a "$LOG"
        local TARGET_W=$((TARGET_HEIGHT * 16 / 9))
        # Make width even
        TARGET_W=$((TARGET_W + TARGET_W % 2))
        ffmpeg -y -i "$INPUT" \
            -vf "scale=${TARGET_W}:${TARGET_HEIGHT}:flags=lanczos" \
            -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
            -c:a copy \
            "$OUTPUT" >> "$LOG" 2>&1
        RC=$?
    fi

    rm -rf "$TMPDIR"
    return $RC
}

# ─── Check prerequisites ───
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

# ─── Wait for GPU ───
echo "[$(date)] Waiting for current GPU job to finish..." | tee -a "$LOG"
while pgrep -f "inference/pipeline/entry.py" > /dev/null 2>&1; do
    echo "[$(date)] GPU busy, waiting 30s..." >> "$LOG"
    sleep 30
done
echo "[$(date)] GPU free. Starting batch generation." | tee -a "$LOG"

# ─── Parse prompts ───
NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$PROMPTS'))))")
echo "[$(date)] Loaded $NUM_PROMPTS prompts. Will generate 2 seeds each = $((NUM_PROMPTS * 2)) videos." | tee -a "$LOG"

TOTAL=0
SUCCESSES=0
FAILURES=0
SCORED=0
CONSECUTIVE_FAILS=0
SEEDS=(42 137)

# ═══════════════════════════════════════════════════════════════
# PHASE 1: Generate all videos at 448x256, score originals
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ PHASE 1: Generation + Original Scoring ═══" | tee -a "$LOG"

for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")
    PROMPT_TEXT=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['prompt'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['seconds'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        OUTPATH="$OUTDIR/$VIDNAME"
        TOTAL=$((TOTAL + 1))

        # ── Resume: skip if already generated ──
        EXISTING=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)
        if [ -n "$EXISTING" ] && [ -f "$EXISTING" ]; then
            FILESIZE=$(stat -c%s "$EXISTING" 2>/dev/null || echo 0)
            if [ "$FILESIZE" -gt 10000 ]; then
                echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] SKIP (exists): $VIDNAME ($(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
                SUCCESSES=$((SUCCESSES + 1))
                CONSECUTIVE_FAILS=0
                continue
            fi
        fi

        # ── Pre-generation cleanup ──
        cleanup_rdzv

        echo "[$(date)] [$TOTAL/$((NUM_PROMPTS * 2))] Generating: $VIDNAME (${SECONDS_VAL}s)" | tee -a "$LOG"
        START_TIME=$(date +%s)

        cd "$WORKDIR"
        timeout 600 torchrun \
            --nnodes=1 --node_rank=0 --nproc_per_node=1 \
            --rdzv-backend=c10d --rdzv-endpoint=localhost:${RDZV_PORT} \
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

        OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

        if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
            FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
            echo "[$(date)] SUCCESS: $VIDNAME (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
            SUCCESSES=$((SUCCESSES + 1))
            CONSECUTIVE_FAILS=0
        else
            echo "[$(date)] FAILED: $VIDNAME (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
            FAILURES=$((FAILURES + 1))
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))

            # ── Circuit breaker: 2 consecutive failures → full cleanup ──
            if [ $CONSECUTIVE_FAILS -ge 2 ]; then
                full_gpu_cleanup
                CONSECUTIVE_FAILS=0
            fi
        fi
    done

    # Score the original pair
    VID_A=$(ls -t "${OUTDIR}/${PROMPT_ID}_seed${SEEDS[0]}"*.mp4 2>/dev/null | head -1)
    VID_B=$(ls -t "${OUTDIR}/${PROMPT_ID}_seed${SEEDS[1]}"*.mp4 2>/dev/null | head -1)

    # Skip if already scored
    if grep -q "\"$PROMPT_ID\"" "$RESULTS" 2>/dev/null; then
        echo "[$(date)] SKIP scoring (exists): $PROMPT_ID (original)" | tee -a "$LOG"
    else
        if score_pair "${VID_A:-}" "${VID_B:-}" "$PROMPT_ID" "$RESULTS" "original_448x256"; then
            SCORED=$((SCORED + 1))
        fi
    fi
done

echo "[$(date)] ═══ PHASE 1 COMPLETE ═══" | tee -a "$LOG"
echo "[$(date)] Generated: $TOTAL | Success: $SUCCESSES | Failed: $FAILURES | Scored: $SCORED" | tee -a "$LOG"

# ═══════════════════════════════════════════════════════════════
# PHASE 2: Upscale to 720p and score
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ PHASE 2: Upscale to 720p + Score ═══" | tee -a "$LOG"

SCORED_720=0
for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        ORIGINAL=$(ls -t "${OUTDIR}/${VIDNAME}"*.mp4 2>/dev/null | head -1)
        UPSCALED_720="$UPSCALE_DIR_720/${VIDNAME}_720p.mp4"

        if [ -n "$ORIGINAL" ] && [ -f "$ORIGINAL" ]; then
            upscale_video "$ORIGINAL" "$UPSCALED_720" 720
        fi
    done

    # Score the 720p pair
    VID_A_720="$UPSCALE_DIR_720/${PROMPT_ID}_seed${SEEDS[0]}_720p.mp4"
    VID_B_720="$UPSCALE_DIR_720/${PROMPT_ID}_seed${SEEDS[1]}_720p.mp4"

    if grep -q "\"$PROMPT_ID\"" "$RESULTS_720" 2>/dev/null; then
        echo "[$(date)] SKIP scoring (exists): $PROMPT_ID (720p)" | tee -a "$LOG"
    else
        if score_pair "$VID_A_720" "$VID_B_720" "$PROMPT_ID" "$RESULTS_720" "upscaled_720p"; then
            SCORED_720=$((SCORED_720 + 1))
        fi
    fi
done

echo "[$(date)] ═══ PHASE 2 COMPLETE: $SCORED_720 pairs scored at 720p ═══" | tee -a "$LOG"

# ═══════════════════════════════════════════════════════════════
# PHASE 3: Upscale to 1080p and score
# ═══════════════════════════════════════════════════════════════
echo "[$(date)] ═══ PHASE 3: Upscale to 1080p + Score ═══" | tee -a "$LOG"

SCORED_1080=0
for IDX in $(seq 0 $((NUM_PROMPTS - 1))); do
    PROMPT_ID=$(python3 -c "import json; print(json.load(open('$PROMPTS'))[$IDX]['id'])")

    for SEED in "${SEEDS[@]}"; do
        VIDNAME="${PROMPT_ID}_seed${SEED}"
        # Upscale from 720p to 1080p (better quality than 256→1080 direct)
        SOURCE_720="$UPSCALE_DIR_720/${VIDNAME}_720p.mp4"
        UPSCALED_1080="$UPSCALE_DIR_1080/${VIDNAME}_1080p.mp4"

        if [ -f "$SOURCE_720" ]; then
            upscale_video "$SOURCE_720" "$UPSCALED_1080" 1080
        elif [ -n "$(ls -t "${OUTDIR}/${VIDNAME}"*.mp4 2>/dev/null | head -1)" ]; then
            # Fallback: upscale directly from original if 720p missing
            ORIGINAL=$(ls -t "${OUTDIR}/${VIDNAME}"*.mp4 2>/dev/null | head -1)
            upscale_video "$ORIGINAL" "$UPSCALED_1080" 1080
        fi
    done

    # Score the 1080p pair
    VID_A_1080="$UPSCALE_DIR_1080/${PROMPT_ID}_seed${SEEDS[0]}_1080p.mp4"
    VID_B_1080="$UPSCALE_DIR_1080/${PROMPT_ID}_seed${SEEDS[1]}_1080p.mp4"

    if grep -q "\"$PROMPT_ID\"" "$RESULTS_1080" 2>/dev/null; then
        echo "[$(date)] SKIP scoring (exists): $PROMPT_ID (1080p)" | tee -a "$LOG"
    else
        if score_pair "$VID_A_1080" "$VID_B_1080" "$PROMPT_ID" "$RESULTS_1080" "upscaled_1080p"; then
            SCORED_1080=$((SCORED_1080 + 1))
        fi
    fi
done

echo "[$(date)] ═══ PHASE 3 COMPLETE: $SCORED_1080 pairs scored at 1080p ═══" | tee -a "$LOG"

# ═══════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════
echo "========================================" | tee -a "$LOG" "$SUMMARY"
echo "BATCH COMPLETE: $(date)" | tee -a "$LOG" "$SUMMARY"
echo "Total generated: $TOTAL" | tee -a "$LOG" "$SUMMARY"
echo "Successes: $SUCCESSES" | tee -a "$LOG" "$SUMMARY"
echo "Failures: $FAILURES" | tee -a "$LOG" "$SUMMARY"
echo "Pairs scored (original): $SCORED / $NUM_PROMPTS" | tee -a "$LOG" "$SUMMARY"
echo "Pairs scored (720p): $SCORED_720 / $NUM_PROMPTS" | tee -a "$LOG" "$SUMMARY"
echo "Pairs scored (1080p): $SCORED_1080 / $NUM_PROMPTS" | tee -a "$LOG" "$SUMMARY"
echo "Output directory: $OUTDIR" | tee -a "$LOG" "$SUMMARY"
echo "========================================" | tee -a "$LOG" "$SUMMARY"

# Compare scores across stages
python3 -c "
import json, os

stages = [
    ('original_448x256', '$RESULTS'),
    ('upscaled_720p', '$RESULTS_720'),
    ('upscaled_1080p', '$RESULTS_1080'),
]

print()
print('Score Comparison Across Stages:')
print(f'{\"Prompt\":<35} {\"Original\":>10} {\"720p\":>10} {\"1080p\":>10}')
print('-' * 70)

all_scores = {}
for stage_name, path in stages:
    if not os.path.exists(path):
        continue
    with open(path) as f:
        for line in f:
            data = json.loads(line)
            pid = data['prompt_id']
            s = data.get('score', {})
            val = s.get('score', s.get('total_score', 0)) if isinstance(s, dict) else float(s)
            all_scores.setdefault(pid, {})[stage_name] = val

for pid in sorted(all_scores.keys()):
    scores = all_scores[pid]
    orig = scores.get('original_448x256', 0)
    s720 = scores.get('upscaled_720p', 0)
    s1080 = scores.get('upscaled_1080p', 0)
    print(f'{pid:<35} {orig:>10.1f} {s720:>10.1f} {s1080:>10.1f}')

# Averages
print('-' * 70)
for stage_name, _ in stages:
    vals = [s.get(stage_name, 0) for s in all_scores.values() if stage_name in s]
    if vals:
        print(f'Mean {stage_name}: {sum(vals)/len(vals):.1f}')
" >> "$SUMMARY" 2>/dev/null
cat "$SUMMARY"

echo "[$(date)] Done. Results at $OUTDIR" | tee -a "$LOG"
