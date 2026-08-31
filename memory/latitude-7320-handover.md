---
name: latitude-7320-handover
description: Progress and standing facts for the Latitude 7320 Detachable OV5678 camera project — what works, what is settled, what must not be re-chased
metadata:
  node_type: memory
  type: project
  originSessionId: 7f22c869-0a22-4a76-a2cf-5b555a258bb8
  modified: 2026-08-23T00:00:00.000Z
---

The front camera on the Dell Latitude 7320 Detachable works on Linux. It runs at
1280x720, ~30 fps at the sensor, through `/dev/video0` in Firefox, Chromium and
anything else that opens a normal camera device, started on demand so an idle
machine stays quiet. Repo: https://github.com/githomeserver/latitude-7320-camera

**Everything needed to rebuild it is in that repo**, including the measured lens
shading map and the libcamera changes as a patch. Do not copy `~/Claude Code` -
most of it is 11 GB of extracted Windows files nothing in the build reads. See
the README's "Moving to another machine". The lens shading map is specific to the
lens it was measured on.

**Settled, and expensive to re-derive:**

- The sensor is RGB-IR, not Bayer - see [[ov5678-is-rgb-ir]] and
  [[ov5678-intel-declares-rgbir]]. This is the root cause of every colour problem
  the project started with.
- **The Windows register-dump lead is dead. Do not chase it again.** All 20,727
  files of System32 were enumerated; `ov5678.sys` is the only binary anywhere
  that even contains the string "OV5678", and PE section analysis proves it has
  nowhere to store register tables - the longest ordered (u16 reg, u8 val) run is
  21 pairs against the 138 one mode needs. Windows builds the sequence in code.
  And a perfect trace could not reveal a Bayer mode, because Windows does not use
  one: it takes RGB-IR out and converts in the IPU6.
- `IRFlashLedIntensity = 63` in the INF - the module has an IR illuminator, which
  independently fits the RGB-IR finding.

**Irreplaceable on disk, not regenerable:**

- `~/Claude Code/handover/raw-captures/rgbir-raw.bin` (+ `.txt`) - one full-res
  2592x1944 frame, black level 64, format GB10. Every offline tool runs from it.
- `~/Claude Code/Camera files second extraction/` - Intel's proprietary
  `.aiqb`/`.cpf` tuning, unobtainable without a Windows install on this model.

**Auth, unchanged and worth not re-deriving:** GitHub is via `gh` over HTTPS as
`githomeserver`, token in the system keyring, so plain `git push` works - do not
set up SSH. Git identity is `Sahan Nissanka <adee.sahan@gmail.com>`, the DCO
identity matching every patch. `sendemail` is configured for smtp.gmail.com:587
but **`smtpPass` is deliberately unset** so git prompts and the credential never
lands on disk - keep it that way, which also means sending must be done by hand.
See [[ov5678-pending-upstream-submission]].

**Where the work stands:** picture quality is being judged by eye against a face
rather than a colour target, after a fitted matrix measured 4.5x better on a
screen palette and looked worse in use - it turned clipped highlights magenta,
which no unclipped target could have revealed. Colour matrix work is therefore
open, not settled; [[ov5678-colour-tuning-settled]] describes a superseded GPU
configuration and should be read as history.

**The current limit is frame rate, not colour.** Delivered rate is 10-20 fps, not
the ~28 the README claims - libcamera's own benchmark does not time the RGB-IR
pre-pass, so every `us/frame` figure understates the work by roughly half. The
pre-pass is single-threaded on one core of eight while the fanless chip throttles
to ~2.2 GHz of its 4.2 GHz under sustained load. Threading the pre-pass across
row bands is the obvious next move, after making the measurement trustworthy.
