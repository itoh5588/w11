#!/usr/bin/env python3
"""Check RL01/RL02 sector expansion and fixed drive offsets."""

import tempfile
import unittest
from pathlib import Path

from pack_rl_sd import IMAGE_BYTES, RL02_SECTORS, pack, parse_unit


class PackRLSDTest(unittest.TestCase):
    def test_layout_and_existing_output(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            rl0 = directory / "rl0.dsk"
            rl1 = directory / "rl1.dsk"
            output = directory / "card.img"
            rl0.write_bytes(b"A" * 256 + b"B" * 256)
            rl1.write_bytes(b"C" * 256)

            pack([(0, "RL01", rl0), (1, "RL02", rl1)], output)
            self.assertEqual(output.stat().st_size, IMAGE_BYTES)
            with output.open("rb") as image:
                self.assertEqual(image.read(512), b"A" * 256 + bytes(256))
                self.assertEqual(image.read(512), b"B" * 256 + bytes(256))
                image.seek(RL02_SECTORS * 512)
                self.assertEqual(image.read(512), b"C" * 256 + bytes(256))
                image.seek(2 * RL02_SECTORS * 512)
                self.assertEqual(image.read(512), bytes(512))

            with self.assertRaises(FileExistsError):
                pack([(0, "RL01", rl0)], output)
            self.assertEqual(output.stat().st_size, IMAGE_BYTES)

    def test_reject_invalid_unit_and_size(self):
        with self.assertRaises(ValueError):
            parse_unit("4:RL02:bad.dsk")
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            invalid = directory / "invalid.dsk"
            invalid.write_bytes(b"x" * 255)
            with self.assertRaises(ValueError):
                pack([(0, "RL01", invalid)], directory / "card.img")
            self.assertFalse((directory / "card.img").exists())


if __name__ == "__main__":
    unittest.main()
