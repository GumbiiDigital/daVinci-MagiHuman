# Voice Cloning & TTS Research for DaVinci-MagiHuman Pipeline

**Date:** 2026-03-26
**Purpose:** Add high-quality voice to AI-generated UGC testimonial videos
**Constraint:** 50 unique voices, ~20 videos/week/voice, 15-30 seconds each

---

## 1. Comparison Table

| Model | Type | Pricing | Voice Cloning | Min Sample | Quality (MOS) | Languages | Latency | VRAM (Local) | License |
|-------|------|---------|---------------|------------|---------------|-----------|---------|-------------|---------|
| **ElevenLabs** | API | $5-$330/mo (30K-2M chars) | Yes (instant + pro) | ~30s (instant), 30min (pro) | ~4.5+ (industry leader) | 32+ | <500ms (Flash) | N/A (cloud) | Proprietary |
| **HeyGen** | API | $29-$149/mo | Yes (face + voice) | 60s video | Good | 175+ | Minutes (video gen) | N/A (cloud) | Proprietary |
| **Fish Speech v1.5 / S2** | API + Local | Free 7min/mo, $11-$75/mo API | Yes (zero-shot) | ~10s | Excellent (lowest WER on Seed-TTS Eval) | 80+ (S2 Pro) | Near real-time | 12GB min, 24GB rec | Apache 2.0 code, Research License weights |
| **Qwen3-TTS 1.7B** | Local | Free | Yes (zero-shot) | 3s | Excellent (beats ElevenLabs on benchmarks) | 10 | 97ms TTFA | 8GB min, 16GB rec | Apache 2.0 |
| **CosyVoice2 0.5B** | Local | Free | Yes (zero-shot) | ~5s | Very good | 9 | Real-time streaming | ~8GB est | Apache 2.0 |
| **IndexTTS-2** | Local | Free | Yes (zero-shot) | ~5s | Excellent (SOTA WER + similarity) | Multi | Near real-time | ~8-12GB est | Open source |
| **XTTS v2 (Coqui)** | Local | Free | Yes (zero-shot) | 6s | Good | 17 | <200ms streaming | 8-16GB | CPML (restricted commercial) |
| **OpenVoice v2** | Local | Free | Yes (zero-shot, tone cloning) | ~5s | Decent (style transfer focus) | Cross-lingual | 85ms/sec (12x RT on A10G) | ~4-6GB | MIT |
| **StyleTTS 2** | Local | Free | Limited (style reference) | ~5s | 3.83 MOS (human-level on LJSpeech) | English primary | 2-3s on RTX 3050M | ~2GB | MIT |
| **Bark (Suno)** | Local | Free | NO (presets only) | N/A | Good (expressive) | 100+ presets | Slow (autoregressive) | ~8-12GB | MIT |

---

## 2. Detailed Breakdown

### Tier 1: Cloud APIs (Pay Per Use)

#### ElevenLabs
- **Plans:** Starter $5/mo (30K chars), Creator $22/mo (100K chars), Pro $99/mo (500K chars), Scale $330/mo (2M chars)
- **Voice cloning:** Instant cloning on Starter+, Professional cloning on Creator+ ($22/mo min)
- **Quality:** Industry benchmark. Natural, expressive, minimal artifacts
- **Strengths:** Best-in-class quality, voice changer feature (swap voices on existing video), massive language support
- **Weaknesses:** Expensive at scale. 2M chars/mo = ~5 hours of speech for $330
- **API:** Full REST API, Python SDK
- **Voice Changer:** Can upload a Veo/DaVinci video and swap the voice to a cloned one -- useful for our pipeline

#### HeyGen
- **Plans:** Creator $29/mo, Pro $99/mo, Business $149/mo
- **API:** Separate subscription starting at $99/mo. 1 credit = 1 minute of video
- **Voice cloning:** Included, but primarily tied to avatar video generation
- **Verdict:** Overkill for voice-only. We already have DaVinci for video gen. Only useful if we wanted to switch to HeyGen avatars entirely

#### Fish Audio API
- **Plans:** Free 7 min/mo, Plus $11/mo (200 min), Pro $75/mo (27 hours)
- **Quality:** S2 Pro model achieves lowest WER among all evaluated TTS models, surpasses Seed-TTS by 24% on Audio Turing Test
- **Voice cloning:** Zero-shot from ~10s sample
- **Verdict:** Best price-to-quality ratio for API. $75/mo for 27 hours covers our entire weekly volume

### Tier 2: Open Source (Run on Spark2 -- GB10 Blackwell, 128GB unified, CUDA 13.0)

#### Qwen3-TTS 1.7B (TOP PICK for local)
- **Released:** January 2026 by Alibaba/Qwen team
- **Quality:** Outperforms ElevenLabs on benchmarks. 97ms time-to-first-audio
- **Voice cloning:** 3 seconds of reference audio. Zero-shot, no training needed
- **Voice design:** Create new voices from text descriptions (e.g., "young Australian woman, confident, slight rasp")
- **VRAM:** 16GB recommended for 1.7B, 8GB for 0.6B variant
- **License:** Apache 2.0 (fully open, commercial OK)
- **Languages:** 10 (CN, EN, JA, KO, DE, FR, RU, PT, ES, IT)
- **GB10 compatibility:** YES. 128GB unified memory is massive overkill. Will run easily. May need PyTorch 2.10 compatibility check for CUDA 13.0 / SM 121

#### Fish Speech v1.5 (Self-Hosted)
- **Quality:** Among the best. 80+ languages with S2 Pro
- **Voice cloning:** Zero-shot from ~10s sample
- **VRAM:** 12GB minimum, 24GB recommended
- **License:** Apache 2.0 for code, BUT model weights are under Fish Audio Research License -- commercial self-hosting requires separate license from Fish Audio
- **GB10 compatibility:** YES for inference. License concern for commercial use

#### CosyVoice2 0.5B
- **Quality:** Very good, emotion and speed control
- **Voice cloning:** Zero-shot, real-time streaming
- **VRAM:** Estimated ~8GB (0.5B params, lightweight)
- **License:** Apache 2.0
- **GB10 compatibility:** YES. Small model, fast inference

#### IndexTTS-2
- **Quality:** SOTA on WER, speaker similarity, and emotional fidelity
- **Voice cloning:** Zero-shot with separate timbre and emotion control
- **Strength:** Precise duration control (critical for lip-sync alignment)
- **License:** Open source
- **GB10 compatibility:** YES. Designed for edge deployment

#### OpenVoice v2
- **Quality:** Decent. Better at style transfer than raw quality
- **Voice cloning:** Zero-shot tone cloning, granular control over emotion/accent/rhythm
- **VRAM:** ~4-6GB (very lightweight, feed-forward)
- **License:** MIT (fully open, commercial OK)
- **GB10 compatibility:** YES. Extremely lightweight
- **Limitation:** Uses MeloTTS as base TTS, then applies tone transfer. Two-stage pipeline can introduce artifacts

#### StyleTTS 2
- **Quality:** 3.83 MOS on LJSpeech (near human). Excellent for English
- **Voice cloning:** Limited -- style reference, not true voice identity cloning
- **VRAM:** ~2GB (very small)
- **License:** MIT
- **GB10 compatibility:** YES
- **Limitation:** English-focused. Not a voice cloner, more of a style-transfer TTS. Not suitable for "50 unique voices" use case

#### XTTS v2 (Coqui Legacy)
- **Quality:** Good, battle-tested
- **Voice cloning:** 6s sample, zero-shot
- **VRAM:** 8-16GB
- **License:** CPML -- restricted commercial use, needs license review
- **Status:** Coqui company shut down Dec 2025. Community-maintained fork. No new development
- **GB10 compatibility:** YES but aging codebase, may have dependency issues with CUDA 13.0

#### Bark (Suno)
- **Verdict:** SKIP. No voice cloning capability. Presets only. Slow inference. Interesting for sound effects but not our use case

---

## 3. Cost Projection

### Our Volume
- 50 voices x 20 videos/week x 22.5 seconds avg = 22,500 seconds/week = **375 minutes/week = 6.25 hours/week**
- Monthly: ~25 hours/month of generated speech
- Characters: ~22.5 seconds avg = ~75 words = ~375 characters per video
- Monthly characters: 50 x 20 x 4 weeks x 375 = **1,500,000 characters/month**

### Cost by Option

| Option | Monthly Cost | Notes |
|--------|-------------|-------|
| **ElevenLabs Scale** | $330/mo | 2M chars covers us. Tight margin at 1.5M usage |
| **ElevenLabs Pro** | $99/mo | 500K chars -- NOT ENOUGH. Need 3x this |
| **Fish Audio Pro** | $75/mo | 27 hours/mo. We need ~25hrs. Tight but works |
| **Fish Audio Plus** | $11/mo | 200 min -- NOT ENOUGH |
| **Qwen3-TTS (local)** | $0/mo | Only electricity + GPU time on spark2 |
| **CosyVoice2 (local)** | $0/mo | Same as above |
| **IndexTTS-2 (local)** | $0/mo | Same as above |
| **OpenVoice v2 (local)** | $0/mo | Same as above |

### Break-Even: API vs Local

At $330/mo (ElevenLabs) or $75/mo (Fish Audio), local open-source models pay for themselves immediately. spark2 is already running and paid for. The only cost is the time to set up and integrate.

Even if we keep an API as fallback, running Qwen3-TTS locally for the bulk and using ElevenLabs Starter ($5/mo) for edge cases is the optimal strategy.

---

## 4. Recommendation

### Primary: Qwen3-TTS 1.7B on spark2 (local, $0/mo)

**Why:**
1. Apache 2.0 -- fully open, no commercial license headaches
2. 3-second voice cloning -- generate 50 unique voices from 50 short audio clips
3. Voice DESIGN from text descriptions -- can create voices without ANY audio sample
4. Outperforms ElevenLabs on benchmarks (WER, Audio Turing Test)
5. 97ms time-to-first-audio -- fast enough for batch pipeline
6. 1.7B model fits in 16GB VRAM. spark2 has 128GB unified. Can run alongside other workloads
7. 10 languages covers our English UGC use case
8. Released January 2026 -- actively maintained, latest architecture

### Fallback: Fish Audio API ($11-$75/mo)

**Why:**
1. If Qwen3-TTS has quality issues in practice, Fish Audio S2 is the best API value
2. $75/mo for 27 hours covers our full volume
3. 80+ languages if we expand to international markets
4. Can use free tier (7 min/mo) for testing immediately

### Skip: ElevenLabs (for now)

ElevenLabs is the quality leader but $330/mo for our volume when open-source alternatives benchmark equally well or better is not justified. Revisit only if local models produce noticeably worse output in A/B testing.

### Skip: HeyGen

We already have DaVinci for video generation. HeyGen is a full avatar platform, not a TTS tool. Paying $99+/mo for voice-only extraction is wasteful.

---

## 5. Integration Plan for DaVinci Pipeline

### Current Pipeline
```
Script (ChatGPT) -> Image (Nanobanana/MJ) -> Video (DaVinci-MagiHuman) -> [NO VOICE] -> Edit (CapCut)
```

### Target Pipeline
```
Script (ChatGPT) -> Image (Nanobanana/MJ) -> Video (DaVinci-MagiHuman)
                                                      |
                                              Script -> Qwen3-TTS (spark2) -> Audio WAV
                                                      |
                                              FFmpeg merge video + audio -> Final MP4
                                                      |
                                              [Optional] Lip-sync correction
                                                      |
                                              Edit (CapCut) or direct upload
```

### Implementation Steps

#### Phase 1: Setup (1-2 hours)
1. SSH into spark2
2. Clone Qwen3-TTS repo: `git clone https://github.com/QwenLM/Qwen3-TTS`
3. Install dependencies (PyTorch 2.10 + CUDA 13.0 compatibility check required)
4. Download 1.7B CustomVoice model from HuggingFace
5. Run smoke test: generate 15s audio from text + reference voice

#### Phase 2: Voice Bank Creation (2-3 hours)
1. Source 50 diverse voice samples (3-10 seconds each):
   - Option A: Use Qwen3-TTS voice DESIGN to generate 50 voices from text descriptions (no samples needed)
   - Option B: Extract audio clips from royalty-free video/audio sources
   - Option C: Generate base voices with Veo 3.1 or Bark, use as reference for Qwen3-TTS
2. Create `voice_bank/` directory with 50 named voice profiles
3. Each profile: reference audio + metadata (name, description, accent, tone)

#### Phase 3: Pipeline Integration (2-3 hours)
1. Write `generate_voice.py` on spark2:
   - Input: script text + voice profile name
   - Output: WAV file at 24kHz
   - API: FastAPI endpoint on port 8550 (consistent with our service pattern)
2. Write `merge_audio.sh`:
   - Input: DaVinci video (MP4) + Qwen3 audio (WAV)
   - Output: merged MP4 with audio track
   - Use FFmpeg: `ffmpeg -i video.mp4 -i voice.wav -c:v copy -c:a aac -map 0:v -map 1:a output.mp4`
3. Add voice generation step to `phase3_generate.sh` or create `phase4_voice.sh`

#### Phase 4: Lip-Sync (Optional, Future)
- DaVinci videos currently have model-generated audio (low quality mouth movement)
- If we replace audio, lips won't match
- Options:
  - Accept minor mismatch (most UGC is filmed with slight audio desync anyway)
  - Use Wav2Lip or similar for post-hoc lip correction
  - Generate video WITHOUT audio first, then add Qwen3 voice, then apply lip-sync
- This is a v2 problem. Ship voice-first, iterate on lip-sync later

#### Phase 5: Batch Automation
1. Integrate into `afk_orchestrator.sh`
2. Batch process: for each video in output dir, generate matching voice, merge
3. Add to the scoring pipeline: score videos WITH voice

---

## 6. Open Source Models That Run on Our Hardware

### spark2 Specs
- NVIDIA GB10 Blackwell
- 128GB unified memory
- CUDA 13.0 (SM 121 -- must verify model compatibility)
- PyTorch 2.10

### Confirmed Compatible (Will Run)

| Model | VRAM Needed | Concurrent with LLM? | Notes |
|-------|------------|----------------------|-------|
| **Qwen3-TTS 1.7B** | ~16GB | YES (128GB total) | Top pick. Check SM 121 kernel compat |
| **CosyVoice2 0.5B** | ~8GB | YES | Good backup. Emotion control |
| **IndexTTS-2** | ~8-12GB | YES | Duration control for lip-sync |
| **OpenVoice v2** | ~4-6GB | YES | Lightest option. Good for quick tests |
| **StyleTTS 2** | ~2GB | YES | English only, limited cloning |
| **Fish Speech v1.5** | ~12GB | YES | License concern for commercial use |
| **XTTS v2** | ~8-16GB | YES | Aging codebase, may have CUDA issues |

### Potential Gotcha: CUDA 13.0 / SM 121

Same issue as llama.cpp -- GB10 Blackwell uses SM 121 (not SM 120). Models compiled with older CUDA may need recompilation. PyTorch 2.10 should handle this natively, but custom CUDA kernels in TTS models may need patching.

**Test order:** Qwen3-TTS first (newest, most likely to support SM 121), then CosyVoice2, then IndexTTS-2.

---

## 7. Quick-Start Command (When Ready to Test)

```bash
# On spark2 via CAT5
ssh gumbiidigital@192.168.250.11

# Clone and setup Qwen3-TTS
cd ~/tensortowns
git clone https://github.com/QwenLM/Qwen3-TTS.git
cd Qwen3-TTS
pip install -r requirements.txt

# Download model
huggingface-cli download Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice --local-dir models/

# Test voice cloning (3s reference audio)
python inference.py \
  --text "This product completely changed my morning routine. I can't believe I waited so long to try it." \
  --reference_audio voice_bank/voice_01.wav \
  --output output_test.wav

# Test voice design (no audio needed)
python inference.py \
  --text "This product completely changed my morning routine." \
  --voice_description "Young American woman, mid-20s, casual and enthusiastic, slight vocal fry, natural pacing" \
  --output output_designed.wav
```

---

## Sources

- [ElevenLabs Pricing](https://elevenlabs.io/pricing)
- [ElevenLabs Pricing Breakdown 2026](https://bigvu.tv/blog/elevenlabs-pricing-2026-plans-credits-commercial-rights-api-costs)
- [HeyGen Pricing](https://www.heygen.com/pricing)
- [HeyGen API Pricing](https://www.heygen.com/api-pricing)
- [Fish Audio Pricing](https://fish.audio/plan/)
- [Fish Speech GitHub](https://github.com/fishaudio/fish-speech)
- [Qwen3-TTS GitHub](https://github.com/QwenLM/Qwen3-TTS)
- [Qwen3-TTS HuggingFace](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
- [Qwen3-TTS Hardware Guide](https://qwen3-tts.app/blog/qwen3-tts-performance-benchmarks-hardware-guide-2026)
- [CosyVoice](https://cosyvoice.org/)
- [IndexTTS-2](https://index-tts.github.io/)
- [OpenVoice GitHub](https://github.com/myshell-ai/OpenVoice)
- [StyleTTS 2 GitHub](https://github.com/yl4579/StyleTTS2)
- [Bark GitHub](https://github.com/suno-ai/bark)
- [XTTS v2 HuggingFace](https://huggingface.co/coqui/XTTS-v2)
- [Coqui TTS GitHub](https://github.com/coqui-ai/TTS)
- [Best Open Source Voice Cloning 2026](https://www.siliconflow.com/articles/en/best-open-source-models-for-voice-cloning)
- [Best Open Source TTS 2026](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models)
- [TTS API Comparison 2026](https://deepgram.com/learn/best-text-to-speech-apis-2026)
- [Skool AI Video Bootcamp - Voice Cloning Module](https://www.skool.com/aivideobootcamp)
