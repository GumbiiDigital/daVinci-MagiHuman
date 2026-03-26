#!/usr/bin/env bash
# continuous_score_loop.sh — Phase 3 continuous scoring + live leaderboard
# Runs every 10 minutes. Scores new videos on spark2, builds leaderboard, copies back.
set -euo pipefail

PHASE3_DIR="$HOME/daVinci-MagiHuman/phase3_output_20260326_100332"
JSONL="$PHASE3_DIR/ugc_scores.jsonl"
LEADERBOARD="$PHASE3_DIR/LEADERBOARD.md"
SPARK2="gumbiidigital@192.168.250.11"
SPARK2_PHASE3="/tmp/score_all/phase3"
SCORER_DIR="~/tensortowns/islands/video_scorer"
LOOP_INTERVAL=600  # 10 minutes
LOCKFILE="/tmp/score_loop.lock"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() { rm -f "$LOCKFILE"; }
trap cleanup EXIT

# Prevent double-run
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "ERROR: Another score loop is running (PID $pid). Exiting."
        exit 1
    fi
fi
echo $$ > "$LOCKFILE"

# Ensure JSONL exists
touch "$JSONL"

round=0
while true; do
    round=$((round + 1))
    log "===== SCORING ROUND $round ====="

    # 1. Count videos on spark2
    spark2_videos=$(ssh "$SPARK2" "ls $SPARK2_PHASE3/*.mp4 2>/dev/null | wc -l" || echo "0")
    log "Videos on spark2: $spark2_videos"

    # 2. Get already-scored filenames
    scored_count=$(wc -l < "$JSONL")
    log "Already scored: $scored_count"

    # 3. Find unscored videos
    # Get list of scored basenames
    scored_list=$(python3 -c "
import json, sys
seen = set()
with open('$JSONL') as f:
    for line in f:
        if line.strip():
            r = json.loads(line)
            seen.add(r['video'].split('/')[-1])
for name in sorted(seen):
    print(name)
" 2>/dev/null || true)

    # Get list of all videos on spark2
    all_on_spark2=$(ssh "$SPARK2" "ls $SPARK2_PHASE3/*.mp4 2>/dev/null" | xargs -I{} basename {} || true)

    # Find unscored
    unscored=""
    unscored_count=0
    while IFS= read -r vid; do
        [ -z "$vid" ] && continue
        if ! echo "$scored_list" | grep -qxF "$vid"; then
            unscored="$unscored $vid"
            unscored_count=$((unscored_count + 1))
        fi
    done <<< "$all_on_spark2"

    log "Unscored videos: $unscored_count"

    if [ "$unscored_count" -gt 0 ]; then
        # 4. Score each unscored video individually on spark2 and append to JSONL
        for vid in $unscored; do
            log "Scoring: $vid"
            result=$(ssh "$SPARK2" "cd $SCORER_DIR && python3 -c \"
import sys, json, os
sys.path.insert(0, '.')
from ugc_scorer.config import ScorerConfig
from ugc_scorer.pipeline import ScoringPipeline
cfg = ScorerConfig(device='cuda')
p = ScoringPipeline(config=cfg, light_mode=False)
r = p.score('$SPARK2_PHASE3/$vid')
print(json.dumps(r, default=str))
\"" 2>/dev/null || echo "")

            if [ -n "$result" ] && echo "$result" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
                echo "$result" >> "$JSONL"
                score=$(echo "$result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['overall_score'])")
                log "  -> Score: $score"
            else
                log "  -> FAILED to score $vid, skipping"
            fi
        done

        new_scored=$(wc -l < "$JSONL")
        log "Total scored after this round: $new_scored"
    fi

    # 5. Generate leaderboard (always, even if no new scores)
    log "Generating leaderboard..."
    python3 - "$JSONL" "$LEADERBOARD" << 'PYEOF'
import json, sys, os
from collections import defaultdict
import statistics
from datetime import datetime

jsonl_path = sys.argv[1]
lb_path = sys.argv[2]

# Load all scores
scores = []
with open(jsonl_path) as f:
    for line in f:
        if line.strip():
            scores.append(json.loads(line))

if not scores:
    with open(lb_path, 'w') as f:
        f.write("# Phase 3 Leaderboard\n\nNo scores yet.\n")
    sys.exit(0)

# Parse face and prompt from filename
# Format: testimonial_{prompt}__{face}_seed42_{dur}_{res}.mp4
def parse_filename(video_path):
    basename = os.path.basename(video_path).replace('.mp4', '')
    # Split on __ to separate prompt from face
    parts = basename.split('__')
    if len(parts) >= 2:
        prompt_part = parts[0].replace('testimonial_', '')
        face_part = parts[1].split('_seed42')[0]
        return prompt_part, face_part
    return 'unknown', 'unknown'

# Build data structures
face_scores = defaultdict(list)
prompt_scores = defaultdict(list)
all_scores = []
content_types = defaultdict(int)
realness_data = []

for s in scores:
    prompt, face = parse_filename(s['video'])
    score = s['overall_score']
    face_scores[face].append(score)
    prompt_scores[prompt].append(score)
    all_scores.append(score)
    content_types[s.get('content_type', 'unknown')] += 1

    # Realness
    face_layer = s.get('layer_scores', {}).get('face', {})
    if face_layer.get('applicable'):
        details = face_layer.get('details', {})
        realness_data.append({
            'video': os.path.basename(s['video']),
            'face': face,
            'prompt': prompt,
            'is_likely_ai': details.get('is_likely_ai', None),
            'realness_score': details.get('realness_score', None),
            'overall_score': score
        })

# Build leaderboard
lines = []
lines.append(f"# Phase 3 Live Leaderboard")
lines.append(f"")
lines.append(f"**Updated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
lines.append(f"**Videos scored:** {len(scores)} / 100")
lines.append(f"")

# Score distribution
lines.append(f"## Score Distribution")
lines.append(f"")
lines.append(f"| Metric | Value |")
lines.append(f"|--------|-------|")
lines.append(f"| Min | {min(all_scores):.1f} |")
lines.append(f"| Max | {max(all_scores):.1f} |")
lines.append(f"| Mean | {statistics.mean(all_scores):.1f} |")
lines.append(f"| Std Dev | {statistics.stdev(all_scores):.2f} |" if len(all_scores) > 1 else f"| Std Dev | N/A |")
lines.append(f"| Median | {statistics.median(all_scores):.1f} |")
lines.append(f"")

# Grade distribution
grades = defaultdict(int)
for s in scores:
    grades[s.get('grade', '?')] += 1
lines.append(f"**Grades:** " + ", ".join(f"{g}: {c}" for g, c in sorted(grades.items())))
lines.append(f"")

# Face rankings
lines.append(f"## Face Rankings (by avg score)")
lines.append(f"")
lines.append(f"| Rank | Face | Avg Score | Count | Min | Max |")
lines.append(f"|------|------|-----------|-------|-----|-----|")
face_ranked = sorted(face_scores.items(), key=lambda x: statistics.mean(x[1]), reverse=True)
for i, (face, sc) in enumerate(face_ranked, 1):
    avg = statistics.mean(sc)
    lines.append(f"| {i} | {face} | {avg:.1f} | {len(sc)} | {min(sc):.1f} | {max(sc):.1f} |")
lines.append(f"")

# Prompt rankings
lines.append(f"## Prompt Rankings (by avg score)")
lines.append(f"")
lines.append(f"| Rank | Prompt | Avg Score | Count | Min | Max |")
lines.append(f"|------|--------|-----------|-------|-----|-----|")
prompt_ranked = sorted(prompt_scores.items(), key=lambda x: statistics.mean(x[1]), reverse=True)
for i, (prompt, sc) in enumerate(prompt_ranked, 1):
    avg = statistics.mean(sc)
    lines.append(f"| {i} | {prompt} | {avg:.1f} | {len(sc)} | {min(sc):.1f} | {max(sc):.1f} |")
lines.append(f"")

# Best individual videos (top 10)
lines.append(f"## Top 10 Videos")
lines.append(f"")
lines.append(f"| Rank | Score | Grade | Face | Prompt |")
lines.append(f"|------|-------|-------|------|--------|")
sorted_scores = sorted(scores, key=lambda x: x['overall_score'], reverse=True)
for i, s in enumerate(sorted_scores[:10], 1):
    prompt, face = parse_filename(s['video'])
    lines.append(f"| {i} | {s['overall_score']:.1f} | {s.get('grade','?')} | {face} | {prompt} |")
lines.append(f"")

# Worst individual videos (bottom 10)
lines.append(f"## Bottom 10 Videos")
lines.append(f"")
lines.append(f"| Rank | Score | Grade | Face | Prompt |")
lines.append(f"|------|-------|-------|------|--------|")
for i, s in enumerate(sorted_scores[-10:], 1):
    prompt, face = parse_filename(s['video'])
    lines.append(f"| {i} | {s['overall_score']:.1f} | {s.get('grade','?')} | {face} | {prompt} |")
lines.append(f"")

# Content type breakdown
lines.append(f"## Content Type Breakdown")
lines.append(f"")
lines.append(f"| Type | Count |")
lines.append(f"|------|-------|")
for ct, c in sorted(content_types.items(), key=lambda x: -x[1]):
    lines.append(f"| {ct} | {c} |")
lines.append(f"")

# Realness analysis
lines.append(f"## Realness Analysis")
lines.append(f"")
if realness_data:
    ai_flagged = sum(1 for r in realness_data if r['is_likely_ai'])
    real_flagged = sum(1 for r in realness_data if not r['is_likely_ai'])
    realness_scores_list = [r['realness_score'] for r in realness_data if r['realness_score'] is not None]
    lines.append(f"| Metric | Value |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Flagged as AI | {ai_flagged}/{len(realness_data)} ({100*ai_flagged/len(realness_data):.0f}%) |")
    lines.append(f"| Flagged as Real | {real_flagged}/{len(realness_data)} ({100*real_flagged/len(realness_data):.0f}%) |")
    if realness_scores_list:
        lines.append(f"| Avg Realness Score | {statistics.mean(realness_scores_list):.1f}/100 |")
        lines.append(f"| Min Realness | {min(realness_scores_list):.1f} |")
        lines.append(f"| Max Realness | {max(realness_scores_list):.1f} |")
    lines.append(f"")

    # Per-face realness
    face_realness = defaultdict(list)
    for r in realness_data:
        if r['realness_score'] is not None:
            face_realness[r['face']].append(r['realness_score'])
    if face_realness:
        lines.append(f"### Per-Face Realness")
        lines.append(f"")
        lines.append(f"| Face | Avg Realness | AI Flagged |")
        lines.append(f"|------|-------------|------------|")
        for face, rs in sorted(face_realness.items(), key=lambda x: statistics.mean(x[1]), reverse=True):
            ai_count = sum(1 for r in realness_data if r['face'] == face and r['is_likely_ai'])
            total = sum(1 for r in realness_data if r['face'] == face)
            lines.append(f"| {face} | {statistics.mean(rs):.1f} | {ai_count}/{total} |")
        lines.append(f"")
else:
    lines.append(f"No face data available.")
    lines.append(f"")

with open(lb_path, 'w') as f:
    f.write('\n'.join(lines))

print(f"Leaderboard written: {len(scores)} videos, {len(face_scores)} faces, {len(prompt_scores)} prompts")
PYEOF

    # 6. Copy leaderboard back (it's already on spark1 since we write to PHASE3_DIR)
    # Also copy JSONL to spark2 for reference
    log "Leaderboard saved to $LEADERBOARD"

    # Print summary
    log "Round $round complete. Next round in $((LOOP_INTERVAL / 60)) minutes."
    echo ""

    sleep "$LOOP_INTERVAL"
done
