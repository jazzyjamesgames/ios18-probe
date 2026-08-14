#!/usr/bin/env python3
"""Resolve the actual disk-image path for the iOS 18.1 Simulator RuntimeRoot
from CoreSimulator's Images/images.plist. Prints the filesystem path on
success, prints nothing on failure -- the caller checks for an empty result.

Schema (confirmed by dumping the real file): top-level dict with an
"images" key holding a *list* of dicts, each with a "runtimeInfo" dict
whose "bundleIdentifier" is e.g. "com.apple.CoreSimulator.SimRuntime.iOS-18-1",
and a "path" dict whose "relative" value is a file:// URL. Some entries
(older runtimes) point at flat files directly under Images/<uuid>.dmg;
others (this one, apparently) use Apple's newer Cryptex packaging, with a
completely different path shape -- so read the real path out of the entry
rather than assuming the flat-file convention.
"""
import plistlib
import urllib.parse

with open("/Library/Developer/CoreSimulator/Images/images.plist", "rb") as f:
    d = plistlib.load(f)

for entry in d.get("images", []):
    if not isinstance(entry, dict):
        continue
    bundle_id = entry.get("runtimeInfo", {}).get("bundleIdentifier", "")
    if bundle_id == "com.apple.CoreSimulator.SimRuntime.iOS-18-1":
        rel = entry.get("path", {}).get("relative", "")
        if rel.startswith("file://"):
            path = urllib.parse.unquote(rel[len("file://"):])
            print(path)
            break
