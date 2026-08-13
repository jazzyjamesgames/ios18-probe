#!/usr/bin/env python3
"""
Turns a normal iOS executable (MH_EXECUTE) into something dlopen() will
accept as a library (MH_DYLIB), and neutralizes __PAGEZERO, which only
makes sense for a binary that owns the process from process start -- not
one being mapped into an already-running process via dlopen.

This is a best-effort first pass based on public knowledge of the Mach-O
format and publicly documented behavior of similar tools (e.g. LiveContainer).
It has NOT been run against a real device -- there was no Mac available to
test it. Two known open questions if dlopen() fails outright (as opposed to
failing on a *missing symbol*, which is the good/expected outcome):

  1. This does not add an LC_ID_DYLIB load command. Real dylibs normally
     have one; this patch leaves whatever load commands the executable
     already had (LC_MAIN / LC_UNIXTHREAD etc. included). If dyld refuses
     to load the file at all citing something other than a missing symbol,
     this is the first thing to add -- report back the exact dlerror() text.
  2. Only 64-bit (arm64) single-architecture Mach-O input is handled. If the
     compiler ever emits a fat/universal binary, this script will not find
     a mach_header_64 at offset 0 and will refuse to patch it.

Usage: patch_macho.py <input-executable> <output-dylib>
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
LC_SEGMENT_64 = 0x19
LC_REQ_DYLD = 0x80000000


def patch(data: bytearray) -> bytearray:
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(
            f"Expected a 64-bit Mach-O (magic {MH_MAGIC_64:#x}), got {magic:#x}. "
            "Is this a fat/universal binary? This script only handles a single "
            "arm64 slice -- extract it first with `lipo -thin arm64`."
        )

    filetype = struct.unpack_from("<I", data, 12)[0]
    if filetype != MH_EXECUTE:
        print(f"note: filetype was already {filetype:#x}, not MH_EXECUTE -- patching anyway")
    struct.pack_into("<I", data, 12, MH_DYLIB)

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32  # end of mach_header_64
    patched_pagezero = False

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base_cmd = cmd & ~LC_REQ_DYLD
        if base_cmd == LC_SEGMENT_64:
            segname = data[offset + 8: offset + 24].rstrip(b"\x00")
            if segname == b"__PAGEZERO":
                vmsize_off = offset + 32  # cmd,cmdsize(8) + segname(16) + vmaddr(8)
                struct.pack_into("<Q", data, vmsize_off, 0)
                patched_pagezero = True
        offset += cmdsize

    if not patched_pagezero:
        print("note: no __PAGEZERO segment found -- nothing to neutralize there")

    return data


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = bytearray(f.read())
    data = patch(data)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"wrote {dst}: filetype -> MH_DYLIB, __PAGEZERO neutralized (if present)")


if __name__ == "__main__":
    main()
