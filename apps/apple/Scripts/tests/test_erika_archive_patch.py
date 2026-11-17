"""Regression checks for the Mach-O repair embedded in fetch-erika.sh.

Run with: python3 -m unittest discover -s Scripts/tests
"""
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "fetch-erika.sh"
PATCHER = SCRIPT.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]


def build_version(platform, with_tool=False):
    command = struct.pack("<IIIIII", 0x32, 32 if with_tool else 24,
                          platform, 0xE0000, 0x1B0000, int(with_tool))
    return command + (struct.pack("<II", 3, 0x150000) if with_tool else b"")


def archive(body):
    name = b"fixture.o"
    payload = name + body
    header = (b"#1/" + str(len(name)).encode().ljust(13)
              + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
              + b"100644".ljust(8) + str(len(payload)).encode().ljust(10)
              + b"`\n")
    return b"!<arch>\n" + header + payload + (b"\n" if len(payload) & 1 else b"")


def object_file(commands):
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 1,
                         len(commands), sum(map(len, commands)), 0, 0)
    return header + b"".join(commands) + b"section-and-symbol-data"


class ErikaArchivePatchTests(unittest.TestCase):
    def run_patch(self, body):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "source.a"
            target = pathlib.Path(directory) / "target.a"
            original = archive(body)
            source.write_bytes(original)
            result = subprocess.run([sys.executable, "-c", PATCHER,
                                     str(source), str(target)], capture_output=True)
            self.assertEqual(source.read_bytes(), original)
            if not target.exists():
                return result, None
            output = target.read_bytes()
            name_length = int(output[8:24].decode().strip()[3:])
            size = int(output[56:66])
            return result, output[68 + name_length:68 + size]

    def test_old_and_new_catalyst_commands_preserve_data_offsets(self):
        for with_tool in (False, True):
            with self.subTest(with_tool=with_tool):
                macos = build_version(1, with_tool)
                catalyst = build_version(6, with_tool)
                # A trailing symbol command with absolute file offsets must move
                # within the command area without changing those offsets.
                data_offset = 32 + len(macos) + len(catalyst) + 24
                symtab = struct.pack("<IIIIII", 2, 24, data_offset, 1,
                                     data_offset + 8, 8)
                original = object_file([macos, catalyst, symtab])
                result, output = self.run_patch(original)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(output), len(original))
                self.assertEqual(struct.unpack_from("<I", output, 16)[0], 3)
                commands_size = len(macos) + 24 + len(symtab)
                self.assertEqual(struct.unpack_from("<I", output, 20)[0], commands_size)
                self.assertEqual(output[32:32 + len(macos)], macos)
                self.assertEqual(output[32 + len(macos):56 + len(macos)],
                                 struct.pack("<IIQQ", 0x1B, 24, 0, 0))
                self.assertEqual(output[56 + len(macos):32 + commands_size], symtab)
                self.assertEqual(output[32 + commands_size:data_offset],
                                 bytes(len(catalyst) - 24))
                self.assertEqual(output[data_offset:], original[data_offset:])

    def test_macos_only_archive_is_left_untouched(self):
        result, output = self.run_patch(object_file([build_version(1, True)]))
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(output)

    def test_malformed_command_is_rejected(self):
        original = object_file([build_version(6, True)])
        malformed = bytearray(original)
        struct.pack_into("<I", malformed, 36, len(original) + 100)
        result, output = self.run_patch(bytes(malformed))
        self.assertNotIn(result.returncode, (0, 2))
        self.assertIsNone(output)


if __name__ == "__main__":
    unittest.main()
