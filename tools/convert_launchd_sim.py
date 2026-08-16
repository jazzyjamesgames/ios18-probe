#!/usr/bin/env python3
"""Convert a simulator launchd_sim into a loadable iOS dylib, offline.

The on-device experiment settled how far a runtime conversion can go: with JIT
(CS_DEBUGGED) the ad-hoc-signed dylib is READ by dyld and then refused with
EPERM, because the process runs under library validation (CS_REQUIRE_LV) and an
ad-hoc signature names no team. A control -- one of our own app-team-signed
dylibs, copied into the same directory -- loaded without complaint. Identity is
the whole difference.

SideStore signs everything inside the app bundle with the app's team
certificate on install. So the move is to do the Mach-O surgery here, ship the
result in Frameworks/, and let SideStore's signature satisfy library
validation. No ad-hoc signing here on purpose: codesign/SideStore adds the real
one, and it must sign the final bytes.

The edits match what the probe did at runtime, minus the signature:
  - select the arm64 slice from the fat binary
  - MH_EXECUTE -> MH_DYLIB
  - LC_BUILD_VERSION platform 7 (iOS Simulator) -> 2 (iOS)
  - LC_LOAD_DYLINKER -> LC_ID_DYLIB (a dylib must name itself; an executable's
    dynamic-linker command is dead weight in a dylib and the right size)
  - drop any existing LC_CODE_SIGNATURE, fixing ncmds/sizeofcmds, so codesign
    starts clean
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_ARM64 = 0x0100000C

LC_REQ_DYLD = 0x80000000
LC_ID_DYLIB = 0xD
LC_LOAD_DYLINKER = 0xE
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32

MH_EXECUTE = 2
MH_DYLIB = 6

PLATFORM_IOS = 2
PLATFORM_IOS_SIM = 7


def thin(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return data
    is64 = magic == FAT_MAGIC_64
    narch = struct.unpack(">I", data[4:8])[0]
    entry = 8
    for _ in range(narch):
        if is64:
            cputype, _sub, off, size, _align = struct.unpack(
                ">IIQQI", data[entry:entry + 28])
            entry += 32
        else:
            cputype, _sub, off, size, _align = struct.unpack(
                ">IIIII", data[entry:entry + 20])
            entry += 20
        if cputype == CPU_ARM64:
            return data[off:off + size]
    raise SystemExit("no arm64 slice in fat binary")


def convert(slice_bytes):
    data = bytearray(slice_bytes)
    magic, _cpu, _sub, filetype, ncmds, sizeofcmds, _flags, _res = \
        struct.unpack_from("<IIIIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit("arm64 slice is not a 64-bit Mach-O (0x%08x)" % magic)

    if filetype == MH_EXECUTE:
        struct.pack_into("<I", data, 12, MH_DYLIB)

    # Pass 1: platform, and repurpose LC_LOAD_DYLINKER into LC_ID_DYLIB.
    off = 32
    made_id = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        base = cmd & ~LC_REQ_DYLD
        if base == LC_BUILD_VERSION:
            plat = struct.unpack_from("<I", data, off + 8)[0]
            if plat == PLATFORM_IOS_SIM:
                struct.pack_into("<I", data, off + 8, PLATFORM_IOS)
        elif base == LC_LOAD_DYLINKER and not made_id and cmdsize >= 32:
            name = b"launchd_sim\x00"
            struct.pack_into("<II", data, off, LC_ID_DYLIB, cmdsize)
            struct.pack_into("<I", data, off + 8, 24)          # name offset
            struct.pack_into("<I", data, off + 12, 1)          # timestamp
            struct.pack_into("<I", data, off + 16, 0x00010000)  # current
            struct.pack_into("<I", data, off + 20, 0x00010000)  # compat
            for i in range(24, cmdsize):
                data[off + i] = 0
            data[off + 24:off + 24 + len(name)] = name
            made_id = True
        off += cmdsize
    if not made_id:
        raise SystemExit("no LC_LOAD_DYLINKER to convert into LC_ID_DYLIB")

    # Pass 2: strip LC_CODE_SIGNATURE cleanly, so ldid (SideStore's signer) can
    # add a fresh one. The first version only removed the load command; it left
    # the stale signature bytes in the file and left __LINKEDIT's filesize still
    # covering them. That inconsistency crashed ldid:
    #
    #   ldid.cpp(1461): _assert(): end >= size - 0x10
    #
    # A properly unsigned binary has __LINKEDIT ending exactly at its real
    # symbol/string content, with the file ending there too. The signature is
    # always the last thing in the file, so removing it means: shrink
    # __LINKEDIT to end where the signature began, drop the load command, fix
    # the header counts, and truncate the file to the signature's old offset.
    linkedit_off = None
    sig_cmd_off = sig_cmdsize = sig_dataoff = None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        base = cmd & ~LC_REQ_DYLD
        if base == 0x19:  # LC_SEGMENT_64
            segname = data[off + 8:off + 24].split(b"\x00")[0]
            if segname == b"__LINKEDIT":
                linkedit_off = off
        elif base == LC_CODE_SIGNATURE:
            sig_cmd_off, sig_cmdsize = off, cmdsize
            sig_dataoff = struct.unpack_from("<I", data, off + 8)[0]
        off += cmdsize

    if sig_dataoff is not None:
        if linkedit_off is not None:
            le_fileoff = struct.unpack_from("<Q", data, linkedit_off + 40)[0]
            new_filesize = sig_dataoff - le_fileoff
            struct.pack_into("<Q", data, linkedit_off + 48, new_filesize)
            vmsize = (new_filesize + 0x3FFF) & ~0x3FFF
            struct.pack_into("<Q", data, linkedit_off + 32, vmsize)

        tail_start = sig_cmd_off + sig_cmdsize
        tail_end = 32 + sizeofcmds
        data[sig_cmd_off:tail_end - sig_cmdsize] = data[tail_start:tail_end]
        for i in range(tail_end - sig_cmdsize, tail_end):
            data[i] = 0
        struct.pack_into("<I", data, 16, ncmds - 1)
        struct.pack_into("<I", data, 20, sizeofcmds - sig_cmdsize)

        # Truncate the signature blob off the end. Guard against it not being
        # last (it always is for Apple binaries, but a bad assumption here
        # would silently corrupt the file).
        if sig_dataoff <= len(data):
            data = data[:sig_dataoff]

    return bytes(data)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    out = convert(thin(data))
    open(dst, "wb").write(out)
    print("%s -> %s (%d bytes, arm64 iOS dylib, unsigned)" % (src, dst, len(out)))


if __name__ == "__main__":
    main()
