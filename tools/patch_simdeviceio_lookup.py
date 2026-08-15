#!/usr/bin/env python3
"""Make CoreSimulator look for its .simdeviceio plugins where iOS lets us put them.

-[SimDeviceIOServer(SimDeviceIOLoadedBundle) loadAllBundlesWithError:] does:

    [[NSBundle bundleWithIdentifier:@"com.apple.CoreSimulator"]
        URLsForResourcesWithExtension:@".simdeviceio" subdirectory:@"Resources"]

and throws "Failed to retrieve paths for simdeviceio bundles." when the result
is empty. The subdirectory is hardcoded because on macOS the framework really
does keep them in Versions/A/Resources.

We cannot reproduce that on iOS. Creating a Resources/ directory inside an
embedded framework changes how CFBundle reads the bundle's layout, and installd
then refuses to install the entire app:

    Info.plist from bundle at path .../CoreSimulator.framework had none of the
    keys that we expect

So the plugins have to sit flat, next to the binary -- and the on-device probe
confirmed that from there, the very same query with a nil subdirectory finds
all six. This patch rewrites just that one argument:

    adrp x3, <page>          ->  nop
    add  x3, x3, #<off>      ->  movz x3, #0        (subdirectory:nil)

Nothing else changes; the extension argument and the call itself are untouched.

The call site is located by walking back from the bl that targets the
_objc_msgSend$URLsForResourcesWithExtension:subdirectory: stub, so this does not
depend on a hardcoded offset. If the binary ever stops matching what we expect,
it fails loudly rather than corrupting instructions.
"""
import struct
import sys

LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2

NOP = 0xD503201F
MOVZ_X3_0 = 0xD2800003

METHOD = "loadAllBundlesWithError"
STUB = "_objc_msgSend$URLsForResourcesWithExtension:subdirectory:"


def parse(data):
    """Return (sections, symbols) with just what this patch needs."""
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, sections, symbols = 32, [], []
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
                sections.append((seg, sect, addr, size, foff))
                so += 80
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, off + 8)
            for i in range(nsyms):
                base = symoff + i * 16
                strx = struct.unpack_from("<I", data, base)[0]
                value = struct.unpack_from("<Q", data, base + 8)[0]
                end = data.index(b"\0", stroff + strx)
                symbols.append(
                    (data[stroff + strx:end].decode(errors="replace"), value))
        off += cmdsize
    return sections, symbols


def text_range(sections):
    for seg, sect, addr, size, foff in sections:
        if seg == "__TEXT" and sect == "__text":
            return addr, size, foff
    raise SystemExit("no __TEXT,__text section")


def is_adrp(w, rd):
    return (w & 0x9F000000) == 0x90000000 and (w & 0x1F) == rd


def is_add_imm(w, rd):
    return (w & 0xFFC00000) == 0x91000000 and (w & 0x1F) == rd


def bl_target(w, addr):
    if (w & 0xFC000000) != 0x94000000:
        return None
    imm = w & 0x03FFFFFF
    if imm & 0x02000000:          # sign-extend imm26
        imm -= 0x04000000
    return addr + imm * 4


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    sections, symbols = parse(data)
    taddr, tsize, tfoff = text_range(sections)

    method = next((v for n, v in symbols if METHOD in n and v), None)
    if method is None:
        raise SystemExit("could not find %s in the symbol table" % METHOD)
    stub = next((v for n, v in symbols if n == STUB), None)
    if stub is None:
        raise SystemExit("could not find the stub %s" % STUB)

    print("%s @ 0x%x" % (METHOD, method))
    print("stub @ 0x%x" % stub)

    # Find the call into that stub within the method body.
    call_addr = None
    for addr in range(method, method + 8000, 4):
        w = struct.unpack_from("<I", data, tfoff + (addr - taddr))[0]
        if bl_target(w, addr) == stub:
            call_addr = addr
            break
    if call_addr is None:
        raise SystemExit("no call to the lookup stub inside the method")
    print("call site @ 0x%x (+%d)" % (call_addr, call_addr - method))

    # Walk back for the adrp/add pair that builds x3 (the subdirectory arg).
    add_addr = None
    for addr in range(call_addr - 4, call_addr - 64, -4):
        w = struct.unpack_from("<I", data, tfoff + (addr - taddr))[0]
        if is_add_imm(w, 3):
            add_addr = addr
            break
    if add_addr is None:
        raise SystemExit("no 'add x3, x3, #imm' before the call")
    adrp_addr = add_addr - 4
    adrp_w = struct.unpack_from("<I", data, tfoff + (adrp_addr - taddr))[0]
    if not is_adrp(adrp_w, 3):
        raise SystemExit(
            "expected 'adrp x3' at 0x%x, found 0x%08x" % (adrp_addr, adrp_w))

    print("patching 0x%x adrp x3 -> nop" % adrp_addr)
    print("patching 0x%x add  x3 -> movz x3, #0   (subdirectory:nil)" % add_addr)
    struct.pack_into("<I", data, tfoff + (adrp_addr - taddr), NOP)
    struct.pack_into("<I", data, tfoff + (add_addr - taddr), MOVZ_X3_0)

    open(dst, "wb").write(data)
    print("wrote %s" % dst)


if __name__ == "__main__":
    main()
