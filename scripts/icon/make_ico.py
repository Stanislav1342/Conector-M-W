#!/usr/bin/env python3
"""Pack 16x16, 32x32, 48x48, and 256x256 PNGs into a Windows .ico file."""
import struct
import sys
from pathlib import Path

if len(sys.argv) < 3:
    raise SystemExit("Usage: make_ico.py <out.ico> <png1> [<png2> ...]")

out_path = Path(sys.argv[1])
images = []
for arg in sys.argv[2:]:
    data = Path(arg).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"Not a PNG: {arg}")
    width, height = struct.unpack(">II", data[16:24])
    images.append((width, height, data))

header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries = bytearray()
payload = bytearray()
for width, height, data in images:
    w_byte = 0 if width >= 256 else width
    h_byte = 0 if height >= 256 else height
    entries.extend(struct.pack("<BBBBHHII", w_byte, h_byte, 0, 0, 1, 32, len(data), offset))
    payload.extend(data)
    offset += len(data)

out_path.write_bytes(header + entries + payload)
print(f"Wrote {out_path} ({len(images)} sizes)")
