#!/usr/bin/env python3
"""
analyze_phase1.py — Full Phase 1 analysis: scores + prompts + patterns
Run after Phase 1 completes to generate the full report.
"""
import json, os, sys, re
from collections import defaultdict

RESULTS_DIR = os.path.expanduser("~/daVinci-MagiHuman/batch_output_20260325_154259")
RESULTS_FILE = os.path.join(RESULTS_DIR, "results_original.jsonl")
PROMPTS_FILE = os.path.join(RESULTS_DIR, "batch_prompts.json")
REPORT_FILE = os.path.join(RESULTS_DIR, "phase1_analysis.txt")

# Load prompts
with open(PROMPTS_FILE) as f:
    prompts = {p["id"]: p for p in json.load(f)}

# Load scores
scores = []
with open(RESULTS_FILE) as f:
    for line in f:
        d = json.loads(line)
        s = d["score"]
        scores.append({
            "id": d["prompt_id"],
            "score": s["score"],
            "ssim": s["pixel_detail"]["avg_ssim"],
            "psnr": s["pixel_detail"]["avg_psnr"],
            "structural": s["structural_detail"]["score"],
            "prompt": prompts.get(d["prompt_id"], {}).get("prompt", "N/A"),
            "seconds": prompts.get(d["prompt_id"], {}).get("seconds", 0),
        })

scores.sort(key=lambda x: -x["score"])

# Categorize prompts
def categorize(prompt_id):
    if prompt_id.startswith("testimonial_"):
        return "testimonial"
    elif prompt_id.startswith("hook_"):
        return "hook"
    elif prompt_id.startswith("cta_"):
        return "cta"
    elif prompt_id.startswith("comparison_"):
        return "comparison"
    else:
        return "other"

# Pattern analysis
def extract_features(prompt_text):
    features = {}
    # Setting
    settings = ["car", "kitchen", "bedroom", "bathroom", "desk", "office", "couch", "living room",
                "park", "bench", "outside", "bar", "mirror", "floor", "wall", "bed"]
    for s in settings:
        if s.lower() in prompt_text.lower():
            features["setting"] = s
            break
    else:
        features["setting"] = "unknown"

    # Lighting
    if "golden hour" in prompt_text.lower():
        features["lighting"] = "golden_hour"
    elif "neon" in prompt_text.lower():
        features["lighting"] = "neon"
    elif "dim" in prompt_text.lower() or "lamp" in prompt_text.lower():
        features["lighting"] = "dim/lamp"
    elif "bright" in prompt_text.lower() or "white" in prompt_text.lower():
        features["lighting"] = "bright"
    elif "natural" in prompt_text.lower() or "daylight" in prompt_text.lower():
        features["lighting"] = "natural"
    elif "dramatic" in prompt_text.lower() or "side light" in prompt_text.lower():
        features["lighting"] = "dramatic"
    elif "overhead" in prompt_text.lower() or "cool" in prompt_text.lower():
        features["lighting"] = "cool/overhead"
    else:
        features["lighting"] = "other"

    # Emotion
    emotions = ["frustrat", "hope", "angry", "anger", "relief", "vulnerable", "defiant",
                "confess", "exhaust", "determined", "social", "milestone", "relapse",
                "money", "taste", "shocking", "relatable", "question"]
    for e in emotions:
        if e.lower() in prompt_text.lower():
            features["emotion"] = e
            break
    else:
        features["emotion"] = "neutral"

    # Framing
    if "tight close" in prompt_text.lower():
        features["framing"] = "tight_closeup"
    elif "medium close" in prompt_text.lower():
        features["framing"] = "medium_closeup"
    else:
        features["framing"] = "other"

    return features

# Build report
report = []
report.append("=" * 80)
report.append("PHASE 1 ANALYSIS — DaVinci-MagiHuman Batch Results")
report.append("=" * 80)
report.append(f"\nTotal prompts scored: {len(scores)}")
report.append(f"Mean score: {sum(s['score'] for s in scores)/len(scores):.2f}")
report.append(f"Min: {scores[-1]['score']:.2f} ({scores[-1]['id']})")
report.append(f"Max: {scores[0]['score']:.2f} ({scores[0]['id']})")
report.append(f"Std dev: {(sum((s['score'] - sum(x['score'] for x in scores)/len(scores))**2 for s in scores)/len(scores))**0.5:.2f}")

report.append("\n" + "=" * 80)
report.append("FULL RANKINGS")
report.append("=" * 80)
report.append(f"\n{'Rank':<5} {'Prompt ID':<35} {'Score':>6} {'SSIM':>7} {'PSNR':>6} {'Sec':>4}")
report.append("-" * 70)
for i, s in enumerate(scores, 1):
    report.append(f"{i:<5} {s['id']:<35} {s['score']:>6.2f} {s['ssim']:>7.4f} {s['psnr']:>6.2f} {s['seconds']:>4}")

# Category analysis
report.append("\n" + "=" * 80)
report.append("CATEGORY ANALYSIS")
report.append("=" * 80)
cat_scores = defaultdict(list)
for s in scores:
    cat_scores[categorize(s["id"])].append(s["score"])

for cat, vals in sorted(cat_scores.items(), key=lambda x: -sum(x[1])/len(x[1])):
    avg = sum(vals) / len(vals)
    report.append(f"\n  {cat.upper()} (n={len(vals)}): avg={avg:.2f}, range={min(vals):.2f}-{max(vals):.2f}")

# Feature correlation
report.append("\n" + "=" * 80)
report.append("FEATURE PATTERNS — What correlates with high scores?")
report.append("=" * 80)

feature_scores = defaultdict(lambda: defaultdict(list))
for s in scores:
    features = extract_features(s["prompt"])
    for feat_name, feat_val in features.items():
        feature_scores[feat_name][feat_val].append(s["score"])

for feat_name, vals in feature_scores.items():
    report.append(f"\n  {feat_name.upper()}:")
    sorted_vals = sorted(vals.items(), key=lambda x: -sum(x[1])/len(x[1]))
    for val, sc in sorted_vals:
        avg = sum(sc) / len(sc)
        report.append(f"    {val:<20} avg={avg:.2f} (n={len(sc)})")

# Duration analysis
report.append("\n" + "=" * 80)
report.append("DURATION ANALYSIS")
report.append("=" * 80)
dur_scores = defaultdict(list)
for s in scores:
    dur_scores[s["seconds"]].append(s["score"])
for dur, vals in sorted(dur_scores.items()):
    avg = sum(vals) / len(vals)
    report.append(f"  {dur}s: avg={avg:.2f} (n={len(vals)})")

# Top 5 with full prompt text
report.append("\n" + "=" * 80)
report.append("TOP 5 — FULL PROMPT TEXT")
report.append("=" * 80)
for i, s in enumerate(scores[:5], 1):
    report.append(f"\n--- #{i}: {s['id']} (score: {s['score']:.2f}) ---")
    report.append(s["prompt"])

# Bottom 5 with full prompt text
report.append("\n" + "=" * 80)
report.append("BOTTOM 5 — FULL PROMPT TEXT")
report.append("=" * 80)
for i, s in enumerate(scores[-5:], len(scores)-4):
    report.append(f"\n--- #{i}: {s['id']} (score: {s['score']:.2f}) ---")
    report.append(s["prompt"])

report_text = "\n".join(report)
with open(REPORT_FILE, "w") as f:
    f.write(report_text)

print(report_text)
print(f"\nReport saved to {REPORT_FILE}")
