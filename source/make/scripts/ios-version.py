#!/usr/bin/env python3
"""Stamp or validate the iOS bundle against the existing Mac release source."""
import pathlib
import plistlib
import re
import sys

source = pathlib.Path(sys.argv[1])
with (source / "macOS-app/Resources/Info.plist").open("rb") as stream:
    release = plistlib.load(stream)
version = release["CFBundleShortVersionString"]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or release["CFBundleVersion"] != version:
    raise SystemExit("Inconsistent release version")
target = pathlib.Path(sys.argv[2])
with target.open("rb") as stream:
    info = plistlib.load(stream)
if "--stamp" in sys.argv[3:]:
    info["CFBundleShortVersionString"] = info["CFBundleVersion"] = version
    if "--ui-tests" in sys.argv[3:]:
        info["CFBundleIdentifier"] = "com.altivecintelligence.rcloud.ui-tests"
        info["CFBundleDisplayName"] = "rCloud Tests"
        info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["rcloud-ui-tests"]}]
    with target.open("wb") as stream:
        plistlib.dump(info, stream)
elif any(info.get(key) != version for key in ("CFBundleVersion", "CFBundleShortVersionString")):
    raise SystemExit("iOS bundle and release versions do not match; rebuild ios-release")
print(version)
