#!/usr/bin/env python3
"""Pack up to four raw RL01/RL02 images for the native RL11 microSD variant.

Each 256-byte RL sector is stored in its own 512-byte microSD block. Each
drive reserves an RL02-sized slot, including when the drive is RL01 or absent.
The output is always a new regular file, never a block device.
"""

import argparse
import os
import stat
from pathlib import Path


RL_SECTOR_BYTES = 256
SD_BLOCK_BYTES = 512
RL01_SECTORS = 256 * 2 * 40
RL02_SECTORS = 512 * 2 * 40
UNIT_SLOT_BYTES = RL02_SECTORS * SD_BLOCK_BYTES
IMAGE_BYTES = 4 * UNIT_SLOT_BYTES


def parse_unit(spec: str) -> tuple[int, str, Path]:
    parts = spec.split(":", 2)
    if len(parts) != 3:
        raise ValueError("unit must be N:RL01:path or N:RL02:path")
    unit = int(parts[0])
    disk_type = parts[1].upper()
    if unit not in range(4) or disk_type not in ("RL01", "RL02"):
        raise ValueError("unit number must be 0..3 and type RL01 or RL02")
    return unit, disk_type, Path(parts[2])


def pack(specs: list[tuple[int, str, Path]], output: Path) -> None:
    units = {}
    for unit, disk_type, source in specs:
        if unit in units:
            raise ValueError(f"duplicate RL unit {unit}")
        size = source.stat()
        maximum = (RL01_SECTORS if disk_type == "RL01" else RL02_SECTORS) * RL_SECTOR_BYTES
        if not stat.S_ISREG(size.st_mode):
            raise ValueError(f"input is not a regular file: {source}")
        if size.st_size == 0 or size.st_size > maximum or size.st_size % RL_SECTOR_BYTES:
            raise ValueError(f"invalid {disk_type} image size: {source}")
        units[unit] = (disk_type, source, size.st_size)

    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "wb") as target:
            zero = bytes(SD_BLOCK_BYTES)
            for unit in range(4):
                if unit in units:
                    disk_type, source, size = units[unit]
                    with source.open("rb") as image:
                        for _ in range(size // RL_SECTOR_BYTES):
                            sector = image.read(RL_SECTOR_BYTES)
                            if len(sector) != RL_SECTOR_BYTES:
                                raise RuntimeError(f"input changed while packing: {source}")
                            target.write(sector)
                            target.write(zero[:RL_SECTOR_BYTES])
                        if image.read(1):
                            raise RuntimeError(f"input changed while packing: {source}")
                    used = (size // RL_SECTOR_BYTES) * SD_BLOCK_BYTES
                    print(f"RL{unit} {disk_type}: LBA {unit * RL02_SECTORS}, "
                          f"{size // RL_SECTOR_BYTES} sectors")
                else:
                    used = 0
                remaining = UNIT_SLOT_BYTES - used
                while remaining:
                    count = min(remaining, len(zero))
                    target.write(zero[:count])
                    remaining -= count
        if output.stat().st_size != IMAGE_BYTES:
            raise RuntimeError("output size check failed")
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--unit", action="append", default=[], metavar="N:TYPE:FILE",
                        help="type is RL01 or RL02; repeat for up to four drives")
    args = parser.parse_args()
    if not args.unit:
        parser.error("at least one --unit is required")
    try:
        pack([parse_unit(spec) for spec in args.unit], args.output)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
