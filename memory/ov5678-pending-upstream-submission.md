---
name: ov5678-pending-upstream-submission
description: Kernel series sent to the lists 2026-08-09; three libcamera patches still unsent
metadata: 
  node_type: memory
  type: project
  originSessionId: cab23403-1de4-43b9-abfe-14c7e1f6837e
  modified: 2026-08-16T07:16:26.910Z
---

**KERNEL SERIES SENT 2026-08-09 and CONFIRMED ARCHIVED on lore.** All four
messages accepted (SMTP 250), correctly threaded, and verified visible in the
public archive - so it is genuinely on the lists, not merely accepted for
delivery. Message-ID of the cover letter:
`20260809042540.15849-1-adee.sahan@gmail.com`, so the thread is at
https://lore.kernel.org/linux-media/20260809042540.15849-1-adee.sahan@gmail.com/

Sent as **`Sahan Nissanka <adee.sahan@gmail.com>`** - his main account, not the
`sanoptional@gmail.com` the patches originally carried. All patches and
`tools/upstream-regen.sh` were updated to match; From and Signed-off-by must be
the same identity for the DCO.

**FIRST REPLY ARRIVED 2026-08-10 — Sakari Ailus on 2/3** (`anmHRjxruBaYQRaC@kekkonen.localdomain`). Four points: (1) "Most non-Bayer colour raw sensors can be programmed to produce Bayer output" — he asks how the Windows driver's register writes differ, suspecting it uses such a mode; (2) his in-progress **metadata series** adds common raw formats and moves the CFA pattern to a *control*, which is where non-Bayer patterns will enter the UAPI — `git.linuxtv.org/sailus/media_tree.git ?h=metadata`. **This pre-empts the planned RGB-IR media-bus-code RFC — align with that branch rather than proposing separately**; (3) move most of the commit message to the cover letter; (4) bottom line: adding ov5678 support "would probably make sense, but the output really should be Bayer or we need to wait for the metadata series". No reply yet on 1/3 or 3/3.

Point (1) is answerable offline from files already held: `iacamera64.sys` documents the IPU6 **`x2b_rgbir`** block (314 registers), i.e. Intel converts RGB-IR→Bayer **in the IPU6, not in the sensor**, and the graph settings declare `sensor_type="RGB_IR"`. That is evidence Intel does not use a sensor Bayer mode — not proof none exists, and it can no longer be tested. See [[ov5678-is-rgb-ir]].

**SETTLED ON HARDWARE 2026-08-14 — front-only board data does NOT reproduce the suspend regression, so 1/3 is no longer gated by it.** `tools/test-suspend-rails.sh` on the refurb, front `ov5675` bound, rear `ov8856` not bound, no `dw9714`: across an `rtcwake -m mem` cycle the regulator tracepoints recorded **zero events**, rail states and enable refcounts were identical before and after, no kernel messages, and the camera still enumerated on resume.

**The silence is trustworthy because the instrument was proved capable of firing** (`tools/check-regulator-trace.sh`): opening the camera produces 15 events — VSIO, AUX2, AUX1 enabled in that order on power-up and released on close. **Do not report a silent trace without running that control first**; a dead probe and a real negative look identical in the output, which is the same trap that nearly passed the GPIO test on stale `dmesg` lines.

**Method note for anyone repeating this: a before/after snapshot cannot detect the reported bug.** The symptom is rails UP during suspend and back DOWN on resume, so both snapshots read "disabled" and the diff says NO CHANGE either way. The suspend window is only observable via ftrace, whose ring buffer keeps recording while userspace is frozen and survives the resume. The first version of the script got this wrong and produced a confident, meaningless pass.

Incidental confirmation from the same trace: the rails that actually power the sensor are **VSIO/AUX1/AUX2**, never CORE/ANA — independent support for `rail_map=1` from a different direction than the `-5` failure.

**UPDATE 2026-08-14 — the suspend regression is now evidenced as VCM-caused, which clears the way for a front-only 1/3.** Charles hit a natural experiment while testing pin 9: the VCM failed to instantiate (`ov8856 i2c-OVTI8856:00: Error -13 runtime-resuming sensor, cannot instantiate VCM`), and **with the VCM absent, suspend no longer brought the rails up**. That is causal evidence, not just correlation with `dw9714` being loaded. The front module has no VCM (`L0VC`=0), so front-only board data should not reproduce it. Charles independently proposes the same scope: "You could do only OVTI5678 first." **So v2 of 1/3 should cover OVTI5678 only** and leave the rear OVTI8856 wiring (reset pin 9) to a later patch once the suspend bug is fixed.

**Do not cite "ov8856 did not bind with rear_reset=-1" as evidence that the rear needs its reset mapped — it is confounded.** Mainline `ov8856.c` puts its regulator/clk/gpio requests behind `if (!is_acpi_node(fwnode))`, so on an ACPI system it never requests a reset GPIO at all; and the DKMS package here rebuilds only int3472/ov5675/ipu-bridge, leaving stock `ov8856` in place. Its failure to bind is fully explained by that guard, independent of any pin. Charles's own account is that the rear camera needs **both** the Intel `0008-media-i2c-ov8856-remove-is_acpi_node-checks-in-power.patch` *and* the reset mapping. That `is_acpi_node` removal changes behaviour for every ACPI ov8856 system including the Surface devices, none of which can be tested here, so it must go upstream as its own patch with its own justification rather than folded into board data. Two further rear-camera bugs are his, not ours: the suspend inversion, and a black frame at full resolution (1920x1080 works).

**The rail-mapping dispute is retired, not resolved (2026-08-14).** Charles now says the AUX1 voltage in this patch is "safer", that avdd/dovdd/dvdd assignment cannot be confirmed without Dell, and that it has no functional impact because all the rails are brought up and down together. So v2 does not need to settle it — do not spend hardware time there.

Original framing follows. **A suspend regression may gate 1/3 (raised by Charles 2026-08-12, unverified here).** On his machine, suspending the tablet **brings the power rails up**, and resuming brings them down — inverted — and it happens only when the **dw9714 VCM** driver is loaded. He argues board data should not be sent until it is fixed, since it would cost battery on machines whose owners never use the camera. That is a fair objection and worth taking seriously. **But it may not touch the front-camera-only patch**: the front module has no VCM (`L0VC`=0), the VCM is the rear module's. Establish on the refurb whether front-only board data reproduces it before conceding the point or widening the patch.

**Charles endorses 2/3 and 3/3** ("go ahead"), though that does not override Sakari's condition on 2/3.

**Attribution decided 2026-08-14: `Co-developed-by:` for Charles, agreed by both.** Two things are still needed before the tag can actually be written, and neither is optional:
- **His public email address.** Current working address is **cdrolet64@gmail.com**. He has reserved **linux@cdrolet.dev** as a long-term address but has not yet chosen a provider or set up signing ("coming soon", 2026-08-15), so it does not work yet. The address goes into git history permanently, so which one to use is his call — gmail now and send this week, or hold v2 for the domain. Note patch 2/3 is blocked on Sakari regardless, so holding costs less than it appears.
- **EMAIL SENT 2026-08-15** to cdrolet64@gmail.com (`upstream/replies/0007-charles-email.txt`), asking him to reply with the literal `Signed-off-by:` line and to choose gmail-now vs waiting for the domain. **v2 of 1/3 is now waiting on that single reply and nothing else.** The GitHub reply (`0006-`) deliberately omits attribution since the email covers it — do not re-add it there.
- **He said "yes, you can add my name" (2026-08-15) — that is NOT sufficient for `Co-developed-by:`.** It covers `Reported-by:`/`Tested-by:`, which can be written on his behalf. `Co-developed-by:` needs his own `Signed-off-by:` line, supplied by him, because it is a DCO certification. Asked for it explicitly in `upstream/replies/0007-charles-email.txt`.
- **His own `Signed-off-by:`, from him.** `Documentation/process/submitting-patches.rst` requires every `Co-developed-by:` to be *immediately followed* by that person's `Signed-off-by:`. It is a DCO statement, so it cannot be written on his behalf — he has to give it. A `Co-developed-by:` without it will be bounced by maintainers.

So the tag block on v2 of 1/3 ends up as `Co-developed-by: Charles Drolet <addr>` then `Signed-off-by: Charles Drolet <addr>` then Sahan's own `Signed-off-by:` last.

**v2 OF 1/3 IS FINAL AND TESTED ALONE, 2026-08-16.** Rebased onto v7.2-rc7, Charles's review incorporated, tested by him on rc7 ("Let's go!"), then tested here in two phases (`tools/test-patch1-isolated.sh`, logs in `ov5678/data/patch1-phase{A,B}-20260816.log`):
- **Phase A, patch 1/3 alone — 12/12.** Stock ov5675 + stock ipu-bridge, upstream int3472 with zero module parameters. Board data found, all 7 rails at the patch's exact voltages, only dmesg line `TPS68470 REVID: 0x21`. The front sensor staying unbound *is* the isolation proof, not a failure.
- **Phase B, upstream board data + patched sensor — 13/13.** This closed the real gap: the camera had only ever run on the dev module's `front_reset=5 rail_map=1` **module parameters**, never on the hardcoded values being submitted. It streams. `gpioinfo` shows `line 5: output active-low consumer="reset"`, and debugfs resolves avdd←VSIO, dvdd←AUX1, dovdd←AUX2.

**SENT 2026-08-16 and archived**: v2 of 1/3 at
https://lore.kernel.org/platform-driver-x86/20260816070108.9308-1-adee.sahan@gmail.com/
(Message-ID `20260816070108.9308-1-adee.sahan@gmail.com`, tagged `v2-sent` on branch `v2-rc7`). The Sakari follow-up went to both lists the same day, threaded under `20260810092457.12357-1-adee.sahan@gmail.com`; its own Message-ID was not captured. Charles's VIO email went earlier that day. Awaiting maintainer response.

**Machine now runs what was submitted.** DKMS package bumped to **camera-dell7320 0.4**: its `int3472/` sources are the `git am` output of the sent patch (with a `PROVENANCE.txt` saying not to hand-edit them), while `ov5675/` and `ipu-bridge/` still carry the unsent 2/3 and 3/3. The parameterised development module is retired — `/etc/modprobe.d/int3472-dell7320.conf` is **gone and must stay gone**, since the upstream module takes no parameters and would fail to load with "unknown parameter". Archived at `ov5678/attic/int3472-dell7320.conf.obsolete`. `provision-machine.sh` now *removes* that file instead of writing it. `tools/test-load.sh` is **disarmed** — it refuses to run, because swapping the int3472 module at runtime cannot work (see [[int3472-board-data-needs-reboot]]) and would leave the camera dead. Still open: Charles never confirmed `linux@cdrolet.dev` receives mail, and it is now permanent in the archive; if it is dead, only a v3 can fix the tag.

**SEND IDENTITY TRAP — caught by dry-run 2026-08-16, would have shipped a broken patch.** This repo's `user.email` is `sanoptional@gmail.com`, but every patch is authored and `Signed-off-by` as **`adee.sahan@gmail.com`**, which is also the identity v1 went out under (message-id `20260809042540.15849-1-adee.sahan@gmail.com`). Without an explicit `--from`, `git send-email` uses `user.email` and rewrites From: and Message-ID to `sanoptional@`, giving **From ≠ Signed-off-by (a DCO violation)** and splitting the series across two authors. Fixed by pinning `sendemail.from = Sahan Nissanka <adee.sahan@gmail.com>` in the `upstream/` repo's local config. **Always dry-run and check `MAIL FROM` / `From:` / `Message-ID` before sending anything.** `smtpPass` stays unset on purpose — git prompts, the Gmail app password never lands on disk, and Claude never handles it.

**Re-run 2026-08-16 as a clean room, and this is the run to cite.** The first run built the module by slicing the added block out of a git branch with a script — that tested the *code*, not the *patch*. The re-run does `git am` of the patch file onto a pristine v7.2-rc7 tree (exit 0, **no fuzz, no manual hunks**), compiles exactly what `am` produced, and boots it: Phase A 12/12, Phase B 13/13, both identical to the first run. Provenance in `upstream/isolated-test/PROVENANCE.txt`; logs `patch1-phase{A,B}-gitam-20260816.log`. Proof the right binary booted: the `.ko` contains **4 rc7-only DMI strings** (MSI Prestige ×3, Nova Lake) that my reconstruction never had. Keep `isolated-test/` as `git am` output only — never hand-edit it, or the test silently stops testing the patch.

Charles's review is now filed verbatim at `upstream/replies/0010-charles-review-received.txt` (it had only ever existed in chat). All five of his asks are met; he explicitly withdrew the AUX1-for-avdd suggestion ("I agree to use your mapping for supplies"). **The one thing he has not seen is the VIO `always_on` change** — it postdates both his review and his rc7 test, so show him before sending.

Machine is currently left in the Phase B config: the upstream `.ko` is **hand-placed** in `updates/dkms` and DKMS does not track it (`camera-dell7320` is `built`, not `installed`). Camera works and survives reboot, but a kernel update would not rebuild it. To get back to the maintained path: `sudo tools/test-patch1-isolated.sh revert` + reboot.

The v1-era guidance below is superseded:
- **The daisy-chain swnode is deliberately NOT used.** Checked the actual consumer: `gpio-tps68470.c` on `daisy-chain-enable` merely puts GPIOs 1 and 2 into input mode for the PMIC's i2c pass-through. MSI/NVL need it because their sensors sit behind the PMIC's i2c; the 7320's sensors are direct ACPI i2c clients and the camera demonstrably works without it. The earlier "v2 should reference the shared swnode" note was inferred from Charles's tree (which carried the rear camera) without checking what the property does.
- **The v1 patch no longer applies to current kernels**: between v7.0 and v7.2-rc7 this file gained the MSI Prestige (x3) and Intel NVL entries at exactly our insertion points, and a cleanup removed the explicit `.num_consumer_supplies = 0` lines from the 7212. v2 is generated against rc7 (`base-commit: db2ddb87143519e20a95aa36c60b36107b736a58`), applies with `git am`, checkpatch --strict clean.
- **Charles's review (2026-08-16), all four points taken**: own `init_data` for every rail (the 7212's are consumerless today, and registering its second camera would have given this board silently-inherited supplies); `dell_7320_detachable_*` naming (products can carry several sensors, and a "Dell Latitude 7320" laptop exists that is a different machine without IPU6); the redundant board_data comment dropped. **VIO changed to `always_on`** at VSIO's voltage (Surface Go precedent). Careful: this is a *description* fix, not a behaviour fix. VIO registers with `tps68470_always_on_reg_ops` in `tps68470-regulator.c`, which implements neither `.enable` nor `.disable`, so the core can never power it off and v1's `valid_ops_mask = REGULATOR_CHANGE_STATUS` declared a capability the ops don't provide. (Mainline's Dell 7212 entry has the same inconsistency — not this patch's business to fix.) I first wrote the changelog claiming v1's VIO "is powered off as unused by the regulator core"; that was **wrong** and is corrected in the patch. Verified on hardware 2026-08-16: VIO alone comes up `use_count=1` with **no sysfs `state` file** — `state` visibility is gated on `rdev->ena_pin || ops->is_enabled`, and `set_machine_constraints()` does `if (always_on) rdev->use_count++`. That pair is the always_on signature; check it via `/sys/kernel/debug/regulator/regulator_summary`, since sysfs `state` does not exist for this rail.
- `git format-patch` **drops a hand-inserted changelog on regeneration** — it was lost once and had to be re-added. Check for "Changes since v1" before sending anything regenerated.

Superseded v1-era note follows. **1/3 is wrong and needs correcting on-list before anyone applies it** — see [[ov5678-verified-hardware-facts]] for the GPIO detail. Also: v2 should reference mainline's shared `int3472_tps68470_daisy_chain_gpio_swnode`, not a board-specific one (Charles's patch names `msi_p14_ai_evo_*`, which is his tree's older name for `msi_prestige_ai_evo_*`). **Disclose on-list that the hardware was a loan and has gone back**, since it limits what can be promised; Charles has a 7320 and is willing, so Tested-by/Co-developed-by is the natural route.

**GATE, reaffirmed 2026-08-09: do not send the libcamera half until the kernel
series gets replies.** *(Partly satisfied 2026-08-10 — one reply, on 2/3, pointing at the metadata series. Sahan's call whether that is enough.)* Everything on that side is otherwise finished and
send-ready — the master patch compiles (166/166, gcc 15.2) and passes
`checkstyle` including clang-format, the five-defect report is written, git
send-email is configured and dry-run clean. The only thing being waited on is
traffic on the lore thread below. Sahan's own reasoning: how linux-media
receives the RGB-IR disclosure determines whether the libcamera side is framed
as "a gain ceiling is too low" or as "here is what a soft ISP needs for RGB-IR
sensors", and sending early commits publicly to the narrower framing. When
replies arrive, also decide whether to send the patch alone, the report alone,
or both — they are three different conversations with that list.

**THE UQ<3,8> PATCH'S EMPIRICAL JUSTIFICATION IS RETRACTED — measured 2026-08-15, and it does not survive.** Measured on the refurb with libcamera master built from `libcamera-upstream` (`tools/measure-awb-gain-range.sh`, 400 frames, both variants converged):

| build | blue gain wanted | applied |
|---|---|---|
| master `UQ<2,8>` | 7.304 | **3.996** (pinned) |
| `awb-gain-range` `UQ<3,8>` | 8.118 | **7.996** (still pinned) |

Red is ~1.8 and unconstrained in both. Three consequences:
1. **The clamped channel is blue, not red** — the patch's commit message claims red. That claim came from the loaned unit *before* the CFA fix, when the red label sat on the IR positions; after GRBG→GBRG the notes already record "red 6.01→1.46, blue 1.54→4.90".
2. **That channel is infrared.** Confirmed on this unit by `tools/check-rgbir.sh`: four positions at 29.4 counts, spread 0.2, against G 251.7 — and GBRG tiling puts the B label on exactly those four. Predicted G/"B" 8.56 and G/"R" 1.71 match libcamera's measured 7.3–8.1 and 1.8. So the gain being clamped amplifies IR, and real blue light is averaged into the "red" channel.
3. **`UQ<3,8>` does not even fix it** — the patched build wants 8.118 and pins at 7.996. If the IR number were the justification, the patch would be self-defeating.

**So no physically meaningful channel on this sensor needs more than 3.996.** The *architectural* argument is untouched and still good on its own: the soft ISP inherits `UQ<2,8>` from rkisp1's hardware register format while carrying gains as `double` end to end (`debayer_cpu.cpp:991`), so the ceiling is unmotivated. The options are to send on that argument alone with no sensor claim, to find a genuinely red/blue-weak Bayer sensor, or to make the real case — with correct RGB-IR handling native blue is ~16% of green, needing ~6x, which is above 3.996 and genuinely about colour — but that cannot be shown through mainline libcamera, which has no RGB-IR demosaic. It could be computed offline from `rgbir-raw.bin`. **Do not send the patch with its current commit message.**

**Two measurement traps found doing this.** 40 frames is far too few — AGC and libipa's 0.2 gain smoothing were still climbing and neither variant pinned, which read as "no effect"; 400 frames converged to `+0.000` movement. And the first version of the script hardcoded the red channel, reporting a confident summary of the wrong one. Report both channels and require the movement to have settled.

**The measurement build is CPU-only**: EGL was not found at configure time so `softisp-gpu` resolved to off and only `debayer_cpu.cpp.o` was built. That does not affect the gain numbers, which come from IPA stats upstream of either debayer, but it is not the production config — see [[ov5678-colour-tuning-settled]]. `libegl1-mesa-dev` and `libgbm-dev` would be needed to match it.

**TO DRAFT (queued 2026-08-15, deliberately deferred): a reply to Sakari on the v1 thread answering his Bayer question with method.** Everything needed is now established and recorded in [[ov5678-is-rgb-ir]]: the sensor's register space was mapped on hardware across `0x3000`–`0x5fff` and contains no CFA or output-format control; aliases were removed; what was *not* checked is stated (`0x5000`–`0x5003` never bit-swept, nothing mapped outside that range); the module EEPROM's own factory label reads `RGBR`; and `IPU6_FW_PSYS_ISA_X2B_SVE_RGBIR_ID` in intel/ipu6-drivers is a **public, citable** source for the IPU6 doing the conversion, replacing the reverse-engineered `iacamera64.sys` citation. Conclusion to convey: no sensor Bayer mode found, so aligning with his metadata series is the path — framed as an answer to his question, not a concession. This reply is independent of Charles's v2 review and can go at any time.

**Still unsent: the three libcamera patches** (AWB 4.0 gain clamp, sensor
delays, black level tuning file) and the four-defect bug report. Those go to
libcamera-devel@lists.libcamera.org, which is a separate list and a separate
thread. Deliberately held back so the kernel series lands first and its
reception informs the RGB-IR RFC. Files live in `~/Claude Code/ov5678/`, published at https://github.com/githomeserver/latitude-7320-camera

| patch | destination |
|---|---|
| `kernel-patches/0001-*` int3472 TPS68470 board data | platform-driver-x86@vger.kernel.org |
| `kernel-patches/0002-*` ov5675 OVTI5678 ACPI id | linux-media@vger.kernel.org |
| `kernel-patches/0003-*` ipu-bridge OVTI5678 entry | linux-media@vger.kernel.org |
| `upstream-libcamera/0001-ipa-simple-awb-Widen-*` AWB gain range (UQ<3,8>) | libcamera-devel@lists.libcamera.org |
| `libcamera-patch/0001-*` AWB 4.0 clamp | **local 0.7.0 build only** — `build-libcamera.sh` applies it; not for upstream |
| `libcamera/ov5675.yaml` black level | libcamera-devel |
| `upstream-libcamera/0001-*` sensor delays | libcamera-devel |
| `upstream-libcamera/AWB-BUG-REPORT.md` four-defect report | libcamera-devel |

git-email is installed and `~/.gitconfig` is configured (smtp.gmail.com:587,
tls, user adee.sahan@gmail.com, `annotate` and `confirm` on). **`smtpPass` is
deliberately unset** so git prompts and the credential never lands on disk -
keep it that way. Note the `[sendemail]` smtpserver keys vanished from
`~/.gitconfig` once mid-session for reasons never established; if send-email
complains about a missing server, check that block still exists before
assuming a credential problem.

**Two open questions before sending the libcamera half** (the kernel series is ready as-is):
1. ~~Check whether libipa's `AwbGrey` on master already dropped the 4.0 clamp~~
   **ANSWERED 2026-08-09 against master `62d4bfc45079`. Both halves matter:**

   *The patch is obsolete* — the exact lines it edits were deleted upstream on
   2026-08-06 by `d5d00b9c3c5d` "ipa: simple: awb: Port to use libipa
   AwbAlgorithm". `simple/algorithms/awb.cpp` no longer computes gains at all;
   it builds a `SimpleAwbStats` and delegates. The patch cannot apply.

   *But the defect survives, and is marginally worse.* `AwbGrey` itself is
   clean (`awb_grey.cpp:87-89`, `means.g() / std::max(means.r(), 1.0)`, only a
   div-by-zero guard — exactly what the patch proposed), yet the ceiling was
   reintroduced one layer up: `AwbAlgorithmBase::process` clamps **every**
   computed result at `libipa/awb.cpp:385`,
   `awbResult.gains = awbResult.gains.clamp(gainMin_, gainMax_)`. The simple
   IPA instantiates `AwbAlgorithm<UQ<2, 8>>` (`simple/algorithms/awb.h:59`),
   and `libipa/awb.h:120-121` derives the bounds from that format: `gainMin_ =
   max(UQ<2,8>::min, 1.0f)` = **1.0**, `gainMax_ = UQ<2,8>::max` = 1023/256 =
   **3.996**. So a sensor needing red gain 6.1 is still pinned — at 3.996
   rather than 4.0.

   So it is **neither send-as-is nor a backport request**: re-target it. The
   new argument is that the soft ISP's gain range is dictated by a fixed-point
   format, while `DebayerParams::gains` is plain `RGB<double>` — and the
   clamp's comment claims it clamps "to the hardware" when the software ISP
   has none. Widening to `UQ<3,8>` (max 7.996) would fix it.
   **Checked 2026-08-09, and the argument holds.** `debayer_cpu.cpp:991` takes
   `const RGB<double> gains = params.gains` and does the LUT maths entirely in
   double; the only `.clamp()` calls (`:1006`, `:1027`) bound the *lookup-table
   index*, i.e. ordinary highlight clipping, not gain magnitude. Nothing in the
   software path quantises a gain. The clincher: `UQ<2,8>` is the **rkisp1
   hardware register format** — `rkisp1/algorithms/awb.h:52` declares the
   identical `AwbAlgorithm<UQ<2, 8>>`. The soft ISP copied a hardware
   register's range while representing gains as `double` end to end. So the
   3.996 ceiling is inherited, not required.

   Secondary, now **written up as defect 5** in `AWB-BUG-REPORT.md` (repo
   `012f157`): `gainMin_ = std::max(Q::TraitsType::min, 1.0f)`
   (`libipa/awb.h:120`) floors the gains at unity, though `UQ<2,8>::min` is
   0.0, so no format requires it. Grey world holds green at 1.0, so a
   red-*strong* sensor needs a red gain below 1.0 and cannot express it — it
   clamps to 1.0, keeps a red cast, and reports success. **Deliberately no
   patch**: unmeasured here (this sensor is red-weak, the opposite case) and
   the bound is shared with every `AwbAlgorithm` user including rkisp1.
2. The EGL-debayer finding is an observation, not a diagnosis. **Resolved 2026-08-09 as far as it can be:** the report now states which explanations are ruled out (the shader DOES receive `combinedMatrix`, the gains ARE folded in, the `GL_FALSE` is deliberately compensated, stats ARE generated). Cause still unknown. Do not re-assert a mechanism — see [[ov5678-colour-tuning-settled]].
3. The report gained a 4th defect on 2026-08-09: `Saturation` is silently inert unless the tuning file defines a `Ccm`. Well-evidenced and self-contained; could reasonably be sent as its own report.
4. The sensor-delays patch does **not** apply to Ubuntu's 0.7.0 tree (their ov5675 entry already has an empty `.sensorDelays = { }`; upstream's has none). It is correct for upstream submission as-is. `tools/build-libcamera.sh` does the local edit separately.

Recipients came from `scripts/get_maintainer.pl`; full list in `upstream/SENDING.md`.
