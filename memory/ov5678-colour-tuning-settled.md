---
name: ov5678-colour-tuning-settled
description: "SUPERSEDED history — a GPU-debayer colour configuration no longer in use; kept for the highlight-magenta observation and the retracted EGL diagnosis"
metadata: 
  node_type: memory
  type: project
  originSessionId: cab23403-1de4-43b9-abfe-14c7e1f6837e
  modified: 2026-08-15T13:09:32.413Z
---

**SUPERSEDED — history only.** The camera runs the CPU debayer with the RGB-IR
pre-pass, not this. Kept because the highlight magenta noted below turned up
again with a strong colour matrix; see [[latitude-7320-handover]].

Settled 2026-08-09. Supersedes the CPU-debayer advice in
[[ov5678-verified-hardware-facts]].

**Running configuration:** GPU debayer (not `LIBCAMERA_SOFTISP_MODE=cpu`), with
`sudo tools/install-ccm.sh sat=1.8,wb=1.0972:1:2.6407`. Sahan chose 1.8 by eye;
2.0 brought back highlight magenta.

**The CPU workaround was wrong and is retracted.** GPU is faster (the CPU path
cost ~13 ms/frame once a CCM was installed, which stuttered) and its blacks are
far better: black floor `(70,50,144)` violet on CPU vs `(28,31,5)` on GPU. The
violet shadows were veiling flare amplified by the ~4.9x blue AWB gain, which
the GPU path does not apply. Correct the balance with a matrix instead.

**Retracted EGL mechanism.** The claim that the shader has no gains uniform is
false: `debayer_egl.cpp:475` uploads `combinedMatrix`, `awb.cpp:46` folds the
gains in unconditionally, the `GL_FALSE` on row-major data is deliberately
compensated by the shader indexing by hand (comment block in
`bayer_unpacked.frag:144-165`), and the EGL path does generate stats. The
defect is real and reproducible; the cause is unknown. Do not re-assert a
mechanism without new evidence.

**New defect found:** `Saturation` is silently inert unless the tuning file
defines a `Ccm`. `Adjust` gates both registration and application on
`ccmEnabled` (`adjust.cpp:33`, `:104`), and only `Ccm::init` (`ccm.cpp:39`) ever
sets it. So `libcamerasrc saturation=N` is accepted and ignored, no warning.
Installing an identity CCM is what turns the knob on.

**Lens shading is the largest remaining defect.** Flat field: 31% brightness
falloff centre to corner, and B/G varies **1.8x** across the frame (centre 1.11,
edges 1.86-1.99) - an IR-cut interference filter whose passband shifts with
incidence angle. No single white balance can be right everywhere; the tuning
targets the centre. The simple IPA has **no LSC algorithm** (`adjust`, `agc`,
`awb`, `blc`, `ccm` only), so fixing it means a new IPA algorithm plus a spatial
gain map in the debayer. Sahan deferred this; it is the obvious next project.

**Three traps that cost real time:**
- **Interior paint is not neutral.** Sahan's walls are cream. Calibrating
  against the wall gave blue 3.24; against white printer paper, 2.64. The
  over-correction is exactly why whites read lavender.
- **Lens shading makes the answer depend on where you sample.** Early wall
  patches were near frame edges, the blue-rich region.
- **Saturation puts magenta on blown highlights.** A clipped pixel reaches the
  matrix as (1,1,1) instead of the sensor's native ratios, so the correction
  overshoots: R and B pin at max, green is pulled down (0.86 at sat=1.4, 0.59 at
  sat=2.2). Inherent, not a bug.

**THE CCM IS FITTED AND INSTALLED, 2026-08-15 — the thing this file said could not be done.** Matrix `[1.8101, -0.3453, -0.4648, 0.3076, 0.4034, 0.2890, -0.1110, -0.6389, 1.7499]` at ct 6750, fitted on 18 of 24 patches, error 0.1414 -> 0.1143, **diagonally dominant** (the tool's own sanity check passes). Sahan's verdict: "much better". Saturation went ~12% -> 31%. The blue row (+1.75 blue, -0.64 green) is the row previously recorded as unfittable — it fits now because blue is real blue rather than infrared.

**Three traps had to be cleared to get there, all worth remembering:**
- **`solve-ccm.py fit` silently REUSES `data/ccm-capture.png`.** The first "result" was a fit on the 2026-08-08 frame from the *loaned* unit, which reproduced the old failure exactly because it was the old data. Run `capture` first; the old frame is now parked as `data/ccm-capture-2026-08-08-loaned-unit.png`.
- **`CCM_DARK_FLOOR` defaults to 0.25** to defend against a shadow artefact where B/G ran 7.9 at black. That artefact was the IR channel and now measures **1.49**, so the floor was excluding the blue patch for a reason that no longer applies. `CCM_DARK_FLOOR=0.08` took the fit from 12 patches to 18. **Note `sudo -E` does not pass it** — use `sudo VAR=value`.
- **Dimmer is not better.** A second, dimmer tablet gave 0 clipped patches and 23 of 24 usable, yet produced an ill-conditioned matrix with ±5 coefficients and no diagonal dominance: the patches were all near-grey (red read `(147,115,133)`, purple `(145,112,146)`) so least squares had nothing to separate. **Colour separation matters more than the patch count.** Keep the brighter fit.

**Always revert the CCM before re-capturing for a fit** — `install-ccm.sh` replaces rather than composes, so fitting over an installed matrix measures camera+CCM.

**"BLUES WILL NOT COME GOOD" IS PROBABLY WRONG — it rests on the same mislabelling as everything else (2026-08-15).** Re-running `tools/rgbir-offline.py` on `handover/raw-captures/rgbir-raw.bin` gives, black-subtracted:

    G 197.9   IR 19.7   R 129.4   B 102.6
    as 2x2 (ships today):  R 116.0  G 197.9  B  19.7   B/G 0.099
    as 4x4 (correct):      R 129.4  G 197.9  B 102.6   B/G 0.518

**Real blue is 51.8% of green, not ~16%.** The "16%" figure is the *infrared* channel: under the 2x2 reading the B label sits on IR positions (19.7/197.9 = 0.099), and the older "R/G 0.164" in [[ov5678-verified-hardware-facts]] is the same IR channel wearing the R label before the CFA fix. So the pessimism about blue was never about the sensor's blue response.

Consequences: with a correct RGB-IR pre-pass the needed gains are about **red x1.53, blue x1.93** — both far below the 3.996 AWB ceiling, so **the gain-clamp problem disappears entirely on this sensor** once the mosaic is read properly. That is a second, independent reason the `UQ<3,8>` patch's sensor justification had to be withdrawn.

Caveat: this is one saved frame measured offline, under whatever light it was captured in. Verify against a live capture before treating the 0.518 as this module's characteristic response.

Original claim follows, retained because the reasoning is instructive. **Blues will not come good.** Native blue is ~16% of green and the room light is
4000 K (from the product listing - the AWB's 3139 K estimate is derived from the
gains, so it is not independent evidence). Correct white balance is achievable;
vivid blues are not, without daylight.

Tooling: `tools/ccm-preview.sh` (captures + renders candidates, with a guard
that rejects unusable frames), `tools/try-ccm.py` (`--matrix <spec>` prints
coefficients; simulation is exact, identity round-trips at 0/255),
`tools/install-ccm.sh`, `tools/set-saturation.sh`.

## Green sharpness vs noise, measured 2026-08-16

`RGBIR_SHARPNESS` (0.0-1.0, in `install-camera-service.sh` and the debayer) trades green resolution against noise. **Default 0.0, which is bit-for-bit the old behaviour — verified 0 differing samples over a full 1259712-sample frame.**

`convert()` averages all 8 greens of the 4x4 cell into one value and writes it to *both* green slots of the output quad, so luma is flat across the cell — effectively 4x4 binning where the geometry only calls for 2x. `convertSharp()` can give each slot its own 2x2 quadrant mean instead.

Measured on one real raw frame (`cam -c1 -s role=raw -C120 --file='raw#.bin'`, then `libcamera-rgbir/compare-real.cpp`):

| sharpness | detail (mean abs vertical diff) | noise (flat-block sd) | detail/noise |
|---|---|---|---|
| 0.0 | 13.96 | 6.57 | 2.12 |
| 0.5 | 15.93 | 7.46 | 2.14 |
| 1.0 | 20.80 | 9.43 | 2.21 |

**I first called this a free 4x resolution recovery. That was wrong.** Detail-to-noise is flat across the range — it is a near-pure trade, because averaging 2 samples instead of 8 can only divide read noise by sqrt(2) rather than sqrt(8). It is a taste knob, not a quality setting. On a flat/clipped scene the extra grain is all you see (`data/sharp-vs-flat-green.png`).

What *is* real: on a synthetic grating at output-Nyquist the 4x4 average cancels the signal completely (peak-to-peak 1 vs 301), so detail at that frequency was being destroyed, not merely softened.

**Two measurement traps hit here.** An on-camera A/B was inconclusive (1.06x) because the scene was clipped, `p95=254`, with no high-frequency content — comparing algorithms needs a *detailed* scene or, better, one captured raw frame fed to both offline. And an awk sweep read the wrong column, reporting noise as constant; always check field positions against a printed sample row.

Since this is noise-limited, the remaining colour/quality levers are denoise, lens shading, and a second CCM at daylight CT — not the demosaic.

## Temporal denoise, 2026-08-16 — the biggest real win so far

`RGBIR_DENOISE` (still-area blend weight, lower = harder, **1.0 disables**) and `RGBIR_DENOISE_THR`, in `libcamera-rgbir/temporal_denoise.{h,cpp}` and `install-camera-service.sh`. **Defaults 0.25 / 40, now live.** Measured on a 120-frame captured raw sequence:

| alpha | temporal noise | recovery after a cut (3 frames) |
|---|---|---|
| 0.25 | **2.02x cleaner** | ~3 counts residual |
| 0.15 | 2.36x | ~5 |
| 0.10 (thr 120) | 3.77x | ~10 |

**No frame-rate cost: still 29.8 fps.** Independent confirmation: the captured PNG shrank 15% (2110202 → 1784674 bytes) — noise is what PNG cannot compress. Visual in `data/denoise-off-vs-on.png`.

Two design points that mattered, both found by measurement:
- **Per-sample motion detection does not work.** In a still scene the per-sample differences *are* the noise, so they drive the blend weight up and throttle the averaging — 1.44x instead of the 2.6x the recursion should give. Deciding motion over blocks fixes the variance but **not** the bias: `E[|d|]` stays at the noise level however many samples you average. What actually works is subtracting a **noise floor estimated from the frame itself** (10th percentile of block means), so it self-calibrates to exposure and gain.
- Use a **soft ramp**, not a hard threshold — hard switching is driven by noise and sparkles in exactly the flat areas being cleaned.

**Metric trap, important:** spatial flat-block sd **saturates on scene texture** and understated this badly (1.64x where the truth was 2.02x). The honest measure of temporal noise is per-pixel sd across settled frames. Also mis-read awk columns **twice** in this session — print one sample row and check `$n` positions before trusting a sweep.

Ranking after this: denoise was the real lever, not the demosaic (see above — that trade is flat). Remaining: lens shading, then a second CCM at daylight CT.

## Lens shading, 2026-08-16 — Intel's tables extracted, NOT yet validated

**Yes, this was derived before**, in `docs/aiqb-format.md` (record 100/28, `lens_shading_correction_4x4`) — but only decoded on paper, never extracted or wired up. Now both: `tools/extract-lens-shading.py` pulls it into `data/lens-shading-ov5678.bin`, and the debayer loads it from `RGBIR_SHADING=<path>`.

Layout confirmed by running it: 4x4 channel map, **7 illuminants x 5 channels**, 63x47 grid, gains fixed point with **2048 = 1.0x**. Plane order is **illuminant-major with the 5 channels contiguous** — proved from the data, since IR sits at column 1 of every row (mean 5.84 vs 1.84 for all others). The channel map reads `G I G I / R G B G / G I G I / B G R G`, a **third** independent confirmation of the mosaic after the graph-settings XML and our own i2c work.

Corner gains by channel at illuminant 0: G ~3.0, R ~3.8, B ~4.5, **IR ~16**. The code applies **only G/R/B** — `gains[Infrared]` is deliberately nulled, because IR is subtracted from the colour channels *before* shading, so a 16x IR gain would multiply IR's noise into R/G/B exactly where they are weakest. Costs a slight under-subtraction of IR at the edges, which is the harmless direction.

**Still OFF by default and unvalidated.** Validating needs a real flat field: on an ordinary room scene the uncorrected corner/centre ratio measured **1.03x** (i.e. "no vignetting at all") and **2.53x** with Intel's correction — both meaningless, because vignetting is inseparable from scene content. Same class of error as judging the sharpness A/B on a blank wall. `tools/measure-lens-shading.sh` captures a flat field, **refuses** it if clipped / too dark / not centre-brightest, reports what this unit actually needs, compares against Intel's table, and with `--write` produces a measured map instead.

Three space-in-path bugs so far from `/home/sahan/Claude Code` — this time `env VAR=$PWD/...` split the assignment. Always quote.

Also: `cam -c1 -C3` with no `-s` asks for full 2584x1944, which the half-size pre-pass cannot satisfy, so the RGB-IR path is **rejected entirely** ("too small for the requested"). Always pass `-s width=1280,height=720` when testing the pre-pass, or you are testing a different code path.

## Lens shading SHIPPED 2026-08-16, measured from raw — and the crop that matters

**Yes, the processed frame is cropped; the raw capture is not.** libcamera logs it: `RGB-IR half-size output 1296x972, window 8,126 1280x720`. So the visible 1280x720 is a window at offset (8,126) of the 1296x972 pre-pass output — in sensor terms, **2560x1440 at offset (16,252) out of 2592x1944**. The visible corners are therefore at a much smaller radius than the sensor's true corners. `cam -s role=raw` gives the **full uncropped 2592x1944** (10,077,696 bytes).

That single fact invalidated two measurements: green needed 2.38x at the *cropped* corners but **3.56x** at the real ones, and a map built from the processed output was applied over the full field, landing every gain at the wrong radius (it under-corrected to 0.78 instead of 1.00).

**The shipped map is measured from RAW** (`tools/measure-shading-raw.py`), which is the only valid way — the CCM's red row is `1.81R -0.345G -0.465B`, so per-channel shading measured through it is meaningless. Split-half validated (built on 10 frames, tested on the other 10): corners go **0.281 → 1.001** (G), **0.310 → 0.996** (R), **0.289 → 0.998** (B). Intel's own table on the same holdout leaves G 0.893, R 1.168, B 0.852 — a 32% red/blue spread, i.e. a warm corner cast. **Ours is used, Intel's is kept for reference.**

Measured need at the true corners: G 3.56x, R 3.22x, B 3.46x, IR 2.82x (not the ~16x Intel's IR plane implies; IR shading is not applied anyway).

**Live config**: `SHARPNESS=0.5 DENOISE=0.15 SHADING=<measured map>`, ~**27.7 fps** by libcamera's own `us/frame`.

### Four traps hit here, all worth remembering
- **`systemctl enable --now` does NOT restart a running unit.** Re-running `install-camera-service.sh` to change settings silently did nothing. Now uses `restart`.
- **systemd splits unquoted `Environment=` on whitespace.** The project path has a space, so the service silently got `RGBIR_SHADING=/home/sahan/Claude` and loaded nothing. Must be `Environment="VAR=value"`. Fourth space-in-path bug in this project.
- **Never trust loopback fps.** `/dev/video0` readings swung 10-30 fps for identical configs; they measure the whole gst chain against background load (Brave etc.), not the ISP. Use libcamera's `us/frame` Benchmark line. I wrongly concluded "denoise costs 3x frame rate" from loopback numbers; by the reliable metric all configs sit at ~28-30 fps.
- **Sampling stride-2 in both axes hits only green**, because green is on even parity — my first raw measurement read exactly 0 for R, B and IR.

## CPU / fan / frame-rate ceiling, 2026-08-17

**The fan running with "the camera off" is our own service.** `ov5678-camera.service` holds the sensor open and runs the full software ISP continuously for as long as it is enabled — measured: the **`SWIspWorker` thread pegged at 99.9% of one core for 24 minutes straight**, with every other core ~90% idle. That is the price of having replaced v4l2-relayd (which started on demand but throttled to 1.3 fps).

**The frame-rate ceiling is that same thread.** libcamera's software ISP is single-threaded; one core sits at 97% while the rest idle. Producer manages **28 fps** by libcamera's own `us/frame`. A browser reporting 14-16 fps is that 28 minus the `videoconvert -> v4l2sink -> loopback -> browser` chain competing for CPU with Brave and the desktop.

**On-demand start does not work as things stand, for a concrete reason:** v4l2loopback is loaded with `exclusive_caps=1` for video0, so with no producer the node advertises **output only** (`Device Caps 0x05200002`) and a consumer *cannot open it at all*. There is therefore no "app wants the camera" event to trigger on. Enabling it would need the module reloaded with `exclusive_caps=0`, which is a system-wide behaviour change — not done, needs a decision.

**A watcher I wrote made things worse and is disabled.** Scanning `/proc/[0-9]*/fd/*` in a bash loop forks `readlink` per descriptor: it consumed **30.5s CPU in 30.6s wall**, a full core, to save a full core. Rewritten as a single `find … -lname`, one scan costs **111 ms** — still 11% of a core at 1 Hz. `tools/ov5678-ondemand.sh` and `ov5678-ondemand.service` exist but are **disabled and not enabled at boot**; always-on is restored.

Ways to lift the ceiling, in order of payoff: the pre-pass converts all 2592x1944 to 1296x972 but only the **window 8,126 1280x720** is used, so ~26% of both the conversion and the denoise is wasted on rows nobody sees; then a GPU/EGL port of the pre-pass (`docs/aiqb-format.md` already argues for this); then multi-threading the debayer.

**Fifth and sixth space-in-path bugs** here: systemd split `ExecStart=$HERE/…` on the space in "Claude Code". Durable fix applied — the installer now stages runtime files to **`/usr/local/libexec/`** and **`/usr/local/share/ov5678/`**, so nothing systemd reads contains a space. Also `systemctl enable --now` does **not** restart a running unit, so re-running the installer to change settings silently did nothing until that was changed to `restart`.

## The CCM is now STALE, and its ct label was already wrong

Two separate problems, found 2026-08-17.

**The matrix is stale.** It was fitted 2026-08-15, *before* lens shading went in. Shading applies up to ~3.5x per-channel gain that varies across the frame, and the fit samples patches spread across that frame, so the matrix no longer describes the pipeline it sits in. It needs re-fitting.

**The `ct:` label is not a physical measurement.** libcamera's simple IPA does `ccm_.getInterpolated(ct)` keyed on `context.activeState.awb.temperatureK`, which comes from `estimateCCT()` over this AWB's own grey-world gains. So the label must be **whatever this estimator reports under the light the matrix was fitted for**. `install-ccm.sh` hardcodes `CT=3100` with the comment "matches the ~3139 K this sensor reports indoors" — true in August, but the same room now reads **4483-4649 K**, because the AWB gain clamp was removed and IR subtraction and lens shading were added since.

With **one** CCM this is harmless: `getInterpolated` returns it whatever the temperature. The moment a **second** is added, the wrong label makes it blend the wrong pair — so the label must be fixed before, not after, adding a daylight matrix. `tools/solve-ccm.py` now measures it: `reported_ct()` runs `cam` with `IPASoftAwb:DEBUG`, takes the median of the settled tail, and emits that as the `ct:` in the suggested YAML instead of the old hardcoded 6750.

The estimate itself is very stable — 30 samples gave median 4483, **stdev 1**.

Order of work: re-fit under current room light and label it with the measured CT; only then shoot a second illuminant and add it. Target to display is `data/ccm-target-16x9.png` (1920x1080).

## CCM re-fit ABANDONED 2026-08-17; IR subtraction is the real lever

**Do not re-fit the CCM against a screen-displayed target on this camera.** Two attempts produced matrices with off-diagonals of -2 to +4, one not even diagonally dominant, and error falling only 17-26%. The original `[1.8101, -0.3453, -0.4648, ...]` is **restored and kept**.

Why it cannot work as things stand: **the AGC fights the chart.** The chart's mean is mid-grey, so the AGC exposes for the mean and lets white clip. Both failures happen *simultaneously* — measured `exposure 2016/2016, analogue_gain 2047/2047` (fully pegged) **and** `white (251,251,251) CLIPPED` in the same frame. Screen brightness cannot fix that: brighter clips everything, dimmer maxes the AGC and white still clips. `EV=-1` does nothing because the AGC is already at its limit. Fixing this needs **manual exposure with the AGC disabled**, not more attempts.

The consequence is that the solver only ever gets ~13 of 24 patches (dark ones excluded for shadow offset, top ones for clipping) and has to reach saturated sRGB targets from a nearly-grey signal: red reads **(137,97,123)** against a (175,54,60) target. Hence the wild off-diagonals — they are the solver compensating for weak colour separation, which is not a job a CCM should be doing.

**The right lever is `RGBIR_IRSUB`, now set to 2.0** (was 1.0). Measured on the chart, red R/G: 1.39 at 0.0, 1.47 at 1.0, **1.56 at 2.0**, 1.68 at 3.0 — but at 3.0 white starts losing red (237,248,248), so 2.0 is the usable limit. Separation is still far short of the target (blue B/G 1.10 against 2.46), because a **single scalar** subtraction assumes every colour channel has the same IR sensitivity. The principled fix is **per-channel IR coefficients** (kR, kG, kB) fitted from the chart, which would let a tame CCM do the rest — that is the next real colour job.

Three tool bugs fixed while getting here, all of which produced confident nonsense:
- **`IRSUB=1.0` was a plain assignment** in `install-camera-service.sh`, so `IRSUB=2.0 ./install...` silently ran at 1.0. A whole four-point sweep came back byte-identical and looked like IR subtraction doing nothing. Now `${IRSUB:-1.0}`. Byte-identical results across a sweep are always a bug in the sweep.
- **`solve-ccm.py fit` reused a stale capture by default** — it scored a frame shot at a different screen brightness. Second time this trap has hit (first was a capture from the loaned unit). `fit` now captures FRESH; `--reuse` for the old behaviour.
- **A timed-out capture leaves its `gst-launch` holding /dev/video0**, so every retry dies with `not-negotiated (-4)` and adds another orphan. `capture` now reaps them by process *name* — never `pgrep -f v4l2src`, which matches the sweeping shell's own command line and kills its caller (did that too).

Also removed `videorate` from the capture pipeline: it stalls intermittently against a 2-buffer loopback, and its frame-spacing was pointless since the producer runs continuously and is already converged. And `solve-ccm.py` now prints `exposure N/max, analogue gain N/max` after every capture, plus normalises any residual white-balance error before solving — the code commented that a CCM must not be asked to fix white balance, but nothing acted on it.

## Per-channel IR coefficients: measured, NOT worth it (2026-08-17)

Fitted properly at last, from **raw mosaic** chart data (`tools/fit-ir-coeffs.py`, 24 averaged raw frames, 22 of 24 patches usable, only yellow clipped). Joint search over kR/kG/kB with a row-sum-constrained matrix solve at each point. **Negative result — do not implement per-channel IR subtraction.**

- best single k: **0.00**, chart error 0.1975
- best per-channel: kR=3.25 kG=3.75 kB=0.00, error 0.1888 — a **4.4%** improvement, and the asymmetric kB=0 smells like noise fitting
- **both** resulting matrices are NOT diagonally dominant

**The real finding: the sensor's colour separation is intrinsically short by 3-7x, and no 3x3 matrix can fix that affordably.** White-normalised dominant/next-channel ratios against what sRGB demands:

| patch | camera | target | shortfall |
|---|---|---|---|
| red | 1.40 | 9.49 | **6.8x** |
| blue | 1.50 | 6.54 | **4.4x** |
| green | 1.72 | 4.44 | 2.6x |

IR is only ~7-14% of green (measured per patch), so subtracting it cannot manufacture a 7x separation — which is exactly why the fit chose k=0.

**Noise amplification settles it** (row norms):

| matrix | worst channel |
|---|---|
| **installed `[1.8101, -0.3453, -0.4648, ...]`** | **1.90x** |
| per-channel fit | 3.89x |
| scalar-k fit | 5.34x |

On a sensor that is already noise-limited, a "more accurate" matrix costs 2-3x more noise. **The installed matrix is the right compromise and stays.** This is the quantitative version of what was already said to Sakari: the colour side is not a tuning problem.

Remaining honest levers for colour: none in the matrix. `RGBIR_IRSUB` is a taste knob (2.0 currently; higher saturates more, above ~3.0 the shadows go magenta as green clamps at zero).

### Guard added, after fitting a dark room for 90 frames
`fit-ir-coeffs.py` now **refuses** input that is not a chart: it scores the white->black neutral ramp for monotonicity in both orientations, picks the better, and exits if <80% monotonic or the brightest neutral is under 120 counts. It had happily fitted 90 raw frames of an empty dark room (6-56 counts per patch, "black" brighter than "white") and reported an answer. **Always confirm the scene before fitting, not after.**

Two more bugs, both mine: **stride-2 sampling hit only 2 of 4 channels** (green and IR read exactly zero, because the patch window started at odd row y=121) — same bug I had already fixed in `measure-shading-raw.py` and reintroduced; it now walks whole 4x4 cells. And **raw frames are upside down** relative to the processed view, because the module is mounted 180 degrees rotated and the pipeline undoes it downstream — now detected from the ramp rather than assumed.

## Fan fix SHIPPED 2026-08-17: on-demand pipeline, idle 104% -> 5.5% of a core

Idle CPU **104% -> 5.5%** of one core, **TCPU 99C -> 42C**. In use it is still ~100% of one core, unchanged and by design — this only stops it running when nothing is watching.

Three units, and only `ov5678-ondemand` is enabled at boot; it owns the other two:
- `ov5678-ondemand.service` — polls for consumers every 2s, starts the real pipeline, stops it 15s after the last one leaves
- `ov5678-placeholder.service` — black videotestsrc at 1 fps (static, watcher-started)
- `ov5678-camera.service` — the real pipeline, **disabled at boot**

Revert with `ONDEMAND=0` to `install-camera-service.sh`.

**Two things had to be discovered, and neither is guessable:**

1. **`exclusive_caps=1` makes on-demand impossible.** Set by `/etc/modprobe.d/v4l2-relayd.conf` (left by the relayd package we replaced). With it, and no producer, the node advertises **output only** (`Device Caps 0x05200002`) and an app cannot open it — so there is no event to trigger on. Overridden in `/etc/modprobe.d/zz-ov5678-loopback.conf` with `exclusive_caps=0` (sorts later, survives relayd being reinstalled). Original backed up to `data/v4l2-relayd.conf.backup`.

2. **Even with `exclusive_caps=0`, polling alone still cannot work.** With no producer the loopback has **no format at all** (`/sys/.../format` reads empty), so a consumer fails negotiation and exits in about **3.5 milliseconds**. Openers read 0 at every poll; no interval is short enough. Hence the **placeholder producer** — something must always hold a format on the device. This is v4l2-relayd's splash-image trick without the relay that throttled to 1.3 fps. Cost: an app opening cold sees black for a few seconds while the real pipeline starts.

**No cheap kernel signal exists.** v4l2loopback exposes no consumer count, and its sysfs is **byte-identical** with and without a consumer attached (checked every attribute). So it is a `/proc/*/fd` scan: ~96 ms each, hence the 2s poll. `v4l2loopback-ctl` (which could set caps directly and remove the placeholder) is not installed — `v4l2loopback-utils` would provide it.

**Measurement traps hit here:**
- A first watcher forked `readlink` per descriptor and consumed **30.5s CPU in 30.6s wall** — a full core, to save a full core. One `find … -lname` instead.
- `pgrep -f v4l2src…` matches the sweeping shell's **own** command line and kills its caller. Match on process name.
- `/proc/PID/stat` fields 14/15 are **self only**; children (`find`, `systemctl`) land in 16/17. Omitting them reported idle cost as **0.1%** when it is 5.5%.

**Why ~100% while streaming, for a webcam**: a normal webcam delivers finished MJPEG/YUYV from hardware. This one delivers a raw RGB-IR mosaic, the IPU6 hardware ISP is unusable here, so libcamera does pre-pass + debayer + denoise + shading in **software, single-threaded**, on 5 MP at 30 fps. Reductions available, in order: the **26% of pre-pass rows outside the 16:9 window** that are computed and discarded; a GPU/EGL port of the pre-pass; multi-threading the debayer (same total CPU but no single pegged core, so less thermal hotspot).

## Wasted pre-pass rows removed, 2026-08-17: streaming CPU 104% -> 78%

The pre-pass emitted 1296x972 but the debayer only ever read a **1280x720 window at (8,126)**, so 26% of both the mosaic conversion and the denoise was spent on rows that were then discarded. `RgbIrToBayer::setActiveRows(y0, y1)` limits the conversion to that band, and the denoise is applied to the same byte range.

Measured: **104% -> 78% of one core while streaming**, exactly the predicted 26%. Log confirms it: `converting rows 124..848 (74% of the frame)`. Image verified unchanged - full frame, no dead strips, top and bottom edge rows live and continuous with the interior (`data/band-check.png`).

Two details that matter if this is ever revisited:
- **Two rows of margin** each side, because the debayer interpolates across neighbours at the window edge. Without it the first and last visible rows would read unconverted data.
- Rows outside the band are deliberately left **stale**, not cleared - nothing reads them. The denoise must therefore be restricted to the same range, or its history would be blending against rows the conversion no longer updates.
- A cell row produces output rows `2*cy` and `2*cy+1`, so the band `[y0,y1)` maps to cell rows `[y0/2, (y1+1)/2 + 1)`.

Combined with the on-demand work, idle is **5.5%** and streaming **78%** of one core, against 104% in both cases before. Remaining reductions are a GPU/EGL port of the pre-pass, then multi-threading the debayer (same total CPU, but no single pegged core).

## exclusive_caps MUST stay 1 — setting it to 0 breaks browsers (2026-08-17)

I set `exclusive_caps=0` to make on-demand detection possible and **it broke the camera in Brave and Firefox.** With 0 the node advertises `Video Capture` **and** `Video Output` (`Device Caps 0x05200003`), and browsers reject a device that advertises output — which is precisely why v4l2loopback has this option.

**And it was never necessary.** `ov5678-placeholder.service` always holds the device as a **producer**, which both keeps a format on it *and*, with `exclusive_caps=1`, makes the node present and **capture-only** (`0x05200001`). The placeholder solves both problems at once; the module parameter change solved nothing and cost browser compatibility.

Reverted in `/etc/modprobe.d/zz-ov5678-loopback.conf` (still needed as a file, to pin `exclusive_caps=1` explicitly and document why). Re-verified after reverting: a consumer negotiates against the placeholder alone, the watcher promotes to the real pipeline within 2s, real video arrives (mean luma 153.6 vs black placeholder), it returns to idle, and `v4l2-ctl` reports **no** Video Output capability.

Lesson: when a module option exists specifically to make a device look like something, changing it will break whatever relied on that appearance. Check `Device Caps` before and after touching `exclusive_caps`.

## The "de-interlacing" artefact was my denoise — fixed 2026-08-18

User reported combing and ghosting on moving objects. Reproduced offline (settle the filter on real frames, shift the content, dump the result) and it was **two distinct faults, both mine**:

1. **Horizontal combing.** Motion was decided over `kBlock = 256` *consecutive samples*, which at 1296 samples per Bayer row is a **horizontal strip about a fifth of a row wide, not a tile**. A moving edge updated some strips and not others, leaving seams across it — exactly an interlacing look. **Fixed structurally**: `TemporalDenoise::setGeometry(w, h)` makes the decision over 32x32 **square tiles**. Row-seam energy 0.2894 -> **0.2025** (below even the denoise-off baseline of 0.2758, since averaging smooths noise too).
2. **Ghosting/double image** — inherent to an IIR temporal blend, not a bug. Mitigated by moving the default from `DENOISE=0.15` to **0.35**: error against ground truth on a moved frame 2.26 -> **1.75**, while keeping most of the noise reduction.

**`setGeometry` must be called or the fix silently does nothing** — the code falls back to linear runs when width/height are unknown. It is wired in `debayer_cpu.cpp` from `rgbIrHalfStride_/2` and the active row band.

Lesson worth keeping: "block-based" motion detection is meaningless without knowing the row stride. A flat sample count makes "block" mean "run", and the artefact that produces is structured and obvious to a viewer while being invisible in aggregate noise metrics — the denoise measured 2.0x cleaner the whole time it was combing moving edges.

## Chroma denoise shipped 2026-08-18 — the best remaining image win

`RGBIR_CHROMA_BLUR` (0 off, 1 = 3x3 cells, 2 = 5x5), **default 1**, in the pre-pass.

Chroma is where the visible noise is: on a flat patch of the finished pipeline, luma sd 5.64, Cb 5.56, but **Cr 10.03** — red-difference noise nearly double the luma. Red occupies 2 of 16 mosaic positions (an eighth of green's density) and the CCM's red row then amplifies it 1.90x.

Smoothing it is nearly free perceptually because R and B are **already one value per 4x4 sensor block** — the blur softens something that was never sharp. Controlled measurement, one raw frame through all three settings:

| radius | R sd | B sd | **G sd** |
|---|---|---|---|
| off | 13.22 | 11.63 | **13.45** |
| 3x3 | 7.06 | 5.08 | **13.45** |
| 5x5 | 5.88 | 3.75 | **13.45** |

**Green identical across all three** — that is the whole point. Visually (`data/chroma-blur-compare.png`) the coloured speckle disappears at 3x3 while embossed detail survives; 5x5 is quieter but looks soft. Costs **78% -> 89%** of one core.

**Measurement trap, again:** comparing three *separate live captures* gave incoherent numbers (luma sd 34 -> 42 -> 55, impossible since chroma blur cannot touch green) because the AGC re-converges independently each run and moves the noise floor. Feeding one raw frame through all settings is the only controlled comparison. A per-frame chroma/luma *ratio* is the usable live metric if separate captures are unavoidable (0.362 -> 0.238 -> 0.263).

Implementation note: `convertSharp` is now two passes — green written as computed, chroma buffered per cell, box-averaged, then written. The blur is clamped to the converted row band so it never reads rows the frame did not fill.
