#!/usr/bin/env python3
"""Check the w11 card label layout and the shifted disk data."""

import tempfile
import unittest
from pathlib import Path

from sd_label import BLOCK, make_label, parse_label, write_card


class SDLabelTest(unittest.TestCase):
    def test_label_words(self):
        label = make_label("rl", 2048, 0b0001, 0b0011)
        self.assertEqual(len(label), BLOCK)
        # the words the FPGA compares: "W11SDLBL", version 1, type 3
        self.assertEqual(label[:12], bytes.fromhex("5731315344 4c424c 0100 0300"))
        self.assertEqual(label[12:20], bytes.fromhex("00080000 0100 0300"))
        self.assertEqual(label[20:], bytes(BLOCK - 20))
        self.assertEqual(parse_label(label), {"type": "rl", "base": 2048,
                                              "rl02_mask": 1, "present_mask": 3})
        self.assertEqual(parse_label(make_label("rk05", 1))["type"], "rk05")
        self.assertEqual(make_label("rk05", 1, 3, 3)[16:20], bytes(4))
        self.assertIsNone(parse_label(bytes(BLOCK)))
        with self.assertRaises(ValueError):
            make_label("rk05", 0)

    def test_card_layout(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            disk = directory / "rk.img"
            card = directory / "card.img"
            disk.write_bytes(b"A" * BLOCK + b"B" * BLOCK)
            write_card(disk, card, make_label("rk05", 4), 4)
            data = card.read_bytes()
            self.assertEqual(len(data), 6 * BLOCK)
            self.assertEqual(parse_label(data[:BLOCK])["base"], 4)
            self.assertEqual(data[BLOCK:4 * BLOCK], bytes(3 * BLOCK))
            self.assertEqual(data[4 * BLOCK:], b"A" * BLOCK + b"B" * BLOCK)
            with self.assertRaises(FileExistsError):
                write_card(disk, card, make_label("rk05", 4), 4)
            relabel = directory / "again.img"
            with self.assertRaises(ValueError):
                write_card(card, relabel, make_label("rk05", 4), 4)
            self.assertFalse(relabel.exists())


if __name__ == "__main__":
    unittest.main()
