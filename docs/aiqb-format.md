# Decoding Intel's `.aiqb` camera tuning, for OV5678 on the Latitude 7320

`OV5678_0BF501T3_TGL.aiqb` (543,144 bytes) is the Intel IQ tuning for this
machine's front camera. `0BF501T3` is the ACPI `_DDN`, so it is this module.
The `OV5678_YHUE_TGL` variant is byte-identical, so this is sensor-level
tuning, not per-unit calibration.

Everything below was derived by inspection. Nothing here is from Intel
documentation, and the parts that are guesses are marked as such.

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
- **Record 101/27** (5112 bytes, RGB-IR only). Presumably the IR subtraction
  model - `iacamera64.sys` documents `x2b_rgbir` registers `irmodelcua{r,g,b}N`
  (11 each), `irmodelcub{r,g,b}N` (6 each), `irmodelcux{r,g,b}N` (12 each),
  plus sigma/offset/max, which is a per-channel model rather than a constant.
- **Colour matrices.** Not yet located. Candidates are the small records
  102/13 (88 bytes) and 101/26 (64 bytes).

## Licensing

These are Intel's proprietary tuning files, shipped in a Windows driver. The
numbers extracted here are facts about how this specific camera module behaves,
which is the sort of interoperability information a driver needs. Do not commit
the `.aiqb` files themselves to this repository, and do not paste extracted
tables into GPL sources without thinking about provenance first.
