import tempfile
import unittest
from pathlib import Path

from pack_sd import IMAGE_BYTES, SECTOR_BYTES, SECTORS_PER_UNIT, UNIT_BYTES, pack


class PackSDTests(unittest.TestCase):
    def test_unit_offsets_padding_and_input_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = [root / f"rk{i}.dsk" for i in range(3)]
            payloads = [bytes([i + 1]) * (i + 1) * SECTOR_BYTES for i in range(3)]
            for path, payload in zip(inputs, payloads):
                path.write_bytes(payload)

            output = root / "card.img"
            pack(inputs, output)
            self.assertEqual(output.stat().st_size, IMAGE_BYTES)
            with output.open("rb") as card:
                for unit, payload in enumerate(payloads):
                    card.seek(unit * SECTORS_PER_UNIT * SECTOR_BYTES)
                    self.assertEqual(card.read(len(payload)), payload)
                    self.assertEqual(card.read(SECTOR_BYTES), bytes(SECTOR_BYTES))
                    card.seek((unit + 1) * UNIT_BYTES - SECTOR_BYTES)
                    self.assertEqual(card.read(SECTOR_BYTES), bytes(SECTOR_BYTES))
            for path, payload in zip(inputs, payloads):
                self.assertEqual(path.read_bytes(), payload)

    def test_rejects_existing_output_and_unaligned_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = [root / f"rk{i}.dsk" for i in range(3)]
            for path in inputs:
                path.write_bytes(bytes(SECTOR_BYTES))
            output = root / "card.img"
            output.write_bytes(b"keep")
            with self.assertRaises(FileExistsError):
                pack(inputs, output)
            self.assertEqual(output.read_bytes(), b"keep")
            output.unlink()
            inputs[1].write_bytes(b"bad")
            with self.assertRaises(ValueError):
                pack(inputs, output)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
