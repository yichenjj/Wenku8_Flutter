#!/usr/bin/env python3
"""Generate lib/legacy/gb18030_ranges.dart.

The GB18030 four-byte space (b1 0x81-0xFE, b2 0x30-0x39, b3 0x81-0xFE,
b4 0x30-0x39) maps linear index -> Unicode code point piecewise-linearly:

    idx = ((b1 - 0x81) * 10 + (b2 - 0x30)) * 1260 + (b3 - 0x81) * 10 + (b4 - 0x30)

Walking every index against Python's gb18030 codec yields the contiguous
runs; the run list is tiny and powers decode (index -> code point) through
one binary search. Encoding stays GBK-conservative on the Dart side, so only
this decode direction is generated.

Usage: python3 linux/gen_gbk18030.py > lib/legacy/gb18030_ranges.dart
"""

TOTAL = 126 * 10 * 126 * 10


def index_to_bytes(idx):
    b4 = idx % 10
    idx //= 10
    b3 = idx % 126
    idx //= 126
    b2 = idx % 10
    idx //= 10
    b1 = idx % 126
    return bytes((b1 + 0x81, b2 + 0x30, b3 + 0x81, b4 + 0x30))


def build_runs():
    runs = []
    start = cp = 0
    open_run = False
    for idx in range(TOTAL):
        try:
            code = ord(index_to_bytes(idx).decode("gb18030"))
        except UnicodeDecodeError:
            code = None
        if code is None:
            if open_run:
                runs.append((start, cp, idx - start))
                open_run = False
            continue
        if not open_run:
            start, cp = idx, code
            open_run = True
        elif code != cp + (idx - start):
            runs.append((start, cp, idx - start))
            start, cp = idx, code
    if open_run:
        runs.append((start, cp, TOTAL - start))
    return runs


def verify(runs):
    import random

    random.seed(18030)
    for _ in range(20000):
        idx = random.randrange(TOTAL)
        try:
            want = ord(index_to_bytes(idx).decode("gb18030"))
        except UnicodeDecodeError:
            want = None
        got = None
        for s, c, length in runs:
            if s <= idx < s + length:
                got = c + (idx - s)
                break
        assert want == got, f"idx {idx}: want {want}, got {got}"
    covered = sum(length for _, _, length in runs)
    print(f"// verified: {covered}/{TOTAL} indices mapped, {len(runs)} runs",
          file=__import__("sys").stderr)


def main():
    runs = build_runs()
    verify(runs)
    print("// GENERATED FILE - linux/gen_gbk18030.py. Do not edit by hand.")
    print("//")
    print("// GB18030 four-byte linear ranges as flat (startIdx, startCp, length)")
    print("// triples, strictly increasing in both index and code point columns.")
    print("// Decode: idx in [startIdx, startIdx + length) -> startCp + (idx - startIdx).")
    print("const List<int> gb18030FourByteRanges = <int>[")
    for i in range(0, len(runs) * 3, 12):
        chunk = [x for triple in runs[i // 3:i // 3 + 4] for x in triple]
        print("  " + ", ".join(str(x) for x in chunk) + ",")
    print("];")


if __name__ == "__main__":
    main()
