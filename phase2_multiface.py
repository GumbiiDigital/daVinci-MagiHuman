#!/usr/bin/env python3
"""
Generate Phase 2 prompts: top 5 prompts × 4 faces, adapted descriptions.
Outputs phase2_prompts.json
"""
import json, os, copy

# 4 selected faces (2F, 2M) - diverse mix
FACES = {
    "female_latina_wavy_01": {
        "file": "female_latina_wavy_01.jpg",
        "desc": "A young Latina woman with dark wavy hair and brown eyes",
        "gender": "F"
    },
    "male_black_fade_02": {
        "file": "male_black_fade_02.jpg",
        "desc": "A young Black man with a fade haircut and warm brown eyes",
        "gender": "M"
    },
    "female_blonde_freckles_01": {
        "file": "female_blonde_freckles_01.jpg",
        "desc": "A young woman with blonde hair, green eyes, and freckles",
        "gender": "F"
    },
    "male_brown_blue_01": {
        "file": "male_brown_blue_01.jpg",
        "desc": "A young man with brown hair and blue eyes",
        "gender": "M"
    }
}

# Original description to replace
ORIG_DESC = "A young woman with light brown shoulder-length hair and blue-green eyes"

# Top 5 prompts from Phase 1
TOP_IDS = [
    "testimonial_vulnerable",
    "testimonial_angry",
    "testimonial_relapse_honest",
    "testimonial_relieved",
    "testimonial_hopeful"
]

# Load original prompts
with open(os.path.expanduser("~/daVinci-MagiHuman/batch_prompts.json")) as f:
    all_prompts = json.load(f)

top_prompts = [p for p in all_prompts if p["id"] in TOP_IDS]

# Gender-specific dialogue adjustments
def adapt_dialogue(prompt_text, face_key, face_info):
    """Replace face description and adjust gendered language"""
    text = prompt_text.replace(ORIG_DESC, face_info["desc"])
    
    if face_info["gender"] == "M":
        # Fix dialogue tags
        text = text.replace("<Young woman, English>", "<Young man, English>")
        text = text.replace("young woman", "young man")
        # Adjust "sister" reference in vulnerable prompt
        text = text.replace("my little sister", "my little brother")
    
    return text

# Build phase 2 prompts
phase2 = []
for face_key, face_info in FACES.items():
    for prompt in top_prompts:
        new_prompt = {
            "id": f"{prompt['id']}__{face_key}",
            "prompt": adapt_dialogue(prompt["prompt"], face_key, face_info),
            "seconds": prompt["seconds"],
            "face": face_info["file"],
            "face_key": face_key
        }
        phase2.append(new_prompt)

outpath = os.path.expanduser("~/daVinci-MagiHuman/phase2_prompts.json")
with open(outpath, "w") as f:
    json.dump(phase2, f, indent=2)

print(f"Generated {len(phase2)} prompts ({len(FACES)} faces × {len(top_prompts)} prompts)")
print(f"Saved to {outpath}")
for p in phase2[:3]:
    print(f"\n  {p['id']}:")
    print(f"    face: {p['face']}")
    print(f"    prompt: {p['prompt'][:120]}...")
