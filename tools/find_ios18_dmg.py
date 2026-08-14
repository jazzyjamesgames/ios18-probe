#!/usr/bin/env python3
"""Resolve the disk-image UUID for the iOS 18.1 Simulator RuntimeRoot from
CoreSimulator's Images/images.plist. Prints the UUID on success (no
trailing newline noise), prints nothing on failure -- the caller checks
for an empty result."""
import plistlib

with open("/Library/Developer/CoreSimulator/Images/images.plist", "rb") as f:
    d = plistlib.load(f)

images = d.get("images", d) if isinstance(d, dict) else d
entries = images.values() if isinstance(images, dict) else images

for entry in entries:
    if not isinstance(entry, dict):
        continue
    text = str(entry)
    if ("iOS" in text and "18.1" in text) or "iOS-18-1" in text:
        uuid = entry.get("imageUUID") or entry.get("UUID") or entry.get("id")
        if uuid:
            print(uuid)
            break
