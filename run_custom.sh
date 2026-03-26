#!/usr/bin/env bash
# Run DaVinci-MagiHuman with custom prompt and image
# Usage: TORCH_COMPILE_DISABLE=1 bash run_custom.sh <prompt_file> <image_path> [seconds] [output_name]

set -euo pipefail

PROMPT_FILE="${1:?Usage: run_custom.sh <prompt_file> <image_path> [seconds] [output_name]}"
IMAGE_PATH="${2:?Usage: run_custom.sh <prompt_file> <image_path> [seconds] [output_name]}"
SECONDS_LEN="${3:-10}"
OUTPUT_NAME="${4:-output_custom_$(date '+%Y%m%d_%H%M%S')}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

export MASTER_ADDR="${MASTER_ADDR:-localhost}"
export MASTER_PORT="${MASTER_PORT:-6010}"
export NNODES="${NNODES:-1}"
export NODE_RANK="${NODE_RANK:-0}"
export GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
export WORLD_SIZE="$((GPUS_PER_NODE * NNODES))"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export NCCL_ALGO="${NCCL_ALGO:-^NVLS}"
export PYTHONPATH="${PROJECT_ROOT}:${PYTHONPATH:-}"

DISTRIBUTED_ARGS="--nnodes=${NNODES} --node_rank=${NODE_RANK} --nproc_per_node=${GPUS_PER_NODE} --rdzv-backend=c10d --rdzv-endpoint=${MASTER_ADDR}:${MASTER_PORT}"

torchrun ${DISTRIBUTED_ARGS} inference/pipeline/entry.py \
  --config-load-path example/distill/config.json \
  --prompt "$(<"$PROMPT_FILE")" \
  --image_path "$IMAGE_PATH" \
  --seconds "$SECONDS_LEN" \
  --br_width 448 \
  --br_height 256 \
  --output_path "$OUTPUT_NAME" \
  2>&1 | tee "log_${OUTPUT_NAME}_$(date '+%Y%m%d_%H%M%S').log"
