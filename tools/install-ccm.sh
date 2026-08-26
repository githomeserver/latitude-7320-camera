#!/bin/bash
# Install a colour correction matrix into the libcamera tuning file.
#
# TWO REASONS TO DO THIS
#
# 1. The matrix itself corrects hue and saturation.
#
# 2. It unlocks the live saturation control. The CPU debayer only reads
#    params.combinedMatrix when ccmEnabled is true (debayer_cpu.cpp
#    STORE_PIXEL), and ccmEnabled is set in exactly one place - Ccm::init,
#    which runs only if the tuning file defines a Ccm algorithm. Adjust's
#    saturation knob writes into that same combinedMatrix and is itself gated
#    on ccmEnabled (adjust.cpp:104). So with no CCM in the tuning file,
#    "libcamerasrc saturation=2.0" is silently ignored.
#
# WHERE THE Ccm ENTRY GOES, AND WHY BOTH BOUNDS MATTER
#
# After Awb: Awb right-multiplies its gains into combinedMatrix and Ccm
# left-multiplies, so that order gives ccm * gains - the matrix acts on
# white-balanced data.
#
# Before Adjust: algorithms are initialised in file order, and Adjust::init
# decides whether to REGISTER controls::Saturation by reading ccmEnabled
# (adjust.cpp:33). If Ccm has not run yet the flag is still false, the control
# is never registered, and the camera does not advertise Saturation at all - so
# setting it is dropped before it ever reaches the IPA.
#
# This script used to append the block to the END of the list, which put it
# after Adjust and left saturation dead even with a matrix installed. Measured
# with the matrix present but listed last: saturation 0.0, 1.0 and 2.0 all gave
# a mean chroma of 3.86 - no effect at all - and cam --list-controls showed
# Contrast and Gamma but no Saturation. With Ccm ahead of Adjust the same three
# settings give 1.00, 4.01 and 7.99, exactly linear.
#
# Run as root:
#   sudo ./install-ccm.sh sat=2.0            saturation matrix
#   sudo ./install-ccm.sh identity bl=6500   raise black level too
#   sudo ./install-ccm.sh sat=2.0,blue=0.92  ... with a blue trim
#   sudo ./install-ccm.sh 1.7,-0.6,-0.1,...  explicit 9 numbers
#   sudo ./install-ccm.sh identity           unlock the saturation knob only
#   sudo ./install-ccm.sh revert             remove it again

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../libcamera/ov5675.yaml"
# Respect the environment. This was a plain assignment, so `CT=5000 ./install-ccm.sh`
# silently labelled a matrix measured at 5000 K as 3100 - the same trap IRSUB hit
# in install-camera-service.sh, and the second time this pattern has bitten here.
CT="${CT:-3100}"   # Must match what this AWB reports for the light a matrix was
            # fitted under (now ~4800 K under this room's LED). With a single
            # entry getInterpolated() returns it regardless of temperature, so it
            # is inert until a second matrix is added - then a wrong label blends
            # the wrong pair. tools/solve-ccm.py reported_ct() measures the value.

# bl=<n> raises the black level above the sensor's own pedestal (4122) to soak
# up veiling flare. The flare floor is scene-dependent, so this is a deliberate
# trade: cleaner blacks in a normally lit room, crushed shadows in a dark one.
# Subtracting here rather than in a matrix matters - black level comes off the
# raw signal BEFORE the AWB gains, so it removes the lift before the ~4.9x blue
# gain turns it violet. A CCM applied afterwards cannot undo that.
#
# Taken as an argument, not an environment variable: "BL=x sudo -E script"
# silently drops the variable under a default sudoers env_reset, which looks
# exactly like the setting having no effect.
BL=""
ARGS=""
for a in "$@"; do
    case "$a" in
        bl=*) BL="${a#bl=}" ;;
        *)    ARGS="${ARGS:+$ARGS }$a" ;;
    esac
done
set -- $ARGS

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
SPEC="${1:-}"
[ -n "$SPEC" ] || { sed -n '2,28p' "$0"; exit 1; }

targets() {
    for d in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
        [ -d "$d" ] && echo "$d/ov5675.yaml"
    done
}

restart() {
    systemctl restart ov5678-ondemand.service
    sleep 2
    printf 'service: '
    systemctl is-active ov5678-ondemand.service || true
}

if [ "$SPEC" = "revert" ]; then
    for t in $(targets); do
        install -m644 "$SRC" "$t"
        echo "  restored $t"
    done
    restart
    echo "CCM removed. Note the saturation control is inert again."
    exit 0
fi

MATRIX="$(python3 "$HERE/try-ccm.py" --matrix "$SPEC")" || exit 1
echo "== $SPEC =="
echo "   [$MATRIX]"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
# The stock file ends with the document terminator; drop it here and put it back
# once the block has been inserted.
sed '/^\.\.\.$/d' "$SRC" > "$TMP"

if [ -n "$BL" ]; then
    case "$BL" in ''|*[!0-9]*) echo "ERROR: BL must be an integer" >&2; exit 1 ;; esac
    [ "$BL" -ge 4096 ] || { echo "ERROR: BL below the sensor pedestal (4096)" >&2; exit 1; }
    [ "$BL" -le 12000 ] || { echo "ERROR: BL above 12000 would crush everything" >&2; exit 1; }
    sed -i "s/^      blackLevel: .*/      blackLevel: $BL/" "$TMP"
    echo "   blackLevel: $BL  (sensor pedestal is 4122; >> 8 = $((BL >> 8)) in 8-bit)"
fi
# Insert directly after the Awb entry, which satisfies both bounds at once.
# Line based rather than a YAML round trip, so the file keeps its comments -
# they carry the measurements that justify the black level.
CCM_BLOCK="  - Ccm:
      ccms:
        - ct: $CT
          ccm: [ $MATRIX ]"
python3 - "$TMP" "$CCM_BLOCK" <<'INSERT'
import sys
path, block = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")

# Drop any Ccm block already present. The source is normally the stock tuning
# file with no Ccm, but it is not guaranteed to be - a previously installed file
# can be handed back in, and this script has already produced a file with TWO
# Ccm entries that way, which parses without complaint and silently applies
# whichever the loader saw last.
out, i = [], 0
while i < len(lines):
    if lines[i].strip() == "- Ccm:":
        ind = len(lines[i]) - len(lines[i].lstrip())
        i += 1
        while i < len(lines) and (not lines[i].strip() or
              (len(lines[i]) - len(lines[i].lstrip())) > ind):
            i += 1
        continue
    out.append(lines[i])
    i += 1
lines = out
try:
    awb = next(i for i, l in enumerate(lines) if l.strip() == "- Awb:")
except StopIteration:
    sys.exit("ERROR: no Awb entry in the tuning file")
indent = len(lines[awb]) - len(lines[awb].lstrip())
end = awb + 1
while end < len(lines) and lines[end].strip() and \
      (len(lines[end]) - len(lines[end].lstrip())) > indent:
    end += 1
open(path, "w").write("\n".join(lines[:end] + block.split("\n") + lines[end:]))
INSERT
printf '...\n' >> "$TMP"

# Fail before touching anything installed if the result is not valid YAML.
python3 - "$TMP" <<'PY' || exit 1
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)   # no pyyaml, skip the check rather than block the install
d = yaml.safe_load(open(sys.argv[1]))
algs = [list(a)[0] for a in d["algorithms"]]
assert "Ccm" in algs, "Ccm missing"
assert algs.count("Ccm") == 1, f"{algs.count('Ccm')} Ccm entries, expected exactly one"
assert algs.index("Ccm") > algs.index("Awb"), \
    "Ccm must come after Awb, or the matrix multiplies in the wrong order"
if "Adjust" in algs:
    assert algs.index("Ccm") < algs.index("Adjust"), \
        "Ccm must come before Adjust, or Saturation is never registered"
print("   yaml ok, order ok:", " -> ".join(algs))
PY

for t in $(targets); do
    install -m644 "$TMP" "$t"
    echo "  installed $t"
done

restart
echo
echo "Saturation is now a live knob too:"
echo "  sudo tools/set-saturation.sh 1.6"
