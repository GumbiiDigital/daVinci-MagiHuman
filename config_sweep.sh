#!/bin/bash
# config_sweep.sh — Test different DaVinci configurations to find best quality
# Runs after Phase 1 batch completes. Tests:
#   1. distill @ 448x256 (baseline — already done in Phase 1)
#   2. distill_sr_540p (native 540p SR)
#   3. distill_sr_1080p (native 1080p SR)
#   4. distill @ 448x256 with 12 steps (more inference steps)
#   5. distill @ 448x256 with 16 steps
#   6. distill @ 512x288 (larger base resolution)
#   7. base (non-distilled) @ 448x256 with 32 steps
#
# Uses top 5 prompts from Phase 1 to keep runtime reasonable.

set -uo pipefail

WORKDIR="$HOME/daVinci-MagiHuman"
PROMPTS="$WORKDIR/batch_prompts.json"
FACE="$HOME/projects/real_face_test/face.jpg"
SCORER="http://192.168.250.11:8540"
RDZV_PORT=6020
SWEEP_DIR="$WORKDIR/config_sweep_$(date +%Y%m%d_%H%M%S)"
LOG="$SWEEP_DIR/sweep.log"
RESULTS="$SWEEP_DIR/results.jsonl"

export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$SWEEP_DIR"

# ─── Cleanup helpers (same as v2) ───
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

# ─── Score a pair ───
score_pair() {
    local VID_A="$1" VID_B="$2" CONFIG_NAME="$3" PROMPT_ID="$4"

    if [ ! -f "$VID_A" ] || [ ! -f "$VID_B" ]; then
        echo "[$(date)] Cannot score $CONFIG_NAME/$PROMPT_ID — missing videos" | tee -a "$LOG"
        return 1
    fi

    scp -q "$VID_A" "gumbiidigital@192.168.250.11:/tmp/score_ref.mp4" 2>/dev/null
    scp -q "$VID_B" "gumbiidigital@192.168.250.11:/tmp/score_prod.mp4" 2>/dev/null

    SCORE_RESULT=$(curl -s --max-time 120 -X POST "$SCORER/compare" \
        -H "Content-Type: application/json" \
        -d '{"reference_path": "/tmp/score_ref.mp4", "produced_path": "/tmp/score_prod.mp4"}' 2>/dev/null)

    if echo "$SCORE_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        SCORE_VAL=$(echo "$SCORE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('score', 'N/A'))" 2>/dev/null)
        echo "{\"config\": \"$CONFIG_NAME\", \"prompt_id\": \"$PROMPT_ID\", \"score\": $SCORE_RESULT}" >> "$RESULTS"
        echo "[$(date)] Score $CONFIG_NAME/$PROMPT_ID: $SCORE_VAL" | tee -a "$LOG"
        return 0
    fi
    return 1
}

# ─── Generate a single video ───
generate_video() {
    local CONFIG_PATH="$1" PROMPT_TEXT="$2" SECONDS_VAL="$3" SEED="$4" OUTPATH="$5"
    local EXTRA_ARGS="${6:-}"

    cleanup_rdzv

    cd "$WORKDIR"
    timeout 900 torchrun \
        --nnodes=1 --node_rank=0 --nproc_per_node=1 \
        --rdzv-backend=c10d --rdzv-endpoint=localhost:${RDZV_PORT} \
        inference/pipeline/entry.py \
        --config-load-path "$CONFIG_PATH" \
        --prompt "$PROMPT_TEXT" \
        --image_path "$FACE" \
        --seconds "$SECONDS_VAL" \
        --seed "$SEED" \
        --output_path "$OUTPATH" \
        $EXTRA_ARGS \
        >> "$LOG" 2>&1
    return $?
}

# ─── Check scorer ───
if ! curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
    echo "FATAL: Scorer not available" | tee -a "$LOG"
    exit 1
fi

# ─── Select top 5 prompts from Phase 1 results ───
PHASE1_DIR=$(ls -td "$WORKDIR"/batch_output_* 2>/dev/null | head -1)
if [ -z "$PHASE1_DIR" ]; then
    echo "FATAL: No Phase 1 output found" | tee -a "$LOG"
    exit 1
fi

# Get top 5 by score, or first 5 if no scores yet
if [ -f "$PHASE1_DIR/results_original.jsonl" ] && [ -s "$PHASE1_DIR/results_original.jsonl" ]; then
    TOP_PROMPTS=$(python3 -c "
import json
scores = []
with open('$PHASE1_DIR/results_original.jsonl') as f:
    for line in f:
        d = json.loads(line)
        s = d.get('score', {})
        val = s.get('score', 0) if isinstance(s, dict) else float(s)
        scores.append((d['prompt_id'], val))
scores.sort(key=lambda x: x[1], reverse=True)
for pid, _ in scores[:5]:
    print(pid)
" 2>/dev/null)
elif [ -f "$PHASE1_DIR/results.jsonl" ] && [ -s "$PHASE1_DIR/results.jsonl" ]; then
    TOP_PROMPTS=$(python3 -c "
import json
scores = []
with open('$PHASE1_DIR/results.jsonl') as f:
    for line in f:
        d = json.loads(line)
        s = d.get('score', {})
        val = s.get('score', 0) if isinstance(s, dict) else float(s)
        scores.append((d['prompt_id'], val))
scores.sort(key=lambda x: x[1], reverse=True)
for pid, _ in scores[:5]:
    print(pid)
" 2>/dev/null)
else
    TOP_PROMPTS=$(python3 -c "import json; [print(p['id']) for p in json.load(open('$PROMPTS'))[:5]]")
fi

echo "[$(date)] ═══ CONFIG SWEEP ═══" | tee -a "$LOG"
echo "[$(date)] Top prompts for sweep: $TOP_PROMPTS" | tee -a "$LOG"

# ─── Define configurations to test ───
declare -A CONFIGS
CONFIGS[distill_256p_8step]="example/distill/config.json|--br_width 448 --br_height 256"
CONFIGS[distill_256p_12step]="example/distill/config.json|--br_width 448 --br_height 256"
CONFIGS[distill_256p_16step]="example/distill/config.json|--br_width 448 --br_height 256"
CONFIGS[distill_288p_8step]="example/distill/config.json|--br_width 512 --br_height 288"
CONFIGS[distill_sr_540p]="example/distill_sr_540p/config.json|--br_width 448 --br_height 256"
CONFIGS[distill_sr_1080p]="example/distill_sr_1080p/config.json|--br_width 448 --br_height 256"

# For step overrides, we need custom configs
create_step_config() {
    local STEPS=$1 OUTFILE=$2
    python3 -c "
import json
with open('$WORKDIR/example/distill/config.json') as f:
    cfg = json.load(f)
cfg['evaluation_config']['num_inference_steps'] = $STEPS
with open('$OUTFILE', 'w') as f:
    json.dump(cfg, f, indent=2)
"
}

create_step_config 12 "$SWEEP_DIR/config_12step.json"
create_step_config 16 "$SWEEP_DIR/config_16step.json"

SEEDS=(42 137)
TOTAL_CONFIGS=6
CURRENT_CONFIG=0
CONSECUTIVE_FAILS=0

for CONFIG_NAME in distill_256p_8step distill_256p_12step distill_256p_16step distill_288p_8step distill_sr_540p distill_sr_1080p; do
    CURRENT_CONFIG=$((CURRENT_CONFIG + 1))

    # Determine config path and extra args
    case "$CONFIG_NAME" in
        distill_256p_8step)
            CONFIG_PATH="$WORKDIR/example/distill/config.json"
            EXTRA="--br_width 448 --br_height 256"
            ;;
        distill_256p_12step)
            CONFIG_PATH="$SWEEP_DIR/config_12step.json"
            EXTRA="--br_width 448 --br_height 256"
            ;;
        distill_256p_16step)
            CONFIG_PATH="$SWEEP_DIR/config_16step.json"
            EXTRA="--br_width 448 --br_height 256"
            ;;
        distill_288p_8step)
            CONFIG_PATH="$WORKDIR/example/distill/config.json"
            EXTRA="--br_width 512 --br_height 288"
            ;;
        distill_sr_540p)
            CONFIG_PATH="$WORKDIR/example/distill_sr_540p/config.json"
            EXTRA="--br_width 448 --br_height 256"
            ;;
        distill_sr_1080p)
            CONFIG_PATH="$WORKDIR/example/distill_sr_1080p/config.json"
            EXTRA="--br_width 448 --br_height 256"
            ;;
    esac

    CONFIG_DIR="$SWEEP_DIR/$CONFIG_NAME"
    mkdir -p "$CONFIG_DIR"

    echo "" | tee -a "$LOG"
    echo "[$(date)] ─── Config $CURRENT_CONFIG/$TOTAL_CONFIGS: $CONFIG_NAME ───" | tee -a "$LOG"

    for PROMPT_ID in $TOP_PROMPTS; do
        PROMPT_TEXT=$(python3 -c "import json; prompts=json.load(open('$PROMPTS')); print(next(p['prompt'] for p in prompts if p['id']=='$PROMPT_ID'))")
        SECONDS_VAL=$(python3 -c "import json; prompts=json.load(open('$PROMPTS')); print(next(p['seconds'] for p in prompts if p['id']=='$PROMPT_ID'))")

        for SEED in "${SEEDS[@]}"; do
            VIDNAME="${PROMPT_ID}_seed${SEED}"
            OUTPATH="$CONFIG_DIR/$VIDNAME"

            # Skip if exists
            EXISTING=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)
            if [ -n "$EXISTING" ] && [ -f "$EXISTING" ]; then
                echo "[$(date)] SKIP (exists): $CONFIG_NAME/$VIDNAME" | tee -a "$LOG"
                CONSECUTIVE_FAILS=0
                continue
            fi

            echo "[$(date)] Generating: $CONFIG_NAME/$VIDNAME (${SECONDS_VAL}s)" | tee -a "$LOG"
            START_TIME=$(date +%s)

            generate_video "$CONFIG_PATH" "$PROMPT_TEXT" "$SECONDS_VAL" "$SEED" "$OUTPATH" "$EXTRA"
            RC=$?

            ELAPSED=$(( $(date +%s) - START_TIME ))
            OUTFILE=$(ls -t "${OUTPATH}"*.mp4 2>/dev/null | head -1)

            if [ $RC -eq 0 ] && [ -n "$OUTFILE" ] && [ -f "$OUTFILE" ]; then
                FILESIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
                echo "[$(date)] SUCCESS: $CONFIG_NAME/$VIDNAME (${ELAPSED}s, $(( FILESIZE / 1024 ))KB)" | tee -a "$LOG"
                CONSECUTIVE_FAILS=0
            else
                echo "[$(date)] FAILED: $CONFIG_NAME/$VIDNAME (rc=$RC, ${ELAPSED}s)" | tee -a "$LOG"
                CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
                if [ $CONSECUTIVE_FAILS -ge 2 ]; then
                    full_gpu_cleanup
                    CONSECUTIVE_FAILS=0
                fi
            fi
        done

        # Score pair
        VID_A=$(ls -t "$CONFIG_DIR/${PROMPT_ID}_seed${SEEDS[0]}"*.mp4 2>/dev/null | head -1)
        VID_B=$(ls -t "$CONFIG_DIR/${PROMPT_ID}_seed${SEEDS[1]}"*.mp4 2>/dev/null | head -1)
        score_pair "${VID_A:-}" "${VID_B:-}" "$CONFIG_NAME" "$PROMPT_ID"
    done
done

# ═══════════════════════════════════════════════════════════════
# FINAL COMPARISON
# ═══════════════════════════════════════════════════════════════
echo "" | tee -a "$LOG"
echo "[$(date)] ═══ SWEEP COMPLETE — COMPARISON ═══" | tee -a "$LOG"

python3 -c "
import json, os
from collections import defaultdict

results_path = '$RESULTS'
if not os.path.exists(results_path):
    print('No results to compare')
    exit()

scores = defaultdict(dict)
with open(results_path) as f:
    for line in f:
        d = json.loads(line)
        config = d['config']
        pid = d['prompt_id']
        s = d.get('score', {})
        val = s.get('score', 0) if isinstance(s, dict) else float(s)
        scores[config][pid] = val

# Print comparison table
configs = sorted(scores.keys())
prompts = sorted(set(p for c in scores.values() for p in c.keys()))

print()
header = f'{\"Prompt\":<35}'
for c in configs:
    short = c.replace('distill_', '').replace('_', ' ')
    header += f'{short:>14}'
print(header)
print('-' * (35 + 14 * len(configs)))

for pid in prompts:
    row = f'{pid:<35}'
    for c in configs:
        val = scores[c].get(pid, 0)
        row += f'{val:>14.1f}'
    print(row)

print('-' * (35 + 14 * len(configs)))
row = f'{\"MEAN\":<35}'
for c in configs:
    vals = list(scores[c].values())
    mean = sum(vals)/len(vals) if vals else 0
    row += f'{mean:>14.1f}'
print(row)

# Find winner
means = {c: sum(scores[c].values())/len(scores[c].values()) for c in configs if scores[c]}
winner = max(means, key=means.get) if means else 'none'
print()
print(f'WINNER: {winner} (mean score: {means.get(winner, 0):.1f})')
" 2>&1 | tee -a "$LOG" "$SWEEP_DIR/comparison.txt"

echo "[$(date)] Results saved to $SWEEP_DIR" | tee -a "$LOG"
