---
name: ov5678-v3-needs-ai-disclosure
description: v3 of the int3472 board-data patch must carry an AI-assistance disclosure - agreed 2026-08-31, and easy to forget because v1 and v2 did not
metadata:
  node_type: memory
  type: project
---

**When the int3472 board-data patch is respun as v3, add a disclosure that it
was developed with AI assistance, per `Documentation/process/coding-assistants.rst`.**
Sahan agreed to this on 2026-08-31 and asked to be reminded at send time. v1 and
v2 carry no such note, so this will not happen by copying the previous cover
letter - which is exactly how it gets missed.

**Why:** Thierry Chatard's v9 series for the Dell Latitude 5285 - the same
TPS68470/INT3472 stack, touching the same `tps68470_board_data.c` - carries one
in its cover letter, and is being reviewed seriously by Andy Shevchenko and
Sakari Ailus at v9. So disclosure demonstrably does not poison reception on this
exact file. Charles has separately mentioned maintainers losing time to
AI-generated noise; being visibly on the right side of that is worth more than
the line costs. Finding out after the fact that it was expected would be worse.

**How to apply: a trailer, not a paragraph.** Thierry used a cover-letter
paragraph in v9 and switched to a per-patch trailer in v10, which is the form to
copy since ours is a single patch with no cover letter:

    Assisted-by: Claude Code:claude-opus-4-8

Put it with the other trailers, above `Co-developed-by:`/`Signed-off-by:`. Use
the model actually used, not that literal string. His v9 cover-letter wording is
still worth reading if a cover letter is ever needed:

> Per Documentation/process/coding-assistants.rst: this work was developed with
> help from an AI coding assistant (Claude Code, by Anthropic). I used it to help
> reverse-engineer the ACPI/TPS68470 bring-up, iterate on the board data, and
> draft these patches; I have reviewed and tested all of it on the hardware and
> take responsibility for the result.

**A v3 is coming regardless**, so there will be a natural moment: int3472 has two
series in flight (Thierry's v9 board data, and Sakari's static-analyser cleanup
touching `discrete.c`/`tps68470.c`), and ours is another board entry in a file
being restructured underneath it. Expect to rebase. See
[[ov5678-pending-upstream-submission]].
