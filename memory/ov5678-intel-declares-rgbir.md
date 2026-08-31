---
name: ov5678-intel-declares-rgbir
description: "Intel's own shipped files declare the OV5678 as RGB_IR with the exact 4x4 CFA order, independently confirming the i2c measurements"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 6243c073-3758-4ca8-b577-c5b315cc9408
  modified: 2026-08-16T06:39:58.644Z
---

**The strongest evidence in the project, found 2026-08-16 — and it was sitting in the Windows files the whole time.**

`System32\drivers\graph_settings_OV5678_{0BF501T3,YHUE}_TGL.xml` (two byte-identical 1.7 MB copies, Apache-2.0, Copyright Intel) declares, for this exact part:

```xml
<sensor_modes sensor_name="OV5678" csi_port="0" metadata="0" interlaced="0"
              bayer_order="GIGI_RGBG_GIGI_BGRG">
  <sensor_mode name="2592X1944" id="0" width="2592" height="1944" fps="30"
               bpp="10" sensor_type="RGB_IR" pdaf_type="PDAFNone" ...>
```

- **Exactly one** `bayer_order` value in the whole file, and **exactly one mode**. No binned variant — independent support for the `num_modes = 1` change.
- `GIGI_RGBG_GIGI_BGRG` matches [[ov5678-is-rgb-ir]] position for position, and it is **not ad-hoc**: it is `cmc_bayer_order_gigi_rgbg_gigi_bgrg` in the `cmc_bayer_order_4x4` family (kept separate from the 2x2 orders) in Intel's **public** header — https://github.com/intel/ipu6-camera-bins/blob/main/include/ipu6/ia_imaging/ia_cmc_types.h
- Same directory, same machine, the rear sensor: `graph_settings_OV8856_*.xml` says `bayer_order="GRBG"` with **two** modes. Same vendor, same format, described differently.

**Corrects an earlier claim that was wrong:** "ov5678.sys is the only file among 20727 containing OV5678, no other driver or DLL references the part." Eight files under System32 contain it — the two XMLs, Intel's `iacamera64_*` extension INFs, the `.inf`/`.ini` — and `ov5678.sys` itself carries it mostly as **UTF-16**, so a plain ASCII grep misses it. The file count (20727) was right; the claim was never checked.

Other numbers that were wrong and are now corrected in the Sakari mail: `.data` is **7 KB raw** (12 KB was VirtualSize — raw is what matters for data tables on disk); the driver is **182424 bytes**; one `ov5675.c` mode is **150 writes / 132 distinct registers / 14 pages**, not "138 across 16 pages". Longest ordered (u16 reg, u8 val) run in the binary really is **21**.

Also found: `jameshi16/ideapad-duet-5i-gc5035-ov5678-patches` on GitHub — another machine (Lenovo IdeaPad Duet 5i) with this same sensor, actively worked on. Supports Charles's product-naming argument in [[ov5678-pending-upstream-submission]].
