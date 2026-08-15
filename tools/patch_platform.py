#!/usr/bin/env python3
"""Flip a thin Mach-O's LC_BUILD_VERSION platform from macOS to iOS.

The minimal, generic form of what patch_coresimulator.py does as part of its
larger job. Needed now because boot reached
-[SimDeviceIOServer loadAllBundlesWithError:], which loads six
*.simdeviceio plugin bundles (framebuffer, HID, audio, rendering) out of
CoreSimulator.framework/Resources -- and every one of those carries a macOS
binary that dyld would refuse on iOS for exactly the reason the unpatched
CoreSimulator did: "(have 'macOS', need 'iOS')".

Only the platform field is touched. Dependency paths are left alone
deliberately: which of their dependencies actually resolve on iOS is the next
thing to learn, and rewriting paths blind would hide that.
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_REQ_DYLD = 0x80000000
PLATFORM_MACOS = 1
PLATFORM_IOS = 2


def patch(data: bytearray) -> tuple:
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (0xFEEDFACF, 0xCFFAEDFE):
        raise SystemExit(f"not a thin 64-bit Mach-O (magic {magic:#x}) -- lipo it first")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    flipped = 0
    seen = []

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base = cmd & ~LC_REQ_DYLD
        if base == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", data, offset + 8)[0]
            seen.append(platform)
            if platform == PLATFORM_MACOS:
                struct.pack_into("<I", data, offset + 8, PLATFORM_IOS)
                flipped += 1
        elif base == LC_VERSION_MIN_MACOSX:
            # Older binaries use LC_VERSION_MIN_MACOSX instead of
            # LC_BUILD_VERSION. There's no platform field to flip, so report
            # it rather than silently doing nothing.
            seen.append("LC_VERSION_MIN_MACOSX")
        offset += cmdsize

    return flipped, seen


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = bytearray(f.read())
    flipped, seen = patch(data)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"{src}: {flipped} platform field(s) macOS->iOS (found: {seen})")


if __name__ == "__main__":
    main()
