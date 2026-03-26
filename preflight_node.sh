#!/bin/bash
# preflight_node.sh — Verify a node can run daVinci-MagiHuman before launching generation
# Usage: bash preflight_node.sh [hostname]
# If hostname is omitted, checks localhost.
#
# EXIT 0 = all clear, EXIT 1 = failed

set -e

HOST="${1:-localhost}"
FAIL=0

run_check() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    if [ "$HOST" = "localhost" ]; then
        result=$(eval "$cmd" 2>/dev/null)
    else
        result=$(ssh "gumbiidigital@$HOST" "$cmd" 2>/dev/null)
    fi

    if echo "$result" | grep -q "$expected"; then
        echo "  [PASS] $name"
    else
        echo "  [FAIL] $name — got: '$result', expected: '$expected'"
        FAIL=1
    fi
}

echo "=== daVinci-MagiHuman Preflight Check: $HOST ==="
echo ""

# 1. GPU
echo "--- Hardware ---"
run_check "CUDA available" \
    "python3 -c 'import torch; print(torch.cuda.is_available())'" \
    "True"

run_check "GPU detected" \
    "nvidia-smi --query-gpu=name --format=csv,noheader" \
    "NVIDIA"

# 2. Python modules
echo ""
echo "--- Python Dependencies ---"
for mod in torch torchvision torchaudio transformers magi_compiler unfoldNd timm; do
    run_check "import $mod" \
        "python3 -c 'import $mod; print(\"OK\")'" \
        "OK"
done

# 3. Model weights — check actual file sizes, not just existence
echo ""
echo "--- Model Weights (size check) ---"

run_check "distill weights (>50GB)" \
    "du -s ~/davinci-magihuman/distill/ | awk '{print (\$1 > 50000000) ? \"OK\" : \"TOO_SMALL\"}'" \
    "OK"

run_check "stable-audio model.ckpt (>4GB)" \
    "stat -c%s ~/davinci-magihuman/externals/stable-audio-open-1.0/model.ckpt 2>/dev/null | awk '{print (\$1 > 4000000000) ? \"OK\" : \"TOO_SMALL\"}'" \
    "OK"

run_check "t5gemma weights (>30GB)" \
    "du -s ~/davinci-magihuman/externals/t5gemma-9b-9b-ul2/ | awk '{print (\$1 > 30000000) ? \"OK\" : \"TOO_SMALL\"}'" \
    "OK"

run_check "Wan2.2 VAE (>2GB)" \
    "du -s ~/davinci-magihuman/externals/Wan2.2-TI2V-5B/ | awk '{print (\$1 > 2000000) ? \"OK\" : \"TOO_SMALL\"}'" \
    "OK"

run_check "turbo_vae checkpoint (>1GB)" \
    "stat -c%s ~/davinci-magihuman/turbo_vae/checkpoint-340000.ckpt 2>/dev/null | awk '{print (\$1 > 1000000000) ? \"OK\" : \"TOO_SMALL\"}'" \
    "OK"

# 4. Code
echo ""
echo "--- Code ---"
run_check "entry.py exists" \
    "test -f ~/daVinci-MagiHuman/inference/pipeline/entry.py && echo OK" \
    "OK"

run_check "config.json exists" \
    "test -f ~/daVinci-MagiHuman/example/distill/config.json && echo OK" \
    "OK"

run_check "PYTHONPATH importable" \
    "cd ~/daVinci-MagiHuman && PYTHONPATH=. python3 -c 'from inference.pipeline import MagiPipeline; print(\"OK\")'" \
    "OK"

# 5. Face images
echo ""
echo "--- Assets ---"
run_check "face images (>10)" \
    "ls ~/projects/real_face_test/*.jpg 2>/dev/null | wc -l | awk '{print (\$1 > 10) ? \"OK\" : \"MISSING\"}'" \
    "OK"

# 6. Network (if remote)
if [ "$HOST" != "localhost" ]; then
    echo ""
    echo "--- Network ---"
    run_check "SSH reachable" \
        "echo OK" \
        "OK"
fi

# Summary
echo ""
echo "==================================="
if [ $FAIL -eq 0 ]; then
    echo "PREFLIGHT: ALL CHECKS PASSED"
    echo "Node $HOST is ready for daVinci generation."
    exit 0
else
    echo "PREFLIGHT: FAILED — fix issues above before launching"
    exit 1
fi
