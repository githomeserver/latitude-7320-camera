# Decoding Intel's `.aiqb` camera tuning, for OV5678 on the Latitude 7320

`OV5678_0BF501T3_TGL.aiqb` (543,144 bytes) is the Intel IQ tuning for this
machine's front camera. `0BF501T3` is the ACPI `_DDN`, so it is this module.
The `OV5678_YHUE_TGL` variant is byte-identical, so this is sensor-level
tuning, not per-unit calibration.

The record layout is **documented by Intel**, in `ia_cmc_types.h` from the
public `ipu6-camera-bins` repo (`include/ipu6/ia_imaging/`, the plain `ipu6`
variant for Tiger Lake). Get it with:

    gh api repos/intel/ipu6-camera-bins/contents/include/ipu6/ia_imaging/ia_cmc_types.h \
       --jq '.content' | base64 -d > ia_cmc_types.h

`cmc_name_id` maps record type IDs to names, and the structs give exact
layouts. No need to touch a Windows install for the format - only for the
`.aiqb` itself.

## Container

```
CPFF                      magic, then total size
  LCMC                    nested, size - 16
    DFLT                  nested, size - 16
      AIQB                nested, size - 16
        metadata strings  timestamp, IQStudio 20.49.1.0, LibIQ 2.0.359.0
        records...        from offset 0xc0
```

Record header is 8 bytes: `uint32 size`, then `format_id`, `group_id`,
`type_id`, `reserved` as single bytes. `size` includes the header. 17 records.

## Record identification

`type_id` maps straight onto `cmc_name_id`:

| type | name | size here |
|---|---|---|
| 2, 3, 31 | general_data, black_level, black_level_global | 40, 464, 2056 |
| 7, 9 | module_sensitivity, noise | 16, 32 |
| 13 | optics_and_mechanics | 88 |
| 15, 16, 17 | chromaticity_response, flash_chromaticity, nvm_info | 1120, 24, 16 |
| 19, 20 | analog_gain_conversion (deprecated), digital_gain | 16, 24 |
| 22 | geometric_distortion_correction2 | 10360 |
| **25** | **advanced_color_matrices** - the CCM | 6552 |
| 26, 34 | hdr, multi_gain_conversions | 64, 280 |
| **27** | **infrared_correction** | 5112 |
| **28** | **lens_shading_correction_4x4** | 207456 |

## Which records matter

Diffing against `OV8856_0BA801T3_TGL.aiqb` - the rear camera, a plain Bayer
sensor - isolates what is RGB-IR specific:

| fmt/type | OV5678 (RGB-IR) | OV8856 (Bayer) | |
|---|---|---|---|
| 100/28 | 207456 | 166008 | lens shading, **5 channels vs 4** |
| 101/27 | 5112 | absent | **only on the RGB-IR sensor** |
| 100/25 | 6552 | 5632 | differs |
| 101/15 | 1120 | 2656 | differs |
| 100/29, 100/33 | absent | 33944, 166008 | Bayer only |

The channel count follows from arithmetic, not guesswork. If the record is a
fixed header `H` plus `n` equal per-channel tables, then
`(207456-H)/5 == (166008-H)/4` gives `H = 216` and 41448 bytes per channel,
exactly, for both files. Nothing else fits.

## Record 100/28 - lens shading

The first 16 bytes are a 4x4 channel-index map:

```
0 1 0 1        0 = G (even rows)
2 3 4 3        1 = IR
0 1 0 1        2 = R
4 3 2 3        3 = G (odd rows)
               4 = B
```

Read that as colours and it is `G I G I / R G B G / G I G I / B G R G` -
Intel's `GIGI_RGBG_GIGI_BGRG`. **This independently confirms both the mosaic
and its phase**, and the phase agrees with the one chosen empirically from skin
tone in `tools/rgbir-offline.py`. Two greens are tracked separately, as Gr/Gb
are in Bayer, hence five channels.

The next values are `7, 5, 63, 47`: 5 channels, 63x47 grid, and 7 is presumably
the illuminant count (5 x 7 = 35 planes).

Layout, established by correlation search over header length and plane size
rather than assumed:

```
38 bytes    record preamble
35 planes   each: 2 uint16 of per-plane header, then 63*47 uint16 of gain
```

`35 * (2 + 2961) * 2 + 38 = 207448`, exactly the record body length.

**Gains are fixed point with 2048 = 1.0x.** A plane's radial profile:

```
r=0.00  1.04x
r=0.50  1.41x
r=1.00  2.40x
r=1.38  3.29x     monotonically increasing with radius
```

### Cross-check against our own measurement

A flat field captured on this machine gives centre 237, corners 165 in 8-bit
output. **In linear light** - `(v/255)^2.2`, which is what a shading gain acts
on - corners are 45% of centre, so they need **2.22x**. Intel's table at the
equivalent radius says **2.40x**. Agreement within 8%, from two completely
independent sources.

Note the README previously quoted "31% falloff" for this. That figure was
computed on gamma-encoded values and understates it badly; the linear falloff
is 55%.

## Still undecoded

- **Plane ordering.** Which of the 35 planes is which channel and illuminant is
  not established. The 2-uint16 per-plane header sometimes reads 32768 or 0,
  which suggests the split between preamble and plane header is not exactly
  right even though the total arithmetic works.
- **Colour matrices** are record 100/25, `cmc_advanced_color_matrix_correction`:
  `num_light_srcs`, `num_sectors`, then per light source a `traditional` matrix
  plus an array of per-hue-sector matrices. Not yet extracted.

## Record 101/27 - infrared_correction (decoded)

`cmc_infrared_correction`: `grid_indices[4][4]`, `num_light_srcs`, grid count,
`grid_width`, `grid_height`, then per light source a `cmc_ir_grid`.

The grid indices confirm the mosaic and phase a third time:

```
 0 -1  0 -1        G  I  G  I     0 = green
 1  0  2  0        R  G  B  G     1 = red
 0 -1  0 -1        G  I  G  I     2 = blue
 2  0  1  0        B  G  R  G    -1 = IR, not corrected
```

Every -1 lands on an IR pixel. Red at (1,0)/(3,2), blue at (1,2)/(3,0).

Layout: 830-byte stride per light source = 20-byte header + 3 grids of 15x9
uint16. Six light sources, with `chromaticity_i_per_g` - the sensor's IR/G
ratio:

```
A (incandescent)  0.862      D65   0.484
F12 (fluorescent) 0.686      D75   0.459
D50               0.550      (type 20, unknown)  0.946
```

**Practical consequence.** Measured on this machine, IR/G is about **0.10** -
far below even the daylight figure. White LEDs emit almost no near-infrared,
and the room here is a 4000 K LED. So IR contamination is a second-order
effect *in this lighting*, which is why empirical IR subtraction barely changed
the image. It would matter a great deal under halogen or daylight.

## Licensing

These are Intel's proprietary tuning files, shipped in a Windows driver. The
numbers extracted here are facts about how this specific camera module behaves,
which is the sort of interoperability information a driver needs. Do not commit
the `.aiqb` files themselves to this repository, and do not paste extracted
tables into GPL sources without thinking about provenance first.


## Full-resolution throughput (measured 2026-08-09)

RGB-IR requires the unbinned mode, which is 4x the pixels we run today. It is
not a bottleneck:

```
GPU  1280x720    30.69 fps      CPU  1280x720    29.96 fps
GPU  2560x1600   29.96 fps      CPU  2560x1600   29.96 fps
GPU  2584x1944   29.95 fps      CPU  2584x1944   29.95 fps
```

Measured from the slope of a 40-buffer and a 160-buffer run so pipeline
startup cancels out. The sensor runs at 30 fps and nothing downstream limits
it, so **full resolution costs no frame rate**.

Note libcamera's maximum is **2584x1944**, not the sensor's 2592x1944 -
`(2x2)-(2584x1944)/(+2,+2)`. Requesting 2592 is rejected outright with
`not-negotiated`. The 8-column crop preserves the 4x4 mosaic phase.

The CPU column is not trusted: it contradicts an earlier in-service
measurement of 12.6 ms/frame at 1296x972, which would predict ~20 fps at 5 MP.
The benchmark uses fakesink and so excludes the relay's v4l2sink, conversion
and loopback costs. Unexplained; the GPU figure is the one the plan rests on.

## First integration attempt failed (2026-08-09)

`tools/install-rgbir.sh` builds and installs cleanly, but the resulting
picture was **worse**: more magenta, plus lag, black frames and white frames.
Reverted with `install-rgbir.sh disable`, which restored the working pipeline.
Two separate problems, and they need separating before another attempt.

**1. Performance, and this one was predicted.** The CPU now does a 5 MP
pre-pass *and* a 5 MP debayer *and* a 5 MP to 720p scale, every frame. The
lag, black frames and white frames are all consistent with the pipeline
missing its deadline and frames being dropped or delivered incomplete.

`tools/bench-fullres.sh` reported the CPU debayer managing 29.95 fps at
2584x1944, which was recorded at the time as **not trusted** - it contradicts
an in-service measurement of 12.6 ms/frame at 1296x972, which predicts ~20 fps
at 5 MP before any pre-pass is added. That scepticism looks justified. The
benchmark uses `fakesink`, so it excludes the relay's v4l2sink, the format
conversion and the loopback, and it excludes the scaler this configuration
adds.

**Consequence: the pre-pass belongs in the EGL shader, not the CPU debayer.**
The GPU path is what runs today at 30 fps and it is where the work has to go.
That is a bigger change than hooking `DebayerCpu::process()` - the shader
reads the mosaic directly, so it means a new fragment shader variant rather
than a buffer transform - but the CPU route appears to be a dead end on this
hardware.

**2. Magenta, cause not established.** Magenta means green low relative to red
and blue. Candidates, none yet tested:

- **Crop phase.** libcamera's stream is 2584x1944 against the sensor's
  2592x1944, so it crops 8 columns. The conversion runs from the buffer origin
  over `inputCfg.size`, but `DebayerCpu::process2()` then offsets into that
  buffer by `window_.x/y`. If `window_.x` is not a multiple of 4 the 4x4 cell
  phase shifts under the debayer and the channel assignment is wrong. This is
  the first thing to check - print `window_` and `inputCfg.size` and see.
- **Bayer order.** The code derives GBRG from the declared `SGBRG10`. If the
  emitted order is wrong, red and blue transpose - though that would look
  swapped rather than magenta.
- **Black level.** Hardcoded 64 in the pre-pass. Wrong here would shift all
  three channels, but not obviously toward magenta.

**Not yet ruled out and worth checking first**, because it is cheap: whether
the `LIBCAMERA_RGBIR` log line appeared at all. If the pre-pass never ran,
the magenta is simply what full-resolution capture looks like through the
existing 2x2 misreading, and only the performance problem is real.
