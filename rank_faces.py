#!/usr/bin/env python3
"""Rank faces by average UGC Scorer v3 score across all phases."""

import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
import statistics

# Layer keys to extract
LAYER_KEYS = ["technical", "perceptual", "face", "temporal"]

def parse_face_from_filename(video_path: str) -> str:
    r"""Extract face name from video filename.

    Patterns:
      Phase 1 (no face): promptid_seedN_Xs_WxH.mp4 -> "original"
      Phase 2/3 (face):  promptid__facename_seedN_Xs_WxH.mp4 -> facename

    The double underscore (__) separates prompt from face+params.
    Face name ends before _seed\d+.
    """
    basename = os.path.basename(video_path)
    name = basename.replace(".mp4", "")

    # Check for double-underscore pattern (has face name)
    if "__" in name:
        after_prompt = name.split("__", 1)[1]
        # Face name is everything before _seed\d+
        m = re.match(r"(.+?)_seed\d+", after_prompt)
        if m:
            return m.group(1)

    # No face name = phase 1 original
    return "original"


def extract_layer_scores(entry: dict) -> dict:
    """Extract per-layer scores from a score entry."""
    layers = entry.get("layer_scores", {})
    result = {}
    for key in LAYER_KEYS:
        if key in layers:
            result[key] = layers[key].get("score", None)
        else:
            result[key] = None
    return result


def load_jsonl(filepath: str) -> list:
    """Load a JSONL file, returning list of parsed entries."""
    entries = []
    if not os.path.exists(filepath):
        print(f"  WARNING: {filepath} not found, skipping")
        return entries
    with open(filepath) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"  WARNING: {filepath} line {i}: {e}")
    return entries


def smoke_test(entries: list, phase_label: str):
    """Print 3 example filename parses for verification."""
    print(f"\n--- Smoke Test: {phase_label} ---")
    for entry in entries[:3]:
        video = entry.get("video", "")
        face = parse_face_from_filename(video)
        score = entry.get("overall_score", "?")
        print(f"  {os.path.basename(video)}")
        print(f"    -> face: {face}, score: {score}")


def main():
    # --- Locate score files ---
    score_files = []

    # Phase 1 & 2: local copies (rank_faces.sh puts them here)
    local_dir = os.path.dirname(os.path.abspath(__file__))
    cache_dir = os.path.join(local_dir, ".score_cache")

    p1 = os.path.join(cache_dir, "phase1_ugc_scores.jsonl")
    p2 = os.path.join(cache_dir, "phase2_ugc_scores.jsonl")

    # Phase 3: find the latest phase3 output dir
    phase3_dirs = sorted(Path(local_dir).glob("phase3_output_*"))
    p3_candidates = []
    for d in phase3_dirs:
        p3_file = d / "ugc_scores.jsonl"
        if p3_file.exists():
            p3_candidates.append(str(p3_file))

    # Also check for cached phase3
    p3_cached = os.path.join(cache_dir, "phase3_ugc_scores.jsonl")

    # Determine phase 3 file: prefer latest real dir, fallback to cache
    p3 = p3_candidates[-1] if p3_candidates else p3_cached

    score_files = [
        ("Phase 1 (original face)", p1),
        ("Phase 2 (4 faces)", p2),
        ("Phase 3 (20 faces)", p3),
    ]

    print("=" * 70)
    print("FACE RANKING — UGC Scorer v3")
    print("=" * 70)

    # --- Load all data ---
    all_entries = []
    for label, filepath in score_files:
        entries = load_jsonl(filepath)
        print(f"\n  {label}: {len(entries)} scores from {filepath}")
        all_entries.extend(entries)

    print(f"\n  TOTAL: {len(all_entries)} scored videos")

    if not all_entries:
        print("\nERROR: No score data found. Run rank_faces.sh to fetch from spark2.")
        sys.exit(1)

    # --- Smoke test: parse 3 filenames from each phase ---
    p1_entries = load_jsonl(score_files[0][1])
    p2_entries = load_jsonl(score_files[1][1])
    p3_entries = load_jsonl(score_files[2][1])

    if p1_entries:
        smoke_test(p1_entries, "Phase 1")
    if p2_entries:
        smoke_test(p2_entries, "Phase 2")
    if p3_entries:
        smoke_test(p3_entries, "Phase 3")

    # --- Group by face ---
    face_data = defaultdict(lambda: {
        "scores": [],
        "technical": [],
        "perceptual": [],
        "face": [],
        "temporal": [],
    })

    for entry in all_entries:
        video = entry.get("video", "")
        face = parse_face_from_filename(video)
        overall = entry.get("overall_score")
        if overall is None:
            continue

        face_data[face]["scores"].append(overall)
        layers = extract_layer_scores(entry)
        for key in LAYER_KEYS:
            if layers[key] is not None:
                face_data[face][key].append(layers[key])

    # --- Compute stats and rank ---
    rankings = []
    for face, data in face_data.items():
        scores = data["scores"]
        if not scores:
            continue

        entry = {
            "face": face,
            "count": len(scores),
            "mean": statistics.mean(scores),
            "std": statistics.stdev(scores) if len(scores) > 1 else 0.0,
            "min": min(scores),
            "max": max(scores),
        }

        for key in LAYER_KEYS:
            vals = data[key]
            entry[f"{key}_mean"] = statistics.mean(vals) if vals else 0.0

        rankings.append(entry)

    rankings.sort(key=lambda x: x["mean"], reverse=True)

    # --- Output report ---
    print("\n" + "=" * 70)
    print("RANKINGS BY MEAN OVERALL SCORE (descending)")
    print("=" * 70)
    print(f"\n{'#':<4} {'Face':<35} {'Mean':>6} {'Std':>6} {'Min':>6} {'Max':>6} {'N':>4}  {'Tech':>5} {'Perc':>5} {'Face':>5} {'Temp':>5}")
    print("-" * 105)

    for i, r in enumerate(rankings, 1):
        print(f"{i:<4} {r['face']:<35} {r['mean']:>6.1f} {r['std']:>6.1f} {r['min']:>6.1f} {r['max']:>6.1f} {r['count']:>4}  {r['technical_mean']:>5.1f} {r['perceptual_mean']:>5.1f} {r['face_mean']:>5.1f} {r['temporal_mean']:>5.1f}")

    # --- Summary ---
    print(f"\n{'=' * 70}")
    print("SUMMARY")
    print(f"{'=' * 70}")
    print(f"  Total faces:  {len(rankings)}")
    print(f"  Total scores: {len(all_entries)}")
    if rankings:
        best = rankings[0]
        worst = rankings[-1]
        print(f"  Best face:    {best['face']} (mean {best['mean']:.1f}, n={best['count']})")
        print(f"  Worst face:   {worst['face']} (mean {worst['mean']:.1f}, n={worst['count']})")

        # Spread
        spread = best["mean"] - worst["mean"]
        print(f"  Spread:       {spread:.1f} points")

        # Phase 1 baseline comparison
        original = next((r for r in rankings if r["face"] == "original"), None)
        if original:
            print(f"\n  Phase 1 baseline (original): mean {original['mean']:.1f} (n={original['count']})")
            print(f"  Faces beating baseline:")
            for r in rankings:
                if r["face"] != "original" and r["mean"] > original["mean"]:
                    delta = r["mean"] - original["mean"]
                    print(f"    {r['face']}: +{delta:.1f}")
            print(f"  Faces below baseline:")
            for r in rankings:
                if r["face"] != "original" and r["mean"] <= original["mean"]:
                    delta = r["mean"] - original["mean"]
                    print(f"    {r['face']}: {delta:.1f}")

    print()


if __name__ == "__main__":
    main()
