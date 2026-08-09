#!/bin/bash
# Build RgbIrToBayer and check it against the Python reference on a real frame.
#   ./check.sh [/tmp/rgbir-raw.bin]
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${1:-/tmp/rgbir-raw.bin}"
[ -f "$RAW" ] && [ -f "$RAW.txt" ] || { echo "need $RAW and $RAW.txt (run tools/rgbir-proof.sh)" >&2; exit 1; }
g++ -std=c++17 -O2 -Wall -Wextra -o /tmp/test_rgbir "$HERE/test_rgbir.cpp" "$HERE/rgbir_to_bayer.cpp"
read -r W H STRIDE _ < "$RAW.txt"
BLACK=$(sed -n '2p' "$RAW.txt" | awk '{print $2}')
/tmp/test_rgbir "$RAW" "$W" "$H" "$STRIDE" "$BLACK" /tmp/rgbir-out.bayer
python3 - "$RAW" "$W" "$H" "$STRIDE" "$BLACK" <<'PY'
import sys
raw=open(sys.argv[1],'rb').read()
w,h,stride,black=int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4]),int(sys.argv[5])
# 0=G 1=IR 2=R 3=G 4=B. Channels 0 and 3 are BOTH green - the two green
# populations, as Gr/Gb are in Bayer - so green is 8 positions across the two.
CHAN=[[0,1,0,1],[2,3,4,3],[0,1,0,1],[4,3,2,3]]
GREEN={0,3}
n={"G":8,2:2,4:2}; acc={"G":0.0,2:0.0,4:0.0}; cells=0
for cy in range(h//4):
    rows=[(cy*4+dy)*stride for dy in range(4)]
    for cx in range(w//4):
        s={"G":0,2:0,4:0}
        for dy,r in enumerate(rows):
            p=r+cx*8
            for dx in range(4):
                c=CHAN[dy][dx]
                key="G" if c in GREEN else c
                if key in s: s[key]+=(raw[p]|(raw[p+1]<<8))-black
                p+=2
        for c in s: acc[c]+=s[c]/n[c]
        cells+=1
print(f"py   G {acc["G"]/cells:.3f}  R {acc[2]/cells:.3f}  B {acc[4]/cells:.3f}")
print(f"py   R/G {acc[2]/acc["G"]:.4f}  B/G {acc[4]/acc["G"]:.4f}")
PY
