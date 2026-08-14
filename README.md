# Dell Latitude 7320 Detachable — front camera on Linux

The user-facing 5MP camera on the Dell Latitude 7320 Detachable has never
worked on Linux. This repository makes it work: kernel patches, a libcamera
patch and tuning file, the local configuration needed to reach it from a
browser, and the diagnostic scripts used to find all of it.

Two long-standing reports ask for this hardware:
[intel/ipu6-drivers#24](https://github.com/intel/ipu6-drivers/issues/24) (2022)
and [#402](https://github.com/intel/ipu6-drivers/issues/402) (2025), the latter
blocked waiting for "OV5678 sensor specifications (clock rates, power
requirements)".

## The short version

**`ov5675.c` drives it — but the sensor is RGB-IR, and no Linux driver can
describe that yet.**

ACPI names the part `OVTI5678` and no driver has ever claimed that ID. Once
powered it reports chip id `0x005675` at register `0x300a`, and every value
`ov5675.c` is sensitive to agrees:

| measured on this machine | `ov5675.c` |
|---|---|
| chip id `0x005675` @ `0x300a` | `OV5675_CHIP_ID 0x5675` |
| 2 CSI-2 data lanes (ACPI `L0NL`) | `OV5675_DATA_LANES 2` |
| 19.2 MHz MCLK (ACPI `L0CK`) | `OV5675_XVCLK_19_2` |
| 5MP front camera | 2592×1944 |

Three of those came from ACPI *before* the sensor was ever powered on. So no
new sensor driver and no reverse-engineered register tables were needed to make
it **stream** — which is what the problem had looked like for three years.

**Colour is a different story.** This is not a plain OV5675. It carries a 4×4
RGB-IR colour filter array, one pixel in four being infrared
([defect 5](#5-the-sensor-is-rgb-ir-not-bayer-at-all-kernel--root-cause)):

```
G I G I
R G B G
G I G I
B G R G
```

Read as the 2×2 Bayer every Linux tool assumes, the "blue" channel is **pure
infrared** and the "red" channel interleaves real red with real blue. That one
fact explains every colour problem documented below, and it cannot be fixed in
a driver: **mainline V4L2 has no RGB-IR media bus code at all.**

An earlier version of this file said flatly "it is an OV5675". That was wrong,
and it was wrong for an instructive reason — every measurement behind it was
taken through the sensor's *binned* mode, which averages IR pixels together
with colour ones and destroys the very structure being looked for.

## Status

Working: 1280x720 at ~30 fps in Firefox, Chromium, and anything else that opens
`/dev/video0`. Greys are neutral. Colour accuracy is limited by the sensor
being RGB-IR while the pipeline reads it as Bayer - see
[defect 5](#5-the-sensor-is-rgb-ir-not-bayer-at-all-kernel--root-cause).

| | before | after |
|---|---|---|
| works at all | no driver claimed the ACPI id | 1280x720, 30.7 fps |
| white balance (linear R/G) | 0.372 | 1.009 |
| colour cast | 34% saturation on white paper | ~6% |
| colour temperature | 6752 K indoors (nonsense) | 3139 K (correct) |
| red and blue | transposed | correct |
| black floor on a lit scene | `(70, 50, 144)` violet | `(28, 31, 5)` |
| debayer | CPU, ~13 ms/frame with a CCM | GPU, no stutter |
| full resolution | assumed too slow | 2584x1944 at 29.95 fps |

Those are single measurements on lit white paper; they move with the scene. See
[What step 6 should print](#what-step-6-should-print) for the ranges to expect.

Saturation is still low - see [Known limitations](#known-limitations). The rear
OV8856 is **not** addressed here.

## What was actually broken

Eight independent faults across three layers. Each had to be fixed before the
next became visible, which is why this took a while - and why the diagnostic
scripts in `tools/` may be more useful to you than the patches.

### 1. IPU6 firmware never loaded (kernel)

`MODULES=most` pulled `intel_ipu6` into the initrd, so it probed at t≈1.07 s —
before the root filesystem was mounted at t≈2.66 s. `intel/ipu/ipu6_fw.bin` did
not exist yet, probe failed `-ENOENT`, and PCI probe failures are not retried.

Fixed by regenerating the initrd with dracut, whose hostonly default does not
include it: `sudo dracut --force --kver "$(uname -r)"`. **No `omit_drivers`
configuration is needed** — the plain rebuild is enough.

### 2. No TPS68470 board data (kernel)

```
int3472-tps68470 i2c-INT3472:07: error -ENODEV: No board-data found for this model
```

Both sensors declare an ACPI `_DEP` on the control logic, so until the PMIC
driver probes successfully, **no i²c client is created for either sensor at
all**. Nothing can bind to a device that does not exist.

The rail assignment matches the Dell 7212 and Dell 5290 — VSIO/AUX1/AUX2 feeding
avdd/dvdd/dovdd — but **the GPIO mapping does not**. Reset is on `tps68470-gpio`
**5**, active low, and there is **no powerdown pin at all**: `ov5675.c` requests
only `"reset"`, so any `"powerdown"` lookup is dead code. Pin 3, which the 7212
and 5290 use for reset, is inert on this board.

An earlier version of this file said reset on 3 and powerdown on 4, taken from
that prior art and confirmed by the camera working. That was wrong, and wrong
instructively: the sensor probes with **no pin assigned at all**, because the
real reset line sits released by default. A wrong mapping is therefore invisible
here. What establishes the mapping is making the probe *fail* on demand — hold
line 5 low and the sensor stops identifying; hold line 3 low and nothing
happens. Verified on two physical units, three trials per condition.
Note the control logic here enumerates as `INT3472:07`, not `:05` as on the
other Dell models — the lookup matches on DMI *and* device name, so this must
be exact.

→ `kernel-patches/0001-*`

### 3. No driver claimed OVTI5678, and ipu-bridge did not know it (kernel)

Adding the ACPI ID to `ov5675.c` and an `IPU_SENSOR_CONFIG("OVTI5678", 1,
450000000)` entry to `ipu-bridge.c` is all that was required. 450 MHz is
`OV5675_LINK_FREQ_450MHZ`, the only link frequency that driver supports.

→ `kernel-patches/0002-*`, `kernel-patches/0003-*`

### 4. Browsers could not reach it (system configuration)

The kernel side working is not enough. Applications open a plain V4L2 device,
and the IPU6's 64 `/dev/videoN` nodes are raw Bayer sinks that cannot serve
one. The usable device is `/dev/video0`, a v4l2loopback fed by `v4l2-relayd`.

Two problems there:

- `v4l2-relayd` shipped `VIDEOSRC=icamerasrc`, Intel's closed CamHAL, which has
  no tuning data for this sensor. It falls back to an AR0234 tuning file and
  fails in a loop (`CamHAL[ERR] Input stream was missing`), so the loopback
  exists but nothing ever writes frames to it. Use `libcamerasrc` instead.
- The service sandbox permits only `char-drm/media/intel-ipu6-psys/psys/
  video4linux`, but libcamera's software ISP needs `/dev/dma_heap/system`
  (char **248**). Without it: `Could not open any dma-buf provider` →
  `disabling software debayering`, and no frames. **Testing the pipeline by
  hand does not reproduce this** — it only fails inside the unit.

Also constrain `libcamerasrc` to the target size. Left alone it picks the
sensor's full-resolution mode and software-debayers 2560×1600 per frame, giving
about 2 fps; constrained, libcamera selects the binned 1296×972 sensor mode and
it runs at 28.

→ `tools/fix-browser-camera.sh`, `tools/tune-relay-pipeline.sh`

### 5. The sensor is RGB-IR, not Bayer at all (kernel) — ROOT CAUSE

**Confirmed 2026-08-09 and it supersedes the GBRG explanation below.** Intel's
own pipeline configuration for this exact module - `graph_settings_OV5678_`
`0BF501T3_TGL.xml`, matching this machine's ACPI `_DDN` - declares
`bayer_order="GIGI_RGBG_GIGI_BGRG"` and `sensor_type="RGB_IR"`. The rear OV8856
in the same directory says plain `GRBG`.

```
G I G I        one pixel in four is INFRARED
R G B G
G I G I
B G R G
```

Measured directly at 2592x1944 on a red subject (`tools/check-rgbir.sh`),
black-level corrected, 10-bit counts:

```
G  8 positions   mean 116.1   spread 3.4
I  4 positions   mean  14.2   spread 0.1
R  2 positions   mean  89.7   spread 0.5
B  2 positions   mean  73.3   spread 0.1
```

Positions a 2x2 Bayer calls one channel differ by **18%**; the IR pair agrees
to **0.4%**. Not lens shading - the positions interleave at pixel level across
the same sampling area.

Read as 2x2 GBRG, which is what the patched driver declares:

| declared channel | what it actually is |
|---|---|
| green | green |
| **blue** | **pure infrared, at every position** |
| **red** | real red and real blue, checkerboarded |

That is the root cause of the whole colour effort: the ~4.9x blue gain was
amplifying infrared at 12% of green; "blue" was anti-correlated with subject
blue because infrared is (yellow reflects strongly in NIR); the CCM's blue row
was unfittable because the channel was not a colour channel; and the red
channel is an R/B spatial average, which is close to grey by construction.

**Binning destroys the mosaic.** Intel lists exactly one mode, 2592x1944, where
the plain-Bayer OV8856 gets several. Our pipeline runs the binned 1296x972
mode, which averages IR in with colour. Any RGB-IR work must be full-res.

Fixing this properly needs an RGB-IR demosaic, which libcamera's software ISP
does not have - it handles 2x2 mosaics only. Note that dropping the IR rows
does not leave a Bayer pattern either: rows 1 and 3 are `R G B G` and `B G R G`,
with red and blue in the same row.

### 5b. The GBRG workaround (superseded, still what ships here)

`ov5675.c` hardcodes `MEDIA_BUS_FMT_SGRBG10_1X10` in three places. On this board
red and blue are transposed, consistent with the module being mounted 180
degrees - rotating a GRBG array by 180 gives GBRG:

```
G R                G B
B G   --180-->     R G
```

Proven by capturing one raw frame and demosaicing it both ways
(`tools/demosaic-both-ways.sh`): a known-red Kmart logo renders red under GBRG
and blue under GRBG. After patching, two independent things fell into place -
the AWB gains mirrored (red 6.01 -> 1.46, blue 1.54 -> 4.90) and the estimated
colour temperature went from 6752 K to **3139 K**, i.e. from implausible
daylight to correct warm-indoor.

**A warning for anyone testing this.** The obvious check - confirming the two
green CFA positions agree - *cannot detect this fault*. GRBG and GBRG both put
greens at (0,0) and (1,1), so that test only rules out RGGB/BGGR. An R/B swap is
also invisible to grey-world AWB, because balancing to neutral works whichever
way the channels are labelled. Greys look perfect while every colour is wrong.
It cost a lot of time here.

Not upstreamable as-is: changing the code unconditionally would break every
ov5675 mounted the other way up. Upstream this needs a board-specific key. There
is also a genuine latent bug alongside it - the driver never adjusts the mbus
code when H/V flip are applied.

### 6. A strong cyan cast (libcamera)

Three further defects, each masking the next. On lit white paper, in **linear**
light (undo the sRGB transfer before averaging — comparing gamma-encoded ratios
against linear sensor ratios badly understates the error):

```
stock libcamera 0.7.0             R/G 0.372   B/G 0.897    saturation 34%
+ remove the AWB 4.0 gain clamp   R/G 0.551   B/G 0.901
+ tuning file with black level    R/G 0.562   B/G 0.905
+ LIBCAMERA_SOFTISP_MODE=cpu      R/G 1.091   B/G 0.997    saturation 5.1%
```

- **The AWB caps colour gains too low.** 0.7.0 clamps at a hardcoded 4.0; this
  sensor needs 6.1, so red sat pinned at exactly 4 on every frame while blue
  computed normally. → `libcamera-patch/` (applied to the local 0.7.0 build).
  Master does not fix this: the hardcoded clamp went away in `d5d00b9c3c5d`,
  but `AwbAlgorithmBase::process()` clamps to `gainMax_`, derived from the
  `AwbAlgorithm<UQ<2, 8>>` the simple IPA instantiates — a ceiling of 3.996.
  → `upstream-libcamera/0001-ipa-simple-awb-Widen-*` widens it to `UQ<3, 8>`.
- **The black level is guessed from the scene** when no tuning file exists —
  the 2nd percentile of the luminance histogram — and the AWB subtracts that
  guess before computing gains. Here the pedestal (64/1023) is about twice the
  red signal, so the error lands almost entirely on red. Pinning it took the
  computed gain from 4.79 to 6.01, against 6.13 predicted from raw
  measurements. → `libcamera/ov5675.yaml`
- **The EGL debayer does not apply the AWB gains.** Same scene, same build,
  only `LIBCAMERA_SOFTISP_MODE` differing: GPU `R/G 0.552`, CPU `R/G 1.091`.
  Not sensor-specific; it affects any camera on the software ISP with GPU
  acceleration, which is the default.

  **The mechanism is not known, and three plausible ones are ruled out.** An
  earlier version of this file claimed the shader has no gains uniform. That is
  wrong. `debayer_egl.cpp:475` uploads `params.combinedMatrix` as the `ccm`
  uniform; `awb.cpp:46` folds the gains into that matrix unconditionally; the
  apparently-wrong `GL_FALSE` on row-major data is deliberately compensated by
  the shader indexing the matrix by hand (`bayer_unpacked.frag:173`, with a
  comment block explaining it); and the EGL path does generate statistics. The
  one real asymmetry found is that `DebayerCpu` branches on `ccmEnabled` while
  `DebayerEGL` takes it as `[[maybe_unused]]` and always uses `combinedMatrix`.
  Installing an identity `Ccm` does not fix it either.

  Because the workaround is a colour correction, not `SOFTISP_MODE=cpu`, see
  [Colour tuning](#colour-tuning). → `tools/try-cpu-isp.sh`

- **The gains are floored at 1.0 as well as capped**, by
  `gainMin_ = std::max(Q::TraitsType::min, 1.0f)` (`libipa/awb.h:120`), even
  though `UQ<2, 8>::min` is 0.0. Grey world holds green at 1.0, so a sensor
  whose red is *stronger* than green would need a red gain below 1.0 and
  cannot express it. Not reproduced here — this sensor is red-weak, the
  opposite case — so it is reported as an observation from source, with no
  patch. Reported, not fixed.

### 7. `Saturation` is silently inert without a CCM (libcamera)

`Adjust` implements `controls::Saturation` by writing `combinedMatrix`, but
both the control's registration and its application are gated on
`context.ccmEnabled` (`adjust.cpp:33` and `:104`). That flag is set in exactly
one place, `Ccm::init` (`ccm.cpp:39`), which runs only if the tuning file
defines a `Ccm` algorithm.

So with no `ccms` section, `libcamerasrc saturation=2.0` is accepted and does
nothing at all, with no warning. Adding an identity `Ccm` makes the same
control start working. → `tools/install-ccm.sh`, `tools/set-saturation.sh`

## Installing

Ubuntu 26.04, kernel 7.0.0-29, libcamera 0.7.0-1ubuntu2. Adapt as needed.

`build-libcamera.sh` builds whatever `apt-get source libcamera` gives you, so it
tracks your distro rather than pinning a release. It checks for the clamp before
patching and tells you if the source has moved on — if the clamp is already gone
in your version, skip the patch and keep the rest of step 4.

Prerequisites — all in the Ubuntu archive, no OEM PPA required:

```sh
sudo apt install dkms build-essential "linux-headers-$(uname -r)" \
                 v4l2-relayd v4l2loopback-dkms v4l-utils \
                 gstreamer1.0-plugins-good python3-pil
```

`build-libcamera.sh deps` installs its own build dependencies on top of these.

```sh
# 1. kernel modules (board data + ov5675 ACPI id + ipu-bridge entry) via DKMS
sudo tools/dkms-install.sh
printf 'options intel_skl_int3472_tps68470 front_reset=5 front_powerdown=-1 rail_map=1 rear_reset=-1 rear_powerdown=-1\n' \
    | sudo tee /etc/modprobe.d/int3472-dell7320.conf
sudo dracut --force --kver "$(uname -r)"      # also fixes the IPU6 firmware race
sudo reboot

# 2. verify the kernel side
tools/check-camera.sh          # expects "Connected 2 cameras" and ov5675 in the graph

# 3. make it usable from browsers
sudo tools/fix-browser-camera.sh
sudo tools/tune-relay-pipeline.sh

# 4. colour: patched libcamera into /usr/local, nothing under /usr is touched
sudo tools/build-libcamera.sh deps
sudo tools/build-libcamera.sh build
sudo tools/build-libcamera.sh install
sudo tools/install-tuning.sh

# 5. colour correction (see "Colour tuning" - these numbers are per-camera)
sudo tools/install-ccm.sh sat=1.8,wb=1.0972:1:2.6407

# 6. verify colour
tools/check-colour.sh

# optional: hide the 64 dead ipu6 entries from the browser's camera list
sudo tools/hide-raw-ipu6-nodes.sh
```

Steps 1, 4 and 5 are all required to get colour right. Step 1 fixes the
red/blue transposition, step 4 fixes the libcamera defects, step 5 corrects the
residual white balance the GPU path leaves behind. Any one alone still looks
wrong, which is what made this confusing to diagnose.

**Do not copy the numbers in step 5.** They were solved for this camera in this
room. Derive your own - see [Colour tuning](#colour-tuning).

### What step 6 should print

Point the camera at a normally lit scene, not a coloured surface filling the
frame:

```
  linear   R/G 0.99   B/G 1.11     (1.000 = neutral)
  approx saturation 7.8%
```

These are scene-dependent — expect **R/G and B/G within roughly 0.9–1.15** and
**saturation under about 10%**. Exact agreement with the numbers above is not
the goal, and chasing it will mislead you. What matters is which failure you are
looking at if it is out:

| symptom | cause | fix |
|---|---|---|
| `R/G` around 0.3–0.4, strong cyan cast | full step 4 not applied | re-run step 4 in order |
| `R/G` around 0.55, cast reduced but present | no CCM installed | run step 5 |
| balance neutral but colours plainly wrong (red objects look blue) | GBRG CFA patch not loaded | check `modinfo -n ov5675` resolves to `updates/dkms` |
| saturation above ~30% | nothing from step 4 is in effect | check `systemctl show v4l2-relayd@default -p Environment` |
| whites tinted lavender | blue coefficient too high for your light | re-derive it, see [Colour tuning](#colour-tuning) |

Note the third row: **white balance can read perfectly neutral while every
colour is wrong.** Grey-world AWB balances to grey whichever way the channels
are labelled, so `check-colour.sh` passing does not by itself prove the CFA
phase is right. Confirm that separately with `tools/demosaic-both-ways.sh`.

## Uninstalling

Not every script uses the same word, so spelling it out:

```sh
sudo tools/dkms-install.sh revert         # or: remove
sudo tools/build-libcamera.sh revert
sudo tools/install-tuning.sh revert
sudo tools/fix-browser-camera.sh revert
sudo tools/hide-raw-ipu6-nodes.sh revert
sudo tools/try-cpu-isp.sh gpu             # no 'revert' - back to the default
sudo rm /etc/modprobe.d/int3472-dell7320.conf
sudo dracut --force --kver "$(uname -r)"
sudo reboot
```

`tune-relay-pipeline.sh` has no undo; `fix-browser-camera.sh revert` restores
the relay configuration it edited. The `/usr/local` libcamera build is left on
disk by `build-libcamera.sh revert` — remove it by hand if you want the space.

## Colour tuning

Step 5 installs a colour correction matrix. It does two jobs: it corrects the
white balance the GPU debayer leaves wrong (defect 6), and its mere presence
switches on the `ccmEnabled` code path, without which the `Saturation` control
does nothing (defect 7).

**Use the GPU debayer, not `SOFTISP_MODE=cpu`.** Earlier revisions of this file
recommended the CPU path as the workaround for defect 6. That was a mistake.
Measured on the same machine:

| | CPU debayer | GPU debayer |
|---|---|---|
| frame time (with a CCM) | ~13 ms | no stutter |
| black floor on a lit scene | `(70, 50, 144)` | `(28, 31, 5)` |

The CPU path also applies the CCM per pixel in software, which more than
doubled frame time here. The violet shadows in the CPU column are flare being
amplified by the ~4.9x blue AWB gain; the GPU path does not apply that gain, so
its blacks stay black. Correct the balance with the matrix instead.

### Deriving your own matrix

```sh
# 1. hold WHITE PRINTER PAPER filling the centre of the frame, then capture
tools/ccm-preview.sh              # refuses frames it cannot tune from

# 2. install, sweep saturation by eye, ~8 s per step
sudo tools/install-ccm.sh sat=1.2,wb=<r>:1:<b>
sudo tools/install-ccm.sh sat=1.8,wb=<r>:1:<b>

sudo tools/install-ccm.sh revert  # back out entirely
```

`tools/try-ccm.py` renders a captured frame through candidate matrices offline,
so you compare options side by side instead of restarting the relay for each.
The simulation is exact rather than approximate — the pipeline computes
`gammaLut[CCM * (gains * (raw - blacklevel))]` with `kDefaultGamma = 2.2` and
`kDefaultContrast = 1.0`, so linearising a capture, applying the matrix and
re-encoding reproduces what the camera would have emitted. Identity round-trips
at 0/255 error.

The values in step 5 came out of that process on this machine:
`wb=1.0972:1:2.6407` under a 4000 K LED, `sat=1.8` chosen by eye.

### Three traps, all of which cost time here

- **Your wall is probably not neutral.** Most interior paint is cream. Calibrate
  against it and you cancel a yellow that was genuinely there, so everything
  actually white comes out lavender. Use printer paper. Deriving the correction
  against a wall gave `b=3.24` here; against paper it was `2.64`.
- **Lens shading makes the answer depend on where you measure.** See below. Take
  the reference from the centre, which is where faces and held objects are.
- **Saturation puts magenta on blown highlights.** A clipped highlight arrives
  at the matrix as `(1,1,1)` rather than the sensor's native ratios, so the
  correction over-shoots: red and blue pin at maximum, green is pulled down.
  At `sat=1.0` clipped whites stay white; green falls to 0.86 at `sat=1.4` and
  0.59 at `sat=2.2`. That is inherent to correcting a large imbalance with a
  matrix, not a bug — real ISPs use highlight recovery, which the soft ISP has
  no equivalent of.

## Known limitations

**Saturation, and it is a sensor limit not a software one.** Colours render
undersaturated. A colour correction matrix would normally fix that, and it was
attempted and abandoned - deliberately. Red and green fit cleanly (~1.5 diagonal,
modest negative off-diagonals) but the blue row is unfittable:

```
patch            target B   camera B
yellow                 31        236     <- least blue subject, highest blue reading
blue flower           177        181
blue sky              157        177
cyan                  161        165
```

Target blue spans 6x, camera blue only 2.4x, and the two are anti-correlated.
With native `B/G 0.163` and a 4.9x AWB gain, blue is dominated by crosstalk and
flare rather than blue light, so there is no relationship for least squares to
find. Excluding shadow-corrupted dark patches made the blue row *worse*
(-0.08 -> -0.43), confirming it is not a shadow-offset problem. The tools are
kept (`tools/solve-ccm.py`, `tools/make-ccm-target.py`) but do not expect a
usable matrix from this sensor without better equipment than a tablet screen.

**Blues are weak because of the demosaic, NOT the sensor or the lighting.**
An earlier version of this file said the opposite - that ~16% native blue
response and warm indoor light made vivid blues physically unavailable. That
was wrong, and it was wrong because the channel being measured was infrared
(defect 5). The same sensor under Windows renders a colour-swatch poster with
vivid blues, magentas and yellows. Until an RGB-IR demosaic exists, blue is
half a checkerboarded channel and will stay weak; that is a software limit
with a known fix, not a hardware ceiling.

**The rear OV8856 does not work.** Its rails are covered by the same board data.
Its reset is reported to be `tps68470-gpio` 9 (`s_resetn`) and it has no
powerdown pin — that comes from Charles Drolet, who has the same machine, and is
not independently verified here. The `ov8856` driver Ubuntu ships also does no
power management at all on ACPI, and mainline's skips regulators and GPIOs when
`is_acpi_node()`, so the sensor needs those guards removed before any pin
mapping matters. That change affects every ACPI ov8856 system, the Surface
devices included, so it belongs in its own patch rather than folded into board
data. Two further rear-camera defects are open: a black frame at full
resolution (1920x1080 works), and power rails coming up on suspend — the latter
only when the `dw9714` VCM is loaded, which the front module does not have.

**`tools/hide-raw-ipu6-nodes.sh` makes `cam` need sudo**, because it takes the
raw nodes out of the `video` group. That is the trade for a clean camera list;
`cam` and `check-camera.sh` will report permission errors without it.

**Lens shading is uncorrected, and it is the largest remaining defect.**
Measured on a flat field (one uniform wall filling the frame):

```
              brightness   linear B/G
centre            237         1.11
edges             ~165        1.86 - 1.99
```

Those brightness figures are 8-bit gamma-encoded. **In linear light, which is
what a shading gain corrects, the corners are at 45% of centre and need a
2.22x gain** - an earlier version of this file called it "31% falloff", which
was the gamma-encoded difference and understated it badly. Separately,
**B/G varies 1.8x across the frame** - blue is nearly twice as strong at the
edges as in the middle.

Intel's own tuning file for this module ships lens shading tables that agree:
2.40x at the equivalent radius, within 8% of our measurement, from a completely
independent source. See [docs/aiqb-format.md](docs/aiqb-format.md). That is
an IR-cut filter behaving as interference filters do: its passband shifts with
the angle of incidence, so off-axis rays get a different colour response.

The consequence is that **no single white balance can be correct everywhere**.
Correct the centre and the corners go blue; correct the corners and the centre
goes yellow. The tuning here targets the centre, because that is where faces
and held objects are.

libcamera's simple IPA has no lens shading algorithm at all - its algorithms
are `adjust`, `agc`, `awb`, `blc` and `ccm` - so this is not a setting that can
be turned on. Fixing it means writing a new IPA algorithm plus a spatial gain
map in the debayer.

**The correction tables now exist.** Intel's tuning for this module contains
per-channel 63x47 gain grids - five channels, the fifth being infrared - in
1/2048 fixed point. Decoding is documented in
[docs/aiqb-format.md](docs/aiqb-format.md).

## Diagnostics

`tools/` holds everything used to work this out, not just the fixes. The
measurement scripts may be more useful than the patches if your hardware
differs:

| script | what it does |
|---|---|
| `collect-acpi.sh`, `collect-nvs.sh`, `decode-acpi.py` | read and decode the live ACPI camera description |
| `measure-sensor-delays.sh` | measure exposure/gain/vblank application delays from raw Bayer |
| `check-bayer-order.sh` | verify CFA phase and native channel balance, black level subtracted |
| `awb-evidence.sh` | native vs post-ISP colour balance in one run |
| `dump-ipa-debug.sh` | read libcamera's own computed gains rather than inferring them |
| `check-colour.sh` | current colour balance, no root needed |
| `diagnose-fps.sh` | isolate frame-rate loss between libcamera and the relay |
| `demosaic-both-ways.sh` | capture one raw frame, demosaic as GRBG and GBRG, compare |
| `check-rb-swap-raw.sh` | per-CFA-position response to a coloured subject, raw |
| `solve-ccm.py`, `make-ccm-target.py` | fit a colour correction matrix from a displayed target |
| `ccm-preview.sh` | capture a frame and render it through candidate matrices; refuses unusable frames |
| `try-ccm.py` | the renderer behind it; `--matrix <spec>` prints coefficients |
| `install-ccm.sh` | install a matrix and/or raise the black level |
| `set-saturation.sh` | the live saturation knob (needs a CCM installed first) |
| `check-rgbir.sh` | prove the mosaic is 4x4 RGB-IR, not 2x2 Bayer, from raw pixels |
| `rgbir-proof.sh` | demosaic one raw frame both ways, side by side; saves the raw |
| `rgbir-offline.py` | try mosaic phases and IR subtraction on a saved raw, no hardware |
| `rgbir-pipeline.py` | the full proposed chain using Intel's own tuning data |
| `bench-fullres.sh` | frame rate at binned vs full resolution, GPU and CPU |
| `diag-fullres.sh` | what sizes libcamera actually offers, when negotiation fails |
| `check-boot.sh` | IPU6 firmware timing and probe order after a reboot |
| `check-camera.sh` | end-to-end state: modules, i2c clients, media graph, nodes |
| `test-sensor.sh`, `test-load.sh` | load the modules and read the chip id by hand |
| `retry-regulator.sh` | recover a wedged TPS68470 without a reboot |
| `build.sh` | build the three modules out-of-tree, without DKMS |
| `upstream-regen.sh` | regenerate the patches in `kernel-patches/` |

Two scripts that were used along the way are in `attic/`, not `tools/`, because
they gave answers that turned out to be wrong: `check-rb-swap.sh` (tests through
the processed output — see the third trap below) and `calibrate-colour.sh`
(pins `ColourGains`, which the soft ISP ignores). Neither is worth running.

Two traps worth knowing:

- **`acpi_call` truncates its `/proc` reply at 256 characters**, about 42 bytes.
  `CLDB` (32 B) survives; `SSDB` (108 B) is silently cut at offset 0x29, losing
  MCLK and the control-logic id. Read the root-scope NVS scalars individually.
- **Subtract the black level** before computing channel ratios from raw Bayer.
  The pedestal is 64/1023 here, and in dim light it dominates entirely.
- **Do not test colour through the processed output.** Grey-world AWB neutralises
  any uniform colour that fills the frame, so a red screen photographed
  full-frame comes out grey. That is the algorithm working, not the camera
  failing. Use raw Bayer with fixed exposure, or a mixed scene.

Measurement logs from this machine are in `data/`.

## Upstream status

**The kernel series was submitted on 2026-08-09** and is on the lists:

  https://lore.kernel.org/linux-media/20260809042540.15849-1-adee.sahan@gmail.com/

Nothing merged yet. The libcamera half is deliberately held back until the
kernel series settles, because how linux-media responds to the RGB-IR
disclosure shapes how the libcamera side should be framed.

| patch | destination |
|---|---|
| `kernel-patches/0001-*` int3472 board data | platform-driver-x86 |
| `kernel-patches/0002-*` ov5675 ACPI id | linux-media |
| `kernel-patches/0003-*` ipu-bridge entry | linux-media |
| `upstream-libcamera/0001-ipa-simple-awb-Widen-*` AWB gain range | libcamera-devel |
| `libcamera-patch/0001-*` AWB 4.0 clamp | **local 0.7.0 build only** - the row above replaces it upstream |
| `libcamera/ov5675.yaml` black level | libcamera-devel |
| `upstream-libcamera/0001-libcamera-sensor-*` sensor delays | libcamera-devel |
| `Saturation` inert without a `Ccm` (report only) | libcamera-devel |
| AWB gain floor of 1.0 (report only, unmeasured) | libcamera-devel |
| GBRG CFA phase (`sensor-ov5675/ov5675.c`) | **not submittable** - a workaround, see below |

The GBRG change is a workaround, not a fix, and should not be sent anywhere.
The sensor is RGB-IR (defect 5); GBRG merely puts real red into the red channel
at half the positions, which is why it beats the alternative. The better of two
wrong answers.

**The real fix needs an ABI addition first.** There is no RGB-IR media bus code
in mainline V4L2 - 36 Bayer codes, none for an IR mosaic - and libcamera's
`BayerFormat` models 2x2 by construction. This is not specific to this sensor:
`ox05b1s` declares `SGRBG10` for an RGB-IR part of the same class and
resolution, and TI carries 4x4 RGB-IR formats in their vendor tree for the
OV2312 and OX05B1S which never reached mainline. The next step is an RFC to
linux-media proposing those codes, aligned with TI's naming rather than
inventing a second convention.

`upstream-libcamera/AWB-BUG-REPORT.md` writes up all four libcamera defects
with measurements. Its EGL section states which explanations have been *ruled
out* as well as what was observed - an earlier draft asserted a mechanism that
turned out to be wrong, and reporting a confident wrong cause is worse than
reporting an honest observation.

## Work in progress: RGB-IR support

`libcamera-rgbir/` holds the first piece of a proper fix: a converter turning
the 4x4 RGB-IR mosaic into a half-resolution 2x2 Bayer image, so libcamera's
existing debayer, statistics, AWB and CCM all work unmodified. That is the
architecture Intel's own IPU6 hardware uses (its block is called `x2b_rgbir`).

Half resolution is not a compromise. A 4x4 RGB-IR cell holds exactly two red
and two blue pixels, and a 2x2 Bayer cell at half resolution needs exactly one
of each, so chroma maps across with nothing discarded. Green averages four into
one - the same reduction the sensor's binned mode already performs, except
binning averages IR in with colour and this does not.

Validated against the Python reference on a real captured frame, agreeing to
0.0002 in channel ratios (`libcamera-rgbir/check.sh`). It is not yet wired into
libcamera; the remaining work is buffer plumbing in `SoftwareIsp`, telling
libcamera the sensor is RGB-IR at all, and the pipeline handler accepting
full-res in with half-res out.

**Frame rate is not the obstacle** - full resolution measured at 29.95 fps
against 30.69 at 1280x720, so four times the pixels cost nothing
(`tools/bench-fullres.sh`).

[`docs/aiqb-format.md`](docs/aiqb-format.md) documents how Intel's `.aiqb`
tuning files decode - lens shading, colour matrices and the infrared model -
and where to get the struct definitions, which Intel publishes. The tuning
files themselves are proprietary and are deliberately not in this repository;
extract them from a Windows install as described there.

## Licence

The kernel sources under `module/`, `sensor-ov5675/` and `ipu-bridge/` are
derived from Linux and are GPL-2.0, as marked in each file. The scripts under
`tools/` are GPL-2.0 to match. `libcamera/ov5675.yaml` is CC0-1.0, matching
libcamera's other tuning files.

## Credit

The TPS68470 GPIO and rail mapping came from
[jelsco/latitude-5290-camera](https://github.com/jelsco/latitude-5290-camera)
and the in-tree Dell 7212 entry; two independent Dell tablets agreeing is what
made that configuration worth trying first.
