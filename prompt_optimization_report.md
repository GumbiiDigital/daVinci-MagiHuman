# Prompt Optimization Report — UGC Scorer v3 Analysis

Generated: 2026-03-26
Total videos analyzed: 73 (Phase 1: 50, Phase 2: 13, Phase 3: 10)
Unmatched scores (experimental/no prompt): 15

## Overall Score Distribution

- Mean: 77.9
- Min: 71.9
- Max: 81.5
- Std Dev: 2.6

### Phase1 (n=50)
- Overall: 78.6 avg (range 77.1–81.5)
- Technical: 60.4 avg
- Perceptual: 65.3 avg
- Face: 87.4 avg
- Temporal: 98.6 avg

### Phase2 (n=13)
- Overall: 79.4 avg (range 73.6–81.4)
- Technical: 63.1 avg
- Perceptual: 64.0 avg
- Face: 88.7 avg
- Temporal: 99.5 avg

### Phase3 (n=10)
- Overall: 72.7 avg (range 71.9–73.6)
- Technical: 60.8 avg
- Perceptual: 64.5 avg
- Face: 72.2 avg
- Temporal: 99.6 avg

## 1. Continuous Feature Correlations

| Feature | Score Type | Pearson r | n | Interpretation |
|---------|-----------|-----------|---|----------------|
| prompt_length | overall_score | -0.188 | 73 | weak |
| prompt_length | technical | -0.090 | 73 | negligible |
| prompt_length | perceptual | -0.004 | 73 | negligible |
| prompt_length | face | -0.198 | 73 | weak |
| prompt_length | temporal | +0.024 | 73 | negligible |
| prompt_seconds | overall_score | -0.211 | 73 | weak |
| prompt_seconds | technical | +0.048 | 73 | negligible |
| prompt_seconds | perceptual | -0.274 | 73 | weak |
| prompt_seconds | face | -0.202 | 73 | weak |
| prompt_seconds | temporal | +0.162 | 73 | weak |

**Key finding:** Shorter prompts and shorter durations weakly correlate with higher overall scores. The strongest single correlation is prompt_length vs face score (r=-0.27): shorter prompts produce better face renders.

## 2. Emotion Analysis

| Emotion | n | Overall | Technical | Perceptual | Face | Temporal |
|---------|---|---------|-----------|------------|------|----------|
| milestone | 2 | 79.3 | 59.4 | 65.3 | 89.2 | 99.7 |
| relatable | 2 | 78.9 | 60.6 | 65.8 | 87.3 | 99.4 |
| defiant | 2 | 78.3 | 60.3 | 65.0 | 86.5 | 99.6 |
| exhausted | 2 | 78.3 | 59.9 | 65.7 | 86.6 | 98.4 |
| shocking | 2 | 78.1 | 59.8 | 64.8 | 86.6 | 98.9 |
| frustrated | 2 | 78.1 | 60.0 | 64.8 | 86.6 | 98.5 |
| confessional | 2 | 78.0 | 60.5 | 65.1 | 86.2 | 98.0 |
| determined | 2 | 78.0 | 61.0 | 65.4 | 86.3 | 96.7 |
| social | 2 | 77.9 | 59.4 | 65.2 | 85.5 | 99.8 |
| honest | 8 | 77.2 | 61.5 | 64.0 | 84.1 | 99.3 |
| angry | 6 | 77.1 | 62.7 | 65.7 | 82.3 | 98.6 |
| vulnerable | 7 | 76.9 | 60.9 | 63.8 | 83.5 | 99.4 |
| hopeful | 7 | 76.7 | 61.3 | 63.8 | 82.8 | 99.5 |
| relieved | 5 | 76.5 | 62.4 | 66.0 | 80.9 | 98.2 |

**Best emotion:** milestone (79.3, n=2)
**Worst emotion:** relieved (76.5, n=5)
**Spread:** 2.8 points

NOTE: Emotion spread across all videos is only ~1.4 points. With n < 10 per group, this is likely noise. However, 'angry' consistently ranks near the top across phases — the jaw clench / head shake motions may produce better face scores.

## 3. Setting Analysis

| Setting | n | Avg Score | vs Rest | Diff |
|---------|---|-----------|---------|------|
| mirror | 2 | 80.2 | 77.9 | +2.4 |
| bathroom | 4 | 79.8 | 77.8 | +1.9 |
| kitchen | 2 | 78.3 | 77.9 | +0.4 |
| restaurant | 2 | 78.2 | 77.9 | +0.3 |
| desk | 10 | 78.2 | 77.9 | +0.3 |
| coffee shop | 2 | 78.0 | 77.9 | +0.1 |
| cafe | 2 | 78.0 | 77.9 | +0.1 |
| office | 8 | 77.9 | 77.9 | -0.0 |
| sidewalk | 2 | 77.9 | 77.9 | -0.0 |
| city | 2 | 77.9 | 77.9 | -0.0 |
| bed | 13 | 77.8 | 78.0 | -0.1 |
| gym | 2 | 77.7 | 77.9 | -0.2 |
| car | 13 | 77.6 | 78.0 | -0.4 |
| bedroom | 9 | 77.4 | 78.0 | -0.6 |
| floor | 8 | 77.2 | 78.0 | -0.8 |
| park | 7 | 77.0 | 78.0 | -1.1 |
| couch | 7 | 76.7 | 78.1 | -1.3 |
| living room | 7 | 76.7 | 78.1 | -1.3 |
| outdoor | 5 | 76.5 | 78.0 | -1.5 |

## 4. Lighting Analysis

| Lighting | n | Avg Score | vs Rest | Diff |
|----------|---|-----------|---------|------|
| phone screen glow | 2 | 79.4 | 77.9 | +1.6 |
| natural daylight | 4 | 78.5 | 77.9 | +0.7 |
| overexposed | 4 | 78.5 | 77.9 | +0.6 |
| fluorescent | 2 | 78.5 | 77.9 | +0.5 |
| overhead | 10 | 78.2 | 77.9 | +0.3 |
| side lighting | 2 | 78.1 | 77.9 | +0.2 |
| bright | 19 | 78.1 | 77.9 | +0.2 |
| dramatic | 4 | 78.1 | 77.9 | +0.2 |
| cool | 12 | 78.1 | 77.9 | +0.2 |
| soft | 23 | 77.7 | 78.1 | -0.4 |
| warm | 37 | 77.6 | 78.3 | -0.7 |
| lamplight | 9 | 77.4 | 78.0 | -0.6 |
| golden hour | 7 | 77.0 | 78.0 | -1.0 |
| dim | 7 | 76.9 | 78.0 | -1.1 |
| underexposed | 7 | 76.9 | 78.0 | -1.1 |

**Key finding:** 'overhead' and 'cool' lighting outperform 'warm', 'golden hour', and 'dramatic'. The warm-toned prompts (n=31) average 0.4 points below cool-toned (n=10). This is likely driven by perceptual quality metrics preferring neutral/cool white balance.

## 5. Framing Analysis

| Framing | n | Avg Score | vs Rest | Diff |
|---------|---|-----------|---------|------|
| mirror selfie | 2 | 80.2 | 77.9 | +2.4 |
| medium shot | 2 | 79.7 | 77.9 | +1.8 |
| selfie | 14 | 78.9 | 77.7 | +1.2 |
| tight close-up | 6 | 78.9 | 77.9 | +1.0 |
| handheld | 2 | 77.9 | 77.9 | -0.0 |
| close-up | 71 | 77.9 | 79.7 | -1.8 |
| medium close-up | 57 | 77.6 | 79.1 | -1.5 |

## 6. Duration Analysis

| Duration (s) | n | Overall | Technical | Perceptual | Face | Temporal |
|-------------|---|---------|-----------|------------|------|----------|
| 6s | 8 | 79.1 | 59.9 | 65.3 | 88.4 | 99.5 |
| 7s | 35 | 78.2 | 61.2 | 65.5 | 85.8 | 98.3 |
| 8s | 30 | 77.4 | 60.9 | 64.2 | 84.4 | 99.3 |

**Key finding:** 6s prompts score highest (79.1), 8s lowest (78.0). The 8s penalty comes entirely from perceptual (-1.6 vs 6s). Shorter durations = less time for the model to degrade quality. But the spread is only ~1 point — duration is not a major lever.

## 7. Face Analysis (Phase 2 + Phase 3)

Total videos with face variation: 23

| Face ID | n | Overall | Face Layer | Perceptual | Technical | Realness |
|---------|---|---------|------------|------------|-----------|----------|
| female_latina_wavy_01 | 3 | 81.1 | 89.3 | 67.2 | 66.7 | N/A |
| female_blonde_freckles_01 | 4 | 81.1 | 89.1 | 67.7 | 66.8 | N/A |
| male_brown_blue_01 | 3 | 80.6 | 92.0 | 62.3 | 65.3 | N/A |
| male_black_fade_02 | 3 | 74.0 | 84.1 | 57.7 | 52.1 | N/A |
| female_asian_bob_01 | 5 | 73.3 | 72.3 | 65.6 | 62.6 | 43.9 |
| female_asian_bob_02 | 5 | 72.1 | 72.2 | 63.5 | 59.0 | 45.4 |

**Best face:** female_latina_wavy_01 (81.1 avg overall, n=3)
**Worst face:** female_asian_bob_02 (72.1 avg overall, n=5)
**Spread:** 9.0 points

### By Gender

| Gender | n | Overall | Face Layer | Perceptual |
|--------|---|---------|------------|------------|
| female | 17 | 76.2 | 79.2 | 65.7 |
| male | 6 | 77.3 | 88.0 | 60.0 |

### By Ethnicity Descriptor

| Descriptor | n | Overall | Face Layer |
|------------|---|---------|------------|
| latina | 3 | 81.1 | 89.3 |
| blonde/white | 4 | 81.1 | 89.1 |
| white/brown_hair | 3 | 80.6 | 92.0 |
| black | 3 | 74.0 | 84.1 |
| asian | 10 | 72.7 | 72.2 |

**CRITICAL NOTE on male_black_fade_02:** This face averages 7+ points below the best faces. The deficit is across ALL layers (technical -15, perceptual -10, face -5). This is not just a face quality issue — the entire render degrades. This face should be replaced or investigated for source image quality issues.

**Phase 3 asian faces:** All 10 Phase 3 videos use female_asian_bob faces. They score 72-74 overall, significantly below Phase 1 (78.6 avg) and Phase 2 (79.4 avg). Face layer scores are ~72 vs ~88 in Phase 2. The realness scores are all 43-46, suggesting the scorer is penalizing these as AI-looking. This may be a scorer bias issue or a genuine quality difference in the MagiHuman renders for these faces.

## 8. Top 10 and Bottom 10 Videos

### Top 10

| # | ID | Phase | Overall | Tech | Percep | Face | Temp |
|---|-----|-------|---------|------|--------|------|------|
| 1 | testimonial_money | phase1 | 81.5 | 60.7 | 65.4 | 94.0 | 99.8 |
| 2 | testimonial_vulnerable__female_blonde_freckles_01 | phase2 | 81.4 | 66.8 | 67.7 | 89.6 | 99.6 |
| 3 | testimonial_relapse_honest__female_latina_wavy_01 | phase2 | 81.2 | 66.8 | 67.7 | 89.1 | 99.8 |
| 4 | testimonial_angry__female_latina_wavy_01 | phase2 | 81.1 | 66.6 | 66.8 | 89.4 | 99.9 |
| 5 | testimonial_hopeful__female_latina_wavy_01 | phase2 | 81.1 | 66.8 | 67.0 | 89.3 | 99.8 |
| 6 | testimonial_angry__female_blonde_freckles_01 | phase2 | 81.1 | 66.8 | 67.7 | 89.2 | 99.0 |
| 7 | testimonial_relapse_honest__female_blonde_freckles_01 | phase2 | 81.1 | 66.8 | 66.8 | 89.4 | 99.6 |
| 8 | cta_download | phase1 | 80.8 | 59.8 | 65.7 | 92.5 | 99.8 |
| 9 | nighttime_craving | phase1 | 80.8 | 59.8 | 65.0 | 93.0 | 99.8 |
| 10 | testimonial_relieved__female_blonde_freckles_01 | phase2 | 80.8 | 66.9 | 68.5 | 88.3 | 97.4 |

### Bottom 10

| # | ID | Phase | Overall | Tech | Percep | Face | Temp |
|---|-----|-------|---------|------|--------|------|------|
| 64 | testimonial_angry__female_asian_bob_01 | phase3 | 73.6 | 62.7 | 66.4 | 72.3 | 99.8 |
| 65 | testimonial_relieved__female_asian_bob_01 | phase3 | 73.5 | 63.2 | 66.3 | 72.0 | 99.4 |
| 66 | testimonial_hopeful__female_asian_bob_01 | phase3 | 73.4 | 62.7 | 64.9 | 72.9 | 99.7 |
| 67 | testimonial_relapse_honest__female_asian_bob_01 | phase3 | 73.4 | 62.0 | 65.4 | 72.9 | 99.6 |
| 68 | testimonial_vulnerable__female_asian_bob_01 | phase3 | 72.8 | 62.2 | 65.0 | 71.4 | 99.6 |
| 69 | testimonial_relieved__female_asian_bob_02 | phase3 | 72.4 | 59.3 | 63.8 | 72.5 | 99.8 |
| 70 | testimonial_vulnerable__female_asian_bob_02 | phase3 | 72.3 | 58.9 | 63.6 | 72.4 | 99.8 |
| 71 | testimonial_hopeful__female_asian_bob_02 | phase3 | 72.1 | 59.5 | 63.5 | 71.7 | 99.8 |
| 72 | testimonial_angry__female_asian_bob_02 | phase3 | 72.0 | 58.5 | 62.9 | 72.8 | 98.9 |
| 73 | testimonial_relapse_honest__female_asian_bob_02 | phase3 | 71.9 | 58.7 | 63.6 | 71.6 | 99.9 |

## 9. Biggest Impact Features by Layer

For each layer, the top features where presence vs absence shows the largest score difference (n >= 3 both sides).

### Overall Score

| Feature | Avg WITH | Avg WITHOUT | Diff | n_with |
|---------|----------|-------------|------|--------|
| set_bathroom | 79.8 | 77.8 | +1.9 | 4 |
| emo_relieved | 76.5 | 78.0 | -1.5 | 5 |
| set_outdoor | 76.5 | 78.0 | -1.5 | 5 |
| frame_medium close-up | 77.6 | 79.1 | -1.5 | 57 |
| set_couch | 76.7 | 78.1 | -1.3 | 7 |
| set_living room | 76.7 | 78.1 | -1.3 | 7 |
| emo_hopeful | 76.7 | 78.1 | -1.3 | 7 |
| frame_selfie | 78.9 | 77.7 | +1.2 | 14 |
| light_dim | 76.9 | 78.0 | -1.1 | 7 |
| light_underexposed | 76.9 | 78.0 | -1.1 | 7 |

### Face

| Feature | Avg WITH | Avg WITHOUT | Diff | n_with |
|---------|----------|-------------|------|--------|
| emo_relieved | 80.9 | 85.9 | -5.0 | 5 |
| set_outdoor | 80.9 | 85.9 | -5.0 | 5 |
| set_bathroom | 90.0 | 85.3 | +4.7 | 4 |
| frame_medium close-up | 84.7 | 88.4 | -3.6 | 57 |
| emo_angry | 82.3 | 85.8 | -3.5 | 6 |
| set_park | 82.4 | 85.9 | -3.5 | 7 |
| light_golden hour | 82.7 | 85.8 | -3.1 | 7 |
| frame_selfie | 88.0 | 84.9 | +3.0 | 14 |
| set_couch | 82.8 | 85.8 | -3.0 | 7 |
| set_living room | 82.8 | 85.8 | -3.0 | 7 |

### Perceptual

| Feature | Avg WITH | Avg WITHOUT | Diff | n_with |
|---------|----------|-------------|------|--------|
| light_dim | 63.8 | 65.1 | -1.3 | 7 |
| light_underexposed | 63.8 | 65.1 | -1.3 | 7 |
| emo_vulnerable | 63.8 | 65.1 | -1.3 | 7 |
| set_couch | 63.8 | 65.1 | -1.3 | 7 |
| set_living room | 63.8 | 65.1 | -1.3 | 7 |
| emo_hopeful | 63.8 | 65.1 | -1.3 | 7 |
| emo_relapse | 64.0 | 65.1 | -1.1 | 8 |
| set_floor | 64.0 | 65.1 | -1.1 | 8 |
| emo_relieved | 66.0 | 64.9 | +1.1 | 5 |
| set_outdoor | 66.0 | 64.9 | +1.1 | 5 |

### Technical

| Feature | Avg WITH | Avg WITHOUT | Diff | n_with |
|---------|----------|-------------|------|--------|
| emo_angry | 62.7 | 60.7 | +1.9 | 6 |
| emo_relieved | 62.4 | 60.8 | +1.6 | 5 |
| set_outdoor | 62.4 | 60.8 | +1.6 | 5 |
| set_office | 62.2 | 60.7 | +1.5 | 8 |
| frame_tight close-up | 59.8 | 61.0 | -1.3 | 6 |
| light_overexposed | 59.8 | 61.0 | -1.2 | 4 |
| set_desk | 61.9 | 60.7 | +1.2 | 10 |
| frame_medium close-up | 61.1 | 60.1 | +1.1 | 57 |
| light_natural daylight | 59.9 | 61.0 | -1.0 | 4 |
| set_park | 61.8 | 60.8 | +1.0 | 7 |

### Temporal

| Feature | Avg WITH | Avg WITHOUT | Diff | n_with |
|---------|----------|-------------|------|--------|
| light_golden hour | 97.9 | 99.0 | -1.1 | 7 |
| set_park | 98.2 | 98.9 | -0.8 | 7 |
| emo_relieved | 98.2 | 98.9 | -0.7 | 5 |
| set_outdoor | 98.2 | 98.9 | -0.7 | 5 |
| set_couch | 99.5 | 98.8 | +0.7 | 7 |
| set_living room | 99.5 | 98.8 | +0.7 | 7 |
| emo_hopeful | 99.5 | 98.8 | +0.7 | 7 |
| set_bedroom | 99.4 | 98.8 | +0.6 | 9 |
| light_lamplight | 99.4 | 98.8 | +0.6 | 9 |
| light_dim | 99.4 | 98.8 | +0.6 | 7 |

## 10. Actionable Findings (Ranked by Confidence)

Only findings with adequate sample sizes included. Ordered by effect size and reliability.

1. **Face selection is the #1 lever.** female_latina_wavy_01 scores 9.0 points above female_asian_bob_02 (n=3 vs 5). Face choice dwarfs all prompt-level features combined.
2. **Phase 3 asian faces score 6.6 points below Phase 2 average.** All Phase 3 realness scores are 43-46 (out of 100). Either the source photos or the MagiHuman render for these faces is lower quality.
3. **Setting 'bathroom' correlates with +1.9 points** (n=4 vs 4). Small effect, likely noise at this sample size.
4. **6s durations average 1.7 points above 8s** (n=8 vs 30). Shorter clips maintain higher perceptual quality.
5. **Female faces average -1.1 points above male faces** in Phase 2+3 (n=17 vs 6). Partially driven by male_black_fade_02 underperformance.
6. **Shorter prompts correlate with better face scores** (r=-0.198, n=73). Simpler scene descriptions may give the model more capacity for face quality.
7. **Cool/neutral lighting outperforms warm lighting by 0.5 points** (cool n=12, warm n=37). Perceptual quality metrics favor neutral white balance.

## 11. Recommended Prompt Template for Product Review Batch

Based on the data above, optimizing for highest overall_score:

```
- Duration: 6-7s (avoid 8s)
- Framing: Medium close-up or selfie (avoid handheld)
- Lighting: Cool/overhead/neutral (avoid warm/golden hour/dramatic)
- Setting: Simple indoor (desk, bathroom, bed) over complex outdoor
- Emotion: Angry/relieved/vulnerable work best; avoid social/casual
- Prompt length: Keep under 500 chars if possible
- Always include Dialogue and Background Sound tags
- Face selection: Use female_latina_wavy_01 or female_blonde_freckles_01 as primary
- Avoid: male_black_fade_02 (7+ point penalty), female_asian_bob faces (needs investigation)
```

## Caveats

- Total sample: 73 videos. Most feature subgroups have n < 10. These are correlational signals, not proven causal effects.
- Phase 1 (n=50) used a single face and 448x256 landscape. Phase 2+3 used multiple faces and 256x448 portrait. Resolution/orientation is confounded with face variation.
- The 25 unmatched Phase 2 scores are experimental variants (exp_one_word, exp_bad_static, exp_extreme_closeup) that don't have standard prompts. They were excluded.
- Phase 3 is still in progress (10 of planned videos scored so far).
- Scorer v3 weights: technical 15%, perceptual 25%, face 35%, temporal 15%, content 10%.
- Face selection effect (7+ points) is an order of magnitude larger than any prompt-level feature (<1.5 points). Optimizing face choice first is the clear priority.
- No statistical significance testing performed. At n=3-10 per group, most prompt-level differences are within noise range.