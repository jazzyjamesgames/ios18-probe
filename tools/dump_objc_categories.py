#!/usr/bin/env python3
"""List every Objective-C category a Mach-O defines, with its method names.

CoreSimulatorUtilities extends Foundation classes with private category
methods, and our stub has been reimplementing them one crash at a time:
sim_realPath, sim_packedVersion, sim_cpuType, sim_copyItemAtPath,
sim_reentrantSafeCreateDirectoryAtPath, and then popLastObject -- which the
earlier "grep the binary for sim_ selectors" sweep could never have found,
because it has no sim_ prefix. Each one costs a build, an install, and a crash.

Reading __objc_catlist gives the whole set at once: exactly which classes are
extended and exactly which selectors are added.

Categories are laid out as

    struct category_t {
        const char *name;                 // +0
        classref_t  cls;                  // +8
        method_list_t *instanceMethods;   // +16
        method_list_t *classMethods;      // +24
        ...
    };

and method lists are either the classic form (pointer-sized entries) or the
modern relative form (three int32 offsets per entry), flagged by the high bit
of entsize. Pointers in __DATA are chained-fixup values, so they're masked down
to their target offset the same way the selector-reference decoding does.
"""
import struct
import sys

LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2
LC_DYLD_CHAINED_FIXUPS = 0x80000034


class Image:
    def __init__(self, data):
        self.data = data
        self.sections = []
        self.imports = []        # bind ordinal -> imported symbol name
        self._parse()
        self._parse_imports()

    def _parse_imports(self):
        """Imported symbol names from LC_DYLD_CHAINED_FIXUPS.

        A category's cls field points at a class from another image, so it is
        not a rebase but a BIND: the slot holds an ordinal into this table
        rather than an address. Resolving it turns a guess ("methods like
        -sim_realPath are probably on NSString") into the linker's own answer,
        _OBJC_CLASS_$_NSString.
        """
        ncmds = struct.unpack_from("<I", self.data, 16)[0]
        off, cf = 32, None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.data, off)
            if cmd == LC_DYLD_CHAINED_FIXUPS:
                cf = struct.unpack_from("<I", self.data, off + 8)[0]
            off += cmdsize
        if cf is None:
            return
        _ver, _starts, imports_off, symbols_off, imports_count, imports_fmt = \
            struct.unpack_from("<IIIIII", self.data, cf)
        # Three import encodings differ only in where the name offset sits.
        # arm64e binaries (the real CoreSimulatorUtilities) do not use format 1,
        # which is why an earlier version of this resolved every class to "?".
        widths = {1: 4, 2: 8, 3: 16}
        if imports_fmt not in widths:
            return
        for i in range(imports_count):
            base = cf + imports_off + i * widths[imports_fmt]
            if imports_fmt == 1:
                name_off = struct.unpack_from("<I", self.data, base)[0] >> 9
            elif imports_fmt == 2:
                name_off = (struct.unpack_from("<Q", self.data, base)[0] >> 9) & 0x7FFFFF
            else:
                name_off = struct.unpack_from("<Q", self.data, base)[0] >> 32
            start = cf + symbols_off + name_off
            end = self.data.index(b"\0", start)
            self.imports.append(self.data[start:end].decode(errors="replace"))

    def bind_name(self, addr):
        """If the pointer slot at addr is a bind, return the symbol it binds."""
        raw = self.at(addr, 8)
        if not raw:
            return None
        val = struct.unpack("<Q", raw)[0]
        # Two pointer formats in play. DYLD_CHAINED_PTR_64 (plain arm64) flags a
        # bind in bit 63 with a 24-bit ordinal; DYLD_CHAINED_PTR_ARM64E uses bit
        # 63 for auth and bit 62 for bind, with a 16-bit ordinal. Try whichever
        # applies and keep the reading that names an actual class.
        candidates = []
        if (val >> 63) & 1:
            candidates.append(val & 0xFFFFFF)
        if (val >> 62) & 1:
            candidates.append(val & 0xFFFF)
        for ordinal in candidates:
            if ordinal < len(self.imports):
                name = self.imports[ordinal]
                if "_OBJC_CLASS_$_" in name:
                    return name
        for ordinal in candidates:
            if ordinal < len(self.imports):
                return self.imports[ordinal]
        return None

    def _parse(self):
        data = self.data
        ncmds = struct.unpack_from("<I", data, 16)[0]
        off = 32
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
                    self.sections.append((seg, sect, addr, size, foff))
                    so += 80
            off += cmdsize

    def section(self, name):
        for seg, sect, addr, size, foff in self.sections:
            if sect == name:
                return addr, size, foff
        return None

    def section_for(self, addr):
        for seg, sect, saddr, size, foff in self.sections:
            if saddr <= addr < saddr + size:
                return seg, sect, saddr, size, foff
        return None

    def at(self, addr, n):
        s = self.section_for(addr)
        if not s:
            return None
        _seg, _sect, saddr, _size, foff = s
        start = foff + (addr - saddr)
        return self.data[start:start + n]

    def ptr(self, addr):
        """Read a pointer slot, resolving the chained-fixup encoding."""
        raw = self.at(addr, 8)
        if not raw:
            return 0
        val = struct.unpack("<Q", raw)[0]
        if val == 0:
            return 0
        for cand in (val & 0xFFFFFFFFF, val & 0x7FFFFFFFFF, val):
            if self.section_for(cand):
                return cand
        return 0

    def cstr(self, addr):
        s = self.section_for(addr)
        if not s:
            return None
        _seg, _sect, saddr, _size, foff = s
        start = foff + (addr - saddr)
        end = self.data.index(b"\0", start)
        return self.data[start:end].decode(errors="replace")

    def method_names(self, mlist_addr):
        """Method names from either the classic or relative method list form."""
        if not mlist_addr:
            return []
        hdr = self.at(mlist_addr, 8)
        if not hdr:
            return []
        entsize, count = struct.unpack("<II", hdr)
        relative = bool(entsize & 0x80000000)
        entsize &= 0xFFFF
        names = []
        for i in range(min(count, 512)):
            entry = mlist_addr + 8 + i * entsize
            if relative:
                raw = self.at(entry, 4)
                if not raw:
                    break
                delta = struct.unpack("<i", raw)[0]
                # The name field points at a selector reference, which in turn
                # points at the string.
                selref = entry + delta
                target = self.ptr(selref)
                nm = self.cstr(target) if target else None
                if nm is None:
                    nm = self.cstr(selref)
            else:
                nm = self.cstr(self.ptr(entry))
            if nm:
                names.append(nm)
        return names


def main():
    img = Image(open(sys.argv[1], "rb").read())
    catlist = img.section("__objc_catlist")
    if not catlist:
        print("no __objc_catlist (binary defines no categories)")
        return
    addr, size, _foff = catlist
    total = 0
    for i in range(size // 8):
        cat = img.ptr(addr + i * 8)
        if not cat:
            continue
        name = img.cstr(img.ptr(cat)) or "?"
        inst = img.method_names(img.ptr(cat + 16))
        cls = img.method_names(img.ptr(cat + 24))
        target = img.bind_name(cat + 8) or "?"
        if target.startswith("_OBJC_CLASS_$_"):
            target = target[len("_OBJC_CLASS_$_"):]
        print("category %s (%s)" % (target, name))
        for m in inst:
            print("    -%s" % m)
        for m in cls:
            print("    +%s" % m)
        total += len(inst) + len(cls)
    print()
    print("%d category methods total" % total)


if __name__ == "__main__":
    main()
