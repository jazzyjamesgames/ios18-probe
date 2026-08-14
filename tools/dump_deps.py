#!/usr/bin/env python3
"""Dump every dependency-representing load command from a Mach-O.

Originally only handled LC_LOAD_DYLIB/LC_LOAD_WEAK_DYLIB/LC_RPATH -- missed
LC_REEXPORT_DYLIB and LC_LOAD_UPWARD_DYLIB entirely, which is exactly how
CoreSimulator's real dependency on CoreSimDeviceIO went undetected through
the whole earlier symbol-recon and patching pass. Found out the hard way,
from a real dlopen() failure on device, not from static analysis -- fixing
the tool now that we know the gap exists.
"""
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000
LC_REEXPORT_DYLIB = 0x1F | 0x80000000
LC_LOAD_UPWARD_DYLIB = 0x23 | 0x80000000
LC_RPATH = 0x1C | 0x80000000
LC_REQ_DYLD = 0x80000000

KINDS = {
    LC_LOAD_DYLIB: "LOAD_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "REEXPORT_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LOAD_UPWARD_DYLIB",
    LC_RPATH: "RPATH",
}


def main(path):
    with open(path, "rb") as f:
        data = f.read()
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd in KINDS:
            name_off = struct.unpack_from("<I", data, offset + 8)[0]
            raw = data[offset + name_off: offset + cmdsize]
            name = raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
            print(f"{KINDS[cmd]:18s} {name}")
        offset += cmdsize


if __name__ == "__main__":
    main(sys.argv[1])
