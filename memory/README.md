# Camera project notes

Mirrored from Claude's memory directory by `tools/sync-memory.sh`.
To use them on another machine, copy these into that machine's
`~/.claude/projects/<derived-path>/memory/` - the path is derived from
the project's working directory, so keep the project at `~/Claude Code`.

- [`int3472-board-data-needs-reboot.md`](int3472-board-data-needs-reboot.md) — INT3472 can only probe once per boot - unbind/bind and module reload both fail, so every board-data change costs a reboot
- [`latitude-7320-handover.md`](latitude-7320-handover.md) — Progress and standing facts for the Latitude 7320 Detachable OV5678 camera project — what works, what is settled, what must not be re-chased
- [`ov5678-colour-tuning-settled.md`](ov5678-colour-tuning-settled.md) — SUPERSEDED history — a GPU-debayer colour configuration no longer in use; kept for the highlight-magenta observation and the retracted EGL diagnosis
- [`ov5678-intel-declares-rgbir.md`](ov5678-intel-declares-rgbir.md) — Intel's own shipped files declare the OV5678 as RGB_IR with the exact 4x4 CFA order, independently confirming the i2c measurements
- [`ov5678-is-rgb-ir.md`](ov5678-is-rgb-ir.md) — The Latitude 7320 front sensor is a 4x4 RGB-IR mosaic, not a 2x2 Bayer - confirmed empirically 2026-08-09; root cause of every colour problem
- [`ov5678-latitude-7320-blockers.md`](ov5678-latitude-7320-blockers.md) — Status of the Dell Latitude 7320 Detachable OV5678 camera-driver project — Phase A done, both original blockers resolved 2026-08-08
- [`ov5678-pending-upstream-submission.md`](ov5678-pending-upstream-submission.md) — Kernel series sent to the lists 2026-08-09; three libcamera patches still unsent
- [`ov5678-v3-needs-ai-disclosure.md`](ov5678-v3-needs-ai-disclosure.md) — v3 of the int3472 board-data patch must carry an AI-assistance disclosure - agreed 2026-08-31, and easy to forget because v1 and v2 did not
- [`ov5678-verified-hardware-facts.md`](ov5678-verified-hardware-facts.md) — Live-verified ACPI/hardware values for the Dell Latitude 7320 Detachable cameras, read from NVS on 2026-08-07
- [`readme-progress-images-plan.md`](readme-progress-images-plan.md) — Agreed plan for tomorrow - capture the CCM chart at each pipeline stage so the README shows visible progress
