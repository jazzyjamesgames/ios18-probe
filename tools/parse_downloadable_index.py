#!/usr/bin/env python3
"""Extract iOS simulator-runtime entries from Apple's dvtdownloadableindex.

Kept as a standalone script rather than an inline heredoc in the workflow:
a heredoc body sits at column 0, which terminates the YAML `run: |` literal
block early and silently corrupts the whole workflow file (GitHub then can't
read even the `name:` field). Same reason dump_images_plist.py exists.
"""
import plistlib
import sys


def main(path):
    with open(path, "rb") as f:
        data = plistlib.load(f)

    if isinstance(data, dict) and "downloadables" in data:
        downloadables = data["downloadables"]
    elif isinstance(data, list):
        downloadables = data
    else:
        downloadables = []

    for item in downloadables:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", ""))
        ident = str(item.get("identifier", ""))
        if "iOS" not in name and "iOS" not in ident:
            continue
        src = item.get("source", "")
        ver = item.get("version", "")
        size = item.get("fileSize", item.get("contentSize", ""))
        print(f"{name} | {ident} | ver={ver} | size={size}")
        print(f"   {src}")


if __name__ == "__main__":
    main(sys.argv[1])
