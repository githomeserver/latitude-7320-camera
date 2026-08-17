# Kernel patches

## What to apply

**`v2-0001-...board-data...patch`** — the only one that has been submitted and is
current. Generated against **v7.2-rc7** with a `base-commit:` trailer, so:

```sh
git am v2-0001-platform-x86-int3472-Add-TPS68470-board-data-for-Dell-7320-Detachable.patch
```

Archived on the list at
<https://lore.kernel.org/platform-driver-x86/20260816070108.9308-1-adee.sahan@gmail.com/>

On its own this patch makes the PMIC probe and the two i2c clients appear. **No
sensor binds from it alone** — that needs the `ov5675` ACPI id below. If you just
want a working camera, use `tools/dkms-install.sh` instead, which builds this same
board data plus the two sensor-side changes as out-of-tree modules.

## superseded-v1/

The first series, sent 2026-08-09. **Do not apply these.** Its board-data patch
has the **wrong GPIO** — reset on line 3 and a powerdown pin that does not exist —
which was found by making the probe fail on demand rather than by the camera
working, since the sensor probes with no pin assignment at all and a wrong mapping
is invisible in normal use. Kept only so the list discussion has context.

Patches 2/3 (`ov5675` ACPI id) and 3/3 (`ipu-bridge` entry) are still needed for a
working camera, but the copies here are the **v1** versions generated against 7.0.
They are held upstream pending the RGB-IR format question, so they have not been
regenerated. `tools/dkms-install.sh` carries the current versions.

## 0009-sakari-followup.mail

The follow-up sent to the linux-media thread reporting the RGB-IR investigation,
including retractions of two earlier claims. Kept because it is the fullest
written record of why 2/3 is held.
