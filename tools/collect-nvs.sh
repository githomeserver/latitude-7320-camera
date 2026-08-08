#!/bin/bash
# Read the individual ACPI NVS scalars that populate CLDB and SSDB.
#
# Why not just read the buffers? acpi_call's /proc reply is capped at 256
# characters, which at 6 chars per byte truncates any buffer past ~42 bytes.
# CLDB (32 bytes) survives; SSDB (108 bytes) does not. These NVS variables are
# root-scope integers, so each reply is tiny and complete.
#
# The variable list comes from this machine's DSDT:
#   \_SB.PC00.CLP0.CLDB  and  \_SB.PC00.LNK{0,1}.SSDB
#
# Run as root:  sudo ./collect-nvs.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../data"
mkdir -p "$OUT"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

if [ ! -e /proc/acpi/call ]; then
    modprobe acpi_call 2>/dev/null || { echo "ERROR: acpi_call unavailable" >&2; exit 1; }
fi

RESULT="$OUT/nvs.txt"
: > "$RESULT"

read_var() {
    local var="$1"
    printf '%s' "\\$var" > /proc/acpi/call 2>/dev/null
    local reply
    reply="$(tr -d '\0' < /proc/acpi/call)"
    printf '%-6s %s\n' "$var" "$reply" >> "$RESULT"
    printf '  %-6s %s\n' "$var" "$reply"
}

echo "== CLP0 control logic (TPS68470) =="
# CLDB-visible: C0VE version, C0TP type, C0CV sku, C0IC, C0SP, C0W0..C0W5.
# Not in CLDB but present in NVS and describing the same board wiring:
# C0GP gpio count, C0IB/C0IA i2c bus+address, C0P* pin, C0G* gpio,
# C0F* function, C0A* / C0I* aux, C0PL privacy led, C0CS clock source.
for v in C0VE C0TP C0CV C0IC C0SP C0W0 C0W1 C0W2 C0W3 C0W4 C0W5 \
         C0GP C0IB C0IA C0PL C0CS \
         C0P0 C0P1 C0P2 C0P3 C0G0 C0G1 C0G2 C0G3 \
         C0F0 C0F1 C0F2 C0F3 C0A0 C0A1 C0A2 C0A3 C0I0 C0I1 C0I2 C0I3; do
    read_var "$v"
done

for n in 0 1; do
    echo
    if [ "$n" = 0 ]; then echo "== LNK0 / OVTI5678 (front, the target) =="
    else echo "== LNK1 / OVTI8856 (rear) =="; fi
    # DV/CV version, LC clockdiv, LU link(CSI-2 port), NL lanes, EE eeprom,
    # VC vcm, FS flash, LE privacy led, DG rotation, CK MCLK Hz, CL control
    # logic id, PP/VR/PV/PU misc; A0/BS/DI feed _CRS; EN is _STA; PL is _PLD.
    for s in DV CV LC LU NL EE VC FS LE DG CK CL PP VR PV PU FD SM A0 A1 BS DI EN PL; do
        read_var "L${n}${s}"
    done
done

chown --reference="$HERE" "$RESULT" 2>/dev/null
chmod a+r "$RESULT" 2>/dev/null

echo
echo "Saved to $RESULT"
