#!/usr/bin/env python3
"""Validate staged macOS and rootful iOS assets before publishing a release."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile


def check_bundle(data, version):
    info = plistlib.loads(data)
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info.get(key) != version:
            raise SystemExit(f"{key} does not match {version}")


def validate(version, dist):
    mac = dist / f"Retro-Cloud-Sync-{version}-macOS.zip"
    with zipfile.ZipFile(mac) as archive:
        required = {
            "rCloud.app/Contents/Info.plist",
            "rCloud.app/Contents/MacOS/rCloud",
            "rCloud.app/Contents/Library/LaunchServices/rcloudd",
        }
        missing = required - set(archive.namelist())
        if missing:
            raise SystemExit("Missing app files: " + ", ".join(sorted(missing)))
        if archive.testzip() is not None:
            raise SystemExit("Corrupt macOS ZIP")
        check_bundle(archive.read("rCloud.app/Contents/Info.plist"), version)

    deb = dist / f"Retro-Cloud-Sync-{version}-iOS-rootful.deb"
    package_version = subprocess.check_output(
        ["dpkg-deb", "--field", str(deb), "Version"], text=True
    ).strip()
    if package_version != version:
        raise SystemExit(f"Debian package version does not match {version}")
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(["dpkg-deb", "--extract", str(deb), directory], check=True)
        root = pathlib.Path(directory)
        bundle = root / "Applications/rCloud.app"
        check_bundle((bundle / "Info.plist").read_bytes(), version)
        executable = bundle / "rCloud"
        if not executable.is_file() or executable.stat().st_size == 0:
            raise SystemExit("Missing iOS GUI/daemon executable")
        launch = plistlib.loads(
            (root / "Library/LaunchDaemons/com.altivecintelligence.rcloudd.plist").read_bytes()
        )
        if launch.get("ProgramArguments") != ["/Applications/rCloud.app/rCloud", "--daemon"]:
            raise SystemExit("iOS daemon does not use the versioned app executable")
    print(f"macOS and iOS release assets match {version}")


if __name__ == "__main__":
    validate(sys.argv[1], pathlib.Path(sys.argv[2]))
