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
