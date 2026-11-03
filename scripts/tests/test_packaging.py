"""Isolated packaging regressions: no Swift builds, signing keys, network, or installed app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
BINARIES = [
    "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
    "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "XPCServices/Installer.xpc/Contents/MacOS/Installer",
]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open("commands.jsonl", "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "swift":
    universal = args.count("--arch") == 2
    path = pathlib.Path(".build/out/universal" if universal else ".build/native")
    if "--show-bin-path" in args:
        print(path.resolve())
    else:
        path.mkdir(parents=True, exist_ok=True)
        (path / "dinky").write_text("arm64 x86_64" if universal else "arm64")
elif name == "lipo":
    if args[0] == "-archs":
        archs = pathlib.Path(args[1]).read_text().split()
        print(" ".join(archs))
    else:
        assert len(args) == 3 and args[1] == "-verify_arch", args
        archs = pathlib.Path(args[0]).read_text().split()
        sys.exit(0 if args[2] in archs else 1)
elif name == "plutil":
    import plistlib
    path = pathlib.Path(args[-1])
    info = plistlib.loads(path.read_bytes())
    info[args[1]] = args[3]
    path.write_bytes(plistlib.dumps(info))
elif name == "xcrun":
    if args[0] == "actool":
        out = pathlib.Path(args[args.index("--compile") + 1])
        for filename in ["Assets.car", "Dinky.icns"]:
            (out / filename).touch()
    elif args[0] not in ["notarytool", "stapler"]:
        sys.exit(2)
elif name == "ditto":
    if args[0] == "-c":
        source, target = map(pathlib.Path, args[-2:])
        with zipfile.ZipFile(target, "w") as archive:
            for path in source.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(source.parent))
    elif args[0] == "-x":
        with zipfile.ZipFile(args[-2]) as archive:
            archive.extractall(args[-1])
        if os.environ.get("THIN_ARCHIVE"):
            (pathlib.Path(args[-1]) / "dinky.app/Contents/MacOS/dinky").write_text("arm64")
    else:
        shutil.copytree(args[0], args[1])
elif name == "git":
    print("123")
elif name == "sign_update":
    print("A" * 86 + "==")
elif name not in ["codesign", "spctl"]:
    sys.exit("Unexpected command: " + name)
'''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dinky-packaging-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        (self.root / "Resources/Dinky.icon").mkdir(parents=True)
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
        }))
        (self.root / "CHANGELOG.md").write_text("# Changelog\n")
        self.framework = self.root / ".build/artifacts/sparkle/Sparkle/macos-arm64_x86_64/Sparkle.framework/Versions/Current"
        for binary in BINARIES:
            path = self.framework / binary
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("arm64 x86_64")
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        for name in ["swift", "lipo", "plutil", "xcrun", "ditto", "codesign", "spctl", "git"]:
            path = mock_bin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        signer = self.root / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        signer.parent.mkdir(parents=True)
        signer.write_text(MOCK)
        signer.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{mock_bin}:{os.environ['PATH']}",
                    "DEVELOPER_ID_APPLICATION": "Test identity", "VERSION": "0.24"}

    def run_script(self, script, *args):
        return subprocess.run(["bash", f"scripts/{script}", *args], cwd=self.root,
                              env=self.env, text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]

    def test_release_uses_matching_universal_build_and_lookup_flags(self):
        result = self.run_script("bundle.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [cmd for cmd in self.commands() if cmd[0] == "swift"]
        self.assertEqual(builds, [
            ["swift", "build", "-c", "release", "--jobs", "4", "--arch", "arm64", "--arch", "x86_64"],
            ["swift", "build", "-c", "release", "--jobs", "4", "--arch", "arm64", "--arch", "x86_64", "--show-bin-path"],
        ])
        self.assertEqual(len([c for c in self.commands() if c[0] == "lipo"]), 12)

    def test_debug_stays_native(self):
        result = self.run_script("bundle.sh", "--debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [cmd for cmd in self.commands() if cmd[0] == "swift"]
        self.assertTrue(all("--arch" not in cmd and "debug" in cmd for cmd in builds))
        self.assertFalse(any(cmd[0] == "lipo" for cmd in self.commands()))

    def test_every_thin_or_missing_sparkle_binary_fails_before_signing(self):
        for binary in BINARIES:
            path = self.framework / binary
            for missing in [False, True]:
                with self.subTest(binary=binary, missing=missing):
                    if missing:
                        path.unlink()
                    else:
                        path.write_text("arm64")
                    (self.root / "commands.jsonl").write_text("")
                    result = self.run_script("bundle.sh")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(any(cmd[0] == "codesign" for cmd in self.commands()))
                    path.write_text("arm64 x86_64")

    def test_validator_rejects_thin_main_executable(self):
        app = self.root / "thin.app/Contents/MacOS"
        app.mkdir(parents=True)
        shutil.copytree(self.framework, app.parent / "Frameworks/Sparkle.framework/Versions/Current")
        (app / "dinky").write_text("arm64 x86_64")
        result = self.run_script("check-universal.sh", str(app.parent.parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        for archs in ["arm64", "x86_64"]:
            with self.subTest(archs=archs):
                (app / "dinky").write_text(archs)
                self.assertNotEqual(self.run_script("check-universal.sh", str(app.parent.parent)).returncode, 0)

    def test_package_checks_archive_before_unrestricted_cask(self):
        result = self.run_script("package-release.sh", "0.24")
        self.assertEqual(result.returncode, 0, result.stderr)
        cask = (self.root / "dist/dinky.rb").read_text()
        self.assertNotIn("depends_on arch:", cask)
        self.assertNotIn("@VERSION@", cask)
        commands = self.commands()
        self.assertEqual(len([c for c in commands if c[0] == "lipo" and "-verify_arch" in c]), 36)
        self.assertIn(["codesign", "--verify", "--strict", "--verbose=1", "build/dinky.app"], commands)
        self.assertTrue(any(c[:2] == ["xcrun", "notarytool"] for c in commands))
        self.assertTrue(any(c[:2] == ["xcrun", "stapler"] for c in commands))
        self.assertTrue(any(c[0] == "spctl" for c in commands))
        self.assertFalse(any("hardwareRequirements" in e.tag for e in ET.parse(self.root / "dist/appcast.xml").iter()))

    def test_thin_archive_fails_before_sparkle_signing_and_cask(self):
        self.env["THIN_ARCHIVE"] = "1"
        result = self.run_script("package-release.sh", "0.24")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dist/dinky.rb").exists())
        self.assertFalse(any(c[0] == "sign_update" for c in self.commands()))

    def test_appcast_keeps_architecture_safeguard(self):
        app = self.root / "build/dinky.app/Contents/MacOS"
        app.mkdir(parents=True)
        shutil.copy(self.root / "Resources/Info.plist", app.parent / "Info.plist")
        dist = self.root / "dist"
        dist.mkdir()
        (dist / "dinky.app.zip").write_bytes(b"archive")
        (dist / "signature.txt").write_text("A" * 86 + "==")
        for archs, expected in [("arm64", "arm64"), ("arm64 x86_64", None), ("x86_64", None)]:
            with self.subTest(archs=archs):
                (app / "dinky").write_text(archs)
                result = subprocess.run(["python3", "scripts/appcast.py", "0.0"],
                                        cwd=self.root, env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                requirement = ET.parse(dist / "appcast.xml").findtext(
                    ".//{http://www.andymatuschak.org/xml-namespaces/sparkle}hardwareRequirements")
                self.assertEqual(requirement, expected)


if __name__ == "__main__":
    unittest.main()
