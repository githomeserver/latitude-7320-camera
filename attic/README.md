# attic

Superseded work, kept because it documents how the key finding was made.

## `ov5678.c`

A from-scratch V4L2 sensor driver skeleton, written when the part was still
believed to be an OV5678 with no existing driver. It binds `OVTI5678`, brings
up the clock, regulators and GPIOs, and reads the chip id — deliberately
stopping there, because everything past that point needs the per-mode register
sequences that were assumed to require reverse engineering.

It never got that far. On its first successful run it reported:

```
ov5678 i2c-OVTI5678:00: chip id at 0x300a reads 0x005675
  reg 0x300a = 0x00   reg 0x300b = 0x56   reg 0x300c = 0x75
```

`0x005675` is an OV5675, and `ov5675.c` has been in mainline since 2019. So the
register tables were never needed, this driver was never needed, and the real
fix was one line added to an existing driver's ACPI match table.

Use `../sensor-ov5675/` instead. This is kept only as the record of that
measurement, and as a reminder that reading the chip id is worth doing before
assuming a part is undocumented.

## `check-rb-swap.sh`

Shows a saturated primary fullscreen and reads which channel the camera
reports. Its own header argued that reading the *processed* output "is the
point, since the demosaic assumes GRBG". That reasoning is wrong, and it is the
single most expensive mistake in this project.

Grey-world AWB neutralises any uniform colour that fills the frame. A fullscreen
red target comes back grey — not because the channels are fine, but because the
algorithm did exactly its job. The test cannot distinguish a working camera from
a swapped one. It also wants `data/rbtest/*.png`, which is gitignored, so it
will not run from a fresh clone anyway.

`../tools/demosaic-both-ways.sh` is the test that actually settled it: capture
one raw frame, demosaic it both ways, and look at a subject of known colour.

## `calibrate-colour.sh`

Measures the colour error and pins `ColourGains` on `libcamerasrc` via a
systemd drop-in. It does not work — the soft ISP ignores `ColourGains`
entirely, confirmed by sweeping red from 2 to 8 with no change in output, and
`AwbEnable=false` produces identical frames too.

Kept because the drop-in technique is still the right answer to a real problem:
`colour-gains` needs GstValueArray syntax (`<r,b>`), and putting that in
`VIDEOSRC` fails because systemd expands the variable into `/bin/sh`, which
reads `<` as a redirection and dies with `cannot open 2.77,1.38`.

The green cast was a libcamera bug, not a missing calibration. See defect 6 in
the top-level README.
