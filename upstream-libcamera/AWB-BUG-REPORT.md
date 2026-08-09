# Soft ISP: four colour defects found on an OV5675 (AWB gain clamp, black
# level sensitivity, EGL debayer not applying AWB gains, inert Saturation)

Draft for libcamera-devel@lists.libcamera.org. Nothing has been sent.

---

**Subject:** Soft ISP: AWB colour gains capped too low (4.0 on 0.7.0, 3.996 on
master), and the EGL debayer does not apply AWB gains

## Environment

- libcamera 0.7.0 (Ubuntu 26.04, package 0.7.0-1ubuntu2)
- Pipeline handler `simple`, software ISP, GPU acceleration available and
  enabled by default
- Sensor: OV5675, 1296x972 SGRBG10 binned mode, behind an Intel IPU6
  (Dell Latitude 7320 Detachable). Described as OVTI5678 in ACPI but reports
  chip id 0x005675 and is driven by `ov5675.c`.
- Kernel 7.0.0-29-generic

## Summary

The camera produced a strong cyan cast that no amount of configuration could
shift. Chasing it turned up four separate problems, the first three of which masked
each other: fixing any one alone changes little or nothing.

| # | Problem | Effect on output |
|---|---------|------------------|
| 1 | AWB caps colour gains at 4.0, and at 3.996 on master | red gain pinned at the cap, needs 6.1 |
| 2 | Black level is guessed from the scene when no tuning file exists | computed red gain wrong (4.79 vs 6.01) |
| 3 | The EGL debayer does not apply the AWB gains | correct gains never reach the pixels |
| 4 | `Saturation` is inert unless the tuning file defines a `Ccm` | control accepted, silently ignored |

Measured on lit white paper, in **linear** light (the sRGB transfer function is
undone before averaging), R/G and B/G, where 1.000 is neutral:

```
stock 0.7.0                       R/G 0.372   B/G 0.897    saturation 34%
+ remove the 4.0 clamp            R/G 0.551   B/G 0.901
+ tuning file with black level    R/G 0.562   B/G 0.905
+ LIBCAMERA_SOFTISP_MODE=cpu      R/G 1.091   B/G 0.997    saturation 5.1%
```

## 1. AWB caps colour gains too low

`src/ipa/simple/algorithms/awb.cpp`:

```c
	/*
	 * Calculate red and blue gains for AWB.
	 * Clamp max gain at 4.0, this also avoids 0 division.
	 */
	auto &gains = context.activeState.awb.gains;
	gains = { {
		sum.r() <= sum.g() / 4 ? 4.0f : static_cast<float>(sum.g()) / sum.r(),
		1.0,
		sum.b() <= sum.g() / 4 ? 4.0f : static_cast<float>(sum.g()) / sum.b(),
	} };
```

Any sensor whose red response is below a quarter of green can therefore never
be white balanced. This one needs 6.1. The IPA log shows red pinned at exactly
4 on every frame while blue computes normally:

```
IPASoftAwb awb.cpp:103 gain R/B: Vector { 4, 1, 1.54655 }; temperature: 6448
IPASoftAwb awb.cpp:103 gain R/B: Vector { 4, 1, 1.54634 }; temperature: 6448
IPASoftAwb awb.cpp:103 gain R/B: Vector { 4, 1, 1.54581 }; temperature: 6451
```

Blue jitters in the fourth decimal; red does not move at all.

`AwbGrey` in libipa on master has no such ceiling - it does
`means.g() / std::max(means.r(), 1.0)`. The clamp survives one layer up,
though, so the refactor does **not** resolve this. Checked against master
`62d4bfc45079` on 2026-08-09:

- `d5d00b9c3c5d` (2026-08-06, "ipa: simple: awb: Port to use libipa
  AwbAlgorithm") deleted the code quoted above. The simple IPA now computes
  RGB means only and delegates the gain calculation.
- `AwbAlgorithmBase::process()` then clamps every computed result:
  `awbResult.gains = awbResult.gains.clamp(gainMin_, gainMax_)`
  (`src/ipa/libipa/awb.cpp:385`).
- Those bounds come from a fixed-point template parameter. The simple IPA
  instantiates `AwbAlgorithm<UQ<2, 8>>` (`src/ipa/simple/algorithms/awb.h:59`)
  and `src/ipa/libipa/awb.h:120-121` derives `gainMin_ = 1.0` and
  `gainMax_ = UQ<2,8>::max`, which is 1023/256 = **3.996**.

So on master this sensor is still pinned, now at 3.996 rather than 4.0.

The choice is not forced by anything. The member's own comment concedes as
much - "There actually is no Q register format for SoftISP, but allow the
colour gains to range in the [0.0f, 3.999f] interval, which seems reasonable"
- and nothing in the software path quantises a gain: `DebayerParams::gains` is
an `RGB<double>`, and `DebayerCpu` builds its lookup tables in double,
clamping only the table index rather than the gain magnitude. The identical
`AwbAlgorithm<UQ<2, 8>>` appears in the rkisp1 IPA
(`src/ipa/rkisp1/algorithms/awb.h:52`), where that format is a real register
layout; the software ISP appears to have inherited the range without the
hardware.

Note also that the comment describes the interval as `[0.0f, 3.999f]` while
`gainMin_ = std::max(Q::TraitsType::min, 1.0f)` makes the floor 1.0, so a
sensor whose red is *stronger* than green cannot be attenuated either.

Two patches are attached, for the two trees:

- Against master, widening the format to `UQ<3, 8>` (ceiling 7.996). Not
  compile-tested - see Caveats.
- Against 0.7.0, removing the hardcoded clamp. This is the one actually
  measured here: with it applied the gain becomes live (4.73-4.79) and R/G
  moves 0.372 -> 0.551.

## 2. Black level is guessed from the scene

Not a bug so much as a sensitivity worth flagging. With no tuning file,
`BlackLevel` estimates the pedestal from the 2nd percentile of the luminance
histogram, and `Awb::calculateRgbMeans()` subtracts that estimate before
computing grey-world gains. On this sensor the pedestal is 64/1023, about 6.3%
of full scale, while red carries only ~3.3% signal in ordinary indoor light -
so the pedestal is roughly twice the red signal and any error in it lands
almost entirely on the red gain.

Measured directly off the sensor (raw Bayer, dark frame subtracted):

```
black level (exposure=4):          64.7  64.1  64.5  64.7   (10-bit)
signal (exposure=2016, gain=1024): green 209.4 counts above black

black-level-corrected CFA means:
  (0,0) Gr 209.2   (0,1) R 34.2   (1,0) B 139.3   (1,1) Gb 209.6
  native balance: R/G 0.164  B/G 0.665
```

so neutral requires red x6.1. Pinning `blackLevel: 4122` in a tuning file took
the computed gain from 4.79 to **6.01**, against 6.13 predicted from the raw
measurements. A tuning file for ov5675 is attached; it defines only the black
level.

## 3. The EGL debayer does not apply the AWB gains

This is the one that matters most, because it is not sensor-specific.

With the clamp removed and the black level pinned, the AWB computes the correct
red gain of 6.01 - and the image does not change. Same scene, same build, only
`LIBCAMERA_SOFTISP_MODE` differing:

```
GPU (default)   R/G 0.552   B/G 0.903    saturation 23.6%
CPU             R/G 1.091   B/G 0.997    saturation  5.1%
```

The CPU debayer applies `params.gains` directly when building its lookup
tables. The EGL path does not, and the output is visibly wrong.

**What is NOT the cause.** An earlier draft of this report claimed the EGL
shader has no gains uniform and that the gains are therefore never folded in.
That is wrong, and it is stated here explicitly so nobody spends time on it:

- `debayer_egl.cpp:475-485` does upload `params.combinedMatrix`, as the `ccm`
  uniform.
- `awb.cpp:46` folds the gains into `combinedMatrix` unconditionally
  (`combinedMatrix = combinedMatrix * gainMatrix`), so that matrix does carry
  them.
- The column-major upload is *not* a bug either. `glUniformMatrix3fv` is called
  with `GL_FALSE` on row-major data, but `bayer_unpacked.frag:173-175` indexes
  the matrix manually to compensate, and a comment block at lines 144-165
  documents exactly that convention. Upload and shader agree.
- The EGL path does generate statistics (`SwStatsCpu`, `debayer_egl.cpp:566`),
  so the AWB is not starved of input.

**A concrete asymmetry worth checking.** `DebayerCpu::configure()` stores
`ccmEnabled` (`debayer_cpu.cpp:528`) and branches on it per pixel, using the
gains LUTs when it is false and `combinedMatrix` when it is true.
`DebayerEGL::configure()` takes the same argument as
`[[maybe_unused]] bool ccmEnabled` (`debayer_egl.cpp:291`) and ignores it,
always going through `combinedMatrix`. The two backends therefore disagree
about which path is authoritative, and `ccmEnabled` is only ever true when a
tuning file happens to define a `Ccm` algorithm (`ccm.cpp:39` is its sole
assignment).

I could not pin down where the gain is actually lost, so this is reported as a
reproducible observation with the wrong explanations eliminated, rather than as
a diagnosis. Installing an identity `Ccm` in the tuning file does **not** fix
it: on this hardware the GPU output still needs a manual diagonal correction of
R x1.10, B x2.64 to reach neutral, measured against white paper.

If confirmed, it affects every sensor using the software ISP with GPU
acceleration, which is the default when `HAVE_DEBAYER_EGL` is set.

## 4. The saturation control is silently inert without a CCM

`Adjust` registers `controls::Saturation` and applies it by modifying
`combinedMatrix` (`adjust.cpp:105`), but both the registration and the
application are gated on `context.ccmEnabled` (`adjust.cpp:33` and `:104`).
That flag is set in exactly one place - `Ccm::init` (`ccm.cpp:39`) - which runs
only if the tuning file defines a `Ccm` algorithm.

So for any sensor whose tuning file has no `ccms` section, setting
`Saturation` - including via `libcamerasrc saturation=2.0` - is accepted and
does nothing. No warning is logged. Adding an identity `Ccm` to the tuning file
makes the same control start working, which is a surprising dependency between
an unrelated tuning entry and a public control.

Either the control should be rejected when it cannot be honoured, or
`Adjust` should be able to write `combinedMatrix` on its own.

## Reproduction

```sh
# after the ISP, via a v4l2loopback fed by libcamerasrc
gst-launch-1.0 libcamerasrc ! video/x-raw,width=1280,height=720 \
  ! videoconvert ! identity eos-after=8 ! pngenc ! multifilesink location=f-%02d.png

# then the same with LIBCAMERA_SOFTISP_MODE=cpu and compare
```

Average the frame in linear light, not in sRGB - comparing gamma-encoded ratios
against linear sensor ratios understates the error considerably, which cost me
a while.

## Caveats

- One sensor, one illuminant. The native R/G of 0.164 is low; I have not
  characterised the light source, so the absolute figure may be partly that.
- The raw CFA sampling used a stride of 4 pixels, so it samples one fixed
  phase. Enough to confirm the two green positions of a 2x2 Bayer agree to
  0.2%, but it would not detect a larger repeating CFA.
- Native and post-ISP figures are separate captures of a static scene seconds
  apart, not the same frame.
- Point 3 is an observation with a clean A/B, not a diagnosis.
- Every measurement here was taken on 0.7.0. The master patch is reasoned from
  the source and is neither compile-tested nor measured: the machine was a
  loan and has gone back, so no further captures are possible on it. The
  sensor figures it rests on (R/G 0.164 native, red gain 6.1 for neutral) are
  properties of the sensor rather than of a libcamera version.

## Attachments

- `0001-ipa-simple-awb-Widen-the-colour-gain-range-to-UQ-3-8.patch`
  (against master `62d4bfc45079`)
- `0001-soft-awb-remove-hardcoded-4.0-gain-clamp.patch` (against 0.7.0, the
  tree these measurements were taken on)
- `ov5675.yaml` (black level only)
