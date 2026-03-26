#!/bin/bash
# dual_node_score.sh — Batch-score all generated videos using spark2's UGC Scorer
# Copies videos to spark2, runs batch_score.py, copies results back.
#
# Usage:
#   bash dual_node_score.sh /path/to/video/dir
#   bash dual_node_score.sh /path/to/video/dir --light       # Faster, less accurate
#   bash dual_node_score.sh /path/to/video/dir --csv scores  # Also output CSV
#
# Prerequisites:
#   - spark2 reachable via CAT5 (192.168.250.11)
#   - No active generation on spark2 GPU
#   - UGC Scorer v3 installed on spark2

set -uo pipefail

# ============================================================
# CONFIG
# ============================================================

SPARK2_IP="192.168.250.11"
SPARK2_USER="gumbiidigital"
SPARK2_SSH="${SPARK2_USER}@${SPARK2_IP}"
SPARK2_SCORER_DIR="/home/gumbiidigital/tensortowns/islands/video_scorer"
SPARK2_STAGING="/tmp/dual_score_staging"

SCORER_API_PORT=8540

# Parse args
VIDEO_DIR="${1:?Usage: bash dual_node_score.sh /path/to/videos [--light] [--csv name]}"
shift

EXTRA_ARGS=""
CSV_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --light) EXTRA_ARGS="$EXTRA_ARGS --light"; shift ;;
        --csv) CSV_NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ ! -d "$VIDEO_DIR" ]; then
    echo "FATAL: Directory not found: $VIDEO_DIR"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="$VIDEO_DIR/scoring_${TIMESTAMP}.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# Count videos
NUM_VIDEOS=$(ls "$VIDEO_DIR"/*.mp4 2>/dev/null | wc -l)
if [ "$NUM_VIDEOS" -eq 0 ]; then
    log "FATAL: No .mp4 files found in $VIDEO_DIR"
    exit 1
fi

log "============================================"
log "=== DUAL-NODE SCORING ==="
log "============================================"
log "Videos: $NUM_VIDEOS in $VIDEO_DIR"
log "Scorer: spark2 ($SPARK2_IP)"

# ============================================================
# PREFLIGHT — verify spark2 is reachable and scorer works
# ============================================================

log ""
log "--- Preflight ---"

# Check SSH
if ! ssh -o ConnectTimeout=5 "$SPARK2_SSH" "echo OK" > /dev/null 2>&1; then
    log "FATAL: Cannot SSH to spark2 ($SPARK2_IP)"
    exit 1
fi
log "  [PASS] SSH to spark2"

# Check no generation running on spark2
if ssh "$SPARK2_SSH" "pgrep -f 'inference/pipeline/entry.py'" > /dev/null 2>&1; then
    log "FATAL: Generation is running on spark2. Wait for it to finish or stop it first."
    exit 1
fi
log "  [PASS] No active generation on spark2"

# Check batch_score.py exists
if ! ssh "$SPARK2_SSH" "test -f $SPARK2_SCORER_DIR/batch_score.py" 2>/dev/null; then
    log "FATAL: batch_score.py not found on spark2"
    exit 1
fi
log "  [PASS] batch_score.py exists"

# Check GPU available
if ! ssh "$SPARK2_SSH" "nvidia-smi > /dev/null 2>&1"; then
    log "FATAL: nvidia-smi failed on spark2"
    exit 1
fi
log "  [PASS] GPU available on spark2"

# ============================================================
# STOP SCORER API (if running — GPU contention)
# ============================================================

log ""
log "--- Stopping scorer API on spark2 (if running) ---"

SCORER_PID=$(ssh "$SPARK2_SSH" "pgrep -f 'video_scorer_api.py' || true" 2>/dev/null)
SCORER_WAS_RUNNING=false
if [ -n "$SCORER_PID" ]; then
    ssh "$SPARK2_SSH" "kill $SCORER_PID" 2>/dev/null || true
    sleep 2
    SCORER_WAS_RUNNING=true
    log "Stopped scorer API (was PID $SCORER_PID)"
else
    log "Scorer API was not running"
fi

# ============================================================
# TRANSFER VIDEOS TO SPARK2
# ============================================================

log ""
log "--- Transferring $NUM_VIDEOS videos to spark2 ---"

# Create staging dir on spark2
ssh "$SPARK2_SSH" "rm -rf '$SPARK2_STAGING' && mkdir -p '$SPARK2_STAGING'"

# rsync videos (CAT5 direct link — should be ~300MB/s)
TRANSFER_START=$(date +%s)
rsync -avz --progress \
    "$VIDEO_DIR"/*.mp4 \
    "${SPARK2_SSH}:${SPARK2_STAGING}/" \
    2>&1 | tee -a "$LOG"
TRANSFER_END=$(date +%s)
TRANSFER_ELAPSED=$((TRANSFER_END - TRANSFER_START))

# Verify transfer
REMOTE_COUNT=$(ssh "$SPARK2_SSH" "ls '$SPARK2_STAGING'/*.mp4 2>/dev/null | wc -l" 2>/dev/null)
log "Transferred: $REMOTE_COUNT/$NUM_VIDEOS videos in ${TRANSFER_ELAPSED}s"

if [ "$REMOTE_COUNT" -ne "$NUM_VIDEOS" ]; then
    log "WARNING: Transfer count mismatch. Local=$NUM_VIDEOS Remote=$REMOTE_COUNT"
    log "Continuing with $REMOTE_COUNT videos..."
fi

# ============================================================
# RUN BATCH SCORING ON SPARK2
# ============================================================

log ""
log "--- Running batch scorer on spark2 ---"

SCORE_START=$(date +%s)

# Build scoring command
SCORE_CMD="cd $SPARK2_SCORER_DIR && python3 batch_score.py '$SPARK2_STAGING'"
SCORE_CMD="$SCORE_CMD --output '$SPARK2_STAGING/ugc_scores.jsonl'"

if [ -n "$CSV_NAME" ]; then
    SCORE_CMD="$SCORE_CMD --csv '$SPARK2_STAGING/${CSV_NAME}.csv'"
fi

if [ -n "$EXTRA_ARGS" ]; then
    SCORE_CMD="$SCORE_CMD $EXTRA_ARGS"
fi

log "Command: $SCORE_CMD"

# Run scoring (can take a while — 30s+ per video)
ssh "$SPARK2_SSH" "$SCORE_CMD" 2>&1 | tee -a "$LOG"
SCORE_RC=${PIPESTATUS[0]}

SCORE_END=$(date +%s)
SCORE_ELAPSED=$((SCORE_END - SCORE_START))

if [ $SCORE_RC -ne 0 ]; then
    log "WARNING: Batch scorer exited with rc=$SCORE_RC"
fi

PER_VIDEO=$(( REMOTE_COUNT > 0 ? SCORE_ELAPSED / REMOTE_COUNT : 0 ))
log "Scoring took ${SCORE_ELAPSED}s (~${PER_VIDEO}s per video)"

# ============================================================
# COPY RESULTS BACK TO SPARK1
# ============================================================

log ""
log "--- Copying results back to spark1 ---"

# Copy JSONL results
scp -q "${SPARK2_SSH}:${SPARK2_STAGING}/ugc_scores.jsonl" \
    "$VIDEO_DIR/ugc_scores.jsonl" 2>/dev/null && \
    log "Copied: ugc_scores.jsonl" || \
    log "WARNING: Failed to copy ugc_scores.jsonl"

# Copy CSV if requested
if [ -n "$CSV_NAME" ]; then
    scp -q "${SPARK2_SSH}:${SPARK2_STAGING}/${CSV_NAME}.csv" \
        "$VIDEO_DIR/${CSV_NAME}.csv" 2>/dev/null && \
        log "Copied: ${CSV_NAME}.csv" || \
        log "WARNING: Failed to copy ${CSV_NAME}.csv"
fi

# Copy any report files the scorer may have generated
scp -q "${SPARK2_SSH}:${SPARK2_STAGING}/"*.txt \
    "$VIDEO_DIR/" 2>/dev/null || true

# ============================================================
# CLEANUP SPARK2 STAGING
# ============================================================

log ""
log "--- Cleaning up spark2 staging ---"
ssh "$SPARK2_SSH" "rm -rf '$SPARK2_STAGING'"
log "Staging dir removed"

# ============================================================
# RESTART SCORER API (if it was running before)
# ============================================================

if $SCORER_WAS_RUNNING; then
    log ""
    log "--- Restarting scorer API on spark2 ---"
    ssh "$SPARK2_SSH" "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &" 2>/dev/null
    sleep 3
    if ssh "$SPARK2_SSH" "pgrep -f 'video_scorer_api.py'" > /dev/null 2>&1; then
        log "Scorer API restarted"
    else
        log "WARNING: Failed to restart scorer API"
    fi
fi

# ============================================================
# SUMMARY
# ============================================================

log ""
log "============================================"
log "=== SCORING COMPLETE ==="
log "============================================"

if [ -f "$VIDEO_DIR/ugc_scores.jsonl" ]; then
    NUM_SCORED=$(wc -l < "$VIDEO_DIR/ugc_scores.jsonl" 2>/dev/null || echo 0)
    log "  Scored: $NUM_SCORED/$NUM_VIDEOS videos"
    log "  Results: $VIDEO_DIR/ugc_scores.jsonl"

    # Print top/bottom scores
    python3 -c "
import json

scores = []
with open('$VIDEO_DIR/ugc_scores.jsonl') as f:
    for line in f:
        if line.strip():
            d = json.loads(line)
            name = d.get('file', d.get('video', 'unknown'))
            # Handle different score formats
            if isinstance(d.get('score'), dict):
                val = d['score'].get('overall', d['score'].get('score', 0))
            elif isinstance(d.get('score'), (int, float)):
                val = d['score']
            elif isinstance(d.get('overall_score'), (int, float)):
                val = d['overall_score']
            else:
                val = 0
            scores.append((name, val))

if scores:
    scores.sort(key=lambda x: -x[1])
    print()
    print('Top 5:')
    for name, val in scores[:5]:
        print(f'  {val:6.2f}  {name}')
    print()
    print('Bottom 5:')
    for name, val in scores[-5:]:
        print(f'  {val:6.2f}  {name}')
    print()
    avg = sum(v for _, v in scores) / len(scores)
    print(f'Mean score: {avg:.2f} (n={len(scores)})')
" 2>&1 | tee -a "$LOG"
else
    log "  WARNING: No scores file found"
fi

log ""
log "  Transfer time: ${TRANSFER_ELAPSED}s"
log "  Scoring time: ${SCORE_ELAPSED}s"
log "  Log: $LOG"
log "============================================"
