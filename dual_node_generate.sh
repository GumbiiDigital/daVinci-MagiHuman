#!/bin/bash
# dual_node_generate.sh — Parallel video generation across spark1 + spark2
# Splits the prompt×face matrix between two nodes, generates in parallel,
# rsyncs results back to spark1, and merges into one output directory.
#
# Usage:
#   bash dual_node_generate.sh                        # All prompts × all faces
#   bash dual_node_generate.sh --faces 10             # First 10 faces
#   bash dual_node_generate.sh --prompts top5         # Top 5 prompts only
#   bash dual_node_generate.sh --resume               # Resume both nodes
#   bash dual_node_generate.sh --weight 60:40         # 60% spark1, 40% spark2
#   bash dual_node_generate.sh --dry-run              # Show split, don't generate

set -uo pipefail

# ============================================================
# CONFIG
# ============================================================

WORKDIR="$HOME/daVinci-MagiHuman"
FACEDIR="$HOME/projects/real_face_test"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="$WORKDIR/dual_output_${TIMESTAMP}"
LOG="$OUTDIR/dual_generation.log"

SPARK1_IP="localhost"
SPARK2_IP="192.168.250.11"
SPARK2_USER="gumbiidigital"
SPARK2_SSH="${SPARK2_USER}@${SPARK2_IP}"

# Spark2 paths (mirrored layout)
SPARK2_WORKDIR="/home/gumbiidigital/daVinci-MagiHuman"
SPARK2_FACEDIR="/home/gumbiidigital/projects/real_face_test"
SPARK2_OUTDIR="${SPARK2_WORKDIR}/dual_output_${TIMESTAMP}"

# Scorer on spark2 — must be stopped during generation
SCORER_PORT=8540

# Parse args
MAX_FACES=20
PROMPT_SET="all"
RESUME=false
SEED=42
WEIGHT_S1=50
WEIGHT_S2=50
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --faces) MAX_FACES="$2"; shift 2 ;;
        --prompts) PROMPT_SET="$2"; shift 2 ;;
        --resume) RESUME=true; shift ;;
        --seed) SEED="$2"; shift 2 ;;
        --weight) IFS=':' read -r WEIGHT_S1 WEIGHT_S2 <<< "$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTDIR"
touch "$LOG"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# ============================================================
# PREFLIGHT — Both nodes must pass before we start
# ============================================================

log "============================================"
log "=== DUAL-NODE GENERATION — PREFLIGHT ==="
log "============================================"
log "Weight split: spark1=${WEIGHT_S1}% spark2=${WEIGHT_S2}%"

log ""
log "--- Preflight: spark1 (localhost) ---"
if ! bash "$WORKDIR/preflight_node.sh" localhost 2>&1 | tee -a "$LOG"; then
    log "FATAL: spark1 preflight failed. Aborting."
    exit 1
fi

log ""
log "--- Preflight: spark2 ($SPARK2_IP) ---"
if ! bash "$WORKDIR/preflight_node.sh" "$SPARK2_IP" 2>&1 | tee -a "$LOG"; then
    log "FATAL: spark2 preflight failed. Aborting."
    exit 1
fi

# ============================================================
# STOP SCORER ON SPARK2 (GPU contention prevention)
# ============================================================

log ""
log "--- Stopping scorer on spark2 (GPU contention) ---"
SCORER_PID=$(ssh "$SPARK2_SSH" "pgrep -f 'video_scorer_api.py' || true" 2>/dev/null)
if [ -n "$SCORER_PID" ]; then
    ssh "$SPARK2_SSH" "kill $SCORER_PID" 2>/dev/null || true
    sleep 2
    # Verify it's dead
    if ssh "$SPARK2_SSH" "pgrep -f 'video_scorer_api.py'" 2>/dev/null; then
        ssh "$SPARK2_SSH" "kill -9 \$(pgrep -f 'video_scorer_api.py')" 2>/dev/null || true
    fi
    log "Scorer stopped on spark2 (was PID $SCORER_PID)"
    echo "SCORER_WAS_RUNNING=true" > "$OUTDIR/.scorer_state"
else
    log "Scorer was not running on spark2"
    echo "SCORER_WAS_RUNNING=false" > "$OUTDIR/.scorer_state"
fi

# ============================================================
# BUILD PROMPT × FACE MATRIX
# ============================================================

log ""
log "--- Building job matrix ---"

# Get faces (sorted, excluding face.jpg)
FACES=($(ls "$FACEDIR"/*.jpg 2>/dev/null | grep -v '/face\.jpg$' | sort | head -$MAX_FACES))
NUM_FACES=${#FACES[@]}
log "Faces found: $NUM_FACES"

if [ $NUM_FACES -eq 0 ]; then
    log "FATAL: No face images found in $FACEDIR"
    exit 1
fi

# Build prompts JSON in output dir
python3 -c "
import json, sys
prompts = json.load(open('$WORKDIR/batch_prompts.json'))

top5 = ['testimonial_vulnerable', 'testimonial_angry', 'testimonial_relapse_honest',
        'testimonial_relieved', 'testimonial_hopeful']

prompt_set = '$PROMPT_SET'
if prompt_set == 'top5':
    prompts = [p for p in prompts if p['id'] in top5]
elif prompt_set == 'top10':
    top10 = top5 + ['testimonial_determined', 'testimonial_money', 'education_health',
                     'testimonial_confessional', 'comparison_after']
    prompts = [p for p in prompts if p['id'] in top10]

json.dump(prompts, open('$OUTDIR/prompts.json', 'w'), indent=2)
print(len(prompts))
"
NUM_PROMPTS=$(python3 -c "import json; print(len(json.load(open('$OUTDIR/prompts.json'))))")

# Build the full job list and split between nodes
python3 -c "
import json, os

outdir = '$OUTDIR'
seed = $SEED
w1, w2 = $WEIGHT_S1, $WEIGHT_S2

prompts = json.load(open(os.path.join(outdir, 'prompts.json')))
faces_raw = '''$(printf '%s\n' "${FACES[@]}")'''.strip().split('\n')

jobs = []
for face_path in faces_raw:
    face_name = os.path.basename(face_path).replace('.jpg', '')
    face_file = os.path.basename(face_path)
    for pi, p in enumerate(prompts):
        vid_name = f\"{p['id']}__{face_name}_seed{seed}\"
        jobs.append({
            'face_idx': faces_raw.index(face_path),
            'prompt_idx': pi,
            'vid_name': vid_name,
            'face_file': face_file,
            'prompt_id': p['id'],
            'prompt_text': p['prompt'],
            'seconds': p['seconds']
        })

split_idx = int(len(jobs) * w1 / (w1 + w2))
spark1_jobs = jobs[:split_idx]
spark2_jobs = jobs[split_idx:]

json.dump(spark1_jobs, open(os.path.join(outdir, 'spark1_jobs.json'), 'w'), indent=2)
json.dump(spark2_jobs, open(os.path.join(outdir, 'spark2_jobs.json'), 'w'), indent=2)

print(f'Total: {len(jobs)} | spark1: {len(spark1_jobs)} | spark2: {len(spark2_jobs)}')
" | tee -a "$LOG"

TOTAL_VIDEOS=$(python3 -c "
import json
s1 = len(json.load(open('$OUTDIR/spark1_jobs.json')))
s2 = len(json.load(open('$OUTDIR/spark2_jobs.json')))
print(s1 + s2)
")

log "Matrix: $NUM_PROMPTS prompts × $NUM_FACES faces = $TOTAL_VIDEOS videos"
log "Seed: $SEED | Resume: $RESUME"

if $DRY_RUN; then
    log ""
    log "=== DRY RUN — showing split ==="
    python3 -c "
import json
s1 = json.load(open('$OUTDIR/spark1_jobs.json'))
s2 = json.load(open('$OUTDIR/spark2_jobs.json'))
print(f'spark1 ({len(s1)} jobs):')
for j in s1[:5]: print(f'  {j[\"vid_name\"]}')
if len(s1) > 5: print(f'  ... and {len(s1)-5} more')
print(f'spark2 ({len(s2)} jobs):')
for j in s2[:5]: print(f'  {j[\"vid_name\"]}')
if len(s2) > 5: print(f'  ... and {len(s2)-5} more')
"
    log "=== Remove --dry-run to start generation ==="
    exit 0
fi

# ============================================================
# PREPARE SPARK2 — sync job list + ensure output dir exists
# ============================================================

log ""
log "--- Preparing spark2 ---"

# Create output dir on spark2
ssh "$SPARK2_SSH" "mkdir -p '$SPARK2_OUTDIR'"

# Sync prompts and job list to spark2
scp -q "$OUTDIR/prompts.json" "${SPARK2_SSH}:${SPARK2_OUTDIR}/prompts.json"
scp -q "$OUTDIR/spark2_jobs.json" "${SPARK2_SSH}:${SPARK2_OUTDIR}/spark2_jobs.json"

log "spark2 prepared: $SPARK2_OUTDIR"

# ============================================================
# GENERATE: NODE WORKER SCRIPT (runs on each node)
# ============================================================

# Write the worker script that both nodes will execute
cat > "$OUTDIR/node_worker.sh" << 'WORKER_EOF'
#!/bin/bash
# node_worker.sh — Single-node generation worker
# Called by dual_node_generate.sh. NOT meant to be run directly.
#
# Args: <workdir> <outdir> <facedir> <jobs_json> <seed> <node_name> <resume>

set -uo pipefail

WORKDIR="$1"
OUTDIR="$2"
FACEDIR="$3"
JOBS_JSON="$4"
SEED="$5"
NODE_NAME="$6"
RESUME="$7"

LOG="$OUTDIR/${NODE_NAME}_generation.log"
RESULTS="$OUTDIR/${NODE_NAME}_results.jsonl"
TRACKER="$OUTDIR/${NODE_NAME}_completed.txt"

export PYTHONPATH="${WORKDIR}:${PYTHONPATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
export NCCL_ALGO="^NVLS"
export TORCH_COMPILE_DISABLE=1

mkdir -p "$OUTDIR"
touch "$TRACKER"
touch "$RESULTS"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$NODE_NAME] $1" | tee -a "$LOG"; }

wait_for_gpu() {
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
    pkill -f "torch.distributed.run" 2>/dev/null || true
    sleep 5
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
        echo "{\"node\":\"$NODE_NAME\",\"prompt_id\":\"$vid_name\",\"face\":\"$(basename "$face_path")\",\"seed\":$SEED,\"seconds\":$seconds,\"elapsed\":$elapsed,\"file\":\"$outfile\",\"size\":$filesize,\"status\":\"success\"}" >> "$RESULTS"
        return 0
    else
        log "FAILED: $vid_name (rc=$rc, ${elapsed}s)"
        echo "{\"node\":\"$NODE_NAME\",\"prompt_id\":\"$vid_name\",\"face\":\"$(basename "$face_path")\",\"seed\":$SEED,\"seconds\":$seconds,\"elapsed\":$elapsed,\"status\":\"failed\",\"rc\":$rc}" >> "$RESULTS"
        if [ $rc -eq 137 ]; then
            log "OOM detected (rc=137). Waiting 10s for GPU memory cleanup..."
            sleep 10
        fi
        return 1
    fi
}

# Read jobs from JSON
NUM_JOBS=$(python3 -c "import json; print(len(json.load(open('$JOBS_JSON'))))")
log "Starting $NODE_NAME worker: $NUM_JOBS jobs"

GENERATED=0
FAILED=0
SKIPPED=0

for IDX in $(seq 0 $((NUM_JOBS - 1))); do
    # Extract job fields via Python to handle prompts with quotes/newlines safely
    # Write prompt to temp file to avoid shell escaping issues
    TMPJOB=$(mktemp /tmp/job_XXXXXX)
    python3 -c "
import json
jobs = json.load(open('$JOBS_JSON'))
j = jobs[$IDX]
with open('${TMPJOB}', 'w') as f:
    json.dump(j, f)
"
    VID_NAME=$(python3 -c "import json; print(json.load(open('${TMPJOB}'))['vid_name'])")
    FACE_FILE=$(python3 -c "import json; print(json.load(open('${TMPJOB}'))['face_file'])")
    SECONDS_VAL=$(python3 -c "import json; print(json.load(open('${TMPJOB}'))['seconds'])")
    # Write prompt text to file to preserve newlines/quotes
    python3 -c "import json; print(json.load(open('${TMPJOB}'))['prompt_text'], end='')" > "${TMPJOB}.prompt"
    PROMPT_TEXT=$(cat "${TMPJOB}.prompt")
    rm -f "$TMPJOB" "${TMPJOB}.prompt"
    FACE_PATH="$FACEDIR/$FACE_FILE"

    # Resume support
    if [ "$RESUME" = "true" ] && grep -qF "$VID_NAME" "$TRACKER" 2>/dev/null; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    wait_for_gpu

    TOTAL_DONE=$((GENERATED + FAILED + SKIPPED))
    REMAINING=$((NUM_JOBS - TOTAL_DONE))
    log "[$((TOTAL_DONE + 1))/$NUM_JOBS] (ok=$GENERATED fail=$FAILED skip=$SKIPPED remain=$REMAINING)"

    if generate_video "$PROMPT_TEXT" "$FACE_PATH" "$SECONDS_VAL" "$VID_NAME"; then
        GENERATED=$((GENERATED + 1))
    else
        FAILED=$((FAILED + 1))
        RECENT_FAILS=$(tail -3 "$RESULTS" 2>/dev/null | grep -c '"failed"')
        if [ "$RECENT_FAILS" -ge 3 ]; then
            log "ERROR: 3 consecutive failures. Pausing 30s for GPU recovery..."
            sleep 30
        fi
    fi
done

# Write node summary
log ""
log "=== $NODE_NAME COMPLETE ==="
log "  Jobs: $NUM_JOBS | Generated: $GENERATED | Failed: $FAILED | Skipped: $SKIPPED"

echo "{\"node\":\"$NODE_NAME\",\"total\":$NUM_JOBS,\"generated\":$GENERATED,\"failed\":$FAILED,\"skipped\":$SKIPPED,\"timestamp\":\"$(date -Iseconds)\"}" > "$OUTDIR/${NODE_NAME}_summary.json"
WORKER_EOF

chmod +x "$OUTDIR/node_worker.sh"

# Copy worker script to spark2
scp -q "$OUTDIR/node_worker.sh" "${SPARK2_SSH}:${SPARK2_OUTDIR}/node_worker.sh"

log ""
log "============================================"
log "=== LAUNCHING PARALLEL GENERATION ==="
log "============================================"

# ============================================================
# LAUNCH SPARK1 (background)
# ============================================================

log "Launching spark1 worker (${WEIGHT_S1}% of jobs)..."
bash "$OUTDIR/node_worker.sh" \
    "$WORKDIR" "$OUTDIR" "$FACEDIR" \
    "$OUTDIR/spark1_jobs.json" "$SEED" "spark1" "$RESUME" \
    >> "$LOG" 2>&1 &
SPARK1_PID=$!
log "spark1 PID: $SPARK1_PID"

# ============================================================
# LAUNCH SPARK2 (background via SSH)
# ============================================================

log "Launching spark2 worker (${WEIGHT_S2}% of jobs)..."
ssh "$SPARK2_SSH" "bash '${SPARK2_OUTDIR}/node_worker.sh' \
    '${SPARK2_WORKDIR}' '${SPARK2_OUTDIR}' '${SPARK2_FACEDIR}' \
    '${SPARK2_OUTDIR}/spark2_jobs.json' '$SEED' 'spark2' '$RESUME'" \
    >> "$LOG" 2>&1 &
SPARK2_PID=$!
log "spark2 SSH PID: $SPARK2_PID"

# ============================================================
# PROGRESS MONITOR — poll both nodes every 60s
# ============================================================

log ""
log "--- Monitoring progress (every 60s) ---"

S1_TOTAL=$(python3 -c "import json; print(len(json.load(open('$OUTDIR/spark1_jobs.json'))))")
S2_TOTAL=$(python3 -c "import json; print(len(json.load(open('$OUTDIR/spark2_jobs.json'))))")

monitor_progress() {
    while true; do
        # Check if both workers are done
        S1_ALIVE=true
        S2_ALIVE=true
        kill -0 $SPARK1_PID 2>/dev/null || S1_ALIVE=false
        kill -0 $SPARK2_PID 2>/dev/null || S2_ALIVE=false

        # Count completions
        S1_DONE=$(wc -l < "$OUTDIR/spark1_completed.txt" 2>/dev/null || echo 0)
        S2_DONE=$(ssh "$SPARK2_SSH" "wc -l < '${SPARK2_OUTDIR}/spark2_completed.txt' 2>/dev/null || echo 0" 2>/dev/null || echo 0)
        S2_DONE=$(echo "$S2_DONE" | tr -d '[:space:]')

        COMBINED=$((S1_DONE + S2_DONE))
        log "PROGRESS: spark1=$S1_DONE/$S1_TOTAL (alive=$S1_ALIVE) | spark2=$S2_DONE/$S2_TOTAL (alive=$S2_ALIVE) | total=$COMBINED/$TOTAL_VIDEOS"

        if ! $S1_ALIVE && ! $S2_ALIVE; then
            break
        fi

        sleep 60
    done
}

monitor_progress &
MONITOR_PID=$!

# Wait for both workers to finish
wait $SPARK1_PID
SPARK1_RC=$?
log "spark1 worker exited with rc=$SPARK1_RC"

wait $SPARK2_PID
SPARK2_RC=$?
log "spark2 worker exited with rc=$SPARK2_RC"

# Stop monitor
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

# ============================================================
# RSYNC RESULTS FROM SPARK2 → SPARK1
# ============================================================

log ""
log "--- Syncing spark2 results to spark1 ---"

# Sync all generated videos and metadata
rsync -avz --progress \
    "${SPARK2_SSH}:${SPARK2_OUTDIR}/" \
    "$OUTDIR/spark2_raw/" \
    >> "$LOG" 2>&1

S2_VIDS=$(ls "$OUTDIR/spark2_raw/"*.mp4 2>/dev/null | wc -l)
log "Synced $S2_VIDS videos from spark2"

# ============================================================
# MERGE INTO FINAL OUTPUT
# ============================================================

log ""
log "--- Merging results ---"

FINAL_DIR="$OUTDIR/merged"
mkdir -p "$FINAL_DIR"

# Copy spark1 videos
for f in "$OUTDIR"/*.mp4; do
    [ -f "$f" ] && cp "$f" "$FINAL_DIR/" 2>/dev/null
done

# Copy spark2 videos
for f in "$OUTDIR/spark2_raw/"*.mp4; do
    [ -f "$f" ] && cp "$f" "$FINAL_DIR/" 2>/dev/null
done

TOTAL_MERGED=$(ls "$FINAL_DIR"/*.mp4 2>/dev/null | wc -l)

# Merge results JSONL
cat "$OUTDIR/spark1_results.jsonl" "$OUTDIR/spark2_raw/spark2_results.jsonl" \
    > "$FINAL_DIR/all_results.jsonl" 2>/dev/null || true

# Merge completed trackers
cat "$OUTDIR/spark1_completed.txt" "$OUTDIR/spark2_raw/spark2_completed.txt" \
    > "$FINAL_DIR/all_completed.txt" 2>/dev/null || true

# ============================================================
# RESTART SCORER ON SPARK2 (if it was running before)
# ============================================================

if grep -q "SCORER_WAS_RUNNING=true" "$OUTDIR/.scorer_state" 2>/dev/null; then
    log ""
    log "--- Restarting scorer on spark2 ---"
    ssh "$SPARK2_SSH" "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &" 2>/dev/null
    sleep 3
    if ssh "$SPARK2_SSH" "pgrep -f 'video_scorer_api.py'" 2>/dev/null > /dev/null; then
        log "Scorer restarted on spark2"
    else
        log "WARNING: Failed to restart scorer on spark2"
    fi
fi

# ============================================================
# FINAL SUMMARY
# ============================================================

S1_GEN=$(python3 -c "import json; d=json.load(open('$OUTDIR/spark1_summary.json')); print(d['generated'])" 2>/dev/null || echo "?")
S1_FAIL=$(python3 -c "import json; d=json.load(open('$OUTDIR/spark1_summary.json')); print(d['failed'])" 2>/dev/null || echo "?")
S2_GEN=$(python3 -c "import json; d=json.load(open('$OUTDIR/spark2_raw/spark2_summary.json')); print(d['generated'])" 2>/dev/null || echo "?")
S2_FAIL=$(python3 -c "import json; d=json.load(open('$OUTDIR/spark2_raw/spark2_summary.json')); print(d['failed'])" 2>/dev/null || echo "?")

log ""
log "============================================"
log "=== DUAL-NODE GENERATION COMPLETE ==="
log "============================================"
log "  spark1: generated=$S1_GEN failed=$S1_FAIL (rc=$SPARK1_RC)"
log "  spark2: generated=$S2_GEN failed=$S2_FAIL (rc=$SPARK2_RC)"
log "  Merged: $TOTAL_MERGED videos in $FINAL_DIR"
log "  Log: $LOG"
log "============================================"

# Write final summary
cat > "$OUTDIR/dual_summary.txt" << SUMEOF
========================================
DUAL-NODE GENERATION COMPLETE: $(date)
========================================
spark1: generated=$S1_GEN failed=$S1_FAIL
spark2: generated=$S2_GEN failed=$S2_FAIL
Total merged: $TOTAL_MERGED
Output: $FINAL_DIR
Resolution: 256x448 (9:16 portrait)
Faces: $NUM_FACES | Prompts: $NUM_PROMPTS
Weight: spark1=${WEIGHT_S1}% spark2=${WEIGHT_S2}%
Seed: $SEED
========================================
SUMEOF

log ""
log "To score all videos: bash $WORKDIR/dual_node_score.sh $FINAL_DIR"
