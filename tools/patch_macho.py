#!/usr/bin/env python3
"""
Turns a normal iOS executable (MH_EXECUTE) into something dlopen() will
accept as a library (MH_DYLIB):

  1. Flips the mach_header_64.filetype field from MH_EXECUTE to MH_DYLIB.
  2. Neutralizes __PAGEZERO's vmsize -- that segment only makes sense for a
     binary that owns the process from its start, not one being mapped into
     an already-running process via dlopen.
  3. Inserts an LC_ID_DYLIB load command. Confirmed necessary on-device:
     without it, dyld refuses with "MH_DYLIB is missing LC_ID_DYLIB" even
     though the filetype flip alone is otherwise accepted.

LC_ID_DYLIB insertion strategy: rather than shifting every subsequent byte
in the file (which would require rewriting every fileoff in every segment,
the symbol table, code signature, etc.), this writes the new load command
into the padding space that already exists between the end of the current
load commands and the first real section of __TEXT. Compilers leave that
gap because segments are page-aligned, so a small compiled binary typically
has several KB of zero padding there -- this is the same strategy tools
like `insert_dylib` use. If there isn't enough room, this refuses to write
a corrupt binary and tells you so explicitly instead.

Known remaining limitation: only 64-bit (arm64) single-architecture Mach-O
input is handled. If the compiler ever emits a fat/universal binary, this
script will not find a mach_header_64 at offset 0 and will refuse to patch it.

Usage: patch_macho.py <input-executable> <output-dylib>
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_REQ_DYLD = 0x80000000


def iter_load_commands(data: bytes, ncmds: int):
    offset = 32  # end of mach_header_64
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        yield offset, cmd & ~LC_REQ_DYLD, cmdsize
        offset += cmdsize


def neutralize_pagezero(data: bytearray, ncmds: int) -> bool:
    patched = False
    for offset, base_cmd, cmdsize in iter_load_commands(data, ncmds):
        if base_cmd == LC_SEGMENT_64:
            segname = data[offset + 8: offset + 24].rstrip(b"\x00")
            if segname == b"__PAGEZERO":
                vmsize_off = offset + 32  # cmd,cmdsize(8) + segname(16) + vmaddr(8)
                struct.pack_into("<Q", data, vmsize_off, 0)
                patched = True
    return patched


def text_padding_available(data: bytes, ncmds: int, sizeofcmds: int) -> int:
    """Bytes of unused space between end-of-load-commands and the first
    real (non-zerofill) section of __TEXT, i.e. how much room we have to
    grow the load commands in place without moving anything else."""
    min_section_offset = None
    for offset, base_cmd, cmdsize in iter_load_commands(data, ncmds):
        if base_cmd != LC_SEGMENT_64:
            continue
        segname = data[offset + 8: offset + 24].rstrip(b"\x00")
        if segname != b"__TEXT":
            continue
        nsects = struct.unpack_from("<I", data, offset + 64)[0]
        sect_base = offset + 72  # sizeof(segment_command_64)
        for i in range(nsects):
            s = sect_base + i * 80  # sizeof(section_64)
            sect_file_offset = struct.unpack_from("<I", data, s + 48)[0]
            if sect_file_offset == 0:
                continue  # zerofill section, not backed by file data
            if min_section_offset is None or sect_file_offset < min_section_offset:
                min_section_offset = sect_file_offset
    end_of_cmds = 32 + sizeofcmds
    if min_section_offset is None:
        return 0
    return min_section_offset - end_of_cmds


def build_lc_id_dylib(name: bytes = b"target.dylib") -> bytes:
    name_with_nul = name + b"\x00"
    header_size = 24  # cmd,cmdsize,name_offset,timestamp,current_version,compat_version
    total = header_size + len(name_with_nul)
    padded_size = (total + 7) // 8 * 8
    pad = padded_size - total
    return (
        struct.pack(
            "<IIIIII",
            LC_ID_DYLIB,
            padded_size,
            header_size,   # name.offset -- points past this fixed header to the string
            0,             # timestamp
            0x00010000,    # current_version: 1.0.0
            0x00010000,    # compatibility_version: 1.0.0
        )
        + name_with_nul
        + b"\x00" * pad
    )


def insert_lc_id_dylib(data: bytearray) -> bytearray:
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    new_cmd = build_lc_id_dylib()
    slack = text_padding_available(data, ncmds, sizeofcmds)
    if slack < len(new_cmd):
        raise SystemExit(
            f"Not enough header padding to insert LC_ID_DYLIB in place: "
            f"need {len(new_cmd)} bytes, have {slack}. Full load-command "
            f"relocation (rewriting every fileoff in every segment/symtab/"
            f"codesig) isn't implemented -- if this hits, the fix is either "
            f"linking the target with extra headerpad (`-Wl,-headerpad,0x200`) "
            f"or extending this script to do full relocation."
        )
    end_of_cmds = 32 + sizeofcmds
    data[end_of_cmds:end_of_cmds + len(new_cmd)] = new_cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + len(new_cmd))
    return data


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

    ncmds, _sizeofcmds = struct.unpack_from("<II", data, 16)

    # Insert LC_ID_DYLIB *before* flipping filetype, while ncmds/sizeofcmds
    # in the header still describe the original (unpatched) command list.
    data = insert_lc_id_dylib(data)

    struct.pack_into("<I", data, 12, MH_DYLIB)

    ncmds, _sizeofcmds = struct.unpack_from("<II", data, 16)
    if not neutralize_pagezero(data, ncmds):
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
    print(f"wrote {dst}: filetype -> MH_DYLIB, LC_ID_DYLIB inserted, __PAGEZERO neutralized (if present)")


if __name__ == "__main__":
    main()
