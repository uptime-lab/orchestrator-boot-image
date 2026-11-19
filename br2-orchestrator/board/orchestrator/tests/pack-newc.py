#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Test helper: pack a directory into a gzipped newc cpio, as Buildroot does.

  pack-newc.py TARGET_DIR OUT.cpio.gz [rev] [DEVICES]

Every entry is owned by root (Buildroot packs under fakeroot), mtimes are the
files' own, and "rev" writes the entries in reverse order, as a rebake's
repack may. DEVICES, when given, is a file of "path kind mode major minor"
lines (kind c or b, mode octal): device nodes a non-root test cannot mknod,
added to the archive the way Buildroot's cpio step adds dev/console. Not
shipped in any image.
"""
import gzip
import os
import stat
import sys


def header(ino, mode, nlink, mtime, size, rmaj, rmin, name):
    namesize = len(name) + 1
    fields = (ino, mode, 0, 0, nlink, mtime, size, 0, 0, rmaj, rmin, namesize, 0)
    return b"070701" + b"".join(b"%08x" % f for f in fields) + name + b"\0"


def pad(n):
    return b"\0" * ((4 - n % 4) % 4)


def main(argv):
    target, out = argv[0], argv[1]
    rev = len(argv) > 2 and argv[2] == "rev"
    devices = argv[3] if len(argv) > 3 else (argv[2] if len(argv) > 2 and argv[2] != "rev" else None)
    entries = []
    for dirpath, dirs, files in os.walk(target):
        dirs.sort()
        for n in sorted(dirs + files):
            full = os.path.join(dirpath, n)
            entries.append((os.path.relpath(full, target), full))
    rows = []
    for rel, full in entries:
        st = os.lstat(full)
        if stat.S_ISLNK(st.st_mode):
            body = os.readlink(full).encode()
        elif stat.S_ISREG(st.st_mode):
            with open(full, "rb") as fh:
                body = fh.read()
        else:
            body = b""
        rows.append((rel, st.st_mode, int(st.st_mtime), body, 0, 0))
    if devices:
        with open(devices) as fh:
            for line in fh:
                p = line.split()
                if len(p) == 5:
                    kind = stat.S_IFCHR if p[1] == "c" else stat.S_IFBLK
                    rows.append((p[0], kind | int(p[2], 8), 0, b"", int(p[3]), int(p[4])))
    rows.sort(key=lambda r: r[0], reverse=rev)
    data = bytearray()
    for ino, (rel, mode, mtime, body, rmaj, rmin) in enumerate([(".", stat.S_IFDIR | 0o755, 0, b"", 0, 0)] + rows, 1):
        h = header(ino, mode, 1, mtime, len(body), rmaj, rmin, rel.encode())
        data += h + pad(len(h)) + body + pad(len(body))
    t = header(0, 0, 1, 0, 0, 0, 0, b"TRAILER!!!")
    data += t + pad(len(t))
    with open(out, "wb") as fh:
        fh.write(gzip.compress(bytes(data), mtime=0))


if __name__ == "__main__":
    main(sys.argv[1:])
