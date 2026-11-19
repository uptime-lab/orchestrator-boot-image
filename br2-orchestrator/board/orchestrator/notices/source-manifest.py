#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bind the recovery image's GPL corpus to a committed manifest.

The source offer in the image names a base id, and check-notices.sh asserts the
image names the base in source-offer.env. Neither proves that the bytes in the
image are the build the corresponding-source bundle was cut from: a label is
only a label. This script records, beside source-offer.env, what the base
actually IS -- the configurations, the package sources, the kernels, the rootfs,
the FAT root, the board files and the archives the offer names -- and compares a
build output, an image or a bundle with it.

What the manifest records (file: ../source-manifest):

  base_id, buildroot_version       the base the offer names
  board_commit <sha>               the commit of this tree whose board files
                                   (config.txt, cmdline.txt and the tracked
                                   rootfs-overlay files) the base's image
                                   carries; usually the base commit itself
  archive bundle|toolchain <name> <sha256> <size>
                                   the corresponding-source bundle and the
                                   toolchain source snapshot the offer names, as
                                   served beside each other (the same values as
                                   source-offer.env and source-SHA256SUMS)
  config <name> <sha256>           Buildroot, kernel and BusyBox .config of both
                                   SoC builds, normalised (comments other than
                                   "# X is not set", blank lines and the two
                                   lines that record a checkout PATH dropped)
  legal_manifest <soc> <sha256>    legal-info/manifest.csv of each build
  source <path> <sha256>           every target source archive and patch
                                   legal-info saved (legal-info.sha256)
  kernel <soc> <sha256>            the kernel Image of each build
  rootfs_exclude <path>            the rootfs paths the Orchestrator overlay
                                   installs, DERIVED from the tree: every file
                                   tracked under board/orchestrator/rootfs-overlay
                                   plus the overlay paths .gitignore names (the
                                   agent binary). They stay out of the digest
                                   below; every one of them but the ignored agent
                                   is bound by an `overlay` line instead.
  overlay <path> <kind> <mode> <uid>:<gid> <size> <sha256>
                                   each TRACKED overlay file as the image carries
                                   it, byte for byte; with a tree, each must be
                                   the tree's file at board_commit. Only the
                                   gitignored agent path is unbound: a rebake
                                   swaps exactly that.
  rootfs_stripped_sha256 / _entries
                                   sha256 over every OTHER rootfs entry, sorted by
                                   path: kind, mode, owner, size and content hash
                                   (for a link, of its target; for a device node,
                                   its major and minor). cpio order and mtimes are
                                   not part of it, so a rebake that repacks the
                                   archive keeps the digest.
  fat_exclude <path>               FAT-root files outside the FAT digest: the
                                   rootfs archive (bound above), the notices
                                   (LICENSES/, SOURCE-OFFER.txt) and the board
                                   files assemble-boot-img.sh copies from this
                                   board directory (config.txt, cmdline.txt,
                                   derived from that script)
  board_file <name> <sha256>       each of those board files, byte for byte; with
                                   a tree, the tree's file at board_commit (the
                                   assemble script copies them verbatim and a
                                   rebake never touches them, so what the tree
                                   renders for the base IS the file)
  licence <name> <sha256|by-name>  LICENSES/ is EXACTLY the set the notices
                                   generator (make-notices.sh beside this script)
                                   writes, derived by running it; the licence
                                   texts are bound by sha256, the two agent
                                   notices by name only (see LICENCES_BY_NAME)
  fat_base_sha256 / _files         sha256 over every other FAT-root file: kernels,
                                   device trees, overlays, GPU firmware. A file
                                   anywhere that none of the above names changes
                                   it.

A value of "pending" means no build output or image has yet been measured for
that field. A check that needs a pending field exits 3: pending is not a pass.

Usage:
  source-manifest.py generate [--manifest FILE] [--env FILE] [--tree DIR]
                              (--out-cm4 DIR --out-cm5 DIR [--image IMG | --fat-dir DIR]
                               | --bundle DIR|TAR) [--bundle TAR] [--toolchain FILE]
  source-manifest.py check    [--manifest FILE] [--env FILE] [--tree DIR] [--sums FILE]
                              [--out-cm4 DIR --out-cm5 DIR] [--image IMG]
                              [--fat-dir DIR] [--rootfs CPIO] [--bundle DIR|TAR]
                              [--toolchain FILE]
  source-manifest.py show     [--manifest FILE] [--env FILE] [--tree DIR] [--sums FILE]
  source-manifest.py measure  [--tree DIR | --manifest FILE] <any input above>

  generate  write the manifest; from build outputs (with --image or --fat-dir
            the FAT-root digest too, else that field is pending) or from a
            bundle that carries an image inventory. A bundle given as a TAR
            (alone or beside the outputs) fills `archive bundle`, --toolchain
            fills `archive toolchain`; an archive not given stays pending. With
            both archives measured it also writes source-SHA256SUMS beside the
            manifest: the file each install serves as /source/SHA256SUMS.
  check     compare every given input with the manifest
  show      the manifest is well-formed, names the env's base and archives,
            agrees with source-SHA256SUMS, records the exclusions and board
            files the tree derives and the licence set the generator writes;
            exit 3 when a field is pending
  measure   print what an input measures to, in manifest syntax, writing
            nothing (to see WHAT differs, or to build a test fixture)

  --out-cm4/--out-cm5  Buildroot output trees (O=); legal-info must have run
  --image IMG          a boot.img (needs mtools: mcopy)
  --fat-dir DIR        a FAT root already copied out of an image (mcopy -s)
  --rootfs CPIO        a rootfs.cpio(.gz) taken out of an image
  --bundle DIR|TAR     a corresponding-source bundle (recovery-image-source-*.tar
                       or its unpacked directory); a TAR is also hashed whole
  --toolchain FILE     the toolchain source snapshot the offer names
  --sums FILE          a SHA256SUMS (default: source-SHA256SUMS beside the
                       manifest, when it exists); every archive the manifest
                       records must be listed in it with the same sha256
  --tree DIR           the br2-orchestrator directory to derive the exclusions
                       and the board files from (default: the one holding this
                       script, when it is a git checkout)
  --env FILE           source-offer.env; its SOURCE_BASE_ID must equal base_id and
                       its archive hashes the manifest's

Exit: 0 every checked field matches; 1 a mismatch, or a manifest that is
missing, malformed or of a different format; 2 usage, or an input that cannot
be read; 3 nothing mismatched but a field the check needs is pending.
"""

import argparse
import csv  # noqa: F401  (kept for callers that import this module)
import gzip
import hashlib
import io  # noqa: F401
import lzma
import os
import re
import subprocess
import sys
import tarfile
import tempfile

FORMAT = "2"
PENDING = "pending"
BY_NAME = "by-name"
SOCS = ("cm4", "cm5")
KERNEL_SOC = {"cm4": "bcm2711", "cm5": "bcm2712"}
# The FAT-root names assemble-boot-img.sh gives the two kernels.
FAT_KERNELS = {"kernel8.img": "bcm2711", "kernel_2712.img": "bcm2712"}
# The FAT-root entries outside the FAT digest whatever the tree says: the
# rootfs archive has its own digest, and notices/make-notices.sh writes
# LICENSES/ and SOURCE-OFFER.txt (bound by the `licence` lines and by
# check-notices.sh). tests/source-manifest.sh pins that make-notices.sh still
# writes exactly these.
FAT_ALWAYS_EXCLUDED = ("LICENSES/", "SOURCE-OFFER.txt", "rootfs.cpio.gz")
LICENSES_DIR = "LICENSES/"
# The two notices bound by NAME only, and why. Every other file the generator
# writes into LICENSES/ is bound by sha256.
LICENCES_BY_NAME = {
    # Generated in the agent's source from the Go modules compiled into the
    # agent being baked; a rebake passes that release's copy
    # (inject-notices.sh --agent-notices), so it changes with every agent.
    "THIRD-PARTY-NOTICES-orchestrator-agent.md":
        "the notices of the baked agent's Go modules, regenerated per agent release",
    # The agent's own Apache NOTICE: it travels with the agent, not with the
    # GPL base, and changes when the agent's attribution does.
    "NOTICE-orchestrator-agent.txt": "the agent's Apache NOTICE, which follows the agent release",
}
OVERLAY = "board/orchestrator/rootfs-overlay"
BOARD = "board/orchestrator"
ARCHIVES = ("bundle", "toolchain")
SUMS_NAME = "source-SHA256SUMS"

HERE = os.path.dirname(os.path.abspath(__file__))
BOARD_DIR = os.path.dirname(HERE)
DEFAULT_MANIFEST = os.path.join(BOARD_DIR, "source-manifest")
GENERATOR = os.path.join(HERE, "make-notices.sh")


class Unreadable(Exception):
    """An input that cannot be read: exit 2."""


class Malformed(Exception):
    """A manifest that cannot be trusted: exit 1."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    """(sha256, size) of a file, read in chunks: the bundle is ~900 MB."""
    h = hashlib.sha256()
    size = 0
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
                size += len(chunk)
    except OSError:
        raise Unreadable("cannot read %s" % path)
    return h.hexdigest(), size


# --- configurations -----------------------------------------------------------

NOT_SET = re.compile(r"^# [A-Za-z0-9_]+ is not set$")
# Where the checkout was, not what was built: Buildroot writes the absolute
# path of the external tree and of the defconfig into .config.
PATH_LINES = re.compile(r"^(BR2_DEFCONFIG|BR2_EXTERNAL(_[A-Z0-9_]+)?_PATH)=")


def normalise_config(data):
    keep = []
    for line in data.decode("utf-8", "replace").splitlines():
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("#") and not NOT_SET.match(line):
            continue
        if PATH_LINES.match(line):
            continue
        keep.append(line)
    return ("\n".join(keep) + "\n").encode()


def buildroot_version(data):
    m = re.search(rb"^# Buildroot (\S+) Configuration$", data, re.M)
    if not m:
        raise Unreadable("a Buildroot .config without its '# Buildroot <version> Configuration' header")
    return m.group(1).decode()


def legal_sources(data):
    """{path: sha256} of the target sources legal-info saved."""
    out = {}
    for line in data.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith("sources/"):
            out[parts[1]] = parts[0]
    if not out:
        raise Unreadable("legal-info.sha256 lists no sources/ entries")
    return out


# --- rootfs -------------------------------------------------------------------

def _kind(mode):
    t = mode & 0o170000
    return {0o040000: "d", 0o120000: "l", 0o020000: "c", 0o060000: "b",
            0o010000: "p", 0o140000: "s"}.get(t, "-")


def _norm_name(name):
    while name.startswith("./"):
        name = name[2:]
    return "" if name in (".", "") else name


def _rdev(major, minor):
    return "rdev=%d,%d" % (major, minor)


def cpio_entries(data):
    """{name: (kind, mode, uid, gid, size, hash)} of a newc archive. The hash of
    a file is of its content, of a link of its target, and a device node's is
    its major and minor numbers: a changed dev/console is a changed rootfs."""
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    elif data[:6] == b"\xfd7zXZ\x00":
        data = lzma.decompress(data)
    entries = {}
    links = {}
    off = 0
    while True:
        magic = data[off:off + 6]
        if magic not in (b"070701", b"070702"):
            raise Unreadable("not a newc cpio archive (bad header at offset %d)" % off)
        try:
            f = [int(data[off + 6 + i * 8:off + 14 + i * 8], 16) for i in range(13)]
        except ValueError:
            raise Unreadable("corrupt cpio header at offset %d" % off)
        ino, mode, uid, gid, nlink, _mtime, size, devmaj, devmin, rdevmaj, rdevmin, namesize, _chk = f
        name = data[off + 110:off + 110 + namesize - 1].decode("utf-8", "surrogateescape")
        body_at = (off + 110 + namesize + 3) & ~3
        body = data[body_at:body_at + size]
        if len(body) != size:
            raise Unreadable("truncated cpio archive at %s" % name)
        off = (body_at + size + 3) & ~3
        if name == "TRAILER!!!":
            break
        name = _norm_name(name)
        if not name:
            continue
        kind = _kind(mode)
        if kind in "-l":
            digest = sha256(body)
        elif kind in "cb":
            digest = _rdev(rdevmaj, rdevmin)
        else:
            digest = "-"
        entries[name] = [kind, mode & 0o7777, uid, gid, size, digest]
        if kind == "-" and nlink > 1:
            links.setdefault((devmaj, devmin, ino), []).append(name)
    # newc stores a hard-linked file's data with ONE of its names; give every
    # name the content, so the digest does not depend on which one carried it.
    for names in links.values():
        carriers = [n for n in names if entries[n][4] > 0]
        if carriers:
            size, digest = entries[carriers[-1]][4], entries[carriers[-1]][5]
            for n in names:
                entries[n][4], entries[n][5] = size, digest
    return {k: tuple(v) for k, v in entries.items()}


MKNOD = re.compile(r"mknod\s+-m\s+([0-7]+)\s+\$\(TARGET_DIR\)/(\S+)\s+([cb])\s+(\d+)\s+(\d+)")


def devices_from_cpio_mk(text):
    """{path: (kind, mode, rdev)} of the device nodes Buildroot's cpio step
    creates (fs/cpio/cpio.mk: `mknod -m 0622 $(TARGET_DIR)/dev/console c 5 1`).
    A member listing records no device numbers; the Buildroot release the
    bundle carries is where they come from, never a typed value."""
    out = {}
    for mode, path, kind, major, minor in MKNOD.findall(text):
        out[_norm_name(path)] = (kind, int(mode, 8) & 0o7777, _rdev(int(major), int(minor)))
    return out


def listing_entries(text, devices=None):
    """The same mapping from a member listing (image-inventory/*.members):
    "kind mode uid:gid size mtime sha256|- name [link target]". A listing has
    no device numbers: each device node takes them from `devices`, and one
    that `devices` does not name cannot be measured."""
    devices = devices or {}
    entries = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        p = line.split()
        if len(p) < 7 or (len(p) > 7 and not (p[0] == "l" and len(p) == 8)):
            raise Unreadable("cannot parse member listing line: %r" % line)
        uid, _, gid = p[2].partition(":")
        name = _norm_name(p[6])
        if not name:
            continue
        digest = p[5]
        mode = int(p[1], 8)
        if p[0] in "cb":
            dev = devices.get(name)
            if dev is None:
                raise Unreadable("the listing names device node %s, and nothing in the bundle says its "
                                 "major and minor (the Buildroot release's fs/cpio/cpio.mk does not create it)"
                                 % name)
            if dev[0] != p[0] or dev[1] != mode:
                raise Unreadable("device node %s is %s %04o in the listing, but Buildroot creates it as %s %04o"
                                 % (name, p[0], mode, dev[0], dev[1]))
            digest = dev[2]
        entries[name] = (p[0], mode, int(uid), int(gid), int(p[3]), digest)
    if not entries:
        raise Unreadable("empty member listing")
    return entries


def stripped_digest(entries, exclude):
    lines = []
    for name in sorted(entries):
        if name in exclude:
            continue
        kind, mode, uid, gid, size, digest = entries[name]
        lines.append("%s %04o %d:%d %d %s %s" % (kind, mode, uid, gid, size, digest, name))
    return sha256(("\n".join(lines) + "\n").encode()), len(lines)


def overlay_value(entry):
    kind, mode, uid, gid, size, digest = entry
    return "%s %04o %d:%d %d %s" % (kind, mode, uid, gid, size, digest)


def overlay_bindings(entries, paths):
    """{path: value} for the bound overlay paths the rootfs carries."""
    return {p: overlay_value(entries[p]) for p in paths if p in entries}


# --- FAT root -----------------------------------------------------------------

def fat_excluded(path, exclude):
    for e in exclude:
        if e.endswith("/") and path.startswith(e):
            return True
        if path == e:
            return True
    return False


def fat_digest(files, exclude):
    lines = ["%s  %s" % (files[p], p) for p in sorted(files) if not fat_excluded(p, exclude)]
    return sha256(("\n".join(lines) + "\n").encode()), len(lines)


def fat_dir_files(root):
    files = {}
    for dirpath, _dirs, names in os.walk(root):
        for n in names:
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, "rb") as fh:
                files[rel] = sha256(fh.read())
    if not files:
        raise Unreadable("no files under %s" % root)
    return files


def fat_list_files(text):
    files = {}
    for line in text.splitlines():
        p = line.split(None, 1)
        if len(p) == 2 and re.fullmatch(r"[0-9a-f]{64}", p[0]):
            files[_norm_name(p[1].strip())] = p[0]
    if not files:
        raise Unreadable("empty FAT inventory")
    return files


def copy_fat_root(image, dest):
    if not os.path.isfile(image):
        raise Unreadable("not a file: %s" % image)
    try:
        subprocess.run(["mcopy", "-n", "-s", "-i", image, "::/*", dest + "/"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise Unreadable("mcopy (mtools) is not installed; cannot read %s" % image)
    except subprocess.CalledProcessError as e:
        raise Unreadable("mcopy could not read %s: %s" % (image, e.stderr.decode().strip()))


# --- the tree: what is excluded and bound, derived ----------------------------

def git(tree, *args, binary=False):
    try:
        out = subprocess.run(["git", "-C", tree] + list(args), check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError):
        raise Unreadable("%s is not a git checkout (or lacks what `git %s` asks for)" % (tree, " ".join(args[:2])))
    return out if binary else out.decode()


def derive_overlay_tracked(tree):
    """The overlay files this tree tracks, relative to the overlay root."""
    prefix = OVERLAY + "/"
    tracked = git(tree, "ls-files", "-z", "--", OVERLAY).split("\0")
    return sorted(p[len(prefix):] for p in tracked if p.startswith(prefix))


def derive_rootfs_exclude(tree):
    """Every path the overlay installs: the files tracked under it, plus the
    overlay paths .gitignore names (the agent is built elsewhere and dropped in
    before the build, so it is ignored, not tracked). Nothing typed here.

    post-build.sh needs no entry: what it does to the target is part of the
    build and so inside the digest, and a rebake does not run it."""
    paths = set(derive_overlay_tracked(tree))
    top = git(tree, "rev-parse", "--show-toplevel").strip()
    rel = git(tree, "rev-parse", "--show-prefix").strip()
    ignore = os.path.join(top, ".gitignore")
    prefix = OVERLAY + "/"
    if os.path.isfile(ignore):
        full_prefix = "/" + rel + prefix if rel else "/" + prefix
        with open(ignore) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                cand = line if line.startswith("/") else "/" + line
                if not cand.startswith(full_prefix):
                    continue
                if re.search(r"[*?\[!]", line):
                    raise Unreadable(".gitignore names overlay paths by a pattern (%s); "
                                     "name each ignored overlay file exactly" % line)
                paths.add(cand[len(full_prefix):])
    if not paths:
        raise Unreadable("no overlay files under %s/%s" % (tree, OVERLAY))
    return sorted(paths)


COPY_FROM_BOARD = re.compile(r'^\s*cp\s+"\$BOARD_DIR/([^"/]+)"\s+"\$STAGE/([^"]+)"', re.M)


def derive_board_copies(tree):
    """{FAT name: board-directory name} of every file assemble-boot-img.sh
    copies verbatim from the board directory into the FAT root."""
    script = os.path.join(tree, BOARD, "assemble-boot-img.sh")
    try:
        with open(script) as fh:
            text = fh.read()
    except OSError:
        raise Unreadable("cannot read %s" % script)
    copies = {dst: src for src, dst in COPY_FROM_BOARD.findall(text)}
    if not copies:
        raise Unreadable("%s copies nothing from the board directory; "
                         "the FAT exclusions cannot be derived" % script)
    return copies


def derive_fat_exclude(tree):
    return sorted(set(FAT_ALWAYS_EXCLUDED) | set(derive_board_copies(tree)))


def resolve_commit(tree, rev):
    out = git(tree, "rev-parse", "--verify", "--quiet", rev + "^{commit}")
    return out.strip()


def board_blobs(tree, commit):
    """What the tree at `commit` puts into an image: ({overlay path: value},
    {FAT board file: sha256}), values in the `overlay` / `board_file` syntax.
    An overlay file is installed with its git mode and owned by root."""
    rel = git(tree, "rev-parse", "--show-prefix").strip()
    overlay = {}
    listing = git(tree, "ls-tree", "-r", "-z", "--full-tree", commit, "--", rel + OVERLAY + "/")
    prefix = rel + OVERLAY + "/"
    for row in listing.split("\0"):
        if not row:
            continue
        meta, _, path = row.partition("\t")
        mode, _type, obj = meta.split()
        if not path.startswith(prefix):
            continue
        data = git(tree, "cat-file", "blob", obj, binary=True)
        if mode == "120000":
            entry = ("l", 0o777, 0, 0, len(data), sha256(data))
        else:
            entry = ("-", int(mode[-4:], 8), 0, 0, len(data), sha256(data))
        overlay[path[len(prefix):]] = overlay_value(entry)
    board = {}
    for fat_name, src in derive_board_copies(tree).items():
        spec = "%s:%s%s/%s" % (commit, rel, BOARD, src)
        try:
            data = git(tree, "cat-file", "blob", spec, binary=True)
        except Unreadable:
            continue  # not in that commit: absent, and compared as such
        board[fat_name] = sha256(data)
    return overlay, board


def derive_licences(generator=GENERATOR):
    """{name: sha256 | by-name} of the files the notices generator writes into
    LICENSES/, by running it: the set is what make-notices.sh does, never a
    list kept here. None when the generator is not beside this script."""
    if not os.path.isfile(generator):
        return None
    with tempfile.TemporaryDirectory() as tmp:
        env = os.path.join(tmp, "offer.env")
        with open(env, "w") as fh:
            # The texts do not depend on these values; the generator wants them.
            fh.write("SOURCE_BASE_ID='buildroot-2000.01.0+br2-00000000+20000101'\n"
                     "SOURCE_BUNDLE_SHA256='%s'\nSOURCE_FIRST_BASE_DATE='2000-01-01'\n"
                     "SOURCE_OFFER_CONTACT='derivation'\n" % ("0" * 64))
        out = os.path.join(tmp, "out")
        try:
            subprocess.run(["sh", generator, "--out", out, "--env", env], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           env=dict(os.environ, SOURCE_DATE_EPOCH="0"))
        except (OSError, subprocess.CalledProcessError) as e:
            raise Unreadable("the notices generator %s did not run: %s" % (generator, getattr(e, "stderr", e)))
        lic = os.path.join(out, "LICENSES")
        found = {}
        for dirpath, _d, names in os.walk(lic):
            for n in names:
                rel = os.path.relpath(os.path.join(dirpath, n), lic).replace(os.sep, "/")
                if rel in LICENCES_BY_NAME:
                    found[rel] = BY_NAME
                else:
                    with open(os.path.join(dirpath, n), "rb") as fh:
                        found[rel] = sha256(fh.read())
    if not found:
        raise Unreadable("the notices generator wrote no LICENSES/")
    missing = set(LICENCES_BY_NAME) - set(found)
    if missing:
        raise Unreadable("the notices generator no longer writes %s, which LICENCES_BY_NAME names"
                         % ", ".join(sorted(missing)))
    return found


# --- the manifest file --------------------------------------------------------

SCALARS = ("format", "base_id", "buildroot_version", "board_commit", "rootfs_stripped_sha256",
           "rootfs_stripped_entries", "fat_base_sha256", "fat_base_files")
MAPS = ("config", "legal_manifest", "source", "kernel", "board_file", "licence")


def empty_manifest():
    return {"scalars": {}, "config": {}, "legal_manifest": {}, "source": {}, "kernel": {},
            "board_file": {}, "licence": {}, "overlay": {}, "archive": {},
            "rootfs_exclude": [], "fat_exclude": []}


def read_manifest(path):
    if not os.path.isfile(path):
        raise Malformed("no source manifest at %s" % path)
    m = empty_manifest()
    lines = []
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if line.strip() and not line.startswith("#"):
                lines.append((n, line, line.split()))
    fmt = [p[1] for _n, _l, p in lines if p[0] == "format" and len(p) == 2]
    if fmt != [FORMAT]:
        raise Malformed("%s is manifest format %s, a different format from the %s this script reads; "
                        "regenerate it from the bundle (`source-manifest.py generate --bundle <tar>`)"
                        % (path, fmt[0] if fmt else "<none>", FORMAT))
    for n, line, p in lines:
        key = p[0]
        if key in SCALARS and len(p) == 2:
            m["scalars"][key] = p[1]
        elif key in MAPS and len(p) == 3:
            m[key][p[1]] = p[2]
        elif key == "overlay" and len(p) in (3, 7):
            m["overlay"][p[1]] = " ".join(p[2:])
        elif key == "archive" and p[1:2] and p[1] in ARCHIVES and len(p) in (3, 5):
            m["archive"][p[1]] = " ".join(p[2:])
        elif key in ("rootfs_exclude", "fat_exclude") and len(p) == 2:
            m[key].append(p[1])
        else:
            raise Malformed("%s:%d: cannot parse %r" % (path, n, line))
    for k in ("base_id", "buildroot_version", "board_commit", "rootfs_stripped_sha256", "fat_base_sha256"):
        if k not in m["scalars"]:
            raise Malformed("%s: no %s" % (path, k))
    if not m["rootfs_exclude"] or not m["fat_exclude"]:
        raise Malformed("%s: no rootfs_exclude or fat_exclude entries" % path)
    if not m["licence"] or not m["board_file"]:
        raise Malformed("%s: no licence or board_file entries" % path)
    for a in ARCHIVES:
        if a not in m["archive"]:
            raise Malformed("%s: no archive %s line (write `archive %s pending` when unmeasured)" % (path, a, a))
    unbound = sorted(set(m["rootfs_exclude"]) - set(m["overlay"]))
    if len(unbound) > 1:
        raise Malformed("%s: overlay paths %s are excluded from the rootfs digest and bound by nothing; "
                        "only the agent path may be" % (path, unbound))
    for name in m["board_file"]:
        if name not in m["fat_exclude"]:
            raise Malformed("%s: board_file %s is not a fat_exclude entry" % (path, name))
    return m


def write_manifest(path, m, provenance):
    s = m["scalars"]
    out = [
        "# Source manifest of the recovery image's GPL base: what the corpus the",
        "# offer names actually IS. Written by notices/source-manifest.py; never",
        "# edit by hand. A rebake that swaps only the agent keeps every value.",
        "# Measured from: " + provenance,
        "format %s" % FORMAT,
        "base_id %s" % s["base_id"],
        "buildroot_version %s" % s["buildroot_version"],
        "board_commit %s" % s.get("board_commit", PENDING),
    ]
    for a in ARCHIVES:
        out.append("archive %s %s" % (a, m["archive"].get(a, PENDING)))
    for key in ("config", "legal_manifest", "kernel", "source"):
        for name in sorted(m[key]):
            out.append("%s %s %s" % (key, name, m[key][name]))
    for p in m["rootfs_exclude"]:
        out.append("rootfs_exclude %s" % p)
    for p in sorted(m["overlay"]):
        out.append("overlay %s %s" % (p, m["overlay"][p]))
    out.append("rootfs_stripped_sha256 %s" % s.get("rootfs_stripped_sha256", PENDING))
    out.append("rootfs_stripped_entries %s" % s.get("rootfs_stripped_entries", PENDING))
    for p in m["fat_exclude"]:
        out.append("fat_exclude %s" % p)
    for name in sorted(m["board_file"]):
        out.append("board_file %s %s" % (name, m["board_file"][name]))
    for name in sorted(m["licence"]):
        out.append("licence %s %s" % (name, m["licence"][name]))
    out.append("fat_base_sha256 %s" % s.get("fat_base_sha256", PENDING))
    out.append("fat_base_files %s" % s.get("fat_base_files", PENDING))
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")


def write_sums(path, m):
    """source-SHA256SUMS: the archives as each install serves them."""
    lines = []
    for a in ARCHIVES:
        name, sha, _size = m["archive"][a].split()
        lines.append("%s  %s" % (sha, name))
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def read_env(env):
    """The single-quoted SOURCE_* assignments of source-offer.env; None when absent."""
    if not env or not os.path.isfile(env):
        return None
    out = {}
    with open(env) as fh:
        for line in fh:
            m = re.match(r"^(SOURCE_[A-Z0-9_]+)='([^']*)'\s*$", line.strip())
            if m:
                out[m.group(1)] = m.group(2)
    if "SOURCE_BASE_ID" not in out:
        raise Unreadable("%s has no SOURCE_BASE_ID" % env)
    return out


def read_env_base(env):
    vals = read_env(env)
    return None if vals is None else vals["SOURCE_BASE_ID"]


def read_sums(path):
    """{name: sha256} of a SHA256SUMS file."""
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                p = line.split()
                if len(p) == 2 and re.fullmatch(r"[0-9a-f]{64}", p[0]):
                    out[p[1].lstrip("*")] = p[0]
    except OSError:
        raise Unreadable("cannot read %s" % path)
    if not out:
        raise Unreadable("%s lists no sha256" % path)
    return out


# --- measuring inputs ---------------------------------------------------------

def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        raise Unreadable("cannot read %s" % path)


def _one(out, pattern_dir, what):
    """The .config of the one build directory out/build/<pattern>."""
    build = os.path.join(out, "build")
    try:
        dirs = sorted(d for d in os.listdir(build) if re.fullmatch(pattern_dir, d))
    except OSError:
        raise Unreadable("no build/ directory in %s" % out)
    found = [os.path.join(build, d, ".config") for d in dirs
             if os.path.isfile(os.path.join(build, d, ".config"))]
    if len(found) != 1:
        raise Unreadable("want exactly one %s .config under %s, found %d" % (what, build, len(found)))
    return _read(found[0])


def measure_outputs(outs, exclude, overlay_paths):
    """Facts from the two Buildroot output trees."""
    m = empty_manifest()
    versions = set()
    for soc in SOCS:
        out = outs[soc]
        cfg = _read(os.path.join(out, ".config"))
        versions.add(buildroot_version(cfg))
        m["config"]["buildroot-" + soc] = sha256(normalise_config(cfg))
        m["config"]["linux-" + soc] = sha256(normalise_config(_one(out, r"linux-(?!headers)[^/]*", "kernel")))
        m["config"]["busybox-" + soc] = sha256(normalise_config(_one(out, r"busybox-[^/]*", "BusyBox")))
        manifest_csv = os.path.join(out, "legal-info", "manifest.csv")
        if not os.path.isfile(manifest_csv):
            raise Unreadable("%s/legal-info is missing; run `make legal-info` (make source-bundle does)" % out)
        m["legal_manifest"][soc] = sha256(_read(manifest_csv))
        m["kernel"][KERNEL_SOC[soc]] = sha256(_read(os.path.join(out, "images", "Image")))
    if len(versions) != 1:
        raise Unreadable("the output trees were built by different Buildroot releases: %s" % sorted(versions))
    m["scalars"]["buildroot_version"] = versions.pop()
    m["source"] = legal_sources(_read(os.path.join(outs["cm5"], "legal-info", "legal-info.sha256")))
    # assemble-boot-img.sh ships the CM5 build's rootfs for both SoCs.
    images = os.path.join(outs["cm5"], "images")
    for name in ("rootfs.cpio.gz", "rootfs.cpio"):
        if os.path.isfile(os.path.join(images, name)):
            entries = cpio_entries(_read(os.path.join(images, name)))
            break
    else:
        raise Unreadable("no rootfs.cpio(.gz) in %s" % images)
    sha, count = stripped_digest(entries, set(exclude))
    m["scalars"]["rootfs_stripped_sha256"], m["scalars"]["rootfs_stripped_entries"] = sha, str(count)
    m["overlay"] = overlay_bindings(entries, overlay_paths)
    return m, {"buildroot_version", "config", "legal_manifest", "source", "kernel", "rootfs", "overlay"}


def measure_fat(files, rootfs_bytes, rootfs_exclude, fat_exclude, overlay_paths, board_names):
    m = empty_manifest()
    for fat_name, soc in FAT_KERNELS.items():
        if fat_name not in files:
            raise Unreadable("the FAT root has no %s" % fat_name)
        m["kernel"][soc] = files[fat_name]
    sha, count = fat_digest(files, fat_exclude)
    m["scalars"]["fat_base_sha256"], m["scalars"]["fat_base_files"] = sha, str(count)
    m["board_file"] = {n: files[n] for n in board_names if n in files}
    # Every file under LICENSES/, at any depth: a name the generator does not
    # write (a kernel, an initramfs, an os_prefix directory) is a mismatch.
    m["licence"] = {p[len(LICENSES_DIR):]: files[p] for p in files if p.startswith(LICENSES_DIR)}
    checked = {"kernel", "fat", "board_file", "licence"}
    if rootfs_bytes is not None:
        entries = cpio_entries(rootfs_bytes)
        sha, count = stripped_digest(entries, set(rootfs_exclude))
        m["scalars"]["rootfs_stripped_sha256"], m["scalars"]["rootfs_stripped_entries"] = sha, str(count)
        m["overlay"] = overlay_bindings(entries, overlay_paths)
        checked |= {"rootfs", "overlay"}
    return m, checked


def measure_fat_dir(root, rootfs_exclude, fat_exclude, overlay_paths, board_names):
    files = fat_dir_files(root)
    cpio = os.path.join(root, "rootfs.cpio.gz")
    if not os.path.isfile(cpio):
        raise Unreadable("the FAT root has no rootfs.cpio.gz")
    return measure_fat(files, _read(cpio), rootfs_exclude, fat_exclude, overlay_paths, board_names)


def measure_rootfs(path, rootfs_exclude, overlay_paths):
    m = empty_manifest()
    entries = cpio_entries(_read(path))
    sha, count = stripped_digest(entries, set(rootfs_exclude))
    m["scalars"]["rootfs_stripped_sha256"], m["scalars"]["rootfs_stripped_entries"] = sha, str(count)
    m["overlay"] = overlay_bindings(entries, overlay_paths)
    return m, {"rootfs", "overlay"}


def measure_archive(kind, path):
    sha, size = file_digest(path)
    m = empty_manifest()
    m["archive"][kind] = "%s %s %d" % (os.path.basename(path), sha, size)
    return m, {"archive"}


class Bundle:
    """The small members of a corresponding-source bundle, by path relative to
    its top directory. A tar is read once, sequentially, keeping only what the
    manifest needs (the sources themselves are hashed by legal-info.sha256),
    plus the names of the external-tree archives it carries and the cpio step
    of the Buildroot release it carries (for the device numbers)."""

    WANT = re.compile(r"^(BASE\.txt|configs/[^/]+|legal-info-cm[45]/(manifest\.csv|legal-info\.sha256)"
                      r"|image-inventory/[^/]+)$")
    BR2_TAR = re.compile(r"^br2-orchestrator-([0-9a-f]{7,40})\.tar$")
    BUILDROOT_TAR = re.compile(r"^buildroot-[^/]+\.tar$")
    CPIO_MK = re.compile(r"(^|/)fs/cpio/cpio\.mk$")

    def __init__(self, path):
        self.files = {}
        self.br2_commits = []
        self.cpio_mk = None
        if os.path.isdir(path):
            for dirpath, _d, names in os.walk(path):
                for n in names:
                    full = os.path.join(dirpath, n)
                    rel = os.path.relpath(full, path).replace(os.sep, "/")
                    if self.WANT.match(rel):
                        self.files[rel] = _read(full)
                    self._note(rel, lambda full=full: open(full, "rb"))
        elif os.path.isfile(path):
            try:
                with tarfile.open(path, "r:*") as tf:
                    for ti in tf:
                        rel = ti.name.split("/", 1)[1] if "/" in ti.name else ""
                        # "._name": the AppleDouble metadata a macOS tar adds.
                        if rel.rsplit("/", 1)[-1].startswith("._") or not ti.isfile():
                            continue
                        if self.WANT.match(rel):
                            self.files[rel] = tf.extractfile(ti).read()
                        self._note(rel, lambda ti=ti, tf=tf: tf.extractfile(ti))
            except (tarfile.TarError, OSError) as e:
                raise Unreadable("cannot read bundle %s: %s" % (path, e))
        else:
            raise Unreadable("no bundle at %s" % path)
        if "BASE.txt" not in self.files:
            raise Unreadable("%s is not a corresponding-source bundle (no BASE.txt)" % path)

    def _note(self, rel, opener):
        m = self.BR2_TAR.match(rel)
        if m:
            self.br2_commits.append(m.group(1))
        elif self.BUILDROOT_TAR.match(rel):
            try:
                with tarfile.open(fileobj=opener(), mode="r:") as nested:
                    for ni in nested:
                        if ni.isfile() and self.CPIO_MK.search(ni.name):
                            self.cpio_mk = nested.extractfile(ni).read().decode("utf-8", "replace")
                            break
            except (tarfile.TarError, OSError) as e:
                raise Unreadable("cannot read the Buildroot archive %s in the bundle: %s" % (rel, e))

    def get(self, rel):
        if rel not in self.files:
            raise Unreadable("the bundle has no %s" % rel)
        return self.files[rel]

    def inventory(self, suffix):
        return {k: v for k, v in self.files.items()
                if k.startswith("image-inventory/") and k.endswith(suffix)}


def _agree(values, what):
    distinct = set(values.values())
    if len(distinct) > 1:
        detail = "; ".join("%s=%s" % (k, v) for k, v in sorted(values.items()))
        raise Unreadable("the bundle's %s disagree with each other: %s" % (what, detail))
    return distinct.pop()


def measure_bundle(path, rootfs_exclude, fat_exclude, overlay_paths, board_names):
    b = Bundle(path)
    m = empty_manifest()
    base = re.search(rb"^Base id: *(\S+)", b.get("BASE.txt"), re.M)
    if not base:
        raise Unreadable("BASE.txt names no base id")
    m["scalars"]["base_id"] = base.group(1).decode()
    versions = set()
    for soc in SOCS:
        cfg = b.get("configs/buildroot-out-%s.config" % soc)
        versions.add(buildroot_version(cfg))
        m["config"]["buildroot-" + soc] = sha256(normalise_config(cfg))
        linux = [k for k in b.files if re.fullmatch(r"configs/linux-%s(-[^/]*)?\.config" % soc, k)]
        if len(linux) != 1:
            raise Unreadable("want one configs/linux-%s*.config in the bundle, found %d" % (soc, len(linux)))
        m["config"]["linux-" + soc] = sha256(normalise_config(b.get(linux[0])))
        m["config"]["busybox-" + soc] = sha256(normalise_config(b.get("configs/busybox-%s.config" % soc)))
        m["legal_manifest"][soc] = sha256(b.get("legal-info-%s/manifest.csv" % soc))
    if len(versions) != 1:
        raise Unreadable("the bundle's .configs name different Buildroot releases: %s" % sorted(versions))
    m["scalars"]["buildroot_version"] = versions.pop()
    m["source"] = legal_sources(b.get("legal-info-cm5/legal-info.sha256"))
    checked = {"base_id", "buildroot_version", "config", "legal_manifest", "source"}
    if os.path.isfile(path):
        sha, size = file_digest(path)
        m["archive"]["bundle"] = "%s %s %d" % (os.path.basename(path), sha, size)
        checked.add("archive")

    # Optional: an inventory of the build outputs and of served images. Every
    # listing must agree, which is itself the claim that the served images are
    # the base apart from the overlay. The CM4 build's rootfs is compiled for
    # another CPU and never shipped (assemble-boot-img.sh takes CM5's for both
    # SoCs), so its listing is not a claim about any image. The overlay files
    # are bound from the SERVED images' listings (the build-output listing
    # carries the overlay of the build, which a later image may not), and
    # from the build's only when the bundle inventories no served image.
    devices = devices_from_cpio_mk(b.cpio_mk) if b.cpio_mk else {}
    listings = {k: listing_entries(v.decode("utf-8", "replace"), devices)
                for k, v in b.inventory(".members").items() if "out-cm4" not in k}
    if listings:
        digests = {k: "%s/%s" % stripped_digest(v, set(rootfs_exclude)) for k, v in listings.items()}
        sha, count = _agree(digests, "rootfs listings (stripped)").split("/")
        m["scalars"]["rootfs_stripped_sha256"], m["scalars"]["rootfs_stripped_entries"] = sha, count
        served = {k: v for k, v in listings.items() if not k.startswith("image-inventory/rootfs-out-")} or listings
        for p in overlay_paths:
            values = {k: overlay_value(v[p]) for k, v in served.items() if p in v}
            if len(values) == len(served):
                m["overlay"][p] = _agree(values, "copies of overlay file %s" % p)
        checked |= {"rootfs", "overlay"}
    fats = {k: fat_list_files(v.decode("utf-8", "replace")) for k, v in b.inventory(".sha256").items()
            if "fat" in k.rsplit("/", 1)[1]}
    if fats:
        digests = {k: "%s/%s" % fat_digest(v, fat_exclude) for k, v in fats.items()}
        sha, count = _agree(digests, "FAT inventories (base files)").split("/")
        m["scalars"]["fat_base_sha256"], m["scalars"]["fat_base_files"] = sha, count
        for soc in KERNEL_SOC.values():
            kernels = {k: v[n] for k, v in fats.items() for n, s in FAT_KERNELS.items() if s == soc and n in v}
            if kernels:
                m["kernel"][soc] = _agree(kernels, "%s kernels" % soc)
        for name in board_names:
            copies = {k: v[name] for k, v in fats.items() if name in v}
            if len(copies) == len(fats):
                m["board_file"][name] = _agree(copies, "copies of %s" % name)
        checked |= {"fat", "kernel", "board_file"}
    return m, checked, b


# --- comparing ------------------------------------------------------------------

FIELD_KEYS = {
    "base_id": ["base_id"],
    "buildroot_version": ["buildroot_version"],
    "rootfs": ["rootfs_stripped_sha256", "rootfs_stripped_entries"],
    "fat": ["fat_base_sha256", "fat_base_files"],
}
# Fields an input measures only in part: an input that measures the bundle
# says nothing about the toolchain archive.
PARTIAL_FIELDS = {"archive"}


def compare(want, got, checked, label):
    """Mismatch lines and pending names for the fields `checked` covers."""
    bad, pending = [], []
    for field in sorted(checked):
        if field in FIELD_KEYS:
            for k in FIELD_KEYS[field]:
                w, g = want["scalars"].get(k, PENDING), got["scalars"].get(k)
                if w == PENDING:
                    pending.append(k)
                elif g != w:
                    bad.append("%s: %s is %s, the manifest says %s" % (label, k, g, w))
            continue
        w, g = want[field], got[field]
        names = set(g) if field in PARTIAL_FIELDS else set(w) | set(g)
        for name in sorted(names):
            if name not in g:
                bad.append("%s: %s %s is absent, the manifest records %s" % (label, field, name, w[name]))
            elif name not in w:
                bad.append("%s: %s %s=%s is not in the manifest" % (label, field, name, g[name]))
            elif w[name] == PENDING:
                pending.append("%s %s" % (field, name))
            elif w[name] == BY_NAME:
                continue
            elif w[name] != g[name]:
                bad.append("%s: %s %s is %s, the manifest says %s" % (label, field, name, g[name], w[name]))
    return bad, pending


def default_tree():
    """The tree holding this script, when it is the boot-image checkout itself.
    A copy of the scripts without the overlay beside them (a serving host's
    kit, say) uses what the manifest records."""
    tree = os.path.dirname(os.path.dirname(BOARD_DIR))
    if not os.path.isdir(os.path.join(tree, OVERLAY)):
        return None
    try:
        subprocess.run(["git", "-C", tree, "rev-parse", "--verify", "HEAD"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return tree
    except (OSError, subprocess.CalledProcessError):
        return None


def measurements(a, want):
    """(label, thunk) per input named on the command line, measured against the
    exclusions and bound names `want` records."""
    rexcl, fexcl = want["rootfs_exclude"], want["fat_exclude"]
    opaths, bnames = sorted(want["overlay"]), sorted(want["board_file"])
    runs = []
    if a.out_cm4:
        runs.append(("build outputs", lambda: measure_outputs({"cm4": a.out_cm4, "cm5": a.out_cm5}, rexcl, opaths)))
    if a.image:
        def image():
            with tempfile.TemporaryDirectory() as tmp:
                copy_fat_root(a.image, tmp)
                return measure_fat_dir(tmp, rexcl, fexcl, opaths, bnames)
        runs.append(("image", image))
    if a.fat_dir:
        runs.append(("FAT root", lambda: measure_fat_dir(a.fat_dir, rexcl, fexcl, opaths, bnames)))
    if a.rootfs:
        runs.append(("rootfs", lambda: measure_rootfs(a.rootfs, rexcl, opaths)))
    if a.bundle:
        runs.append(("bundle", lambda: measure_bundle(a.bundle, rexcl, fexcl, opaths, bnames)[:2]))
    if a.toolchain:
        runs.append(("toolchain", lambda: measure_archive("toolchain", a.toolchain)))
    return runs


def manifest_lines(m):
    s = m["scalars"]
    out = ["%s %s" % (k, s[k]) for k in SCALARS if k in s]
    for a in ARCHIVES:
        if a in m["archive"]:
            out.append("archive %s %s" % (a, m["archive"][a]))
    for key in ("config", "legal_manifest", "kernel", "source", "overlay", "board_file", "licence"):
        out += ["%s %s %s" % (key, n, m[key][n]) for n in sorted(m[key])]
    return out


def check_tree(tree, want):
    """What the tree derives must be what the manifest records: the
    exclusions, the overlay and board-file sets, and -- byte for byte -- the
    overlay and board files of the tree at board_commit."""
    bad = []
    rexcl, fexcl = derive_rootfs_exclude(tree), derive_fat_exclude(tree)
    if rexcl != sorted(want["rootfs_exclude"]):
        bad.append("tree: the overlay installs %s, the manifest excludes %s"
                   % (rexcl, sorted(want["rootfs_exclude"])))
    if fexcl != sorted(want["fat_exclude"]):
        bad.append("tree: the FAT exclusions derive to %s, the manifest has %s"
                   % (fexcl, sorted(want["fat_exclude"])))
    tracked = derive_overlay_tracked(tree)
    if tracked != sorted(want["overlay"]):
        bad.append("tree: the overlay tracks %s, the manifest binds %s" % (tracked, sorted(want["overlay"])))
    boards = sorted(derive_board_copies(tree))
    if boards != sorted(want["board_file"]):
        bad.append("tree: assemble-boot-img.sh copies %s, the manifest binds %s" % (boards, sorted(want["board_file"])))
    commit = want["scalars"]["board_commit"]
    if commit == PENDING:
        return bad
    try:
        full = resolve_commit(tree, commit)
    except Unreadable:
        full = ""
    if not full:
        bad.append("tree: board_commit %s is not a commit of this tree" % commit)
        return bad
    overlay, board = board_blobs(tree, full)
    for p, v in sorted(want["overlay"].items()):
        if v == PENDING:
            continue
        if overlay.get(p) != v:
            bad.append("tree: overlay %s is %s at board_commit, the manifest says %s" % (p, overlay.get(p), v))
    for n, v in sorted(want["board_file"].items()):
        if v != PENDING and board.get(n) != v:
            bad.append("tree: board_file %s is %s at board_commit, the manifest says %s" % (n, board.get(n), v))
    return bad


def check_licences(want, generator=GENERATOR):
    derived = derive_licences(generator)
    if derived is None:
        return [], False
    bad = []
    for name in sorted(set(derived) | set(want["licence"])):
        w, d = want["licence"].get(name), derived.get(name)
        if w == PENDING:
            continue  # reported as pending by the caller
        if w is None:
            bad.append("generator: make-notices.sh writes LICENSES/%s, the manifest does not record it" % name)
        elif d is None:
            bad.append("generator: the manifest records LICENSES/%s, make-notices.sh does not write it" % name)
        elif w != d:
            bad.append("generator: LICENSES/%s is %s from make-notices.sh, the manifest says %s" % (name, d, w))
    return bad, True


def check_env_archives(env_vals, want):
    bad = []
    expect = {"bundle": ("recovery-image-source-%s.tar" % env_vals["SOURCE_BASE_ID"],
                         env_vals.get("SOURCE_BUNDLE_SHA256"))}
    if env_vals.get("SOURCE_TOOLCHAIN_FILE"):
        expect["toolchain"] = (env_vals["SOURCE_TOOLCHAIN_FILE"], env_vals.get("SOURCE_TOOLCHAIN_SHA256"))
    for kind, (name, sha) in expect.items():
        rec = want["archive"].get(kind, PENDING)
        if rec == PENDING or not sha:
            continue
        rname, rsha, _ = rec.split()
        if (rname, rsha) != (name, sha):
            bad.append("source-offer.env names %s %s %s, the manifest records %s %s" % (kind, name, sha, rname, rsha))
    return bad


def check_sums(sums_path, want):
    sums = read_sums(sums_path)
    bad = []
    for kind in ARCHIVES:
        rec = want["archive"].get(kind, PENDING)
        if rec == PENDING:
            continue
        name, sha, _ = rec.split()
        if sums.get(name) != sha:
            bad.append("%s lists %s as %s, the manifest records %s" % (os.path.basename(sums_path), name,
                                                                       sums.get(name, "<absent>"), sha))
    return bad


def find_board_commit(tree, candidates, overlay, board):
    """The one candidate commit whose overlay and board files are, byte for
    byte, what the base's image carries."""
    matches = []
    for cand in candidates:
        try:
            full = resolve_commit(tree, cand)
        except Unreadable:
            continue
        if not full or full in matches:
            continue
        o, b = board_blobs(tree, full)
        if all(o.get(p) == v for p, v in overlay.items()) and all(b.get(n) == v for n, v in board.items()):
            matches.append(full)
    if len(matches) != 1:
        raise Unreadable("%d of the candidate commits %s carry the overlay and board files the base's image "
                         "carries; want exactly one" % (len(matches), candidates))
    return matches[0]


def generate(a, manifest_path, env, tree):
    if tree is None:
        raise Unreadable("generate needs --tree: the exclusions and board files are derived from the tree")
    rexcl, fexcl = derive_rootfs_exclude(tree), derive_fat_exclude(tree)
    tracked, boards = derive_overlay_tracked(tree), sorted(derive_board_copies(tree))
    licences = derive_licences()
    if licences is None:
        raise Unreadable("generate needs the notices generator beside this script (%s)" % GENERATOR)
    env_vals = read_env(env)
    archive = {}
    if a.bundle and not a.out_cm4:
        m, _checked, bundle = measure_bundle(a.bundle, rexcl, fexcl, tracked, boards)
        provenance = "the corresponding-source bundle %s" % os.path.basename(a.bundle.rstrip("/"))
        missing = [p for p in tracked if p not in m["overlay"]] + [n for n in boards if n not in m["board_file"]]
        if missing:
            raise Unreadable("the bundle's inventory does not carry %s; it cannot bind the board files" % missing)
        base_commit = m["scalars"]["base_id"].split("+br2-", 1)[1].split("+", 1)[0]
        m["scalars"]["board_commit"] = find_board_commit(tree, [base_commit] + bundle.br2_commits,
                                                         m["overlay"], m["board_file"])
        archive.update(m["archive"])
    elif a.out_cm4:
        m, _ = measure_outputs({"cm4": a.out_cm4, "cm5": a.out_cm5}, rexcl, tracked)
        if env_vals is None:
            raise Unreadable("generate from build outputs needs source-offer.env for the base id")
        m["scalars"]["base_id"] = env_vals["SOURCE_BASE_ID"]
        provenance = "the Buildroot output trees"
        head = resolve_commit(tree, "HEAD")
        overlay, board = board_blobs(tree, head)
        for p in tracked:
            if m["overlay"].get(p) != overlay.get(p):
                raise Unreadable("the build's %s is not the tree's file (%s vs %s)" % (p, m["overlay"].get(p), overlay.get(p)))
        m["scalars"]["board_commit"] = head
        m["board_file"] = board
        if a.image or a.fat_dir:
            with tempfile.TemporaryDirectory() as tmp:
                root = a.fat_dir
                if a.image:
                    copy_fat_root(a.image, tmp)
                    root = tmp
                fm, _ = measure_fat_dir(root, rexcl, fexcl, tracked, boards)
            if fm["kernel"] != m["kernel"] or \
                    fm["scalars"]["rootfs_stripped_sha256"] != m["scalars"]["rootfs_stripped_sha256"] or \
                    fm["overlay"] != m["overlay"]:
                raise Unreadable("the image's kernels or rootfs are not the build outputs'")
            if fm["board_file"] != m["board_file"]:
                raise Unreadable("the image's board files are not the tree's: %s vs %s" % (fm["board_file"], m["board_file"]))
            for k in FIELD_KEYS["fat"]:
                m["scalars"][k] = fm["scalars"][k]
            provenance += " and the image assembled from them"
        if a.bundle:
            if not os.path.isfile(a.bundle):
                raise Unreadable("beside build outputs --bundle names the bundle TAR, to record its sha256 and size")
            archive.update(measure_archive("bundle", a.bundle)[0]["archive"])
    else:
        sys.stderr.write("source-manifest: generate needs --out-cm4/--out-cm5 or --bundle\n")
        return 2
    if a.toolchain:
        archive.update(measure_archive("toolchain", a.toolchain)[0]["archive"])
    m["archive"] = {k: archive.get(k, PENDING) for k in ARCHIVES}
    if env_vals is not None and env_vals["SOURCE_BASE_ID"] != m["scalars"]["base_id"]:
        raise Unreadable("measured base %s, but %s names %s" % (m["scalars"]["base_id"], env, env_vals["SOURCE_BASE_ID"]))
    m["rootfs_exclude"], m["fat_exclude"], m["licence"] = rexcl, fexcl, licences
    if env_vals is not None:
        bad = check_env_archives(env_vals, m)
        if bad:
            raise Unreadable("; ".join(bad))
    write_manifest(manifest_path, m, provenance)
    if all(m["archive"][k] != PENDING for k in ARCHIVES):
        write_sums(os.path.join(os.path.dirname(os.path.abspath(manifest_path)), SUMS_NAME), m)
    pend = [k for k in ("rootfs_stripped_sha256", "fat_base_sha256") if m["scalars"].get(k, PENDING) == PENDING]
    pend += ["archive " + k for k in ARCHIVES if m["archive"][k] == PENDING]
    print("source-manifest: wrote %s for base %s%s" % (manifest_path, m["scalars"]["base_id"],
          ("; pending: " + ", ".join(pend)) if pend else ""))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("command", nargs="?")
    for opt in ("--manifest", "--env", "--tree", "--out-cm4", "--out-cm5", "--image",
                "--fat-dir", "--rootfs", "--bundle", "--toolchain", "--sums"):
        ap.add_argument(opt)
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args(argv)
    if a.help or a.command not in ("generate", "check", "show", "measure"):
        sys.stderr.write(__doc__)
        return 2
    # The manifest and the env sit side by side: naming one names the other.
    if a.manifest:
        manifest_path = a.manifest
    elif a.env:
        manifest_path = os.path.join(os.path.dirname(os.path.abspath(a.env)), "source-manifest")
    else:
        manifest_path = DEFAULT_MANIFEST
    env = a.env or os.path.join(os.path.dirname(os.path.abspath(manifest_path)), "source-offer.env")
    if bool(a.out_cm4) != bool(a.out_cm5):
        sys.stderr.write("source-manifest: --out-cm4 and --out-cm5 go together\n")
        return 2
    tree = a.tree or default_tree()

    if a.command == "generate":
        return generate(a, manifest_path, env, tree)

    if a.command == "measure":
        if tree is not None:
            want = empty_manifest()
            want["rootfs_exclude"], want["fat_exclude"] = derive_rootfs_exclude(tree), derive_fat_exclude(tree)
            want["overlay"] = {p: PENDING for p in derive_overlay_tracked(tree)}
            want["board_file"] = {n: PENDING for n in derive_board_copies(tree)}
        else:
            want = read_manifest(manifest_path)
        runs = measurements(a, want)
        if not runs:
            sys.stderr.write("source-manifest: measure needs an input\n")
            return 2
        for label, run in runs:
            got, _ = run()
            print("# measured from the %s" % label)
            print("\n".join(manifest_lines(got)))
        print("\n".join("rootfs_exclude %s" % p for p in want["rootfs_exclude"]))
        print("\n".join("fat_exclude %s" % p for p in want["fat_exclude"]))
        return 0

    want = read_manifest(manifest_path)
    bad, pending, did = [], [], []
    env_vals = read_env(env)
    if env_vals is not None:
        did.append("base id and archives against %s" % os.path.basename(env))
        if env_vals["SOURCE_BASE_ID"] != want["scalars"]["base_id"]:
            bad.append("source-offer.env names base %s, the manifest is for %s"
                       % (env_vals["SOURCE_BASE_ID"], want["scalars"]["base_id"]))
        bad += check_env_archives(env_vals, want)
    sums = a.sums or os.path.join(os.path.dirname(os.path.abspath(manifest_path)), SUMS_NAME)
    if a.sums or os.path.isfile(sums):
        did.append("archives against %s" % os.path.basename(sums))
        bad += check_sums(sums, want)
    if tree is not None:
        did.append("exclusions and board files derived from the tree")
        bad += check_tree(tree, want)
        # Without a board_commit nothing binds the overlay and board files to
        # the tree, so with a tree to compare against it is pending for every
        # command, never a silent pass.
        if want["scalars"]["board_commit"] == PENDING:
            pending.append("board_commit")
    lbad, ran = check_licences(want)
    if ran:
        did.append("licence set derived from make-notices.sh")
        bad += lbad

    if a.command == "show":
        runs = []
        pending = [k for k in ("rootfs_stripped_sha256", "fat_base_sha256", "board_commit")
                   if want["scalars"][k] == PENDING]
        pending += ["archive " + k for k in ARCHIVES if want["archive"][k] == PENDING]
        for field in ("overlay", "board_file", "licence"):
            pending += ["%s %s" % (field, n) for n, v in sorted(want[field].items()) if v == PENDING]
    else:
        runs = measurements(a, want)
        if not runs:
            sys.stderr.write("source-manifest: check needs something to measure "
                             "(--out-cm4/--out-cm5, --image, --fat-dir, --rootfs, --bundle or --toolchain)\n")
            return 2
    for label, run in runs:
        got, checked = run()
        b, p = compare(want, got, checked, label)
        bad += b
        pending += ["%s (%s)" % (x, label) for x in p]
        did.append("%s: %s" % (label, ", ".join(sorted(checked))))
    for line in bad:
        print("source-manifest: MISMATCH " + line)
    for p in pending:
        print("source-manifest: PENDING %s -- not measured yet; the first build of the base "
              "fills it in with `source-manifest.py generate`" % p)
    if bad:
        print("source-manifest: %d mismatch(es) against base %s" % (len(bad), want["scalars"]["base_id"]))
        return 1
    if pending:
        print("source-manifest: no mismatch, but %d field(s) pending: NOT a pass" % len(pending))
        return 3
    print("source-manifest: ok, base %s (%s; %d configs, %d sources, %d overlay files bound, %d licence files)"
          % (want["scalars"]["base_id"], "; ".join(did) or "manifest well-formed",
             len(want["config"]), len(want["source"]), len(want["overlay"]), len(want["licence"])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Malformed as e:
        print("source-manifest: %s" % e, file=sys.stderr)
        sys.exit(1)
    except Unreadable as e:
        print("source-manifest: %s" % e, file=sys.stderr)
        sys.exit(2)
