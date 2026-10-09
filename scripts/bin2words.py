#!/usr/bin/env python3
"""Convert a FABulous bitstream (.bin) into 32-bit big-endian words.

Output formats:
  hex  : one 8-digit hex word per line ($readmemh, GHDL testbenches)
  c    : C array (bare-metal RV32IM / A72 loaders)

The FABulous ConfigFSM expects every word exactly as it appears in the .bin,
MSB first: [0xFAB0FAB1 sync] [frame address] [N_rows frame-data words] ...
"""
import argparse
import sys
from pathlib import Path


def words(path: Path) -> list[int]:
    data = path.read_bytes()
    if len(data) % 4:
        sys.exit(f"{path}: length {len(data)} is not a multiple of 4")
    w = [int.from_bytes(data[i:i + 4], "big") for i in range(0, len(data), 4)]
    if 0xFAB0FAB1 not in w:
        sys.exit(f"{path}: sync word 0xFAB0FAB1 not found - not a FABulous bitstream?")
    return w


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("bin", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--fmt", choices=["hex", "c"], default="hex")
    ap.add_argument("--name", default="efpga_bitstream")
    a = ap.parse_args()
    w = words(a.bin)
    if a.fmt == "hex":
        a.out.write_text("".join(f"{x:08x}\n" for x in w))
    else:
        body = ",\n".join(
            "  " + ", ".join(f"0x{x:08x}u" for x in w[i:i + 6]) for i in range(0, len(w), 6)
        )
        a.out.write_text(
            "#include <stdint.h>\n"
            f"const uint32_t {a.name}_len = {len(w)}u;\n"
            f"const uint32_t {a.name}[{len(w)}] = {{\n{body}\n}};\n"
        )
    print(f"{a.bin.name}: {len(w)} words -> {a.out}")


if __name__ == "__main__":
    main()
