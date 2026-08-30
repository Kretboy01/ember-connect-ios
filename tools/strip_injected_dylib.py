#!/usr/bin/env python3
"""Remove an injected dylib from an IPA, load command and all.

Neutralizing a mod by patching its constructors to `ret` leaves the library
mapped and half-initialized: ObjC `+load` methods still run, and anything they
reach for that a constructor was supposed to set up is still NULL. Removing the
`LC_LOAD_DYLIB` entry as well means nothing about it is ever loaded.

The load command is dropped in place: the remaining commands shift up, the
freed tail is zeroed, and `ncmds`/`sizeofcmds` are corrected. No file offsets
move, so every segment, section, and symbol table stays exactly where it was.

    python tools/strip_injected_dylib.py in.ipa out.ipa
    python tools/strip_injected_dylib.py in.ipa out.ipa --dylib 80pool.dylib

The result is unsigned; whatever installs it is expected to re-sign. Ember
Connect Mobile does that through ZSign on the way in.
"""

from __future__ import annotations

import argparse
import plistlib
import posixpath
import struct
import sys
import zipfile

FAT_MAGIC_BE = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x1F
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB)

# Anything that is obviously a tweak/mod runtime rather than a real dependency.
DEFAULT_SUSPECTS = ("80pool.dylib",)


def slice_offsets(data: bytes) -> list[int]:
    if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC_BE:
        count = struct.unpack_from(">I", data, 4)[0]
        return [struct.unpack_from(">I", data, 8 + i * 20 + 8)[0] for i in range(count)]
    if struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        return [0]
    raise SystemExit("main executable is not a Mach-O")


def strip_from_slice(buf: bytearray, base: int, targets: set[str]) -> list[str]:
    """Drop matching dylib load commands from one Mach-O slice."""
    ncmds, sizeofcmds = struct.unpack_from("<II", buf, base + 16)
    start = base + 32

    kept = bytearray()
    removed: list[str] = []
    pos = start
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, pos)
        chunk = bytes(buf[pos:pos + cmdsize])
        if cmd in DYLIB_COMMANDS:
            name_off = struct.unpack_from("<I", buf, pos + 8)[0]
            name = chunk[name_off:].split(b"\0", 1)[0].decode(errors="replace")
            if posixpath.basename(name) in targets:
                removed.append(name)
                pos += cmdsize
                continue
        kept += chunk
        pos += cmdsize

    if not removed:
        return []

    # Overwrite the command area with the survivors and zero what is left, so
    # nothing downstream of the header shifts by a single byte.
    buf[start:start + sizeofcmds] = kept + b"\0" * (sizeofcmds - len(kept))
    struct.pack_into("<II", buf, base + 16, ncmds - len(removed), len(kept))
    return removed


def clean_code_resources(raw: bytes, dropped: set[str]) -> bytes:
    """Drop removed files from the bundle's CodeResources manifest."""
    try:
        plist = plistlib.loads(raw)
    except Exception:
        return raw
    changed = False
    for key in ("files", "files2"):
        section = plist.get(key)
        if not isinstance(section, dict):
            continue
        for path in [p for p in section if posixpath.basename(p) in dropped]:
            del section[path]
            changed = True
    return plistlib.dumps(plist) if changed else raw


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("--dylib", action="append", default=None,
                        help="basename to remove (repeatable)")
    args = parser.parse_args()

    targets = set(args.dylib or DEFAULT_SUSPECTS)

    with zipfile.ZipFile(args.source) as src:
        names = src.namelist()
        app_dirs = {n.split("/")[1] for n in names
                    if n.startswith("Payload/") and n.count("/") >= 2}
        if len(app_dirs) != 1:
            raise SystemExit(f"expected one .app in Payload, found {app_dirs}")
        app = f"Payload/{app_dirs.pop()}"

        info = plistlib.loads(src.read(f"{app}/Info.plist"))
        exec_name = info["CFBundleExecutable"]
        exec_path = f"{app}/{exec_name}"

        drop = {n for n in names if posixpath.basename(n) in targets}
        if not drop:
            raise SystemExit(f"none of {sorted(targets)} are present in the IPA")
        for n in sorted(drop):
            print(f"[strip] removing file {n}")

        macho = bytearray(src.read(exec_path))
        removed: list[str] = []
        for base in slice_offsets(macho):
            removed += strip_from_slice(macho, base, targets)
        if not removed:
            raise SystemExit(f"{exec_name} does not link any of {sorted(targets)}")
        for name in removed:
            print(f"[strip] removing load command {name}")

        with zipfile.ZipFile(args.destination, "w", zipfile.ZIP_DEFLATED) as dst:
            for item in src.infolist():
                if item.filename in drop:
                    continue
                if item.filename == exec_path:
                    payload = bytes(macho)
                elif posixpath.basename(item.filename) == "CodeResources":
                    payload = clean_code_resources(src.read(item.filename), targets)
                else:
                    payload = src.read(item.filename)
                dst.writestr(item, payload, item.compress_type)

    print(f"[strip] wrote {args.destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
