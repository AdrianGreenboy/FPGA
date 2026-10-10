#!/usr/bin/env python3
"""efpga.py - drive the efpga_axil block from PetaLinux via /dev/mem.

  efpga.py [--base 0xA4000000] info
  efpga.py [--base ...] load   <bitstream.hex|.bin>
  efpga.py [--base ...] selftest <d1.hex> [<d2.hex> ...] [--loops N]

selftest = the silicon version of sim/tb_axil.v: configure d1, d2, ..., d1
(runtime reconfiguration) and check cycle-exact results produced with IO_PULSE.
Expected values: <design>.expect next to the .hex (golden RTL sim, written by
sim/run_sim.sh), built in for counter14 / lfsr14:
  counter14: n=1 -> 0x0001, n=1000 -> 0x03e8, n=16383 -> 0x3fff
  lfsr14   : n=1 -> 0x0002, n=1000 -> 0x1cda, n=16383 -> 0x0001
Needs root (or CAP_SYS_RAWIO). Base address: whatever Vivado assigned
(the build script prints it and writes build/vivado/efpga_address.txt).
"""
import argparse
import mmap
import os
import struct
import sys
import time
from pathlib import Path

REG = dict(ID=0x00, CTRL=0x04, STATUS=0x08, CFG_DATA=0x0C, CFG_COUNT=0x10, IO_IN=0x14,
           IO_OUT=0x18, IO_OE=0x1C, SCRATCH=0x20, CYCLES=0x24, IO_PULSE=0x28)
ID_EXPECTED = 0xEF0A0001


class Efpga:
    # Register access MUST be one 32-bit load/store: struct.pack_into() writes byte by
    # byte (4 AXI writes with 1-byte WSTRB), which the wrapper counts as 4 CFG_DATA words.
    # memoryview.cast("I") item access compiles to a single 32-bit access.
    def __init__(self, base: int):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                            offset=base)
        self.w = memoryview(self.mm).cast("I")

    def rd(self, name: str) -> int:
        return self.w[REG[name] >> 2]

    def wr(self, name: str, value: int) -> None:
        self.w[REG[name] >> 2] = value & 0xFFFFFFFF

    def wait_not(self, bit: int, timeout_s: float = 1.0) -> None:
        t0 = time.monotonic()
        while self.rd("STATUS") & bit:
            if time.monotonic() - t0 > timeout_s:
                raise TimeoutError(f"STATUS bit 0x{bit:x} stuck, STATUS=0x{self.rd('STATUS'):08x}")

    def configure(self, words: list[int]) -> float:
        self.wr("CTRL", 0x3)                    # isolate + reset ConfigFSM
        t0 = time.perf_counter()
        for w in words:                         # B-channel back-pressure paces the writes
            self.wr("CFG_DATA", w)
        dt = time.perf_counter() - t0
        n = self.rd("CFG_COUNT")
        if n != len(words):
            raise RuntimeError(f"CFG_COUNT={n}, expected {len(words)}")
        self.wr("IO_IN", 0)
        self.wr("CTRL", 0x0)                    # release isolation
        return dt

    def pulse(self, mask: int, count: int) -> None:
        self.wr("IO_PULSE", (count << 16) | (mask & 0xFFFF))
        self.wait_not(0x8)


def load_words(path: Path) -> list[int]:
    if path.suffix == ".bin":
        d = path.read_bytes()
        return [int.from_bytes(d[i:i + 4], "big") for i in range(0, len(d), 4)]
    return [int(line, 16) for line in path.read_text().split() if line]


def builtin_expect(design: str, n: int) -> int:
    if design == "counter14":
        return n & 0x3FFF
    s = 1
    for _ in range(n):
        fb = ((s >> 13) ^ (s >> 12) ^ (s >> 11) ^ (s >> 1)) & 1
        s = ((s << 1) | fb) & 0x3FFF
    return s


def expectations(path: Path) -> list[tuple[int, int]]:
    """(n, value) pairs: from <design>.expect (golden RTL sim) next to the bitstream,
    or built in for counter14 / lfsr14."""
    exp_file = path.with_suffix(".expect")
    if exp_file.exists():
        pairs = []
        for line in exp_file.read_text().splitlines():
            if line.strip():
                n, v = line.split()
                pairs.append((int(n), int(v, 16)))
        return pairs
    if path.stem in ("counter14", "lfsr14"):
        return [(n, builtin_expect(path.stem, n)) for n in (1, 1000, 16383)]
    sys.exit(f"{path}: no {exp_file.name} and no built-in model for '{path.stem}'")


def selftest(fp: Efpga, designs: list[Path], loops: int) -> int:
    """Configure designs[0..k-1] and then designs[0] again (A -> B -> ... -> A)."""
    order = designs + designs[:1]
    data = {p: (load_words(p), expectations(p)) for p in designs}
    errors = 0
    for loop in range(loops):
        for path in order:
            words, exp = data[path]
            name = path.stem
            dt = fp.configure(words)
            oe = fp.rd("IO_OE")
            if oe != 0xFFFC:
                print(f"  {name}: IO_OE=0x{oe:04x} expected 0xfffc"); errors += 1
            line = []
            for n, want in exp:
                fp.pulse(0x3, 1)                 # rst + en for exactly 1 clock
                fp.pulse(0x2, n)                 # en for exactly n clocks
                got = (fp.rd("IO_OUT") >> 2) & 0x3FFF
                ok = got == want
                errors += not ok
                line.append(f"n={n}:{got:04x}{'' if ok else f'!={want:04x}'}")
            print(f"[loop {loop}] {name:9s} cfg {len(words)} words in {dt * 1e3:6.1f} ms  "
                  + "  ".join(line))
    print("RESULT:", "PASS" if errors == 0 else f"FAIL ({errors} errors)")
    return 0 if errors == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0xA4000000)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info")
    p = sub.add_parser("load"); p.add_argument("bitstream", type=Path)
    p = sub.add_parser("selftest"); p.add_argument("designs", type=Path, nargs="+")
    p.add_argument("--loops", type=int, default=1)
    a = ap.parse_args()

    fp = Efpga(a.base)
    ident = fp.rd("ID")
    if ident != ID_EXPECTED:
        print(f"ID=0x{ident:08x}, expected 0x{ID_EXPECTED:08x} - wrong base address or PL not loaded?")
        return 1
    if a.cmd == "info":
        c0 = fp.rd("CYCLES"); time.sleep(0.1); c1 = fp.rd("CYCLES")
        print(f"ID=0x{ident:08x} STATUS=0x{fp.rd('STATUS'):08x} CFG_COUNT={fp.rd('CFG_COUNT')} "
              f"fabric clock ~{(c1 - c0) % (1 << 32) / 0.1 / 1e6:.2f} MHz")
    elif a.cmd == "load":
        w = load_words(a.bitstream)
        print(f"{a.bitstream.name}: {len(w)} words in {fp.configure(w) * 1e3:.1f} ms")
    else:
        return selftest(fp, a.designs, a.loops)
    return 0


if __name__ == "__main__":
    sys.exit(main())
