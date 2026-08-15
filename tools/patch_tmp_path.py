#!/usr/bin/env python3
"""Retarget CoreSimulator's hardcoded /private/tmp scratch directory.

-[SimDevice createLaunchdJobWithBinpref:extraEnvironment:disabledJobs:error:]
does, in order:

    [fm fileExistsAtPath:@"/private/tmp" isDirectory:&isDir]   // else bail
    path = [NSString stringWithFormat:@"/private/tmp/%@", self.launchdJobName]
    [path stringByAppendingPathComponent:@"disabled.plist"]
    sim_reentrantSafeCreateDirectoryAtPath:path ...

and when the check fails it reports

    /private/tmp does not exist or is not accessible. Simulators will NOT be
    available until this misconfiguration of your system is corrected!

iOS has no /private/tmp, and the sandbox will not let the app create one. All
it actually wants is a writable scratch directory, and the app already has one.

Rather than intercept filesystem calls one API at a time, the two path literals
are shortened in place to RELATIVE paths:

    "/private/tmp"     -> "tmp"
    "/private/tmp/%@"  -> "tmp/%@"

The probe chdir()s into its data container before booting, so these resolve to
the app's own tmp directory. Relative paths are resolved by the kernel, so this
covers direct open()/mkdir() calls too -- a Foundation-level swizzle would only
cover whatever went through NSFileManager.

Shortening a constant NSString means editing two things: the C string bytes it
points at, and the length field in the CFString structure. Writing only the
bytes leaves the length reading past the terminator into neighbouring strings.

A cross-reference scan showed these two literals are used by this function
alone, so nothing else changes meaning. The error-message string, which shares
the same prefix, is deliberately left intact.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19

# old literal -> replacement. Replacements must not be longer.
REWRITES = {
    "/private/tmp": "tmp",
    "/private/tmp/%@": "tmp/%@",
}

CFSTRING_DATA_OFF = 16
CFSTRING_LEN_OFF = 24


def sections(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            so = off + 72
            for _ in range(nsects):
                sect = data[so:so + 16].split(b"\0")[0].decode()
                seg = data[so + 16:so + 32].split(b"\0")[0].decode()
                addr, size = struct.unpack_from("<QQ", data, so + 32)
                foff = struct.unpack_from("<I", data, so + 48)[0]
                out.append((seg, sect, addr, size, foff))
                so += 80
        off += cmdsize
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    secs = sections(data)

    def find(name):
        for seg, sect, addr, size, foff in secs:
            if sect == name:
                return addr, size, foff
        return None

    cf = find("__cfstring")
    cs = find("__cstring")
    if not cf or not cs:
        raise SystemExit("missing __cfstring/__cstring")

    def file_off(addr):
        for _seg, _sect, saddr, size, foff in secs:
            if saddr <= addr < saddr + size:
                return foff + (addr - saddr)
        return None

    patched = 0
    cf_addr, cf_size, cf_foff = cf
    for off in range(0, cf_size, 32):
        base = cf_foff + off
        ptr = struct.unpack_from("<Q", data, base + CFSTRING_DATA_OFF)[0]
        length = struct.unpack_from("<Q", data, base + CFSTRING_LEN_OFF)[0]
        # The data pointer is a chained-fixup value; mask to its target.
        target = ptr & 0xFFFFFFFFF
        toff = file_off(target)
        if toff is None:
            continue
        end = data.index(b"\0", toff)
        text = data[toff:end].decode(errors="replace")
        if text not in REWRITES:
            continue
        new = REWRITES[text]
        if len(new) > len(text):
            raise SystemExit("replacement longer than original")
        if length != len(text):
            raise SystemExit(
                "unexpected CFString length %d for %r" % (length, text))

        data[toff:toff + len(new)] = new.encode()
        data[toff + len(new)] = 0
        struct.pack_into("<Q", data, base + CFSTRING_LEN_OFF, len(new))
        print("  %-18r -> %-10r  (cfstring 0x%x, len %d -> %d)" % (
            text, new, cf_addr + off, length, len(new)))
        patched += 1

    if patched != len(REWRITES):
        raise SystemExit(
            "expected %d literals, patched %d" % (len(REWRITES), patched))

    open(dst, "wb").write(data)
    print("wrote %s" % dst)


if __name__ == "__main__":
    main()
