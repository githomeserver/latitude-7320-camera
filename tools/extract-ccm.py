#!/usr/bin/env python3
"""Extract Intel's colour matrices from a camera .aiqb tuning file.

The OV5678 (and OV8856) .aiqb files shipped in the Windows driver contain the
exact colour correction matrices Intel's IPU6 pipeline applies. This reads
record type 25, ``cmc_advanced_color_matrix_correction``, and prints one 3x3
matrix per light source, plus the sensor's native chromaticity (R/G, B/G) and
CIE coordinates Intel measured for each illuminant.

Format reference (public, Apache-2.0):
  intel/ipu6-camera-bins : include/ipu6/ia_imaging/ia_cmc_types.h

Record layout (established by decoding, cross-checked by the invariant that
every matrix row sums to 1.0 - a white-preserving CCM):

    offset 0   ia_mkn_record_header  uint32 size, u8 format, u8 group, u8 type(=25), u8 reserved
    offset 8   u16 num_light_srcs
    offset 10  u16 num_sectors
    offset 12  u32 hue_of_sectors[num_sectors]          (start hue angle, degrees)
    then, per light source:
        u32  source_type                                (enum cmc_light_source)
        f32  chromaticity[2]                            (R/G, B/G)
        f32  cie_coords[2]                              (x, y)
        f32  traditional[3][3]                          (matrix optimised over all sectors)
        f32  advanced[num_sectors][3][3]                (per-hue-sector matrices)
    then 4 zero bytes of terminator.

Usage:
    tools/extract-ccm.py OV5678_0BF501T3_TGL.aiqb

The ``traditional`` matrix is what a single-3x3 consumer (libcamera's simple
IPA ``Ccm``) should use. The ``advanced`` per-sector matrices are for a
hue-segmented ISP and are not usable by the simple IPA.

Provenance: the matrices are interoperability facts about this camera module,
the same category as the lens-shading tables already extracted by
extract-lens-shading.py. Do not commit the .aiqb files themselves.
"""

import math
import struct
import sys

LIGHT_SOURCE = {
    0: "none", 1: "A", 2: "B", 3: "C", 4: "D50", 5: "D55", 6: "D65", 7: "D75",
    8: "E", 9: "F1", 10: "F2", 11: "F3", 12: "F4", 13: "F5", 14: "F6",
    15: "F7", 16: "F8", 17: "F9", 18: "F10", 19: "F11", 20: "F12",
    21: "horizon-IR", 22: "A_md", 23: "A_lw",
}


def cct_from_xy(x, y):
    """Colour temperature in kelvin from CIE xy, McCamy's approximation."""
    try:
        n = (x - 0.3320) / (0.1858 - y)
        return round(449 * n ** 3 + 3525 * n ** 2 + 6823.3 * n + 5520.33)
    except ZeroDivisionError:
        return None


def parse_aiqb(path):
    data = open(path, "rb").read()
    # Records start at offset 0xc0 inside the CPFF/LCMC/DFLT/AIQB container.
    off = 192
    while off + 8 <= len(data):
        size = struct.unpack_from("<I", data, off)[0]
        if size < 8 or off + size > len(data):
            break
        _, _, typ = struct.unpack_from("<BBB", data, off + 4)
        if typ == 25:
            rec = data[off:off + size]
            break
        off += size
    else:
        return None

    num_light, num_sectors = struct.unpack_from("<HH", rec, 8)
    hues = list(struct.unpack_from("<%dI" % num_sectors, rec, 12))
    base = 12 + num_sectors * 4
    block = 4 + 8 + 8 + 36 + num_sectors * 36  # source_type + chroma + cie + trad + advanced

    result = {"num_light_srcs": num_light, "num_sectors": num_sectors,
              "hue_of_sectors": hues, "light_sources": []}
    for i in range(num_light):
        b = base + i * block
        src_type = struct.unpack_from("<I", rec, b)[0]
        r_g, b_g = struct.unpack_from("<ff", rec, b + 4)
        cie_x, cie_y = struct.unpack_from("<ff", rec, b + 12)
        traditional = list(struct.unpack_from("<9f", rec, b + 20))
        advanced = [list(struct.unpack_from("<9f", rec, b + 56 + s * 36))
                    for s in range(num_sectors)]
        result["light_sources"].append({
            "source_type": src_type,
            "name": LIGHT_SOURCE.get(src_type, str(src_type)),
            "chromaticity_rg": r_g, "chromaticity_bg": b_g,
            "cie_x": cie_x, "cie_y": cie_y,
            "cct_k": cct_from_xy(cie_x, cie_y),
            "traditional": traditional, "advanced": advanced,
        })
    return result


def fmt_matrix(m):
    return ("[ % .5f, % .5f, % .5f,\n"
            "    % .5f, % .5f, % .5f,\n"
            "    % .5f, % .5f, % .5f ]" % tuple(m))


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: extract-ccm.py FILE.aiqb [...]")
    for path in sys.argv[1:]:
        r = parse_aiqb(path)
        print("=== %s ===" % path)
        if r is None:
            print("  no record type 25 (advanced_color_matrices) found\n")
            continue
        print("  %d light sources, %d hue sectors\n" % (r["num_light_srcs"], r["num_sectors"]))
        for ls in r["light_sources"]:
            m = ls["traditional"]
            rowsums = [round(sum(m[j * 3:j * 3 + 3]), 6) for j in range(3)]
            print("  %-4s type=%2d  CCT~%5d K  R/G=%.4f  B/G=%.4f  CIE(%.3f, %.3f)"
                  % (ls["name"], ls["source_type"], ls["cct_k"] or -1,
                     ls["chromaticity_rg"], ls["chromaticity_bg"],
                     ls["cie_x"], ls["cie_y"]))
            print("      traditional  (row sums %s):" % rowsums)
            print("      " + fmt_matrix(m).replace("\n", "\n      "))
            print()


if __name__ == "__main__":
    main()
