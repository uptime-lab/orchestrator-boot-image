# Orchestrator HTTP-boot bootstrap image (buildroot)

Builds a single `boot.img` that the Raspberry Pi bootloader fetches over HTTP and
runs entirely in RAM. The image contains the Orchestrator agent, which connects
back to the platform so the node can be adopted and provisioned (full OS → NVMe).

Supports **both CM4 (BCM2711) and CM5 (BCM2712)**: one rootfs, two kernels.

## Layout

```
br2-orchestrator/
  external.desc / external.mk / Config.in   # br2-external definition
  configs/
    cm4-delta.fragment                       # deltas over raspberrypicm4io_64_defconfig
    cm5-delta.fragment                       # deltas over raspberrypicm5io_defconfig
  board/orchestrator/
    rootfs-overlay/usr/bin/orchestrator-agent  # the released arm64 agent (gitignored;
                                               # scripts/fetch-agent.sh puts it there)
    agent-keys/                                # public keys an agent release is verified against
    rootfs-overlay/etc/init.d/S99agent         # BusyBox init: starts the agent
    config.txt / cmdline.txt                   # firmware config for the FAT image
    assemble-boot-img.sh                       # combines both builds → boot.img
    source-offer.env                           # base id + bundle facts the offer names
    source-manifest                            # what that base IS: configs, sources,
                                               # kernels, rootfs and FAT digests
    notices/                                   # licence texts, agent NOTICE, the
                                               # generator for LICENSES/ + SOURCE-OFFER.txt,
                                               # source-manifest.py (writes/checks the manifest)
    tests/                                     # shell tests; never shipped
../scripts/
  inject-notices.sh / check-notices.sh         # notices into / asserted on an existing image
  make-source-bundle.sh                        # the corresponding-source bundle
  fetch-agent.sh                               # a released, signature-verified agent into the overlay
```

The tree is licensed GPL-2.0-or-later and defines no Buildroot packages; the
licence map of the image and how the corresponding source is offered are in
the repository's top-level `README.md`.

## Build

### Host

- **An aarch64 (arm64) Linux host.** The stock CM4/CM5 defconfigs build with
  Buildroot's prebuilt Arm GNU Toolchain (`toolchain-external-arm-aarch64`),
  and Buildroot downloads the toolchain binary made for the build host's
  architecture. The committed base records the aarch64-hosted one
  (`arm-gnu-toolchain-14.2.rel1-aarch64-aarch64-none-linux-gnu.tar.xz`, a
  `source` line of `board/orchestrator/source-manifest`), so only an aarch64
  host reproduces that base. A new base built on another host architecture
  would record a different toolchain archive; that has not been exercised
  with this tree.
- **Buildroot**: a git checkout of a release tag, with no local modification
  (`make-source-bundle.sh` archives it and refuses a modified one). The
  committed base was built with **Buildroot 2026.02.3** (the `buildroot-…`
  part of `SOURCE_BASE_ID` in `board/orchestrator/source-offer.env`); a new
  base needs 2025.08-rc3 or newer, the release that added the CM5 defconfig.
- **Buildroot's own host packages**: the "System requirements" chapter of the
  Buildroot manual.
- **What the scripts here run**: POSIX `sh`, `git`, `python3` (standard
  library only), **GNU tar** (the bundle is packed with `--sort=name`),
  `make`, `sha256sum` or `shasum`, `xz` support in `tar`, `openssl`, `ar`,
  `od` and `curl` (`fetch-agent.sh`; `curl` not with `--deb`), mtools (`mcopy`,
  `mmd`, `mdir`, `mtype`), dosfstools (`mkfs.fat`) and coreutils `truncate`.
- **Disk and time** (estimates, not measured for this README): two complete
  Buildroot output trees with their kernels, the download directory and the
  `legal-info` copies of every source come to tens of GB, so plan for about
  50 GB free; building both SoCs from scratch takes hours rather than minutes.

### The order, and why it matters

A clean build is a new **base**, `buildroot-<release>+br2-<commit>+<YYYYMMDD>`,
and the commit in it is the commit of this repository the base is built
from: the bundle archives exactly that commit, and `check-built-base.sh`
refuses to assemble an image unless HEAD is that commit or a descendant that
changed nothing under `br2-orchestrator/` but the base's three records (`source-offer.env`,
`source-manifest`, `source-SHA256SUMS`). Two files the image carries are
derived from the build's `legal-info` output: `notices/components-buildroot.tsv`
and `notices/LICENSES/THIRD-PARTY-NOTICES.txt`, which `make-notices.sh` copies
into the image as committed. Neither is an input of the Buildroot build, so
they are refreshed and committed after the build and BEFORE the bundle is
cut: that commit is the **build commit** the base id names, and the image
carries the notices it contains. The three records name the build commit, so
they can only be committed after it, as a second **records commit** on top
of it.

```sh
REPO=/path/to/orchestrator-boot-image
BR2_EXT="$REPO/br2-orchestrator"
N="$BR2_EXT/board/orchestrator/notices"

# 0. Whoever builds and distributes an image makes the written offer in it,
#    and requests for the source go to them: set SOURCE_OFFER_CONTACT in
#    board/orchestrator/source-offer.env to your own name and address before
#    building your own base, and commit it.

# 1. The agent the image will carry: a published release, verified against the
#    keys in board/orchestrator/agent-keys before anything is written. The
#    build has no agent without this step (the binary is not in git), and
#    --write-notices refreshes the committed copy of that release's
#    third-party notices, which the image carries. Commit everything before
#    building; only the two derived notice files of step 3 come later.
make -C "$REPO" fetch-agent VERSION=<agent version> FETCH_FLAGS=--write-notices
git -C "$REPO" status --short    # commit what changed

# 2. Build: the full defconfigs = stock + our deltas, then each SoC.
cd /path/to/buildroot            # a release tag, unmodified
BR=$PWD
cat configs/raspberrypicm4io_64_defconfig "$BR2_EXT/configs/cm4-delta.fragment" \
    > configs/orchestrator_cm4_defconfig
cat configs/raspberrypicm5io_defconfig    "$BR2_EXT/configs/cm5-delta.fragment" \
    > configs/orchestrator_cm5_defconfig
make O=out-cm4 BR2_EXTERNAL="$BR2_EXT" orchestrator_cm4_defconfig && make O=out-cm4
make O=out-cm5 BR2_EXTERNAL="$BR2_EXT" orchestrator_cm5_defconfig && make O=out-cm5

# 3. legal-info in both trees, then refresh the two derived notice files from
#    the CM5 tree's output (the one the image's component list comes from) and
#    commit them. This commit, or the one before it if nothing changed, is the
#    build commit.
make O=out-cm5 BR2_EXTERNAL="$BR2_EXT" legal-info
make O=out-cm4 BR2_EXTERNAL="$BR2_EXT" legal-info
{ grep '^#' "$N/components-buildroot.tsv"
  sh "$N/make-notices.sh" --dump-components "$BR/out-cm5/legal-info"; } > "$N/components.new"
mv "$N/components.new" "$N/components-buildroot.tsv"
sh "$N/make-notices.sh" --dump-third-party "$BR/out-cm5/legal-info" > "$N/third-party.new"
mv "$N/third-party.new" "$N/LICENSES/THIRD-PARTY-NOTICES.txt"
git -C "$REPO" status --short    # commit the two files if they changed

# 4. The corresponding-source bundle of the build commit, reusing the
#    legal-info of step 3. --write-env records the new base id and the
#    bundle's sha256 in source-offer.env (left uncommitted until step 9).
make -C "$REPO" source-bundle BUILDROOT="$BR" OUT_CM4="$BR/out-cm4" OUT_CM5="$BR/out-cm5" \
    BUNDLE_FLAGS="--skip-legal-info --write-env"
ID=$(sed -n "s/^SOURCE_BASE_ID='\(.*\)'\$/\1/p" "$BR2_EXT/board/orchestrator/source-offer.env")
BUNDLE="$REPO/dist/recovery-image-source-$ID.tar"

# 5. The toolchain source (see "The toolchain source snapshot" below): put the
#    snapshot's file name and sha256 into SOURCE_TOOLCHAIN_FILE and
#    SOURCE_TOOLCHAIN_SHA256 in source-offer.env BY HAND -- --write-env does
#    not write them. Unchanged when the toolchain version is unchanged.
TOOLCHAIN=/path/to/arm-gnu-toolchain-src-snapshot-<version>.tar.xz
sha256sum "$TOOLCHAIN"

# 6. Record what this base IS (configs, package sources, kernels, the rootfs
#    minus the overlay, the overlay and board files byte for byte, the licence
#    set, the two archives) in board/orchestrator/source-manifest, and
#    source-SHA256SUMS beside it. No image yet: its FAT-root digest stays
#    pending.
make -C "$REPO" source-manifest OUT_CM4="$BR/out-cm4" OUT_CM5="$BR/out-cm5" \
    BUNDLE="$BUNDLE" TOOLCHAIN="$TOOLCHAIN"

# 7. Assemble the single FAT32 boot.img from both outputs. It fails unless
#    source-offer.env names what was BUILT (the Buildroot release in each
#    .config, the build commit, and the corpus source-manifest records --
#    notices/check-built-base.sh), then writes LICENSES/ and SOURCE-OFFER.txt
#    into the FAT root and fails unless the offer in the image names that base.
#    The manifest written above is not committed yet, which only this first
#    run may accept, by saying so:
ALLOW_UNCOMMITTED_MANIFEST=1 "$BR2_EXT/board/orchestrator/assemble-boot-img.sh" \
    "$BR/out-cm4" "$BR/out-cm5" "$BR/boot.img"

# 8. The FAT-root digest (device trees, overlays, firmware) can only be taken
#    from the image; IMG= on the command line is what measures it.
make -C "$REPO" source-manifest OUT_CM4="$BR/out-cm4" OUT_CM5="$BR/out-cm5" \
    IMG="$BR/boot.img" BUNDLE="$BUNDLE" TOOLCHAIN="$TOOLCHAIN"

# 9. The records commit, on top of the build commit: these three files and
#    nothing else. A later assemble accepts it without the flag.
cd "$REPO" && git add br2-orchestrator/board/orchestrator/source-offer.env \
    br2-orchestrator/board/orchestrator/source-manifest \
    br2-orchestrator/board/orchestrator/source-SHA256SUMS
git commit -m "base $ID: records"

# 10. Serve the bundle, the toolchain snapshot and source-SHA256SUMS (as
#     /source/SHA256SUMS) from every install that serves this image, then sign
#     the image (below).
```

Never squash, rebase or otherwise rewrite the build commit once a base names
it (see "Publishing a base" in the top-level `README.md`).

### The toolchain source snapshot

The target C library, libgcc and libstdc++ come from the prebuilt Arm GNU
Toolchain, which `legal-info` saves only as a binary (its licence is listed
as "unknown"), so its source is a second archive served beside the bundle.

- **Which file**: the toolchain version is the `toolchain-external-arm-aarch64`
  row of `out-cm5/legal-info/manifest.csv` (also its `source` line in
  `source-manifest`); the matching source is Arm's source snapshot of that
  release, `arm-gnu-toolchain-src-snapshot-<version>.tar.xz` (14.2.rel1 for
  the committed base).
- **Where**: Arm publishes it beside the binaries of each release, on the
  "Arm GNU Toolchain Downloads" page of its developer website, in the
  release's source-code section.
- **Recording it**: `make-source-bundle.sh --write-env` writes only the base
  id and the bundle's sha256. `SOURCE_TOOLCHAIN_FILE` (the file name) and
  `SOURCE_TOOLCHAIN_SHA256` in `source-offer.env` are edited by hand, before
  `make source-manifest`, which refuses an env whose toolchain disagrees with
  the `TOOLCHAIN=` file. When the Buildroot release selects the same
  toolchain version, both stay as they are; when it selects another, both
  change.
- Do not also pass the snapshot to `make-source-bundle.sh --toolchain-source`:
  that copies it INTO the bundle, while the offer names it as a separate
  archive.

An agent-only rebake, which swaps `usr/bin/orchestrator-agent` inside the
existing image's rootfs, keeps the base: add or refresh the notices with
`scripts/inject-notices.sh <copy of boot.img>` and assert them with
`scripts/check-notices.sh` before re-signing; that check also measures the
image against `source-manifest` (it needs `mtools` and `python3`), so a
rebake that changed anything but the agent is refused.

## Sign + serve

```sh
# privkey.pem: the boot-image signing key whose public half is in the devices'
# EEPROM; its custody is the operator's, and it never enters this repository
rpi-eeprom-digest -i boot.img -o boot.sig -k privkey.pem
# place boot.img + boot.sig into the server's net_install/ (already served on :80)
```

The matching **public key** must be written into each Pi's EEPROM.

> **Do NOT set `SIGNED_BOOT=1`.** It bricks local OS boot with Error 6.
> `SIGNED_BOOT` is global and all-or-nothing: enabling it for signed netboot
> also refuses every unsigned local boot, including the OS this platform
> installs and any SD provisioning card. Netboot on BCM2712 verifies
> `boot.sig` against the embedded key regardless, so the signature protection
> is not lost by leaving it unset. See
> `docs/NETWORK-FIRST.md` in the platform repository, `uptime-lab/orchestrator`;
> the platform's EEPROM bake (its eeprom-signer) leaves it unset.

The real per-device EEPROM settings are produced by the platform's
eeprom-signer, not by hand: `HTTP_HOST=<server>`, `HTTP_PATH=http-boot/<serial>`,
`BOOT_ORDER=0xf1467`, the embedded pubkey and the node's adoption token.

## Notes / open items

- The agent enters through the rootfs overlay as a released binary
  (`scripts/fetch-agent.sh`), not as a Buildroot package built from source;
  the same binary is what the release's `.deb` installs, and its source is the
  agent's public mirror at the release's tag. To carry an agent built from a
  modified source, build it there (`CGO_ENABLED=0 GOOS=linux GOARCH=arm64`) and
  place it at `board/orchestrator/rootfs-overlay/usr/bin/orchestrator-agent`.
- The image is capped at 94 MiB by `assemble-boot-img.sh`. A "96 MB hard
  ramdisk limit" has no citation in the RPi docs, usbboot or the rpi-eeprom
  release notes, and an image of exactly 96 MiB has booted — treat it as an
  unproven convention. If headroom is ever needed, the two UNCOMPRESSED
  23 MiB kernel `Image` files are where ~28 MiB is hiding.
- CM5 needs a recent kernel (rpi-6.12.y) for the RP1/macb NIC + all CM5 DTBs.
- DTB filenames are an explicit **required list** in `assemble-boot-img.sh`, and
  the build FAILS when one is missing: a device tree that is requested but
  never built shows up on a device only as a rainbow screen. The same list
  has to agree with `BR2_LINUX_KERNEL_INTREE_DTS_NAME` in `configs/*-delta.fragment` and the
  `device_tree=` values in `board/orchestrator/config.txt`; the script checks
  the last of those three for you.
