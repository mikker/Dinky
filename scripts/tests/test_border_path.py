"""Execute the actual CoreGraphics border path used by the app (macOS only)."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires macOS CoreGraphics")
class NativeBorderPathTests(unittest.TestCase):
    def test_native_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "border-path-test"
            compiled = subprocess.run([
                "xcrun", "clang", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "Sources/DinkyPrivate"),
                str(Path(__file__).with_name("border_path_test.m")),
                "-framework", "CoreGraphics", "-framework", "Foundation", "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
