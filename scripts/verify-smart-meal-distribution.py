#!/usr/bin/env python3
"""Verify the exported receiver build before TestFlight upload; no network or credentials."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

TEAM = "D3GG62L9X8"
BUNDLE = "org.nightscout." + TEAM + ".trio"
GROUP = "group." + BUNDLE + ".trio-app-group"


def require(value, message):
    if not value:
        raise ValueError(message)


def verify(app, source):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == BUNDLE, "Unexpected app identity")
    require(info["CFBundleShortVersionString"] == "1.0.2", "Unexpected app version")
    details = plistlib.loads((app / "BuildDetails.plist").read_bytes())
    recorded = details.get("com-trio-commit-sha", "")
    require(len(recorded) >= 7 and source.startswith(recorded), "Archive source does not match requested commit")
    entitlements = plistlib.loads(subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True
    ).stdout)
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM, "Unexpected signing team")
    require(entitlements.get("application-identifier") == TEAM + "." + BUNDLE, "Unexpected application identifier")
    require(GROUP in entitlements.get("com.apple.security.application-groups", []), "Missing original App Group")
    require(entitlements.get("aps-environment") == "production", "Distribution requires production push signing")
    require(entitlements.get("get-task-allow") is False, "A debug build cannot be uploaded")
    profile = plistlib.loads(subprocess.run(
        ["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")], check=True, capture_output=True
    ).stdout)
    require(TEAM in profile.get("TeamIdentifier", []), "Unexpected provisioning team")
    require(not profile.get("ProvisionedDevices"), "A device-limited profile is not App Store distribution")
    require(profile["Entitlements"].get("beta-reports-active") is True, "Missing TestFlight distribution entitlement")
    return {"bundleID": BUNDLE, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "sourceCommit": source, "embeddedSource": recorded, "appGroup": GROUP,
            "signatureVerified": True, "pushEnvironment": "production", "debuggable": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(len(args.source) == 40 and all(c in "0123456789abcdef" for c in args.source), "Expected full source SHA")
    with tempfile.TemporaryDirectory(prefix="verify-trio-distribution-") as directory:
        with zipfile.ZipFile(args.ipa) as archive:
            require(all(not Path(n).is_absolute() and ".." not in Path(n).parts for n in archive.namelist()), "Invalid archive path")
        subprocess.run(["ditto", "-x", "-k", str(args.ipa), directory], check=True, capture_output=True)
        apps = list((Path(directory) / "Payload").glob("*.app"))
        require(len(apps) == 1, "Expected one iOS app in archive")
        result = verify(apps[0], args.source)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
