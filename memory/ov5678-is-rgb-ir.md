---
name: ov5678-is-rgb-ir
description: "The Latitude 7320 front sensor is a 4x4 RGB-IR mosaic, not a 2x2 Bayer - confirmed empirically 2026-08-09; root cause of every colour problem"
metadata: 
  node_type: memory
  type: project
  originSessionId: cab23403-1de4-43b9-abfe-14c7e1f6837e
  modified: 2026-08-15T10:41:59.793Z
---

**The front camera is a 4x4 RGB-IR mosaic, not a Bayer sensor.** Confirmed
2026-08-09, both from Intel's Windows driver and by direct measurement.

```
G I G I
R G B G
G I G I
B G R G
```

Source 1: `graph_settings_OV5678_0BF501T3_TGL.xml` from the extracted Windows
driver says `bayer_order="GIGI_RGBG_GIGI_BGRG"` and `sensor_type="RGB_IR"`.
`0BF501T3` is this machine's ACPI `_DDN`, so it is this module. The rear OV8856
alongside says plain `GRBG` - a useful control.

Source 2: measured at 2592x1944 on a red subject (`tools/check-rgbir.sh`),
black-level corrected, 10-bit counts:

    G 8 positions  mean 116.1  spread 3.4
    I 4 positions  mean  14.2  spread 0.1
    R 2 positions  mean  89.7  spread 0.5
    B 2 positions  mean  73.3  spread 0.1

Positions the 2x2 model calls one channel differ 18%; the IR pair agrees to
0.4%. Not lens shading - positions interleave at pixel level over the same
area, and the diagonally offset R pair still agrees to 0.5%.

**Read as 2x2 GBRG (what our patched ov5675.c declares), our "blue" channel is
pure IR and our "red" channel is real red and real blue checkerboarded.** That
is the root cause of everything chased for two days:
- the ~4.9x blue gain (amplifying IR at 12% of green), and why the AWB's
  hardcoded 4.0 clamp bit at all
- blue anti-correlated with subject blue - it was infrared; yellow reflects
  strongly in NIR
- the unfittable CCM blue row, which caused CCM to be abandoned
- washed-out colour: the red channel is an R/B spatial average
- GBRG "beating" GRBG - it put real red in the red channel at half the
  positions. The better of two wrong answers.

**Retractions this forces.** Blues are NOT a hardware or lighting limit - the
Windows photo of a Kmart colour-swatch poster from the same camera has vivid
blues, magentas and yellows. I claimed the limit was physics several times; it
was our demosaic. Also `intel/ipu6-drivers#24` has a public comment from me
saying RGB-Ir was ruled out. Wrong, and needs a further correction. See
[[ov5678-colour-tuning-settled]].

**Binning destroys the mosaic.** Intel lists exactly one sensor mode,
2592x1944, where the plain-Bayer OV8856 gets several. Our pipeline runs the
binned 1296x972 mode, which averages IR into the colour pixels. Any RGB-IR work
must use full resolution.

**DEMONSTRATED 2026-08-09.** `tools/rgbir-offline.py` renders a saved raw both
ways. Phase A - exactly as Intel declares - is correct; phase B (R/B swapped,
which `check-rgbir` cannot distinguish because both groupings are equally
self-consistent) renders human skin blue. Skin tone is the unambiguous
discriminator:

    2x2 GBRG (ships today)  sat  9.6%   skin (97,93,96)   flat grey
    RGB-IR phase A          sat  9.1%   skin (103,93,90)  warm, correct
    RGB-IR phase B          sat  9.1%   skin (90,93,103)  blue skin, wrong
    RGB-IR A + IR x2.0      sat 13.9%   skin (104,92,83)  warm, most saturated

The win is correctness rather than raw saturation: mean saturation barely
moves, but the 2x2 reading's colour is *wrong* (grey skin, purple/teal swatch
mush) where RGB-IR gives warm skin and distinguishable blue/green/pink/purple
swatches. IR subtraction is worth a further ~50% saturation; the x2.0
coefficient is empirical, not calibrated.

An earlier attempt looked like a negative result. It was an underexposed frame:
both exposure and gain pinned at maximum for 11% of full scale. Raising VBLANK
lifts the exposure ceiling (2016 -> 7940 lines) and fixes it. Frame rate is
irrelevant for a stills measurement.

**PUBLIC, CITABLE EVIDENCE THAT INTEL CONVERTS IN THE IPU6 (found 2026-08-15).** `github.com/intel/ipu6-drivers` declares an IPU6 firmware/PSYS accelerator **`IPU6_FW_PSYS_ISA_X2B_SVE_RGBIR_ID`** in `drivers/media/pci/intel/ipu6/psys/ipu6-platform-resources.h` (and the `ipu6ep` equivalent). "X2B" = X-to-Bayer. This is the same block as the `x2b_rgbir` seen in the closed `iacamera64.sys`, but in **Intel's own open-source code**, so it can be cited to linux-media directly instead of citing a reverse-engineered Windows binary. **The repo contains no ov5678 driver at all** — Intel never shipped one for Linux — and no other RGB-IR sensor driver to borrow register tables from. Also present and worth knowing: `patch/v7.0/0008-media-i2c-ov8856-remove-is_acpi_node-checks-in-power.patch`, the rear-camera patch Charles cited, plus `int3472-*` board-data precedents and a `ipu-bridge` DMI-quirk precedent for Dell XPS.

**THE SENSOR-SIDE BAYER MODE WAS SEARCHED FOR ON HARDWARE, 2026-08-15, AND NOT FOUND.** This is the answer to Sakari's question, now backed by method rather than inference. `tools/map-sensor-regs.sh` and `tools/dump-candidate-pages.sh` mapped every register page in `0x3000`–`0x5fff` over i2c (validated each time against chip id `00 56 75` at `0x300a`). `ov5675.c` writes 138 registers across 16 pages; the search targeted pages that are **populated but never written**, since those are uncharacterised silicon. After removing aliases the candidates collapse:

- `0x51xx`, `0x56xx` — 512 registers, **all zero** (unimplemented addresses read 0x00 on this part)
- `0x41xx` — **byte-for-byte alias of `0x40xx`**
- `0x3300` — looked like 128 registers, is really **16 aliased 8×** (low 5 bits decoded); content is a gain-threshold ladder (0x00c8/0x0190/0x0258/0x0320 = 200/400/600/800)
- `0x5800` — **a second instance of the DPC block** the driver configures at `0x5780`, differing in only two bytes, itself repeated within the page
- `0x3200`, `0x3d00`, `0x3e00`, `0x3f00`, `0x4300`, `0x5a00` — 2 to 10 registers each

**Nothing resembling a CFA or output-format control exists in that space.** Weak corroboration pointing the same way: a *duplicated* DPC block is what an RGB-IR part would need, separate correction for the IR plane and the colour planes.

**Two trap lessons.** Aliasing inflates apparent discoveries in both directions — page-to-page (`0x41xx`) and *within* a page (`0x3300`, `0x5800`), and a page-level comparison misses the second kind. And a dense block of defaults is not evidence of a feature; `0x3300` looked like the richest find in the map and is a small lookup table.

**`0x5000`–`0x5003` HAVE NOW BEEN BIT-SWEPT (2026-08-15, `tools/sweep-isp-bits.py`) — all 32 bits, and every effect is accounted for. No Bayer mode.** Method: capture full-res raw, take the mean of each of the 16 positions in the 4x4 cell, flip one bit, re-measure, restore. Four bits changed the IR statistic and all four are explained:
- **`0x5000` bit0 = black-level correction enable.** Clearing it lifts every position by the ~64-count pedestal. That barely moves green (285) but quadruples the IR positions (83), so it looked like a mosaic change. **False hit caused by assuming a fixed black level** — judge candidates from the full 16-position grid, where a pedestal shift moves all sixteen together.
- **`0x5002` bit5 and `0x5003` bit3** — output saturates, all 16 positions at 1023, spread exactly 0.00%. A blown white frame.
- **`0x5002` bit1 = a one-column CFA phase shift** (mirror or window offset). Every position takes its right-hand neighbour's value. **Decisively not a Bayer mode: the modified grid still has exactly four dark positions (~82) out of sixteen — the IR pixels are still there, merely relabelled.** A real Bayer mode would remove the dark cluster entirely. Restoring the register reproduced the baseline to a tenth of a count.
- `0x5002` bits 6 and 7 double the level with the mosaic unchanged (gain-like), everything else does nothing.

Baseline for reference (raw, no black subtraction, exposure 2016 gain 512): green 281–285, **IR 82.6–82.8**, R 201.9, B 177.5.

**Nothing outside `0x3000`–`0x5fff` has been mapped**, which is the only remaining gap in the search. The decisive test for any candidate is cheap — write it, capture full-res raw, run `tools/check-rgbir.sh`, and see whether the four IR positions stop agreeing to 0.8%.

**Incidental find worth following up separately:** the sensor appears to carry an on-chip lens shading / DPC capability the driver leaves at defaults. Lens shading is the largest remaining image defect and the simple IPA has no LSC algorithm, so an on-sensor block would be a cheaper route than writing one. Untested.

**LIVE RGB-IR PRE-PASS: INTEGRATION VERIFIED CORRECT, 2026-08-15.** The previous session's "magenta bug" could not be reproduced and there is no integration fault. Proof: with `RGBIR_TESTPAT=1` the pre-pass writes a *spatial* red|blue pattern into its output buffer, and the camera output shows red on the left (R 186, B 0) and blue on the right (R 0, B 186). The buffer reaches the debayer and channels map correctly.
- **A uniform test pattern proves nothing** — grey-world AWB normalises any constant cast to neutral, so a solid-colour test returns neutral whether or not the buffer is used. Only the spatial version discriminates. This nearly produced a false "buffer not used" conclusion.
- Also verified: `convertSameSize()` is mathematically identical to offline phase A (reimplemented in Python, bit-identical), and `check.sh` shows the C++ matches the Python reference to 0.5%.
- **Do not trust comparisons between the offline renderer and the live pipeline.** They apply different white balance, gamma and black-level handling, so they diverge for reasons unrelated to the mosaic. Several hours were lost treating that divergence as a bug.

**IR subtraction now exists in the live pipeline** (`RgbIrToBayer::setIrSubtract()`, added 2026-08-15; env `RGBIR_IRSUB`). Measured live: saturation 10.7% at k=0, 12.3% at k=1.0, 14.4% at k=2.0. Noise scales with k because IR is the weakest channel, so prefer a low k plus saturation.

**A libcamera CRASH was found and fixed locally — upstream-reportable.** `DebayerCpu`'s gamma LUT index is bounded above by `.min(gammaTableSize - 1)` but **not below**; a negative, NaN or infinite gain casts to a huge `unsigned int` and indexes `std::array<double, 1024>` out of bounds, aborting the process. This killed `v4l2-relayd` repeatedly with SIGABRT (`Assertion '__n < this->size()' failed`), which the user saw as browser errors and a ~7 fps stutter. A lower-bounded index lambda fixes it: 0 crashes in 300 frames afterwards. This is a genuine defect in `src/libcamera/software_isp/debayer_cpu.cpp` and worth reporting regardless of the RGB-IR work.

**THE FULL-RESOLUTION CPU PIPELINE IS NOT VIABLE: ~1.1 fps sustained** through `/dev/video0` (300 frames). Direct `cam` reports 29.95 fps because it excludes the relay's `videoscale` from 2584x1944 to 720p plus the YUY2 conversion at 20 MB/frame. **Measure fps over 300+ frames** — 30-frame samples read 22.9 fps and 150-frame samples 1.3 fps on the same configuration, because the relay buffers. Short measurements produced three contradictory answers in one session.

**Fixing it needs an RGB-IR demosaic**, which libcamera's soft ISP does not
have - it handles 2x2 mosaics only. Note rows 1 and 3 are `R G B G` / `B G R G`,
so it does not reduce to a Bayer pattern by dropping the IR rows either.

**Intel's tuning file is now extracted** (`OV5678_0BF501T3_TGL.aiqb`, second
extraction). Decoded in `docs/aiqb-format.md`. Two results:

- Its lens shading record header carries a 4x4 channel-index map that
  **independently confirms the mosaic AND the phase** - matching the phase
  chosen empirically from skin tone. Five channels (two greens tracked
  separately, plus IR) against four on the rear Bayer sensor.
- **Lens shading tables decoded**: 63x47 gain grids, 1/2048 fixed point,
  monotonic 1.04x centre to 3.29x corner. Cross-checked against our own flat
  field - 2.22x measured vs 2.40x Intel at the same radius, within 8%.

That cross-check corrected a repeat of this project's recurring gamma error:
the "31% corner falloff" figure was computed on gamma-encoded 8-bit values. In
linear light the corners sit at 45% of centre, a 55% falloff.

Note `TPG1/TPG2_INTEL.aiqb` are NOT this sensor - they are byte-identical to
each other and TPG2 resolves to `sensor_name="Imx135_TPG"`, a test pattern
generator. `TPG2_INTEL_rgbir.cpf` is tuning for that in an RGB-IR test mode.

Still undecoded: plane ordering within the shading record, record 101/27 (5112
bytes, RGB-IR only, presumably the IR subtraction model), and the colour
matrices. `iacamera64.sys` documents the IPU6 `x2b_rgbir` hardware block - 314
registers - which shows Intel converts RGB-IR **to Bayer** and then runs the
ordinary pipeline. That is the cheap implementation route for us too: a
pre-pass, not a new demosaic throughout the soft ISP.

**THE MODULE EEPROM HAS NOW BEEN READ (2026-08-15) AND ITS OWN LABEL SAYS RGB-IR.** Dumped from i2c-1 addr 0x51 with `tools/read-eeprom.sh`; raw dump kept at `data/eeprom-0x51.bin`. Near the end of the payload, in plain ASCII:

    W7G97\0  ASSY,CMRA,5M,RGBR,MIPI,0MIC,FF\0  0BF501,

- **`RGBR` is Dell's own part description for the module** — a fourth independent confirmation of RGB-IR, and the most authoritative, since it is the factory label rather than an inference from tuning files or measurement.
- `W7G97` is the **Dell part number** for this camera module.
- `FF` = fixed focus, independently confirming no VCM (ACPI `L0VC`=0).
- `5M` matches 2592x1944; `0MIC` means no microphone.
- `0BF501` matches ACPI `_DDN` `0BF501T3`, so this is the expected variant.

This is the data Windows would have written to `C:\NVMDump\WF_NVM.bin`, which no install we saw ever produced. As far as we know it is the first time this module's NVM has been read on Linux.

**Layout so far:** 8192 bytes readable, but only ~1018 are payload (`0x0000`–`0x03fa`); everything after is `0xff`. A 16-byte header, then ~958 bytes of smooth quasi-periodic numeric data — plausibly per-module shading or AWB calibration, **but the grid shape is NOT decoded**: 958 divides evenly by none of the candidate strides, and the header word `0xe474` is not a sum16 or CRC16-CCITT of any obvious region. Do not assume it is lens shading without decoding it properly.
