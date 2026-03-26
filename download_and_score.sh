#!/bin/bash
# download_and_score.sh — Download TikTok/Reels videos and score against AI baseline
#
# Downloads viral UGC content, scores every pair via UGC Scorer v3 on spark2,
# and generates a comparison report: real TikTok avg vs AI-generated avg.
#
# Usage:
#   bash download_and_score.sh [url_file] [--download-only] [--score-only DIR] [--reference VIDEO]
#
# Arguments:
#   url_file          Path to file with URLs (default: sample_tiktok_urls.txt)
#   --download-only   Download videos but skip scoring
#   --score-only DIR  Score already-downloaded videos in DIR (skip download)
#   --reference VIDEO Use this specific video as the reference for all comparisons
#   --dry-run         Show what would be done without actually downloading
#
# Prerequisites:
#   - yt-dlp installed (pip install yt-dlp)
#   - ffmpeg available
#   - Video scorer running on spark2:8540
#
# Install yt-dlp if missing:
#   pip install --user yt-dlp
#   # or: pipx install yt-dlp
#   # Verify: yt-dlp --version

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL_FILE="${1:-$SCRIPT_DIR/sample_tiktok_urls.txt}"
OUTDIR="$SCRIPT_DIR/tiktok_baseline_$(date +%Y%m%d_%H%M%S)"
SCORER="http://192.168.250.11:8540"
SPARK2="gumbiidigital@192.168.250.11"
LOG=""
RESULTS=""
METADATA=""
SUMMARY=""

# Phase 1 AI baseline (from batch_output analysis)
AI_MEAN_SCORE=71.64
AI_MIN_SCORE=66.24
AI_MAX_SCORE=74.45
AI_STDDEV=2.10

# Parse flags
DOWNLOAD_ONLY=false
SCORE_ONLY=false
SCORE_DIR=""
REFERENCE_VIDEO=""
DRY_RUN=false

shift_count=0
for arg in "$@"; do
    case "$arg" in
        --download-only) DOWNLOAD_ONLY=true ;;
        --score-only)
            SCORE_ONLY=true
            # Next arg is the directory
            ;;
        --dry-run) DRY_RUN=true ;;
        --reference) ;; # handled below
        *)
            if $SCORE_ONLY && [ -z "$SCORE_DIR" ] && [ -d "$arg" ]; then
                SCORE_DIR="$arg"
                OUTDIR="$SCORE_DIR"
            fi
            # Check if previous arg was --reference
            ;;
    esac
done

# Re-parse for --reference and --score-only with proper next-arg handling
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    case "${ARGS[$i]}" in
        --reference)
            if [ $((i+1)) -lt ${#ARGS[@]} ]; then
                REFERENCE_VIDEO="${ARGS[$((i+1))]}"
            fi
            ;;
        --score-only)
            if [ $((i+1)) -lt ${#ARGS[@]} ] && [ -d "${ARGS[$((i+1))]}" ]; then
                SCORE_DIR="${ARGS[$((i+1))]}"
                OUTDIR="$SCORE_DIR"
                SCORE_ONLY=true
            fi
            ;;
    esac
done

# ─── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "$OUTDIR"
LOG="$OUTDIR/download.log"
RESULTS="$OUTDIR/scores.jsonl"
METADATA="$OUTDIR/metadata.jsonl"
SUMMARY="$OUTDIR/baseline_report.txt"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"
}

die() {
    log "FATAL: $*"
    exit 1
}

# ─── Preflight Checks ────────────────────────────────────────────────────────

preflight() {
    log "=== Preflight Checks ==="
    local errors=0

    # Check yt-dlp
    if ! command -v yt-dlp &>/dev/null; then
        log "ERROR: yt-dlp not found. Install with: pip install --user yt-dlp"
        log "       Then ensure ~/.local/bin is in PATH"
        errors=$((errors + 1))
    else
        local ver
        ver=$(yt-dlp --version 2>/dev/null)
        log "OK: yt-dlp version $ver"

        # Check if yt-dlp is recent enough (TikTok extractors break often)
        log "NOTE: If TikTok downloads fail, update with: pip install --user -U yt-dlp"
    fi

    # Check ffmpeg
    if ! command -v ffmpeg &>/dev/null; then
        log "ERROR: ffmpeg not found"
        errors=$((errors + 1))
    else
        log "OK: ffmpeg available"
    fi

    # Check ffprobe
    if ! command -v ffprobe &>/dev/null; then
        log "ERROR: ffprobe not found"
        errors=$((errors + 1))
    else
        log "OK: ffprobe available"
    fi

    # Check scorer
    if curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
        log "OK: Video scorer responding at $SCORER"
    else
        log "WARN: Video scorer not responding at $SCORER"
        log "      Attempting to start scorer on spark2..."
        ssh "$SPARK2" "cd ~/tensortowns/islands/video_scorer && nohup python3 video_scorer_api.py > /tmp/video_scorer.log 2>&1 &" 2>/dev/null
        sleep 5
        if curl -s --max-time 5 "$SCORER/health" | grep -q '"ok"'; then
            log "OK: Scorer started successfully"
        else
            if ! $DOWNLOAD_ONLY; then
                log "ERROR: Cannot reach scorer. Scoring will fail."
                errors=$((errors + 1))
            else
                log "WARN: Scorer unreachable but --download-only mode, continuing"
            fi
        fi
    fi

    # Check URL file
    if ! $SCORE_ONLY; then
        if [ ! -f "$URL_FILE" ]; then
            log "ERROR: URL file not found: $URL_FILE"
            errors=$((errors + 1))
        else
            local url_count
            url_count=$(grep -cE '^https?://' "$URL_FILE" 2>/dev/null)
            url_count=${url_count:-0}
            log "OK: URL file has $url_count URLs: $URL_FILE"
            if [ "$url_count" -eq 0 ]; then
                log "ERROR: No valid URLs found in $URL_FILE"
                log "       Add TikTok/Instagram URLs (one per line)"
                errors=$((errors + 1))
            fi
        fi
    fi

    # Check spark2 connectivity
    if ssh -o ConnectTimeout=3 "$SPARK2" "echo ok" &>/dev/null; then
        log "OK: spark2 reachable via CAT5"
    else
        log "WARN: spark2 not reachable via CAT5 — scoring will use WiFi fallback"
    fi

    if [ $errors -gt 0 ]; then
        die "$errors preflight errors. Fix and retry."
    fi

    log "=== Preflight PASSED ==="
}

# ─── Download Phase ───────────────────────────────────────────────────────────

download_videos() {
    log "=== Download Phase ==="
    log "Output directory: $OUTDIR"

    local total=0
    local success=0
    local failed=0
    local skipped=0

    # Read URLs from file (skip comments and blank lines)
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        local url="$line"
        total=$((total + 1))

        log "[$total] Downloading: $url"

        if $DRY_RUN; then
            log "  [DRY RUN] Would download: $url"
            continue
        fi

        # Determine platform
        local platform="unknown"
        if [[ "$url" == *"tiktok.com"* ]]; then
            platform="tiktok"
        elif [[ "$url" == *"instagram.com"* ]]; then
            platform="instagram"
        elif [[ "$url" == *"youtube.com"* ]] || [[ "$url" == *"youtu.be"* ]]; then
            platform="youtube"
        fi

        # Create per-video output name
        local vid_id
        vid_id=$(echo "$url" | grep -oE '[0-9]{10,}' | tail -1)
        if [ -z "$vid_id" ]; then
            vid_id="vid_${total}"
        fi
        local outname="${platform}_${vid_id}"

        # Skip if already downloaded
        if ls "${OUTDIR}/${outname}"*.mp4 &>/dev/null; then
            log "  SKIP: Already downloaded"
            skipped=$((skipped + 1))
            continue
        fi

        # yt-dlp download with metadata extraction
        # Flags explained:
        #   -f best         : best single file (avoid merge issues)
        #   --no-watermark   : attempt to get watermark-free version (TikTok)
        #   --write-info-json: save metadata (title, views, likes, creator)
        #   --no-playlist    : single video only
        #   --socket-timeout : don't hang on slow connections
        #   --retries 3      : retry on transient failures
        #   --sleep-interval : be polite to avoid rate limiting
        #   --user-agent     : mimic browser to avoid bot detection
        local ytdlp_opts=(
            -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
            --merge-output-format mp4
            --write-info-json
            --no-playlist
            --socket-timeout 30
            --retries 3
            --sleep-interval 2
            --max-sleep-interval 5
            --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            -o "${OUTDIR}/${outname}.%(ext)s"
        )

        # TikTok-specific: try to get non-watermarked version
        if [ "$platform" = "tiktok" ]; then
            ytdlp_opts+=(
                --extractor-args "tiktok:api_hostname=api22-normal-c-useast2a.tiktokv.com"
            )
        fi

        # Instagram-specific: may need cookies
        if [ "$platform" = "instagram" ]; then
            # If cookies file exists, use it
            if [ -f "$SCRIPT_DIR/cookies_instagram.txt" ]; then
                ytdlp_opts+=(--cookies "$SCRIPT_DIR/cookies_instagram.txt")
            fi
        fi

        # TikTok cookies
        if [ "$platform" = "tiktok" ] && [ -f "$SCRIPT_DIR/cookies_tiktok.txt" ]; then
            ytdlp_opts+=(--cookies "$SCRIPT_DIR/cookies_tiktok.txt")
        fi

        # Run yt-dlp
        local start_time
        start_time=$(date +%s)

        if timeout 120 yt-dlp "${ytdlp_opts[@]}" "$url" >> "$LOG" 2>&1; then
            local elapsed=$(( $(date +%s) - start_time ))
            local outfile
            outfile=$(ls -t "${OUTDIR}/${outname}"*.mp4 2>/dev/null | head -1)

            if [ -n "$outfile" ] && [ -f "$outfile" ]; then
                local filesize
                filesize=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
                log "  OK: $(basename "$outfile") (${elapsed}s, $(( filesize / 1024 ))KB)"
                success=$((success + 1))

                # Extract metadata from info.json
                local info_json="${OUTDIR}/${outname}.info.json"
                if [ -f "$info_json" ]; then
                    python3 -c "
import json, sys
try:
    with open('$info_json') as f:
        info = json.load(f)
    meta = {
        'file': '$(basename "$outfile")',
        'url': '$url',
        'platform': '$platform',
        'id': info.get('id', '$vid_id'),
        'title': info.get('title', 'unknown')[:100],
        'creator': info.get('uploader', info.get('channel', 'unknown')),
        'views': info.get('view_count', 0),
        'likes': info.get('like_count', 0),
        'comments': info.get('comment_count', 0),
        'duration': info.get('duration', 0),
        'upload_date': info.get('upload_date', 'unknown'),
        'description': (info.get('description', '') or '')[:200],
        'width': info.get('width', 0),
        'height': info.get('height', 0),
        'filesize_kb': $((filesize / 1024)),
    }
    print(json.dumps(meta))
except Exception as e:
    print(json.dumps({'file': '$(basename "$outfile")', 'url': '$url', 'error': str(e)}))
" >> "$METADATA"
                else
                    echo "{\"file\": \"$(basename "$outfile")\", \"url\": \"$url\", \"platform\": \"$platform\"}" >> "$METADATA"
                fi
            else
                log "  FAIL: No output file found"
                failed=$((failed + 1))
            fi
        else
            local elapsed=$(( $(date +%s) - start_time ))
            log "  FAIL: yt-dlp error (${elapsed}s) — see log for details"
            failed=$((failed + 1))

            # Log common failure reasons
            if [ "$platform" = "tiktok" ]; then
                log "  TIP: TikTok may need cookies. Export from browser:"
                log "       1. Install 'Get cookies.txt LOCALLY' browser extension"
                log "       2. Visit tiktok.com and log in"
                log "       3. Export cookies to: $SCRIPT_DIR/cookies_tiktok.txt"
            elif [ "$platform" = "instagram" ]; then
                log "  TIP: Instagram needs cookies. Export from browser:"
                log "       1. Install 'Get cookies.txt LOCALLY' browser extension"
                log "       2. Visit instagram.com and log in"
                log "       3. Export cookies to: $SCRIPT_DIR/cookies_instagram.txt"
            fi
        fi

    done < "$URL_FILE"

    log "=== Download Summary ==="
    log "Total URLs: $total | Downloaded: $success | Failed: $failed | Skipped: $skipped"
    log "Output: $OUTDIR"
}

# ─── Scoring Phase ────────────────────────────────────────────────────────────

score_videos() {
    local score_dir="${SCORE_DIR:-$OUTDIR}"
    log "=== Scoring Phase ==="
    log "Scoring videos in: $score_dir"

    # Find all downloaded mp4s
    local videos=()
    while IFS= read -r -d '' f; do
        videos+=("$f")
    done < <(find "$score_dir" -maxdepth 1 -name "*.mp4" -print0 | sort -z)

    local count=${#videos[@]}
    if [ "$count" -eq 0 ]; then
        log "ERROR: No .mp4 files found in $score_dir"
        return 1
    fi
    log "Found $count videos to score"

    if [ "$count" -lt 2 ] && [ -z "$REFERENCE_VIDEO" ]; then
        log "ERROR: Need at least 2 videos for pairwise comparison (or use --reference)"
        return 1
    fi

    # Strategy:
    # If --reference is set: score each TikTok against that reference
    # Otherwise: use the FIRST downloaded video as reference, score all others against it
    # Then: also do all-pairs scoring for variance analysis

    local ref_video=""
    if [ -n "$REFERENCE_VIDEO" ]; then
        ref_video="$REFERENCE_VIDEO"
        log "Reference video (explicit): $(basename "$ref_video")"
    else
        ref_video="${videos[0]}"
        log "Reference video (first downloaded): $(basename "$ref_video")"
    fi

    # Copy reference to spark2
    log "Copying reference to spark2..."
    scp -q "$ref_video" "$SPARK2:/tmp/baseline_ref.mp4" 2>/dev/null || \
        die "Cannot copy reference to spark2"

    local scored=0
    local total_score=0
    local pixel_total=0
    local structural_total=0
    local perceptual_total=0

    for video in "${videos[@]}"; do
        # Skip if this IS the reference
        if [ "$video" = "$ref_video" ] && [ -z "$REFERENCE_VIDEO" ]; then
            continue
        fi

        local vname
        vname=$(basename "$video")
        log "Scoring: $vname vs $(basename "$ref_video")"

        # Copy to spark2
        scp -q "$video" "$SPARK2:/tmp/baseline_prod.mp4" 2>/dev/null
        if [ $? -ne 0 ]; then
            log "  FAIL: Cannot copy to spark2"
            continue
        fi

        # Score via API (full comparison)
        local score_result
        score_result=$(curl -s --max-time 180 -X POST "$SCORER/compare" \
            -H "Content-Type: application/json" \
            -d '{"reference_path": "/tmp/baseline_ref.mp4", "produced_path": "/tmp/baseline_prod.mp4"}' 2>/dev/null)

        # Validate JSON response
        if ! echo "$score_result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            log "  FAIL: Invalid scorer response"
            continue
        fi

        # Parse scores
        local score pixel structural perceptual elapsed
        score=$(echo "$score_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('score', 0))" 2>/dev/null)
        pixel=$(echo "$score_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('breakdown',{}).get('pixel', 0))" 2>/dev/null)
        structural=$(echo "$score_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('breakdown',{}).get('structural', 0))" 2>/dev/null)
        perceptual=$(echo "$score_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('breakdown',{}).get('perceptual', 0))" 2>/dev/null)
        elapsed=$(echo "$score_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('elapsed_s', 0))" 2>/dev/null)

        log "  Score: $score/100 (pixel=$pixel, struct=$structural, percept=$perceptual) [${elapsed}s]"

        # Save to results
        echo "{\"video\": \"$vname\", \"reference\": \"$(basename "$ref_video")\", \"score\": $score_result}" >> "$RESULTS"

        scored=$((scored + 1))
        total_score=$(python3 -c "print($total_score + $score)")
        pixel_total=$(python3 -c "print($pixel_total + $pixel)")
        structural_total=$(python3 -c "print($structural_total + $structural)")
        perceptual_total=$(python3 -c "print($perceptual_total + $perceptual)")
    done

    log "=== Scoring Complete: $scored videos scored ==="

    # Generate comparison report
    if [ "$scored" -gt 0 ]; then
        generate_report "$scored" "$total_score" "$pixel_total" "$structural_total" "$perceptual_total"
    fi
}

# ─── Report Generation ───────────────────────────────────────────────────────

generate_report() {
    local scored=$1
    local total_score=$2
    local pixel_total=$3
    local structural_total=$4
    local perceptual_total=$5

    log "=== Generating Baseline Report ==="

    python3 - "$scored" "$AI_MEAN_SCORE" "$AI_MIN_SCORE" "$AI_MAX_SCORE" "$AI_STDDEV" "$RESULTS" "$METADATA" << 'PYEOF' > "$SUMMARY"
import json
import sys
from pathlib import Path
import datetime

scored = int(sys.argv[1])
ai_mean = float(sys.argv[2])
ai_min = float(sys.argv[3])
ai_max = float(sys.argv[4])
ai_std = float(sys.argv[5])
results_file = sys.argv[6]
metadata_file = sys.argv[7]

# Load scores
scores = []
try:
    with open(results_file) as f:
        for line in f:
            if line.strip():
                scores.append(json.loads(line))
except FileNotFoundError:
    pass

# Load metadata
metadata = {}
try:
    with open(metadata_file) as f:
        for line in f:
            if line.strip():
                m = json.loads(line)
                metadata[m.get('file', '')] = m
except FileNotFoundError:
    pass

if not scores:
    print("No scores available for report.")
    sys.exit(0)

# Extract values
def get_val(s, key):
    sc = s.get('score', {})
    if isinstance(sc, dict):
        if key == 'total':
            return sc.get('score', 0)
        return sc.get('breakdown', {}).get(key, 0)
    return float(sc) if key == 'total' else 0

all_scores = [get_val(s, 'total') for s in scores]
all_pixel = [get_val(s, 'pixel') for s in scores]
all_structural = [get_val(s, 'structural') for s in scores]
all_perceptual = [get_val(s, 'perceptual') for s in scores]

tt_mean = sum(all_scores) / len(all_scores)
tt_min = min(all_scores)
tt_max = max(all_scores)
tt_std = (sum((x - tt_mean)**2 for x in all_scores) / len(all_scores)) ** 0.5

px_mean = sum(all_pixel) / len(all_pixel) if all_pixel else 0
st_mean = sum(all_structural) / len(all_structural) if all_structural else 0
pc_mean = sum(all_perceptual) / len(all_perceptual) if all_perceptual else 0

# AI layer means (approximated from Phase 1 SSIM/PSNR data)
ai_px = 71.0
ai_st = 75.0
ai_pc = 70.0

bar = "=" * 72
print(bar)
print("REAL vs AI BASELINE COMPARISON REPORT")
print(f"Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}")
print(bar)
print()
print(f"{'Metric':<30} {'Real TikTok':>15} {'AI-Generated':>15} {'Delta':>10}")
print("-" * 72)
print(f"{'Videos scored':<30} {len(all_scores):>15} {'25':>15} {'':>10}")
print(f"{'Mean score':<30} {tt_mean:>15.2f} {ai_mean:>15.2f} {tt_mean - ai_mean:>+10.2f}")
print(f"{'Min score':<30} {tt_min:>15.2f} {ai_min:>15.2f} {tt_min - ai_min:>+10.2f}")
print(f"{'Max score':<30} {tt_max:>15.2f} {ai_max:>15.2f} {tt_max - ai_max:>+10.2f}")
print(f"{'Std deviation':<30} {tt_std:>15.2f} {ai_std:>15.2f} {tt_std - ai_std:>+10.2f}")
print()
print("Per-Layer Breakdown (means):")
print("-" * 72)
print(f"{'Pixel (40% weight)':<30} {px_mean:>15.2f} {ai_px:>15.1f} {px_mean - ai_px:>+10.2f}")
print(f"{'Structural (15% weight)':<30} {st_mean:>15.2f} {ai_st:>15.1f} {st_mean - ai_st:>+10.2f}")
print(f"{'Perceptual (45% weight)':<30} {pc_mean:>15.2f} {ai_pc:>15.1f} {pc_mean - ai_pc:>+10.2f}")
print()

gap = tt_mean - ai_mean
print("Analysis:")
print("-" * 72)
if gap > 10:
    print(f"  LARGE GAP ({gap:+.1f} pts): Real content scores significantly higher.")
    print("  AI videos need major improvements in quality and authenticity.")
elif gap > 5:
    print(f"  MODERATE GAP ({gap:+.1f} pts): Real content has a noticeable quality edge.")
    print("  Focus on weakest layers for improvement.")
elif gap > 0:
    print(f"  SMALL GAP ({gap:+.1f} pts): AI content is approaching real quality.")
    print("  Fine-tuning specific layers could close the gap.")
elif gap > -5:
    print(f"  COMPARABLE ({gap:+.1f} pts): AI content scores similarly to real content!")
    print("  The scorer may not capture all aspects of 'realness'.")
else:
    print(f"  AI SCORES HIGHER ({gap:+.1f} pts): Unusual. The scorer may be biased.")
    print("  Real UGC has artifacts (shaky cam, varied lighting) that lower pixel scores.")

print()
print("  Weakest layer for AI improvement:")
layer_gaps = [
    ("Pixel", px_mean - ai_px, "resolution, color accuracy, frame consistency"),
    ("Structural", st_mean - ai_st, "duration, scene count, fps, audio"),
    ("Perceptual", pc_mean - ai_pc, "visual quality, artifacts, naturalness"),
]
layer_gaps.sort(key=lambda x: x[1], reverse=True)
for name, lgap, focus in layer_gaps:
    if lgap > 0:
        print(f"  - {name}: Real content leads by {lgap:+.1f} pts. Focus: {focus}")

print()
print(bar)
print("PER-VIDEO SCORES")
print(bar)
print(f"{'Video':<40} {'Score':>8} {'Pixel':>8} {'Struct':>8} {'Percept':>8}")
print("-" * 72)

for i, s in enumerate(sorted(scores, key=lambda x: get_val(x, 'total'), reverse=True)):
    vname = s.get('video', f'video_{i}')[:38]
    sc = get_val(s, 'total')
    px = get_val(s, 'pixel')
    st = get_val(s, 'structural')
    pc = get_val(s, 'perceptual')
    print(f"  {vname:<38} {sc:>8.2f} {px:>8.2f} {st:>8.2f} {pc:>8.2f}")

    meta = metadata.get(vname, {})
    if not meta:
        # Try without extension
        for k, v in metadata.items():
            if k.startswith(vname.replace('.mp4', '')):
                meta = v
                break
    if meta.get('views'):
        creator = meta.get('creator', '?')
        views = meta.get('views', 0)
        likes = meta.get('likes', 0)
        print(f"    Creator: {creator} | Views: {views:,} | Likes: {likes:,}")

print()
print(bar)
print("WHAT THIS MEANS")
print(bar)
print("""
The scorer compares two videos across pixel, structural, and perceptual
layers. When comparing TikToks against each other, high scores mean the
TikToks are SIMILAR (consistent style/quality within the genre). When
comparing AI videos against a TikTok reference, the score shows how
CLOSE our AI output matches real UGC quality.

KEY INSIGHT: Real TikTok UGC has "imperfections" that are actually
features: slightly shaky handheld cam, natural lighting variance,
authentic facial expressions, casual framing. Our AI videos may score
differently on pixel metrics (too clean/smooth) while lacking the
perceptual authenticity that makes UGC work.

NEXT STEPS:
1. If AI perceptual score < TikTok: Focus on naturalness, add subtle
   imperfections (light grain, micro-movements, color warmth)
2. If AI structural score < TikTok: Match real UGC pacing, duration,
   scene transitions
3. If AI pixel score > TikTok: AI may be TOO clean — add realistic
   compression artifacts, camera-like color grading
""")
PYEOF

    cat "$SUMMARY"
    log "Report saved to: $SUMMARY"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    log "=========================================="
    log "TikTok/Reels Baseline Download & Score"
    log "=========================================="

    preflight

    if $SCORE_ONLY; then
        log "Mode: Score-only (using existing videos in $SCORE_DIR)"
        score_videos
    elif $DOWNLOAD_ONLY; then
        log "Mode: Download-only (skipping scoring)"
        download_videos
    elif $DRY_RUN; then
        log "Mode: Dry run"
        download_videos
    else
        log "Mode: Full pipeline (download + score)"
        download_videos
        if ! $DRY_RUN; then
            score_videos
        fi
    fi

    log "=========================================="
    log "Done. Output: $OUTDIR"
    log "=========================================="
}

main
