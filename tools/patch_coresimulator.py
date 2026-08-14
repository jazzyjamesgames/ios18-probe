#!/usr/bin/env python3
"""Patch CoreSimulator's real binary to attempt loading on iOS.

CoreSimulator.framework's binary is already a proper MH_DYLIB with
LC_ID_DYLIB present (confirmed via inspection) -- no MH_EXECUTE flip needed,
unlike our toy targets and Brave's Client binary.

Three kinds of changes, all in-place string overwrites (every replacement
path is shorter than the original, so no load-command resizing is needed --
same constraint, same technique as the earlier LC_ID_DYLIB insertion work,
just simpler since we're not growing anything here):

1. LC_BUILD_VERSION.platform: 1 (macOS) -> 2 (iOS). This is the exact byte
   that produced "(have 'macOS', need 'iOS')" when we tested the unpatched
   binary on device.

2. Dependencies with real iOS equivalents, just referenced via macOS's
   Versions/X/ bundle layout (confirmed by symbol recon: these are actually
   called, and the real frameworks exist on iOS under a flat path):
   Foundation, CoreFoundation, CoreGraphics, Security.

3. Dependencies with no iOS equivalent at all, redirected via @rpath/<Name>
   (an LC_RPATH pointing at @executable_path/Frameworks gets inserted) to
   our own stub dylibs: DiskArbitration, ServiceManagement, ROCKit,
   DeviceIdentity, CoreSimulatorUtilities, libxcselect, CoreServices,
   libRosetta, and SimPasteboardPlus (zero referenced symbols, but still a
   hard dependency -- the file has to exist regardless of symbol usage).

Left alone entirely:
  - AppKit, IntlPreferences, AccessibilityPlatformTranslation: weak-linked,
    a missing file is tolerated regardless of symbol usage (confirmed:
    AppKit has zero referenced symbols anyway).
  - libobjc.A.dylib, libSystem.B.dylib, libMobileGestalt.dylib,
    libDiagnosticMessagesClient.dylib: real, shared libraries assumed to
    exist at the same /usr/lib paths on iOS too -- unverified assumption,
    first real test of it is this patch actually running on device.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000
LC_BUILD_VERSION = 0x32
LC_RPATH = 0x1C | 0x80000000
LC_REQ_DYLD = 0x80000000

PLATFORM_MACOS = 1
PLATFORM_IOS = 2

# path-fix-only: real iOS framework exists, just wrong (macOS-style) path
PATH_FIXES = {
    "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation":
        "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation":
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics":
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/Frameworks/Security.framework/Versions/A/Security":
        "/System/Library/Frameworks/Security.framework/Security",
}

# redirect-to-our-own-stub: no iOS equivalent exists at all. @rpath/ used
# instead of @executable_path/Frameworks/ directly -- some of the original
# paths (the short /usr/lib/... ones especially) don't leave enough in-place
# room for the longer prefix. An LC_RPATH command pointing at
# @executable_path/Frameworks gets inserted below to make @rpath/ resolve
# there, same padding-insertion technique as the earlier LC_ID_DYLIB work.
REDIRECTS = {
    "/System/Library/Frameworks/DiskArbitration.framework/Versions/A/DiskArbitration":
        "@rpath/DiskArbitration",
    "/System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement":
        "@rpath/ServiceManagement",
    "/Library/Developer/PrivateFrameworks/ROCKit.framework/Versions/A/ROCKit":
        "@rpath/ROCKit",
    "/System/Library/PrivateFrameworks/DeviceIdentity.framework/Versions/A/DeviceIdentity":
        "@rpath/DeviceIdentity",
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Frameworks/CoreSimulatorUtilities.framework/Versions/A/CoreSimulatorUtilities":
        "@rpath/CoreSimulatorUtilities",
    "/usr/lib/libxcselect.dylib":
        "@rpath/libxcselect.dylib",
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices":
        "@rpath/CoreServices",
    "/usr/lib/libRosetta.dylib":
        "@rpath/libRosetta.dylib",
    # zero referenced symbols, but still a hard (non-weak) dependency -- the
    # file must exist and be loadable regardless of whether anything in
    # CoreSimulator actually calls into it
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Frameworks/SimPasteboardPlus.framework/Versions/A/SimPasteboardPlus":
        "@rpath/SimPasteboardPlus",
}


def text_padding_available(data: bytes, ncmds: int, sizeofcmds: int) -> int:
    """Bytes of unused space between end-of-load-commands and the first
    real (non-zerofill) section of __TEXT -- same technique as
    patch_macho.py's LC_ID_DYLIB insertion, generalized here for LC_RPATH."""
    min_section_offset = None
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base_cmd = cmd & ~LC_REQ_DYLD
        if base_cmd == LC_SEGMENT_64:
            segname = data[offset + 8: offset + 24].rstrip(b"\x00")
            if segname == b"__TEXT":
                nsects = struct.unpack_from("<I", data, offset + 64)[0]
                sect_base = offset + 72
                for i in range(nsects):
                    s = sect_base + i * 80
                    sect_file_offset = struct.unpack_from("<I", data, s + 48)[0]
                    if sect_file_offset == 0:
                        continue
                    if min_section_offset is None or sect_file_offset < min_section_offset:
                        min_section_offset = sect_file_offset
        offset += cmdsize
    end_of_cmds = 32 + sizeofcmds
    if min_section_offset is None:
        return 0
    return min_section_offset - end_of_cmds


def build_lc_rpath(path: bytes) -> bytes:
    path_with_nul = path + b"\x00"
    header_size = 12  # cmd, cmdsize, path.offset
    total = header_size + len(path_with_nul)
    padded_size = (total + 7) // 8 * 8
    pad = padded_size - total
    return (
        struct.pack("<III", LC_RPATH, padded_size, header_size)
        + path_with_nul
        + b"\x00" * pad
    )


def insert_lc_rpath(data: bytearray, path: bytes) -> bytearray:
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    new_cmd = build_lc_rpath(path)
    slack = text_padding_available(data, ncmds, sizeofcmds)
    if slack < len(new_cmd):
        raise SystemExit(
            f"Not enough header padding to insert LC_RPATH: need "
            f"{len(new_cmd)} bytes, have {slack}."
        )
    end_of_cmds = 32 + sizeofcmds
    data[end_of_cmds:end_of_cmds + len(new_cmd)] = new_cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + len(new_cmd))
    print(f"inserted LC_RPATH: {path.decode()}")
    return data


def patch(data: bytearray) -> bytearray:
    data = insert_lc_rpath(data, b"@executable_path/Frameworks")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    n_path_fixed = 0
    n_redirected = 0
    n_platform_fixed = 0

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base_cmd = cmd & ~LC_REQ_DYLD

        if base_cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", data, offset + 8)[0]
            if platform == PLATFORM_MACOS:
                struct.pack_into("<I", data, offset + 8, PLATFORM_IOS)
                n_platform_fixed += 1
                print(f"platform: macOS -> iOS")

        elif base_cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", data, offset + 8)[0]
            raw = data[offset + name_off: offset + cmdsize]
            path = raw.split(b"\x00", 1)[0].decode("utf-8")

            new_path = None
            if path in PATH_FIXES:
                new_path = PATH_FIXES[path]
                n_path_fixed += 1
            elif path in REDIRECTS:
                new_path = REDIRECTS[path]
                n_redirected += 1

            if new_path is not None:
                new_bytes = new_path.encode("utf-8") + b"\x00"
                available = cmdsize - name_off
                if len(new_bytes) > available:
                    raise SystemExit(
                        f"Replacement path too long for in-place patch: "
                        f"'{new_path}' ({len(new_bytes)} bytes) doesn't fit "
                        f"in {available} bytes available for '{path}'. "
                        f"This one needs load-command resizing, not "
                        f"implemented here."
                    )
                # zero the whole string region first, then write the new one --
                # avoids leaving stray trailing bytes from a longer old string
                for i in range(available):
                    data[offset + name_off + i] = 0
                data[offset + name_off: offset + name_off + len(new_bytes)] = new_bytes
                print(f"{'redirected' if path in REDIRECTS else 'path-fixed'}: {path}\n  -> {new_path}")

        offset += cmdsize

    print(f"\n{n_platform_fixed} platform field(s) fixed, "
          f"{n_path_fixed} path(s) fixed, {n_redirected} redirected")
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
    print(f"\nwrote {dst}")


if __name__ == "__main__":
    main()
