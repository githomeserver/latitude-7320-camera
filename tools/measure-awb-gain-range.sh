#!/bin/bash
# Measure the effect of the UQ<3, 8> AWB gain-range patch on real hardware.
#
# THE CLAIM UNDER TEST. libcamera's software ISP bounds its AWB colour gains
# with a fixed-point format. AwbAlgorithmBase::process() clamps every computed
# result at libipa/awb.cpp:385, and UQ<2, 8> puts the ceiling at 3.996. This
# sensor needs a red gain of about 6.1 to reach neutral, so red pins at the
# ceiling on every frame and the image keeps a cyan cast. The patch widens the
# format to UQ<3, 8>, raising the ceiling to 7.996.
#
# Until now that argument has been made entirely from source reading: the patch
# compiles and the bound was verified against the headers, but it has never
# been run on a sensor. This turns it into a measurement.
#
# WHAT MAKES THIS MEASURABLE. libipa's Awb category logs, at Debug, one line
# per frame carrying both halves of the story:
#
#   LOG(Awb, Debug) << "Means " << stats.rgbMeans()
#                   << ", gains " << state.automatic.gains
#                   << ", temp " << ... << "K";
#
# The means are pre-clamp and the gains are post-clamp, so a single line shows
# what grey world asked for and what it was allowed to have. Grey world holds
# green at 1.0, so the red gain it wants is simply meanG / meanR - computable
# from the same line, independently of the clamp.
#
# The expected result is not "the picture looks better". It is:
#
#   baseline  wanted ~6.1, got 3.996   (pinned at the UQ<2,8> ceiling)
#   patched   wanted ~6.1, got ~6.1    (under the UQ<3,8> ceiling)
#
# A baseline that does NOT pin means the scene is not red-weak enough to
# demonstrate anything - relight and try again rather than reporting it.
#
# Run as your normal user, with v4l2-relayd stopped:
#     sudo systemctl stop v4l2-relayd.service
#     tools/measure-awb-gain-range.sh
#
# Point the camera at a neutral, evenly lit surface filling the frame and do
# not move it or change the lighting between the two variants.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LIBCAMERA_SRC:-$HERE/../../libcamera-upstream}"
BUILD="$SRC/build"
TUNING="$HERE/../libcamera/ov5675.yaml"
OUT="$HERE/../data/awb-gain-range.log"
FRAMES="${FRAMES:-40}"

pass() { printf '  \033[32m%s\033[0m %s\n' "PASS" "$1"; }
fail() { printf '  \033[31m%s\033[0m %s\n' "FAIL" "$1"; }

[ -d "$SRC/.git" ] || { echo "ERROR: no libcamera source at $SRC" >&2; exit 1; }
[ -f "$TUNING" ]   || { echo "ERROR: tuning file missing: $TUNING" >&2; exit 1; }

if systemctl is-active --quiet v4l2-relayd.service 2>/dev/null; then
    echo "ERROR: v4l2-relayd is running and will hold the camera." >&2
    echo "       sudo systemctl stop v4l2-relayd.service" >&2
    exit 1
fi

# The tuning file pins the black level. Without it BlackLevel guesses the
# pedestal from the scene and Awb subtracts that guess before computing gains,
# which moves the answer around by more than the effect being measured.
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/simple"
cp "$TUNING" "$STAGE/simple/ov5675.yaml"
trap 'rm -rf "$STAGE"' EXIT

run_variant() {                      # $1 = git ref, $2 = label
    local ref="$1" label="$2" raw="$STAGE/$2.log"

    echo "== $label ($ref) =="
    git -C "$SRC" checkout -q "$ref" || { fail "checkout failed"; return 1; }

    # Incremental: only awb.h and its dependents change between the two.
    if ! ninja -C "$BUILD" > "$STAGE/$2.build" 2>&1; then
        fail "build failed"; tail -15 "$STAGE/$2.build" | sed 's/^/      /'; return 1
    fi
    printf '  built %s\n' "$(git -C "$SRC" log --oneline -1)"

    # Confirm the binary really carries the format we think it does, rather
    # than trusting that ninja rebuilt what mattered.
    local fmt
    fmt="$(grep -oE 'AwbAlgorithm<UQ<[0-9]+, ?[0-9]+>>' \
           "$SRC/src/ipa/simple/algorithms/awb.h" | head -1)"
    printf '  source declares %s\n' "${fmt:-UNKNOWN}"

    LIBCAMERA_IPA_CONFIG_PATH="$STAGE" \
    LIBCAMERA_LOG_LEVELS="Awb:DEBUG" \
    timeout 120 "$BUILD/src/apps/cam/cam" -c1 --capture="$FRAMES" \
        > "$raw" 2>&1
    local rc=$?
    [ $rc -eq 0 ] || { fail "cam exited $rc"; tail -8 "$raw" | sed 's/^/      /'; return 1; }

    # Take the last few frames, once AGC and AWB have settled.
    grep -E 'Means .*gains .*temp' "$raw" | tail -5 | sed 's/^.*Means/    Means/'

    python3 - "$raw" <<'PY'
import re, sys, statistics
lines = [l for l in open(sys.argv[1]) if 'Means' in l and 'gains' in l]
if not lines:
    print("    NO Awb DEBUG LINES - measurement failed, not a result")
    sys.exit(0)
nums = re.compile(r'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?')
want, got = [], []
wantB, gotB = [], []
for l in lines[-10:]:
    # libcamera prints vectors as "Vector { r, g, b  }" - commas inside the
    # braces, so the field separators must be matched non-greedily by keyword.
    m = re.search(r'Means\s*(.*?),\s*gains\s*(.*?),\s*temp', l)
    if not m:
        continue
    means = [float(x) for x in nums.findall(m.group(1))][:3]
    gains = [float(x) for x in nums.findall(m.group(2))][:3]
    if len(means) < 3 or len(gains) < 3 or means[0] <= 0:
        continue
    want.append(means[1] / means[0])          # grey world: green / red
    got.append(gains[0])
    if means[2] > 0:
        wantB.append(means[1] / means[2])      # green / blue
        gotB.append(gains[2])
if not want:
    print("    could not parse means/gains - check the raw log")
    sys.exit(0)
# Report BOTH channels. Do not assume which one is constrained: on this sensor
# the CFA phase determines it, and an earlier version of this script hardcoded
# red and reported the wrong channel entirely.
for name, w_, g_ in (("red ", want, got), ("blue", wantB, gotB)):
    if not w_:
        continue
    w, g = statistics.median(w_), statistics.median(g_)
    trend = g_[-1] - g_[0] if len(g_) > 1 else 0.0
    print(f"    {name} gain WANTED {w:7.3f}   APPLIED {g:7.3f}"
          f"   (moved {trend:+.3f} over the window)")
    if abs(g - 3.996) < 0.02:
        print(f"         ^ pinned at the UQ<2,8> ceiling")
    elif abs(g - 7.996) < 0.02:
        print(f"         ^ pinned at the UQ<3,8> ceiling")
    elif abs(trend) > 0.05:
        print(f"         ^ STILL CONVERGING - not a settled value, run more frames")
PY
    echo
}

echo "Frames per variant: $FRAMES. Do not move the camera or change the light."
echo

ORIG="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
trap 'git -C "$SRC" checkout -q "$ORIG" 2>/dev/null; rm -rf "$STAGE"' EXIT

{
    echo "=== libcamera AWB gain range, measured ==="
    date -Is
    echo
    run_variant master          "baseline-UQ2-8"
    run_variant awb-gain-range  "patched-UQ3-8"
    echo "Read this as: the baseline pins red at 3.996 while asking for more,"
    echo "and the patched build delivers what grey world actually asked for."
    echo "If the baseline did not pin, the scene was not red-weak enough and"
    echo "nothing has been demonstrated."
} 2>&1 | tee "$OUT"

echo
echo "log: $OUT"
