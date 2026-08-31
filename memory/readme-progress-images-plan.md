---
name: readme-progress-images-plan
description: Agreed plan for tomorrow - capture the CCM chart at each pipeline stage so the README shows visible progress
metadata:
  type: project
---

Agreed 2026-08-17, to do next: **illustrate the README with one picture per stage**, so a reader sees the image improve as they follow the steps.

Subject is `data/ccm-target-16x9.png` displayed full-screen, filling the frame — **not** a room scene. That is deliberate: it makes the captures publishable, where the six room photos withheld on 2026-08-17 were not (`.gitignore` blocks `*.jpg`/`*.png`; force-add only the approved chart shots).

Stages, in the order the README introduces them:

1. **Quick start** — distro libcamera only, no `/usr/local` build. Yellow cast and blocky patterning (measured mean R/G/B 146/125/62). This is the "it works, and this is normal" picture.
2. **+ patched libcamera / RGB-IR pre-pass** — colour roughly correct, soft.
3. **+ CCM** (`install-ccm.sh` with the shipped matrix) — hue and saturation.
4. **+ lens shading** (`SHADING=`) — corners even.
5. **+ denoise** (`DENOISE=0.15`) — less grain.
6. **+ sharpness** (`SHARPNESS=0.5`) — more green detail.

**Only stage 1→2 needs a real switch** (drop `LD_LIBRARY_PATH`/`LIBCAMERA_IPA_MODULE_PATH` to use the distro build, as tested on 2026-08-17). Stages 3-6 are all env vars on `install-camera-service.sh`, so one sitting with the chart up can capture everything.

**Traps to respect, all learned the hard way:**
- **Do not move the laptop or change screen brightness between captures.** Different framing or exposure makes the series a comparison of scenes, not of code.
- The AGC exposes for the chart's mid-grey mean and lets white clip; `EV` does nothing once it is pegged. Expect clipped white in these shots — acceptable for illustration, fatal for fitting (see [[ov5678-colour-tuning-settled]]).
- Verify the chart is actually on screen before each capture. 90 raw frames were once fitted to an empty dark room.
- Crop consistently; the visible frame is a 1280x720 window of a 1296x972 pre-pass output.
