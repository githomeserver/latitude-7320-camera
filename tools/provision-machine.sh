#!/bin/bash
# Bring a fresh Ubuntu install on a Latitude 7320 Detachable up to the point
# where the camera work can continue: packages, DKMS modules, module options.
#
# Written 2026-08-14 for the refurbished unit, which arrived with a clean
# install and none of the project's stack deployed.
#
# Run as root:  sudo ./provision-machine.sh
#
# NOTE ON PIN ASSIGNMENT — obsolete as of 2026-08-16, kept for the reasoning.
#
# None of this applies any more. DKMS package camera-dell7320 0.4 carries the
# UPSTREAM board data (the patch archived at
# https://lore.kernel.org/platform-driver-x86/20260816070108.9308-1-adee.sahan@gmail.com/),
# which hardcodes reset on tps68470-gpio 5 and the VSIO/AUX1/AUX2 rails, and
# accepts NO module parameters at all. Writing the modprobe.d file below would
# now make the module fail to load with "unknown parameter". Step 3 therefore
# removes it instead of writing it.
#
# The historical reasoning follows, because it explains why the pins are what
# they are.
#
# NOTE ON PIN ASSIGNMENT — read before changing it.
#
# This deliberately installs with NO GPIO pin assignment at all
# (front_reset=-1 front_powerdown=-1 rear_reset=-1 rear_powerdown=-1), which
# is NOT what README.md step 1 says. Three reasons:
#
#   1. The README's front_reset=3 front_powerdown=4 is known wrong. There is no
#      powerdown pin (ov5675.c only ever requests "reset"), and reset is pin 5,
#      not 3. A correction is already on the lists.
#   2. The module's compiled-in defaults are front_reset=9, front_powerdown=7 —
#      the very lines the project notes warn wedge the PMIC until reboot. So an
#      absent conf file is not a neutral starting state; the -1s are required to
#      get one.
#   3. Unassigned is the control condition the GPIO mapping test needs: nothing
#      has claimed the lines, so gpioset can drive them without contention.
#
# The camera is expected to work anyway — line 5 sits released by default. That
# is the whole reason a wrong mapping went unnoticed. Do not read a working
# camera as confirmation of anything.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

KVER="$(uname -r)"

echo "== 1. packages =="
apt-get update
apt-get install -y \
    build-essential dkms "linux-headers-$KVER" \
    gpiod i2c-tools v4l-utils \
    libcamera-tools libcamera-ipa gstreamer1.0-libcamera \
    gstreamer1.0-plugins-good \
    v4l2loopback-dkms v4l2-relayd \
    python3-pil git-email gh

echo
echo "== 2. i2c-dev for the EEPROM read at 0x51 =="
modprobe i2c-dev || true
grep -qxF 'i2c-dev' /etc/modules-load.d/i2c-dev.conf 2>/dev/null \
    || echo 'i2c-dev' > /etc/modules-load.d/i2c-dev.conf

echo
echo "== 3. module options: none, and any stale file must go =="
# The upstream board data takes no parameters. A leftover int3472-dell7320.conf
# from an older provisioning run makes modprobe fail outright, so remove it
# rather than assume it is absent.
if [ -e /etc/modprobe.d/int3472-dell7320.conf ]; then
    rm -f /etc/modprobe.d/int3472-dell7320.conf
    echo "  removed stale /etc/modprobe.d/int3472-dell7320.conf (module takes no parameters)"
else
    echo "  none needed - reset pin and rails are hardcoded in the board data"
fi

echo
echo "== 4. DKMS modules =="
"$HERE/dkms-install.sh"

echo
echo "== 5. initrd =="
# The IPU6 firmware race (module pulled into the initrd, probing before rootfs
# and failing -ENOENT on ipu6_fw.bin) is not present on this install: IPU6 is
# already up. Only rebuild if that stops being true.
if [ -e /dev/media0 ]; then
    echo "   /dev/media0 present, IPU6 firmware loads fine — initrd left alone"
else
    echo "   WARNING: no /dev/media0. If IPU6 fails -ENOENT on firmware, the"
    echo "   initrd is pulling intel_ipu6 in early. Fix with: dracut --force"
fi

echo
echo "== done =="
echo "Reboot, then run:  tools/check-camera.sh"
echo
echo "Expect the camera to work WITHOUT any pin assigned. That is the"
echo "starting point for the GPIO mapping test, not a result."
