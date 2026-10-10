#!/usr/bin/env bash
# Write single-block variants of designs/blocks14.v for silicon diagnosis:
#   designs/blk_mac14.v (MULADD only), blk_rf14.v (RegFile only), blk_bram14.v (BRAM only)
set -euo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)/designs"
for v in "mac14 3'b001" "rf14 3'b010" "bram14 3'b100"; do
    set -- $v
    { echo "\`define BLK_NAME blk_$1"; echo "\`define BLK_USE $2"; cat "$D/blocks14.v"; } > "$D/blk_$1.v"
    echo "wrote designs/blk_$1.v"
done
