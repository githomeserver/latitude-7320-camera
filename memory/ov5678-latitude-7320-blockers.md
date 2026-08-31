---
name: ov5678-latitude-7320-blockers
description: "Status of the Dell Latitude 7320 Detachable OV5678 camera-driver project — Phase A done, both original blockers resolved 2026-08-08"
metadata: 
  node_type: memory
  type: project
  originSessionId: 97fc555f-ab9e-4791-8e72-1f6f5673802e
  modified: 2026-08-08T00:41:06.702Z
---

Goal: a Linux V4L2 sensor driver for the front 5MP **OV5678** on a Dell Latitude 7320 Detachable (Ubuntu 26.04, kernel 7.0.0-29-generic, IPU6 at PCI 0000:00:05.0). Brief: `~/Downloads/ov5678-driver-brief.md`. Work tree: `~/Claude Code/ov5678/`. Verified values in [[ov5678-verified-hardware-facts]].

**Phase A is complete and validated on a clean boot (2026-08-08).** Out-of-tree DKMS module `int3472-dell7320/0.1` rebuilds `intel_skl_int3472_tps68470` (upstream `tps68470.c` unmodified + a new `tps68470_board_data.c` with only the 7320 entry, `.dev_name = "i2c-INT3472:07"`). Result at boot: INT3472 binds, all three MFD cells bind, all 7 rails register, and `i2c-OVTI5678:00` / `i2c-OVTI8856:00` finally exist.

Both blockers that dominated the early work turned out to be resolved:

1. **IPU6 firmware race — fixed as a side effect of regenerating the initrd with dracut.** The old initrd (built with initramfs-tools semantics, `MODULES=most`) pulled `intel_ipu6` in early, so it probed at t≈1.07s before rootfs and failed `-ENOENT` on `ipu6_fw.bin`. A plain `dracut --force` rebuild uses hostonly defaults and omits it, so it now loads at t≈3.9s after switch-root, finds the firmware, and comes up: `CSE authenticate_run done`, `/dev/media0`, 8 CSI-2 receivers. **No `/etc/dracut.conf.d/` entry is needed or present** — don't add `omit_drivers`, the default rebuild is enough.
2. **`intel_ipu6_isys` NULL-deref on runtime-PM suspend — did not recur.** Plausibly because the sensors now enumerate properly, so `isys_probe()` sets drvdata before autosuspend fires. `power/runtime_status=suspended` with no oops. Treat as *not reproduced*, not *proven fixed* — it was a race.

**Do not use `wait_for_device_probe()` inside this probe path.** It does `flush_work(&deferred_probe_work)`, which self-deadlocks if the probe runs on that workqueue — a boot-hang risk. A one-off `-ENOENT: getting tps68470-clk` seen on a hand-`insmod` did not reproduce at boot.

**One probe per boot.** `acpi_dev_clear_dependencies()` frees the `_DEP` entries, so after the first successful INT3472 probe any reload fails with "INT3472 seems to have no dependents". Module parameters (`front_reset`, `rear_reset`, `rail_map`, …) are therefore read once per boot — sweeping them needs a reboot each. Drive the tps68470 gpiochip lines directly with libgpiod instead for a fast loop.

**WORKING AS OF 2026-08-08.** The front camera captures: `Connected 2 cameras`, `ov5675 1-0036` in the media graph, libcamera lists "Internal front camera (\_SB_.PC00.LNK0)", and `cam -c1 --capture=5` returns 2584x1944 frames at 29.95 fps. Phase D was never needed — see [[ov5678-verified-hardware-facts]]. Shipped as DKMS package `camera-dell7320/0.2` (int3472 board data + `ov5675` with the extra ACPI id + `ipu-bridge` with `IPU_SENSOR_CONFIG("OVTI5678", 1, 450000000)`), plus `/etc/modprobe.d/int3472-dell7320.conf`. Two cosmetic gaps left: no `ov5675.yaml` libcamera tuning file (falls back to `uncalibrated.yaml`) and no sensor delays in static properties.

**Browsers/Zoom need two more fixes beyond the driver** (done 2026-08-08). Apps open plain V4L2, and `/dev/video0` "Intel MIPI Camera" is a v4l2loopback fed by `v4l2-relayd`:
1. `/etc/v4l2-relayd.d/default.conf` shipped `VIDEOSRC=icamerasrc` — Intel's closed CamHAL, which has no `.aiqb` tuning for OV5675, falls back to `AR0234_TGL_10bits.aiqb` and loops on `CamHAL[ERR] Input stream was missing`. Change to `VIDEOSRC=libcamerasrc ! videoconvert ! videoscale` (the converters are needed — libcamerasrc negotiates the native 2560x1600, not 1280x720).
2. The `v4l2-relayd@.service` sandbox allows only `char-drm/media/intel-ipu6-psys/psys/video4linux`, but libcamera's software ISP needs `/dev/dma_heap/system` (char **248**) or `/dev/udmabuf` (**10:259**) — otherwise `Could not open any dma-buf provider` → `disabling software debayering` → the pipeline can never make YUY2. Fix with a drop-in adding `DeviceAllow=/dev/dma_heap/system rw`. **Testing a gst pipeline as your user does not exercise this** — it only fails inside the unit.

3. Unconstrained `libcamerasrc` picks the sensor's full-res mode (2560x1600 ABGR8888, ~16 MB/frame) and software-debayers all of it. Constrain it: the working `VIDEOSRC=libcamerasrc ! video/x-raw,width=1280,height=720 ! videoconvert` makes libcamera select the binned **1296x972** sensor mode. Result: **28 fps stable** at 1280x720 through /dev/video0 (vs ~2 fps unconstrained).

Scripts: `tools/fix-browser-camera.sh`, `tools/tune-relay-pipeline.sh`, `tools/diagnose-fps.sh` (all have `revert`/`measure` modes).

**Measurement trap:** don't benchmark /dev/video0 immediately after a script that itself ran capture pipelines — leftover gst processes contend for the camera and produce bogus slow readings. Wait, and check `pgrep -f gst-launch` first.

**Not an AGC problem:** the sensor's `exposure=2016` / `analogue_gain=2047` read at maximum regardless of scene brightness, because libcamera's soft ISP applies gain digitally and does not drive those V4L2 controls. Those values are static defaults, not evidence of a pegged auto-exposure loop.

Superseded/remaining: Phase B (`ipu-bridge` entry for `OVTI5678` — currently "Connected 1 cameras", only OVTI8856) and Phase C (the `ov5678.c` driver). Note `ov8856` cannot validate the power path: the loaded Intel DKMS build has no regulator/clk/gpio code at all, and mainline's is behind `if (!is_acpi_node(fwnode))`. `ov5675.c` requests them unconditionally — model `ov5678.c` on that.
