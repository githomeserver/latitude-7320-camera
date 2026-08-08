# Soft ISP: three colour defects found on an OV5675 (AWB gain clamp, black
# level sensitivity, GPU debayer discarding AWB gains)

Draft for libcamera-devel@lists.libcamera.org. Nothing has been sent.

---

**Subject:** Soft ISP: AWB gain clamped at 4.0, and the EGL debayer does not
apply AWB gains

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
shift. Chasing it turned up three separate problems, each of which masked the
next: fixing any one alone changes little or nothing.

| # | Problem | Effect on output |
|---|---------|------------------|
| 1 | AWB clamps colour gains at a hardcoded 4.0 | red gain pinned at 4.0, needs 6.1 |
| 2 | Black level is guessed from the scene when no tuning file exists | computed red gain wrong (4.79 vs 6.01) |
| 3 | The EGL debayer does not apply the AWB gains | correct gains never reach the pixels |

Measured on lit white paper, in **linear** light (the sRGB transfer function is
undone before averaging), R/G and B/G, where 1.000 is neutral:

```
stock 0.7.0                       R/G 0.372   B/G 0.897    saturation 34%
+ remove the 4.0 clamp            R/G 0.551   B/G 0.901
+ tuning file with black level    R/G 0.562   B/G 0.905
+ LIBCAMERA_SOFTISP_MODE=cpu      R/G 1.091   B/G 0.997    saturation 5.1%
```

## 1. AWB clamps colour gains at 4.0

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
`means.g() / std::max(means.r(), 1.0)` - so this may already be resolved
upstream by the refactor, and 0.7.0 simply predates it. A patch matching that
behaviour is attached. With it applied the gain becomes live (4.73-4.79) and
R/G moves 0.372 -> 0.551.

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
tables. The EGL shader has no gains uniform at all - `debayer_egl.cpp` binds
only `ccm`, `blacklevel`, `gamma`, `contrastExp`, `tex_step`, `tex_size`,
`stride_factor`, `tex_bayer_first_red` and `proj_matrix` - so the gains have to
arrive folded into `params.combinedMatrix`. Empirically they do not, or not
fully.

I have not traced where `combinedMatrix` is assembled or why the gains are
lost, so I am reporting the observation rather than proposing a fix. If this is
confirmed, it affects every sensor using the software ISP with GPU
acceleration, which is the default when `HAVE_DEBAYER_EGL` is set.

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

## Attachments

- `0001-soft-awb-remove-hardcoded-4.0-gain-clamp.patch`
- `ov5675.yaml` (black level only)
