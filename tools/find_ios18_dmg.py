#!/usr/bin/env python3
"""Resolve the disk-image UUID for the iOS 18.1 Simulator RuntimeRoot from
CoreSimulator's Images/images.plist. Prints the UUID on success (no
trailing newline noise), prints nothing on failure -- the caller checks
for an empty result.

Schema (confirmed by dumping the real file): top-level dict with an
"images" key holding a *list* of dicts, each with a "uuid" key (lowercase)
and a "runtimeInfo" dict whose "bundleIdentifier" is e.g.
"com.apple.CoreSimulator.SimRuntime.iOS-18-1".
"""
import plistlib

with open("/Library/Developer/CoreSimulator/Images/images.plist", "rb") as f:
    d = plistlib.load(f)

for entry in d.get("images", []):
    if not isinstance(entry, dict):
        continue
    bundle_id = entry.get("runtimeInfo", {}).get("bundleIdentifier", "")
    if bundle_id == "com.apple.CoreSimulator.SimRuntime.iOS-18-1":
        uuid = entry.get("uuid")
        if uuid:
            print(uuid)
            break
