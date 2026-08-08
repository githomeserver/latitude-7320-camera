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

**The sensor is not an OV5678. It is an OV5675, and Linux has had a driver for
it since 2019.**

ACPI describes the part as `OVTI5678` and no driver has ever claimed that ID.
Once powered, it reports chip id `0x005675` at register `0x300a` — exactly what
`ov5675.c` expects. Every other value agrees too:

| measured on this machine | `ov5675.c` |
|---|---|
| chip id `0x005675` @ `0x300a` | `OV5675_CHIP_ID 0x5675` |
| 2 CSI-2 data lanes (ACPI `L0NL`) | `OV5675_DATA_LANES 2` |
| 19.2 MHz MCLK (ACPI `L0CK`) | `OV5675_XVCLK_19_2` |
| 5MP front camera | 2592×1944 |

Three of those came from ACPI *before* the sensor was ever powered on. So no
reverse engineering, no new sensor driver, and no recovering register tables
from a Windows binary — which is what the problem had looked like for three
years.

## Status

Working: 1280×720 at ~28 fps in Firefox, Chromium, and anything else that opens
`/dev/video0`. Colour is white-balanced correctly. Colour *accuracy* is still
approximate — see [Known limitations](#known-limitations).

The rear OV8856 is **not** addressed here.

## What was actually broken

Five independent faults, in three different layers. Each had to be fixed
before the next became visible, which is why this took a while.

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

The GPIO and rail assignments match the Dell 7212 and Dell 5290: reset on
`tps68470-gpio` 3, powerdown on 4, VSIO/AUX1/AUX2 feeding avdd/dvdd/dovdd.
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

### 5. A strong cyan cast (libcamera)

Three further defects, each masking the next. On lit white paper, in **linear**
light (undo the sRGB transfer before averaging — comparing gamma-encoded ratios
against linear sensor ratios badly understates the error):

```
stock libcamera 0.7.0             R/G 0.372   B/G 0.897    saturation 34%
+ remove the AWB 4.0 gain clamp   R/G 0.551   B/G 0.901
+ tuning file with black level    R/G 0.562   B/G 0.905
+ LIBCAMERA_SOFTISP_MODE=cpu      R/G 1.091   B/G 0.997    saturation 5.1%
```

- **The AWB clamps colour gains at a hardcoded 4.0.** This sensor needs 6.1, so
  red sat pinned at exactly 4 on every frame while blue computed normally.
  `AwbGrey` in libipa on master has no such ceiling, so 0.7.0 may simply
  predate that refactor. → `libcamera-patch/`
- **The black level is guessed from the scene** when no tuning file exists —
  the 2nd percentile of the luminance histogram — and the AWB subtracts that
  guess before computing gains. Here the pedestal (64/1023) is about twice the
  red signal, so the error lands almost entirely on red. Pinning it took the
  computed gain from 4.79 to 6.01, against 6.13 predicted from raw
  measurements. → `libcamera/ov5675.yaml`
- **The EGL debayer does not apply the AWB gains.** Its shader has no gains
  uniform — only `ccm`, `blacklevel`, `gamma`, `contrastExp` — so gains must be
  folded into `params.combinedMatrix`, and empirically are not. Same scene,
  same build, only `LIBCAMERA_SOFTISP_MODE` differing: GPU `R/G 0.552`, CPU
  `R/G 1.091`. This is not sensor-specific and affects any camera on the
  software ISP with GPU acceleration, which is the default.
  → `tools/try-cpu-isp.sh`

## Installing

Ubuntu 26.04, kernel 7.0.0-29. Adapt as needed.

```sh
# 1. kernel modules (board data + ov5675 ACPI id + ipu-bridge entry) via DKMS
sudo tools/dkms-install.sh
printf 'options intel_skl_int3472_tps68470 front_reset=3 front_powerdown=4 rail_map=1 rear_reset=-1 rear_powerdown=-1\n' \
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
sudo tools/try-cpu-isp.sh cpu

# optional: hide the 64 dead ipu6 entries from the browser's camera list
sudo tools/hide-raw-ipu6-nodes.sh
```

Every script takes `revert`.

## Known limitations

- **Colour accuracy.** White balance is correct; there is no colour correction
  matrix, so saturated colours render washed out and hue-shifted. A CCM would
  fix it and none has been measured.
- **`LIBCAMERA_SOFTISP_MODE=cpu` costs frame rate.** Relay CPU goes from ~36% to
  ~45%. Measured frame rate was inconsistent between runs (28 and 17.6 fps) and
  has not been pinned down.
- **The rear OV8856 does not work.** Its rails are covered by the same board
  data, but its reset/powerdown GPIOs are unknown, and pins 3 and 4 belong to
  the front sensor. The `ov8856` driver Ubuntu ships also does no power
  management at all on ACPI.
- **`tools/hide-raw-ipu6-nodes.sh` makes `cam` need sudo**, because it takes the
  raw nodes out of the `video` group. That is the trade for a clean camera list.

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

Two traps worth knowing:

- **`acpi_call` truncates its `/proc` reply at 256 characters**, about 42 bytes.
  `CLDB` (32 B) survives; `SSDB` (108 B) is silently cut at offset 0x29, losing
  MCLK and the control-logic id. Read the root-scope NVS scalars individually.
- **Subtract the black level** before computing channel ratios from raw Bayer.
  The pedestal is 64/1023 here, and in dim light it dominates the red channel
  entirely.

Measurement logs from this machine are in `data/`.

## Upstream status

Nothing merged yet.

| patch | destination |
|---|---|
| `kernel-patches/0001-*` int3472 board data | platform-driver-x86 |
| `kernel-patches/0002-*` ov5675 ACPI id | linux-media |
| `kernel-patches/0003-*` ipu-bridge entry | linux-media |
| `libcamera-patch/0001-*` AWB gain clamp | libcamera-devel |
| `libcamera/ov5675.yaml` black level | libcamera-devel |
| `upstream-libcamera/0001-*` sensor delays | libcamera-devel |

`upstream-libcamera/AWB-BUG-REPORT.md` writes up all three libcamera defects
with measurements.

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
