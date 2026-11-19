# shellcheck shell=sh
# Shared fixtures for tests/built-base.sh and tests/source-manifest.sh: a
# throwaway git repository shaped like this one, and fake Buildroot output
# trees with everything the corpus check reads. Sourced, not run.
#
#   fake_repo DIR          git repository with br2-orchestrator/ (an overlay with
#                          two tracked files, the agent ignored by .gitignore,
#                          config.txt and cmdline.txt, an assemble script
#                          copying them); sets REPO, TREE, BOARD
#   fake_out DIR SOC       an output tree (O=) for cm4 or cm5: .config, kernel and
#                          BusyBox .configs, legal-info, images/Image and a rootfs
#                          staged in DIR/target (plus dev/console from
#                          DIR/devices) and packed by pack_rootfs
#   pack_rootfs DIR [rev]  (re)pack DIR/target into DIR/images/rootfs.cpio.gz;
#                          "rev" packs in reverse order, as a rebake's repack may
#   fake_fat DIR OUT_CM4 OUT_CM5
#                          the FAT root assemble-boot-img.sh would stage, with the
#                          notices make-notices.sh writes
#   fake_bundle DIR OUT_CM4 OUT_CM5 BASE_ID FAT_DIR
#                          an unpacked corresponding-source bundle with an image
#                          inventory, as the archived bundle lays it out
#   offer_env FILE BASE_ID a complete source-offer.env for that base

BR_VER=2099.02.1
LIB_HERE=$(CDPATH= cd -- "$(dirname -- "${HERE:?}/lib-fake-build.sh")" && pwd)
PACK="$LIB_HERE/pack-newc.py"
GENERATOR="$LIB_HERE/../notices/make-notices.sh"

offer_env() {
  cat > "$1" <<EOF
SOURCE_BASE_ID='$2'
SOURCE_BUNDLE_SHA256='0000000000000000000000000000000000000000000000000000000000000001'
SOURCE_FIRST_BASE_DATE='2026-07-28'
SOURCE_OFFER_CONTACT='Example Org, https://example.org'
EOF
}

fake_repo() {
  REPO=$1
  TREE="$REPO/br2-orchestrator"
  BOARD="$TREE/board/orchestrator"
  mkdir -p "$BOARD/rootfs-overlay/etc/init.d" "$BOARD/rootfs-overlay/usr/bin" "$BOARD/notices"
  git init -q "$REPO"
  git -C "$REPO" config user.email test@example.org
  git -C "$REPO" config user.name test
  git -C "$REPO" config commit.gpgsign false
  printf 'echo hi\n' > "$BOARD/post-build.sh"
  printf '#!/bin/sh\necho start agent\n' > "$BOARD/rootfs-overlay/etc/init.d/S99agent"
  printf '::sysinit:/etc/init.d/rcS\n' > "$BOARD/rootfs-overlay/etc/inittab"
  printf '/br2-orchestrator/board/orchestrator/rootfs-overlay/usr/bin/orchestrator-agent\n' > "$REPO/.gitignore"
  printf 'kernel=kernel_2712.img\ninitramfs rootfs.cpio.gz followkernel\n[all]\n' > "$BOARD/config.txt"
  printf 'console=tty1 loglevel=7\n' > "$BOARD/cmdline.txt"
  cat > "$BOARD/assemble-boot-img.sh" <<'EOF'
cp "$BOARD_DIR/config.txt"  "$STAGE/config.txt"
cp "$BOARD_DIR/cmdline.txt" "$STAGE/cmdline.txt"
EOF
  printf "SOURCE_BASE_ID='placeholder'\n" > "$BOARD/source-offer.env"
  git -C "$REPO" add .gitignore br2-orchestrator
  git -C "$REPO" commit -q -m one
}

pack_rootfs() {
  python3 -I "$PACK" "$1/target" "$1/images/rootfs.cpio.gz" "${2:-fwd}" "$1/devices"
}

fake_out() {
  o=$1 soc=$2
  mkdir -p "$o/images" "$o/legal-info" "$o/build/linux-6.6.1" "$o/build/linux-headers-6.6.1" \
           "$o/build/busybox-1.37.0" "$o/target/bin" "$o/target/dev" "$o/target/etc/init.d" "$o/target/usr/bin"
  printf '#\n# Automatically generated file; DO NOT EDIT.\n# Buildroot %s Configuration\n#\nBR2_aarch64=y\nBR2_EXTERNAL_ORCHESTRATOR_PATH="%s"\n# BR2_PACKAGE_DROPBEAR is not set\nBR2_TARGET=%s\n' \
    "$BR_VER" "$o" "$soc" > "$o/.config"
  printf '#\n# Linux/arm64 6.6.1 Kernel Configuration\n#\nCONFIG_EXT4_FS=y\n# CONFIG_NFS_FS is not set\nCONFIG_SOC=%s\n' "$soc" > "$o/build/linux-6.6.1/.config"
  printf 'CONFIG_DECOY=y\n' > "$o/build/linux-headers-6.6.1/.config"
  printf '#\n# Busybox version: 1.37.0\n# %s\n#\nCONFIG_ASH=y\n' "$(date)" > "$o/build/busybox-1.37.0/.config"
  printf '"PACKAGE","VERSION","LICENSE"\n"busybox","1.37.0","GPL-2.0"\n"linux","custom","GPL-2.0"\n' > "$o/legal-info/manifest.csv"
  printf '%s  sources/busybox-1.37.0/busybox-1.37.0.tar.bz2\n%s  sources/linux-custom/linux.tar.gz\n%s  host-sources/m4/m4.tar.xz\n%s  manifest.csv\n' \
    1111111111111111111111111111111111111111111111111111111111111111 \
    2222222222222222222222222222222222222222222222222222222222222222 \
    3333333333333333333333333333333333333333333333333333333333333333 \
    4444444444444444444444444444444444444444444444444444444444444444 > "$o/legal-info/legal-info.sha256"
  printf 'kernel image %s\n' "$soc" > "$o/images/Image"
  printf 'busybox 1.37.0\n' > "$o/target/bin/busybox"
  ln -sf busybox "$o/target/bin/sh"
  printf 'init\n' > "$o/target/etc/inittab.base"
  printf '#!/bin/sh\necho start agent\n' > "$o/target/etc/init.d/S99agent"
  printf '::sysinit:/etc/init.d/rcS\n' > "$o/target/etc/inittab"
  printf 'agent 1.0.0\n' > "$o/target/usr/bin/orchestrator-agent"
  printf 'dev/console c 0622 5 1\n' > "$o/devices"
  pack_rootfs "$o"
}

fake_fat() {
  f=$1
  mkdir -p "$f/overlays"
  cp "$2/images/Image" "$f/kernel8.img"
  cp "$3/images/Image" "$f/kernel_2712.img"
  printf 'dtb\n' > "$f/bcm2712-rpi-cm5-cm5io.dtb"
  printf 'dtbo\n' > "$f/overlays/bcm2712d0.dtbo"
  printf 'firmware\n' > "$f/start4.elf"
  cp "${BOARD:?}/config.txt" "$f/config.txt"
  cp "$BOARD/cmdline.txt" "$f/cmdline.txt"
  offer_env "$f.env" "buildroot-2099.01.1+br2-0abc1234+20990102"
  sh "$GENERATOR" --out "$f" --env "$f.env" >/dev/null 2>&1
  rm -f "$f.env"
  cp "$3/images/rootfs.cpio.gz" "$f/rootfs.cpio.gz"
}

# members_listing DIR: a listing of DIR/target in the archived bundle's
# image-inventory format (cpiohash.py): devices carry no numbers there.
members_listing() {
  python3 -I - "$1/target" "$1/devices" <<'EOF'
import hashlib, os, stat, sys
target, devices = sys.argv[1], sys.argv[2]
rows = []
for dirpath, dirs, files in os.walk(target):
    for n in dirs + files:
        full = os.path.join(dirpath, n)
        rel = os.path.relpath(full, target)
        st = os.lstat(full)
        if stat.S_ISLNK(st.st_mode):
            body = os.readlink(full).encode(); kind = "l"
        elif stat.S_ISREG(st.st_mode):
            body = open(full, "rb").read(); kind = "-"
        else:
            body = b""; kind = "d"
        h = hashlib.sha256(body).hexdigest() if kind in "-l" else "-"
        tgt = body.decode() if kind == "l" else ""
        rows.append("%s %04o 0:0 %9d %d %s %s %s" % (kind, st.st_mode & 0o7777, len(body), int(st.st_mtime), h, rel, tgt))
for line in open(devices):
    p = line.split()
    rows.append("%s %s 0:0 %9d 0 - %s " % (p[1], p[2], 0, p[0]))
print("\n".join(sorted(rows, key=lambda r: r.split()[6])))
EOF
}

fake_bundle() {
  b=$1
  mkdir -p "$b/configs" "$b/legal-info-cm4" "$b/legal-info-cm5" "$b/image-inventory"
  printf 'Base id: %s\n' "$4" > "$b/BASE.txt"
  for soc in cm4 cm5; do
    if [ "$soc" = cm4 ]; then o=$2; else o=$3; fi
    cp "$o/.config" "$b/configs/buildroot-out-$soc.config"
    cp "$o/build/busybox-1.37.0/.config" "$b/configs/busybox-$soc.config"
    cp "$o/legal-info/manifest.csv" "$b/legal-info-$soc/manifest.csv"
  done
  cp "$2/build/linux-6.6.1/.config" "$b/configs/linux-cm4-bcm2711.config"
  cp "$3/build/linux-6.6.1/.config" "$b/configs/linux-cm5-bcm2712.config"
  cp "$3/legal-info/legal-info.sha256" "$b/legal-info-cm5/legal-info.sha256"
  (cd "$5" && find . -type f | sort | while read -r p; do
     printf '%s  %s\n' "$(sha256 < "$p")" "$p"
   done) > "$b/image-inventory/image-1-fat-root.sha256"
  members_listing "$3" > "$b/image-inventory/rootfs-served-one.members"
  # The Buildroot release, whose cpio step names the device numbers, and the
  # external tree at the base commit (only its name is read).
  mkdir -p "$b.br/buildroot-$BR_VER/fs/cpio"
  printf '\tmknod -m 0622 $(TARGET_DIR)/dev/console c 5 1\n' > "$b.br/buildroot-$BR_VER/fs/cpio/cpio.mk"
  (cd "$b.br" && tar -cf "$b/buildroot-$BR_VER.tar" "buildroot-$BR_VER")
  rm -rf "$b.br"
  base_commit=${4#*+br2-}; base_commit=${base_commit%%+*}
  : > "$b/br2-orchestrator-$base_commit.tar"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}
