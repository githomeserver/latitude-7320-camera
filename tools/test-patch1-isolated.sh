#!/bin/bash
# Test upstream patch 1/3 (int3472 TPS68470 board data) ALONE, as Charles asked.
#
# WHY THIS NEEDS A REBOOT, AND WHY unbind/bind DOES NOT WORK.
#
# Board data is consumed once, in skl_int3472_tps68470_probe(). The obvious way
# to re-run it is to unbind and rebind the i2c device:
#
#     echo i2c-INT3472:07 > /sys/bus/i2c/drivers/int3472-tps68470/unbind
#     echo i2c-INT3472:07 > /sys/bus/i2c/drivers/int3472-tps68470/bind
#
# The unbind works. The bind then FAILS, with:
#
#     int3472-tps68470 i2c-INT3472:07: INT3472 seems to have no dependents
#
# because probe counts its consumers with for_each_acpi_consumer_dev(), which
# walks the global ACPI dependency list, and the FIRST successful probe called
# acpi_dev_clear_dependencies() -> acpi_scan_clear_dep(), which DELETES those
# entries. They are never recreated. Reloading the module does not help either:
# the state is in ACPI scan data, not in the module.
#
# So: once INT3472 has probed, it can never probe again this boot. Testing any
# board-data change means a reboot. Do not repeat the unbind experiment - it
# leaves the camera dead until you reboot anyway.
#
# WHAT "ALONE" MEANS HERE.
#
# The DKMS package camera-dell7320 carries all three patches at once, so 1/3 has
# never run by itself on this machine. This script removes 2/3 (ov5675 OVTI5678
# ACPI id) and 3/3 (ipu-bridge sensor config) and swaps the parameterised
# development int3472 module for one built from the v2 patch verbatim, with no
# module parameters at all. That last point is the real content of the test: the
# camera has only ever run on the dev module driven by
# /etc/modprobe.d/int3472-dell7320.conf, never on the hardcoded upstream values.
#
# The front sensor is EXPECTED to stay unbound in this configuration. That is
# not a failure, it is the proof that 2/3 and 3/3 are genuinely out of the way.
#
# Usage, as root:
#   ./test-patch1-isolated.sh install   swap in the isolated config, arm boot check
#   (reboot)
#   ./test-patch1-isolated.sh verify    run the checks by hand (boot service also does)
#   ./test-patch1-isolated.sh install-b then reboot: integration on upstream board data
#   ./test-patch1-isolated.sh revert    put everything back the way it was

set -u

KVER="$(uname -r)"
DKMSDIR="/lib/modules/$KVER/updates/dkms"
STASH="/var/lib/ov5678-isolated-test"
MODCONF="/etc/modprobe.d/int3472-dell7320.conf"
SRC="$(cd "$(dirname "$0")/../upstream/isolated-test" && pwd)"
LOG="/var/log/ov5678-patch1-isolated.log"
UNIT="/etc/systemd/system/ov5678-patch1-verify.service"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0 $*)" >&2; exit 1; }

# The kernel build system cannot handle the space in "Claude Code", so the
# module is always built in a temporary space-free directory.
build_module() {
    local b; b="$(mktemp -d)"
    cp "$SRC"/tps68470.c "$SRC"/tps68470.h "$SRC"/tps68470_board_data.c "$SRC"/Makefile "$b/" || return 1
    make -C "$b" >/dev/null 2>&1 || { echo "  BUILD FAILED" >&2; rm -rf "$b"; return 1; }
    local n; n="$(modinfo "$b/intel_skl_int3472_tps68470.ko" | grep -c '^parm')"
    [ "$n" -eq 0 ] || { echo "  REFUSING: built module has $n module parameters, so it is not the upstream version" >&2; rm -rf "$b"; return 1; }
    echo "$b/intel_skl_int3472_tps68470.ko"
}

case "${1:-verify}" in
install)
    mkdir -p "$STASH"
    ko="$(build_module)" || exit 1
    echo "== built isolated module: $(basename "$ko"), 0 module parameters =="

    # The distro kernel ships NO copy of ov5675, ipu-bridge or
    # intel_skl_int3472_tps68470 outside DKMS - installing camera-dell7320 moved
    # the stock ones into DKMS's original_module stash. So "use the stock
    # modules" means asking DKMS to put its originals back, not deleting files.
    if dkms status camera-dell7320/0.3 2>/dev/null | grep -q "$KVER"; then
        dkms uninstall camera-dell7320/0.3 -k "$KVER" >/dev/null 2>&1 \
            && echo "  dkms uninstall: stock ov5675 / ipu-bridge / int3472 restored"
    fi
    # install-b hand-copies the PATCHED sensor modules into updates/dkms, and
    # dkms uninstall knows nothing about those copies - it is a no-op against
    # them. Left behind, they would make a "patch 1/3 alone" run silently
    # include 2/3 and 3/3. Sweep them explicitly.
    for m in ov5675 ipu-bridge; do
        for f in "$DKMSDIR/$m.ko" "$DKMSDIR/$m.ko.zst"; do
            [ -e "$f" ] && { rm -f "$f"; echo "  removed leftover $(basename "$f") from updates/dkms"; }
        done
    done
    depmod -a "$KVER"
    for m in ov5675 ipu-bridge; do
        p="$(modinfo -n $m 2>/dev/null)"
        if [ -n "$p" ] && ! (zstdcat "$p" 2>/dev/null || cat "$p") | strings | grep -q OVTI5678; then
            echo "  confirmed stock: $m -> $p"
        else
            echo "  ABORT: $m is still patched or missing ($p)" >&2; exit 1
        fi
    done

    install -m644 "$ko" "$DKMSDIR/intel_skl_int3472_tps68470.ko"
    rm -rf "$(dirname "$ko")"
    echo "  installed upstream-v2 int3472 into updates/dkms (outranks kernel/)"

    # The upstream module has no parameters, so this file would make modprobe
    # fail outright with "unknown parameter".
    [ -e "$MODCONF" ] && { mv "$MODCONF" "$STASH/"; echo "  stashed $(basename "$MODCONF") (upstream module takes no parameters)"; }

    systemctl disable --now ov5678-camera.service >/dev/null 2>&1 && echo "  stopped ov5678-camera.service (no sensor in this config)"

    depmod -a "$KVER"

    cat > "$UNIT" <<EOF
[Unit]
Description=Capture OV5678 patch-1-alone evidence at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sleep 25; "$(readlink -f "$0")" verify > "$LOG" 2>&1'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable ov5678-patch1-verify.service >/dev/null 2>&1
    echo "  armed boot check -> $LOG"
    echo
    echo "REBOOT REQUIRED. Board data cannot be re-probed without one (see header)."
    ;;

verify)
    echo "=== OV5678 patch 1/3 ALONE - $(date -Is) - kernel $KVER ==="
    pass=0; fail=0
    ck() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

    ov="$(modinfo -n ov5675 2>/dev/null)"
    ib="$(modinfo -n ipu-bridge 2>/dev/null || modinfo -n ipu_bridge 2>/dev/null)"
    has() { [ -n "$1" ] && (zstdcat "$1" 2>/dev/null || cat "$1") | strings | grep -q OVTI5678; }
    if has "$ov"; then PHASE=B; else PHASE=A; fi
    echo "  detected PHASE $PHASE  ($([ $PHASE = A ] && echo 'patch 1/3 alone' || echo 'upstream board data + patched sensor'))"

    echo
    if [ "$PHASE" = A ]; then
        echo "--- Isolation: are patches 2/3 and 3/3 really out of the way? ---"
        echo "  ov5675 in use: ${ov:-<none>}"
        ck "ov5675 is STOCK (no OVTI5678 ACPI id -> patch 2/3 absent)" '! has "$ov"'
        echo "  ipu-bridge in use: ${ib:-<none>}"
        ck "ipu-bridge is STOCK (no OVTI5678 sensor config -> patch 3/3 absent)" '! has "$ib"'
        ck "front sensor UNBOUND (expected without 2/3 - this is the isolation)" \
           '[ ! -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ]'
    else
        echo "--- Phase B: does the HARDCODED upstream board data drive the camera? ---"
        ck "ov5675 is the patched one (2/3 present)" 'has "$ov"'
        ck "ipu-bridge is the patched one (3/3 present)" 'has "$ib"'
        ck "front sensor BOUND on upstream board data alone" \
           '[ -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ]'
        # gpioinfo prints the chip NAME (gpiochip1), never the label, so
        # `gpioinfo | grep tps68470` matches nothing. Find the chip by label via
        # gpiodetect, exactly as test-gpio-mapping.sh does, and never hardcode
        # the number - it depends on probe order.
        CHIP=""
        for c in /dev/gpiochip*; do
            b="$(basename "$c")"
            gpiodetect 2>/dev/null | grep -q "^$b .*tps68470" && { CHIP="$b"; break; }
        done
        echo "  tps68470 gpiochip: ${CHIP:-NOT FOUND}"
        [ -n "$CHIP" ] && gpioinfo -c "$CHIP" 2>/dev/null | sed 's/^/    /'
        ck "reset resolved on tps68470 line 5 (the v2 GPIO_LOOKUP)" \
           '[ -n "$CHIP" ] && gpioinfo -c "$CHIP" 2>/dev/null | grep -E "^[[:space:]]*line[[:space:]]+5:" | grep -qE "used|consumer="'
    fi
    ck "int3472 module has NO parameters (upstream build, not the dev one)" \
       '[ "$(modinfo intel_skl_int3472_tps68470 2>/dev/null | grep -c ^parm)" -eq 0 ]'
    ck "no modprobe.d parameter file in play" '[ ! -e "$MODCONF" ]'

    echo
    echo "--- The patch does its job ---"
    ck "INT3472:07 is BOUND to int3472-tps68470" \
       '[ -e /sys/bus/i2c/drivers/int3472-tps68470/i2c-INT3472:07 ]'

    # A successful probe is SILENT, so "the message is absent" only means
    # something if the ring buffer still covers boot. dmesg -C during an earlier
    # experiment is exactly how you get a meaningless pass here.
    if dmesg 2>/dev/null | grep -qE 'Linux version|Command line:'; then
        ck "no \"No board-data found\" in dmesg (the message Charles watched for)" \
           '! dmesg | grep -q "No board-data found"'
    else
        echo "  INCONCLUSIVE  ring buffer does not reach boot (cleared?); absence of"
        echo "                \"No board-data found\" proves nothing. Reboot and re-run."
        fail=$((fail+1))
    fi
    ck "tps68470 GPIO chip registered" \
       'grep -qi tps68470 /sys/class/gpio/*/label 2>/dev/null || gpiodetect 2>/dev/null | grep -qi tps68470'

    echo
    echo "  regulator                 expected      actual        state"
    declare -A want=( [CORE]=1200000 [ANA]=2815200 [VCM]=2815200 [VIO]=1800600 [VSIO]=1800600 [AUX1]=1213200 [AUX2]=1800600 )
    found=0; wrong=0
    for r in /sys/class/regulator/regulator.*; do
        n="$(cat "$r/name" 2>/dev/null)"; [ -n "${want[$n]:-}" ] || continue
        v="$(cat "$r/microvolts" 2>/dev/null)"; s="$(cat "$r/state" 2>/dev/null)"
        found=$((found+1)); mark="ok"
        [ "$v" = "${want[$n]}" ] || { mark="WRONG"; wrong=$((wrong+1)); }
        printf '  %-12s %12s %12s  %-9s %s\n' "$n" "${want[$n]}" "$v" "${s:-?}" "$mark"
    done
    ck "all 7 rails registered" '[ "$found" -eq 7 ]'
    # Gate on found: with 0 rails examined, wrong is trivially 0 and this would
    # pass while proving nothing.
    ck "all 7 voltages match the patch" '[ "$found" -eq 7 ] && [ "$wrong" -eq 0 ]'

    echo
    echo "--- VIO always-on (changed in v2; never tested on hardware before) ---"
    viost=""; viodir=""
    for r in /sys/class/regulator/regulator.*; do
        [ "$(cat "$r/name" 2>/dev/null)" = VIO ] || continue
        viodir="$r"; viost="$(cat "$r/state" 2>/dev/null)"
    done
    viosum="$(awk '$1 ~ /VIO$/ {print; exit}' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null)"
    echo "  VIO sysfs state : ${viost:-<empty or absent>}"
    echo "  VIO debugfs line: ${viosum:-<unreadable>}"
    # On the dev module VIO's sysfs state file read back EMPTY, so treat that as
    # missing evidence rather than as a negative, and fall back to debugfs.
    if [ "$viost" = enabled ] || echo "$viosum" | grep -qE '[[:space:]]+1[[:space:]]'; then
        echo "  PASS  VIO enabled with no consumer (always_on took effect)"; pass=$((pass+1))
    elif [ -z "$viost" ] && [ -z "$viosum" ]; then
        echo "  INCONCLUSIVE  neither sysfs state nor debugfs summary readable"; fail=$((fail+1))
    else
        echo "  FAIL  VIO is not enabled - always_on did not take effect"; fail=$((fail+1))
    fi

    echo
    echo "--- Consumer supply mapping (needs debugfs) ---"
    if [ -r /sys/kernel/debug/regulator/regulator_summary ]; then
        grep -E 'VSIO|AUX1|AUX2|VIO|CORE|ANA|VCM|OVTI' /sys/kernel/debug/regulator/regulator_summary | sed 's/^/  /'
    else
        echo "  (regulator_summary not readable)"
    fi

    echo
    echo "--- No secondary effects ---"
    ck "no int3472/tps68470 errors in dmesg" \
       '! dmesg | grep -iE "int3472|tps68470" | grep -qiE "error|fail|invalid|no dependents|unable"'
    echo "  rear sensor OVTI8856:00: $([ -e /sys/bus/i2c/devices/i2c-OVTI8856:00/driver ] && echo BOUND || echo unbound)"
    echo "  (unbound was also the state BEFORE this change - not a regression)"
    echo
    echo "  int3472/tps68470 dmesg lines:"
    dmesg | grep -iE 'int3472|tps68470' | sed 's/^/    /' || echo "    (none)"

    echo
    echo "=== $pass passed, $fail failed ==="
    ;;

install-b)
    # Phase B is NOT part of "tested alone". It answers a second question that
    # matters just as much: the camera has only ever run on the dev module with
    # rail_map=1 front_reset=5 passed as module parameters, never on the
    # hardcoded upstream values. Phase B keeps the upstream int3472 and puts the
    # patched sensor modules back, so the picture is produced by the board data
    # exactly as submitted.
    #
    # It needs its own boot: ipu-bridge is loaded far too early to swap live, and
    # INT3472 cannot re-probe in any case.
    [ -e "$DKMSDIR/intel_skl_int3472_tps68470.ko" ] || { echo "ERROR: run 'install' first" >&2; exit 1; }
    B="/var/lib/dkms/camera-dell7320/0.3/$KVER/x86_64/module"
    for m in ov5675 ipu-bridge; do
        cp "$B/$m.ko.zst" "$DKMSDIR/" && echo "  restored PATCHED $m"
    done
    echo "  kept upstream int3472 (still 0 module parameters, still no modprobe.d file)"
    depmod -a "$KVER"
    systemctl enable ov5678-camera.service >/dev/null 2>&1
    echo
    echo "REBOOT for phase B. verify will detect the phase automatically."
    ;;

revert)
    rm -f "$DKMSDIR/intel_skl_int3472_tps68470.ko"
    echo "  removed the isolated upstream int3472 build"
    dkms install camera-dell7320/0.3 -k "$KVER" >/dev/null 2>&1 \
        && echo "  dkms install: all three patched modules back in place" \
        || echo "  WARNING: dkms install failed - check 'dkms status'" >&2
    [ -e "$STASH/$(basename "$MODCONF")" ] && { mv "$STASH/$(basename "$MODCONF")" "$MODCONF"; echo "  restored $(basename "$MODCONF")"; }
    systemctl disable --now ov5678-patch1-verify.service >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl enable ov5678-camera.service >/dev/null 2>&1
    systemctl daemon-reload
    depmod -a "$KVER"
    rmdir "$STASH" 2>/dev/null
    echo
    echo "Reverted. REBOOT to bring the camera back (board data cannot re-probe - see header)."
    ;;
*)
    echo "usage: $0 {install|verify|install-b|revert}" >&2; exit 1;;
esac
