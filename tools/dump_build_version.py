#!/usr/bin/env python3
"""Print a Mach-O's LC_BUILD_VERSION platform/minos/sdk fields."""
import struct
import sys

LC_BUILD_VERSION = 0x32


def main(path):
    with open(path, "rb") as f:
        data = f.read()
    ncmds, _sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if (cmd & ~0x80000000) == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", data, offset + 8)
            print(f"platform={platform} "
                  f"minos={minos >> 16}.{(minos >> 8) & 0xff}.{minos & 0xff} "
                  f"sdk={sdk >> 16}.{(sdk >> 8) & 0xff}.{sdk & 0xff}")
        offset += cmdsize


if __name__ == "__main__":
    main(sys.argv[1])
