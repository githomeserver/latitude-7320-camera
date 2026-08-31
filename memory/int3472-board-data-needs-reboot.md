---
name: int3472-board-data-needs-reboot
description: "INT3472 can only probe once per boot - unbind/bind and module reload both fail, so every board-data change costs a reboot"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6243c073-3758-4ca8-b577-c5b315cc9408
  modified: 2026-08-16T05:05:25.136Z
---

Testing any change to `tps68470_board_data.c` on the Latitude 7320 Detachable **requires a reboot**. There is no live path, and trying one leaves the camera dead until you reboot anyway.

Measured 2026-08-16. `unbind` succeeds and tears down all seven regulators; the following `bind` fails with:

```
int3472-tps68470 i2c-INT3472:07: INT3472 seems to have no dependents
```

**Why:** probe counts consumers with `for_each_acpi_consumer_dev()`, which walks the global ACPI dependency list. The *first* successful probe calls `acpi_dev_clear_dependencies()` → `acpi_scan_clear_dep()`, which **deletes** those entries. They are never recreated. `modprobe -r` + `modprobe` does not help either — the state lives in ACPI scan data, not in the module.

**How to apply:** budget a reboot per board-data experiment, and capture evidence with a systemd oneshot writing to a log rather than expecting to observe it live — a reboot kills the Claude session running on this laptop. `tools/test-patch1-isolated.sh` does exactly this (`install` / `verify` / `install-b` / `revert`).

Two related traps found the same day, both in that script's checks:
- A **successful** INT3472 probe is silent, so "no `No board-data found` in dmesg" proves nothing if the ring buffer was cleared. Gate it on the buffer still reaching boot (`Linux version` / `Command line:`).
- A voltage-comparison loop that examines zero regulators reports zero mismatches and passes. Gate every "all N match" check on N actually being found. Same false-pass shape as the stale-`dmesg` bug in [[ov5678-verified-hardware-facts]].

Also worth knowing: this machine's distro kernel ships **no** copy of `ov5675`, `ipu-bridge` or `intel_skl_int3472_tps68470` outside DKMS — installing `camera-dell7320` moved the stock ones into DKMS's `original_module` stash. "Use the stock module" means `dkms uninstall camera-dell7320/0.3 -k $(uname -r)`, not deleting files. See [[ov5678-pending-upstream-submission]].
