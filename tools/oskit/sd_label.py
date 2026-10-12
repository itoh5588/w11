#!/usr/bin/env python3
"""Put a w11 card label in front of a raw disk image for the Arty S7 microSD.

The standalone Arty S7 bitstream reads block 0 of the card and selects the
RP07, RK05 or RL01/RL02 controller from this label. The disk data follows at
the first data LBA (--base, default 2048 = 1 MiB). A card without a label is
treated as an RP07 card with the disk at LBA 0.

Label (block 0, little-endian 16-bit words):
  word 0..3  ASCII "W11SDLBL"
  word 4     version 1
  word 5     disk type: 1 RP07, 2 RK05, 3 RL01/RL02
  word 6..7  first data LBA, low word first
  word 8     RL only: bit u set = unit u is an RL02 (else RL01)
  word 9     RL only: bit u set = unit u is present
The rest of block 0 is zero; bytes 446..511 are left for an MBR.

The input is the image as the controller sees it from its first LBA: a raw
RP07 image, the pack_sd.py RK05 card or the pack_rl_sd.py RL card. The output
is always a new regular file, never a block device.
"""

import argparse
import os
import stat
import struct
from pathlib import Path


MAGIC = b"W11SDLBL"
VERSION = 1
TYPES = {"rp07": 1, "rk05": 2, "rl": 3}
BLOCK = 512
COPY_CHUNK = 1 << 20


def make_label(disk_type: str, base: int, rl02_mask: int = 0xF,
               present_mask: int = 0xF) -> bytes:
    if disk_type not in TYPES:
        raise ValueError(f"unknown disk type {disk_type}")
    if not 1 <= base < 1 << 32:
        raise ValueError("base must be between 1 and 2**32-1")
    if not (0 <= rl02_mask <= 0xF and 0 <= present_mask <= 0xF):
        raise ValueError("masks are 4 bits")
    if disk_type != "rl":
        rl02_mask = present_mask = 0
    head = MAGIC + struct.pack("<HHIHH", VERSION, TYPES[disk_type], base,
                               rl02_mask, present_mask)
    return head + bytes(BLOCK - len(head))


def parse_label(block: bytes) -> dict | None:
    """Decode a label as the FPGA does; None for an unlabeled card."""
    if len(block) < 20 or block[:8] != MAGIC:
        return None
    version, dtype, base, rl02, present = struct.unpack_from("<HHIHH", block, 8)
    names = {v: k for k, v in TYPES.items()}
    if version != VERSION or dtype not in names:
        return None
    return {"type": names[dtype], "base": base,
            "rl02_mask": rl02 & 0xF, "present_mask": present & 0xF}


def write_card(source: Path, output: Path, label: bytes, base: int) -> None:
    info = source.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
        raise ValueError(f"input is not a non-empty regular file: {source}")
    if info.st_size % BLOCK:
        raise ValueError(f"input size is not a multiple of {BLOCK}: {source}")
    with source.open("rb") as image:
        if parse_label(image.read(BLOCK)) is not None:
            raise ValueError(f"input already has a card label: {source}")
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "wb") as target, source.open("rb") as image:
            target.write(label)
            target.write(bytes((base - 1) * BLOCK))
            copied = 0
            while chunk := image.read(COPY_CHUNK):
                target.write(chunk)
                copied += len(chunk)
            if copied != info.st_size:
                raise RuntimeError(f"input changed while copying: {source}")
        if output.stat().st_size != base * BLOCK + info.st_size:
            raise RuntimeError("output size check failed")
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def mask(text: str) -> int:
    if len(text) != 4 or set(text) - {"0", "1"}:
        raise argparse.ArgumentTypeError("mask is 4 binary digits, RL3..RL0")
    return int(text, 2)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help="raw disk or packed card image")
    parser.add_argument("output", type=Path, help="new labeled card image")
    parser.add_argument("--type", required=True, choices=sorted(TYPES))
    parser.add_argument("--base", type=int, default=2048,
                        help="first data LBA (default 2048)")
    parser.add_argument("--rl02-mask", type=mask, default=0xF, metavar="BBBB",
                        help="RL: RL02 units, RL3..RL0 (default 1111)")
    parser.add_argument("--present-mask", type=mask, default=0xF, metavar="BBBB",
                        help="RL: present units, RL3..RL0 (default 1111)")
    args = parser.parse_args()
    try:
        label = make_label(args.type, args.base, args.rl02_mask, args.present_mask)
        write_card(args.input, args.output, label, args.base)
    except ValueError as error:
        parser.error(str(error))
    print(f"{args.output}: {args.type.upper()} data at LBA {args.base}")


if __name__ == "__main__":
    main()
