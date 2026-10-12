#!/usr/bin/env python3
"""Pack three RK05 images into a regular file for a dedicated microSD card.

This tool never opens a block device. Each RK05 unit occupies its full
203-cylinder slot; short input images are padded with zero bytes.
"""

import argparse
import os
import stat
from pathlib import Path


SECTOR_BYTES = 512
SECTORS_PER_UNIT = 203 * 2 * 12
UNIT_BYTES = SECTOR_BYTES * SECTORS_PER_UNIT
UNIT_COUNT = 3
IMAGE_BYTES = UNIT_BYTES * UNIT_COUNT


def pack(inputs: list[Path], output: Path) -> None:
    if len(inputs) != UNIT_COUNT:
        raise ValueError(f"exactly {UNIT_COUNT} RK05 images are required")

    sizes = []
    for path in inputs:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"input is not a regular file: {path}")
        if info.st_size == 0 or info.st_size > UNIT_BYTES:
            raise ValueError(f"input size is outside one RK05 slot: {path}")
        if info.st_size % SECTOR_BYTES:
            raise ValueError(f"input is not sector aligned: {path}")
        sizes.append(info.st_size)

    # O_EXCL and O_NOFOLLOW also prevent overwriting an existing output or
    # writing directly to a card/device through a symlink.
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(output, flags, 0o644)
    try:
        with os.fdopen(fd, "wb") as dst:
            for unit, (source, size) in enumerate(zip(inputs, sizes)):
                with source.open("rb") as src:
                    copied = 0
                    while chunk := src.read(1024 * 1024):
                        dst.write(chunk)
                        copied += len(chunk)
                    if copied != size:
                        raise RuntimeError(f"input changed while packing: {source}")
                padding = UNIT_BYTES - size
                zero = bytes(1024 * 1024)
                while padding:
                    count = min(padding, len(zero))
                    dst.write(zero[:count])
                    padding -= count
                print(f"RK{unit}: LBA {unit * SECTORS_PER_UNIT}, {size} bytes")
        if output.stat().st_size != IMAGE_BYTES:
            raise RuntimeError("output size check failed")
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rk0", type=Path)
    parser.add_argument("rk1", type=Path)
    parser.add_argument("rk2", type=Path)
    parser.add_argument("output", type=Path, help="new regular file, never a device")
    args = parser.parse_args()
    pack([args.rk0, args.rk1, args.rk2], args.output)


if __name__ == "__main__":
    main()
