#!/usr/bin/env python3
"""Diagnostic dump of CoreSimulator's Images/images.plist structure."""
import json
import plistlib

with open("/Library/Developer/CoreSimulator/Images/images.plist", "rb") as f:
    d = plistlib.load(f)

print(type(d))
if isinstance(d, dict):
    print("top-level keys:", list(d.keys()))
    print(json.dumps(d, indent=2, default=str)[:4000])
