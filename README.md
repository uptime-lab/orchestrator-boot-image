# orchestrator-boot-image

The Buildroot external tree (`BR2_EXTERNAL`) that builds the Orchestrator
recovery image: a single `boot.img` the Raspberry Pi bootloader fetches over
HTTP and runs entirely in RAM, carrying the Orchestrator agent so a node can be
adopted and provisioned. One image serves Compute Module 4 and 5 class boards
(BCM2711 and BCM2712), one rootfs, two kernels.

- **Build instructions, layout, firmware configuration**: `br2-orchestrator/README.md`.
- **Operator entry points** (tests, notices, the source bundle): `make help`.

## The image is built, not committed

Nothing under this tree is a build artifact. `boot.img` and `boot.sig` are
produced by `br2-orchestrator/board/orchestrator/assemble-boot-img.sh` from two
Buildroot output trees and signed on the host that serves them; `net_install/`
is where a serving host keeps them and is ignored by git. The agent binary that
the rootfs overlay carries is a release artifact of the agent and ignored by
git as well: `make fetch-agent VERSION=<version>` downloads that release's
package from the agent's public source mirror
(`https://github.com/uptime-lab/orchestrator-agent`), verifies its detached
signature against the public keys in
`br2-orchestrator/board/orchestrator/agent-keys/`, and places the binary in the
overlay. A fork that signs its own agents replaces those keys.

## Licence

The files of this external tree — the init scripts and the firmware
configuration that go into the image, the delta fragments, the build and
operator scripts — are licensed under the **GNU General Public License,
version 2 or (at your option) any later version**; see `LICENSE`.

The image the tree builds is an aggregate. It carries programs under their own
licences, declared by their Buildroot packages and listed by `make legal-info`:
the Linux kernel (GPL-2.0), BusyBox (GPL-2.0, with the bzip2 licence for its
bzip2 code), util-linux (GPL-2.0+, LGPL-2.1+ libraries, and BSD-4-Clause,
BSD-3-Clause, BSD-2-Clause, ISC and MIT parts), kmod (GPL-2.0+ tools,
LGPL-2.1+ library), xz (public domain, 0BSD, GPL-2.0+, GPL-3.0+ and
LGPL-2.1+ parts), e2fsprogs (GPL-2.0, MIT-like with an advertising clause
for libss and libet), GNU parted (GPL-3.0+), the C library and runtime of
the Arm GNU Toolchain (LGPL/GPL with exception), the Raspberry Pi firmware
under Broadcom's binary redistribution licence (`LICENCE.broadcom`), and the
Orchestrator agent under the Apache License 2.0; the per-package licences
are those `notices/components-buildroot.tsv` records from `legal-info`.
This tree defines no Buildroot packages of its own (`br2-orchestrator/Config.in`
and `external.mk` are empty hooks), so there are no `<PKG>_LICENSE` declarations
to add here. The rootfs overlay's items that are not this tree's own source
-- the agent release, the prebuilt `vcgencmd` (BSD-3-Clause) and the CA
certificate bundle (`etc/ssl/certs/ca-certificates.crt`, MPL-2.0 data from
Mozilla's CA store) -- are named, with their origin, in the image's own notice
instead (`br2-orchestrator/board/orchestrator/notices/components-overlay.tsv`).

## Notices and the corresponding source

Every image carries its notices in the root of its FAT filesystem, so they
travel with the HTTP-boot fetch and with every SD provisioning bundle, which is
extracted from that same root:

- `LICENSES/` — the GPL-2.0, GPL-3.0, LGPL-2.1 and Apache-2.0 texts, the
  firmware's `LICENCE.broadcom`, the agent's Apache `NOTICE`, and
  `THIRD-PARTY-NOTICES.txt` with the BSD, MIT, ISC and 0BSD notices the
  packages and the prebuilt `vcgencmd` ship (BSD wants them WITH the binary,
  not only in the offered source), and `THIRD-PARTY-NOTICES-orchestrator-agent.md`,
  the notices of the Go modules compiled into the agent (generated in the
  agent's source, `https://github.com/uptime-lab/orchestrator-agent`, and
  shipped in its release package; `make fetch-agent FETCH_FLAGS=--write-notices`
  copies the baked release's file, and a rebake passes it).
- `SOURCE-OFFER.txt` — the written offer of corresponding source: the
  component list, the **base id** of the GPL corpus, the name and sha256 of the
  bundle, and where an install serves it:
  `https://<server>/source/recovery-image-source-<base id>.tar`, tokenless —
  once its operator has placed the bundle in the directory `SOURCE_OFFER_DIR`
  names. The community compose leaves that variable empty; the route then
  answers that the install serves no offer.

The facts the offer names live in ONE file,
`br2-orchestrator/board/orchestrator/source-offer.env`. `assemble-boot-img.sh`
refuses to build unless that base names what was BUILT — the Buildroot release
in both output trees' `.config` and the commit of this tree
(`notices/check-built-base.sh`) — then writes the notices and refuses an image
whose offer does not name the base; `scripts/inject-notices.sh` adds the same files to an existing image
for a rebake (agent-only; the base does not change); `scripts/check-notices.sh`
is the assertion to run on an image before signing it.

A base id is a label, and comparing labels proves only that the offer was
generated from `source-offer.env`. What the base IS lives beside it in
`br2-orchestrator/board/orchestrator/source-manifest`, written by
`notices/source-manifest.py generate` from the build the bundle is cut from:
the normalised Buildroot, kernel and BusyBox `.config`s of both SoC builds,
`legal-info`'s package manifests and the sha256 of every target source archive
and patch it saved, both kernels, a digest of the rootfs (every entry's path,
type, mode, owner, size and content, sorted, so cpio order and mtimes do not
count, and a device node's major and minor numbers do), and a digest of the
rest of the FAT root (device trees, overlays, GPU firmware). The rootfs digest
leaves out the paths the Orchestrator overlay installs, derived from
`board/orchestrator/rootfs-overlay` and `.gitignore` rather than typed, and the
manifest binds each TRACKED overlay file byte for byte instead (`overlay`
lines: kind, mode, owner, size, sha256), as the tree has it at `board_commit`,
the commit whose board files the base's image carries; only the gitignored
agent is free, because an agent-only rebake swaps exactly that. `config.txt`
and `cmdline.txt` (derived from `assemble-boot-img.sh`, which copies them
verbatim) are bound the same way (`board_file`), so a `kernel=`,
`initramfs`, `os_prefix=`, `init=`, `rdinit=` or `root=` that is not the
base's is a mismatch. `LICENSES/` must be exactly the set
`notices/make-notices.sh` writes, derived by running it: the licence texts
are bound by sha256 and only the two agent notices
(`NOTICE-orchestrator-agent.txt`, `THIRD-PARTY-NOTICES-orchestrator-agent.md`)
by name, since they follow the agent release; any other file there, a kernel
or an initramfs among them, is refused. The manifest also records the
bundle's and the toolchain snapshot's name, sha256 and size (`archive`), equal
to `source-offer.env` and to `source-SHA256SUMS` beside it, the exact file
every install serves as `/source/SHA256SUMS`. `check-built-base.sh` compares a
build with the manifest before the assemble step writes an offer (and refuses
an uncommitted manifest unless `--allow-uncommitted-manifest`, the
generator's first run for a new base; `ALLOW_UNCOMMITTED_MANIFEST=1` for the
assemble script), `check-notices.sh` compares an image with it before a
rebake is signed, and `source-manifest.py check --bundle <tar> --toolchain
<file>` compares the archives with it. A field still `pending` (measured by no
build yet) fails every check that needs it with exit 3: pending is not a
pass, and a manifest of another format is refused, never read.

What stays a manual acceptance: that the bundle's sources ARE the sources
(`legal-info` hashed them, the manifest binds those hashes, nobody rebuilds
from the bundle to compare binaries).

`.publication-guard-allow` at the root lists the two shape-checker findings
that have no line to carry an inline marker (the upstream notices file and
the prebuilt `vcgencmd`), each with its reason.

A **base** is one clean Buildroot build: `buildroot-<release>+br2-<commit of
this repository>+<YYYYMMDD>`. An agent rebake swaps only the agent inside the
rootfs and keeps the base. A clean rebuild is a new base, and the order of
its steps is fixed by what each one names (the full recipe, commands
included, is "Build" in `br2-orchestrator/README.md`):

1. Build both SoCs, run `make legal-info` in both output trees, and refresh
   the two files derived from it, `notices/components-buildroot.tsv`
   (`notices/make-notices.sh --dump-components <out-cm5>/legal-info`) and
   `notices/LICENSES/THIRD-PARTY-NOTICES.txt` (`--dump-third-party`). They
   are not inputs of the Buildroot build, and the image carries the
   committed copy, so they are committed now: this is the **build commit**.
2. Cut the bundle from the build commit (`make source-bundle
   BUNDLE_FLAGS="--skip-legal-info --write-env"`), which records the base id
   and the bundle's sha256 in `source-offer.env`; put the toolchain
   snapshot's name and sha256 there by hand.
3. `make source-manifest` (with `BUNDLE=` and `TOOLCHAIN=`), assemble the
   image, and `make source-manifest` again with `IMG=` for the FAT-root
   digest.
4. Commit `source-offer.env`, `source-manifest` and `source-SHA256SUMS`, and
   nothing else, on top of the build commit: the **records commit**.

The bundle is `git archive` of this repository at the build commit (the
external tree, `scripts/`, the `Makefile`, the READMEs and `LICENSE`), plus
Buildroot at its release, `legal-info`, the configurations and the firmware
licence. Whoever builds and distributes a base sets `SOURCE_OFFER_CONTACT` in
`source-offer.env` to their own contact first: the written offer is theirs.
Images built before the first base (2026-07-28) predate this tree and cannot
be reconstructed; the offer says so.

## Publishing a base

A base is two commits, and both must stay in the history that is published:

- the **build commit** `S`, which the base id (`br2-<S>`) and the manifest's
  `board_commit` name, and whose tree the bundle archives; and
- the **records commit** `R` on top of it, which changes only
  `source-offer.env`, `source-manifest` and `source-SHA256SUMS`.

`R` cannot be folded into `S`: the records carry `S`'s id, which a commit
cannot contain about itself. Squashing the two, rebasing them or rewriting
the history under them gives `S` a new id that no record names, so
`check-built-base.sh` refuses to assemble from that history and
`source-manifest.py` reports `board_commit` as not a commit of the tree. A
history that has been rewritten needs a clean rebuild from the rewritten
commit, which is a new base. Later commits may follow `R`, but assembling an
image of that base needs a checkout in which nothing under `br2-orchestrator/`
has changed since `S` except those three records: any other change there
means HEAD is no longer what was built. (The check reads that directory,
which holds everything the image consumes; the bundle archives the whole
repository at `S`.)
