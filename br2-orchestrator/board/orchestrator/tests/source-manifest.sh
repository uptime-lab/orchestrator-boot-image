#!/bin/sh
#
# Exercises notices/source-manifest.py: the manifest binds the corpus (configs,
# sources, kernels, rootfs with its device numbers, the overlay files, the
# board files, the licence set, the FAT root and the archives the offer names)
# and not merely the label, an agent-only rebake keeps it, and pending,
# missing or another format is never a pass. Fake build outputs, no Buildroot,
# no mtools (the FAT root is given as a directory; the mtools path is the same
# code after mcopy, and check-notices.sh drives it on a host).
# Run from anywhere:  sh br2-orchestrator/board/orchestrator/tests/source-manifest.sh
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SM="$HERE/../notices/source-manifest.py"
REAL_BOARD=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=lib-fake-build.sh
. "$HERE/lib-fake-build.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; [ -f "$TMP/out" ] && sed 's/^/      /' "$TMP/out"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip: no git"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: no python3"; exit 0; }

fake_repo "$TMP/repo"
C=$(git -C "$REPO" rev-parse --short=8 HEAD)
CFULL=$(git -C "$REPO" rev-parse HEAD)
offer_env "$BOARD/source-offer.env" "buildroot-$BR_VER+br2-$C+20990301"
fake_out "$TMP/out-cm4" cm4
fake_out "$TMP/out-cm5" cm5
fake_fat "$TMP/fat" "$TMP/out-cm4" "$TMP/out-cm5"
M="$BOARD/source-manifest"

sm() { python3 -I "$SM" "$@" --manifest "$M" --env "$BOARD/source-offer.env" --tree "$TREE"; }
# expect <rc> <label> <needle|-> command...
expect() {
  want=$1 label=$2 needle=$3; shift 3
  set +e; "$@" > "$TMP/out" 2>&1; rc=$?; set -e
  [ "$rc" -eq "$want" ] || fail "$label: exit $rc, want $want"
  if [ "$needle" != "-" ]; then grep -qF -- "$needle" "$TMP/out" || fail "$label: output lacks '$needle'"; fi
  echo "ok: $label"
}
check_outs() { sm check --out-cm4 "$TMP/out-cm4" --out-cm5 "$TMP/out-cm5"; }
check_fat() { sm check --fat-dir "$TMP/fat"; }

# 1. Generate from the build outputs plus the FAT root; both measure clean.
expect 0 "generate from the build outputs and the image" "wrote" \
  sm generate --out-cm4 "$TMP/out-cm4" --out-cm5 "$TMP/out-cm5" --fat-dir "$TMP/fat"
grep -q '^format 2$' "$M" || fail "1: not format 2"
grep -q "^board_commit $CFULL\$" "$M" || fail "1: board_commit is not the build commit"
grep -q '^rootfs_exclude etc/init.d/S99agent$' "$M" || fail "1: the tracked overlay file is not excluded"
grep -q '^rootfs_exclude usr/bin/orchestrator-agent$' "$M" || fail "1: the ignored agent path is not excluded"
[ "$(grep -c '^rootfs_exclude ' "$M")" -eq 3 ] || fail "1: exclusions other than the overlay's"
grep -q '^overlay etc/init.d/S99agent - 0644 0:0 ' "$M" || fail "1: the tracked overlay file is not bound"
grep -q '^overlay etc/inittab - 0644 0:0 ' "$M" || fail "1: the second overlay file is not bound"
grep -q '^overlay usr/bin/orchestrator-agent' "$M" && fail "1: the agent path must stay unbound"
grep -q '^board_file config.txt ' "$M" || fail "1: config.txt is not bound"
grep -q '^board_file cmdline.txt ' "$M" || fail "1: cmdline.txt is not bound"
grep -q '^licence GPL-2.0.txt [0-9a-f]\{64\}$' "$M" || fail "1: the GPL text is not bound by hash"
grep -q '^licence THIRD-PARTY-NOTICES-orchestrator-agent.md by-name$' "$M" || fail "1: the agent notices are not by name"
[ "$(grep -c '^licence ' "$M")" -eq 8 ] || fail "1: the licence set is not the generator's eight files"
grep -q '^archive bundle pending$' "$M" || fail "1: an unmeasured bundle archive is not pending"
grep -q '^source sources/busybox-1.37.0/busybox-1.37.0.tar.bz2 1111' "$M" || fail "1: target source not recorded"
grep -q 'host-sources' "$M" && fail "1: host sources are not part of the target corpus"
expect 0 "the build outputs match" "ok, base" check_outs
expect 0 "the FAT root matches" "ok, base" check_fat
expect 3 "show: an unmeasured archive is pending, not a pass" "PENDING archive bundle" sm show
cp "$M" "$TMP/manifest.good"
cp -R "$TMP/out-cm5" "$TMP/out-cm5.good"
cp -R "$TMP/fat" "$TMP/fat.good"
restore() { rm -rf "$TMP/out-cm5" "$TMP/fat"; cp -R "$TMP/out-cm5.good" "$TMP/out-cm5"; cp -R "$TMP/fat.good" "$TMP/fat"; cp "$TMP/manifest.good" "$M"; }

# 2. A Buildroot config change, version header and commit unchanged: refused.
printf 'BR2_PACKAGE_DROPBEAR=y\n' >> "$TMP/out-cm5/.config"
expect 1 "a Buildroot .config change is refused" "config buildroot-cm5" check_outs
restore

# 3. A kernel config change: refused. A date or a comment is not a change.
printf 'CONFIG_NFS_FS=y\n' >> "$TMP/out-cm5/build/linux-6.6.1/.config"
expect 1 "a kernel .config change is refused" "config linux-cm5" check_outs
restore
printf '#\n# Busybox version: 1.37.0\n# a different day\n#\nCONFIG_ASH=y\n' > "$TMP/out-cm5/build/busybox-1.37.0/.config"
sed 's#^BR2_EXTERNAL_ORCHESTRATOR_PATH=.*#BR2_EXTERNAL_ORCHESTRATOR_PATH="/elsewhere"#' "$TMP/out-cm5/.config" > "$TMP/c" && mv "$TMP/c" "$TMP/out-cm5/.config"
expect 0 "a BusyBox date line and a checkout path are not a corpus change" "ok, base" check_outs
restore

# 4. A changed package source: refused.
sed 's/^1111/9999/' "$TMP/out-cm5/legal-info/legal-info.sha256" > "$TMP/s" && mv "$TMP/s" "$TMP/out-cm5/legal-info/legal-info.sha256"
expect 1 "a changed package source is refused" "source sources/busybox" check_outs
restore

# 5. The rootfs outside the overlay: content, a new file, a mode, a device
#    number. Refused.
printf 'busybox 1.37.0 patched\n' > "$TMP/out-cm5/target/bin/busybox"; pack_rootfs "$TMP/out-cm5"
expect 1 "a changed binary outside the overlay is refused" "rootfs_stripped_sha256" check_outs
restore
printf 'x\n' > "$TMP/out-cm5/target/bin/dropbear"; pack_rootfs "$TMP/out-cm5"
expect 1 "a file added outside the overlay is refused" "rootfs_stripped_entries" check_outs
restore
chmod 4755 "$TMP/out-cm5/target/bin/busybox"; pack_rootfs "$TMP/out-cm5"
expect 1 "a mode change outside the overlay is refused" "rootfs_stripped_sha256" check_outs
restore
printf 'dev/console c 0622 4 1\n' > "$TMP/out-cm5/devices"; pack_rootfs "$TMP/out-cm5"
expect 1 "a dev/console with another major number is refused" "rootfs_stripped_sha256" check_outs
cp "$TMP/out-cm5/images/rootfs.cpio.gz" "$TMP/fat/rootfs.cpio.gz"
expect 1 "... and in an image" "rootfs_stripped_sha256" check_fat
restore
printf 'dev/console b 0622 5 1\n' > "$TMP/out-cm5/devices"; pack_rootfs "$TMP/out-cm5"
expect 1 "a dev/console turned into a block device is refused" "rootfs_stripped_sha256" check_outs
restore

# 6. The authorised rebake: only the agent changes, the archive is repacked in
#    another order with new mtimes, and the notices are rewritten for the new
#    agent (its notices by name, the offer by name).
sleep 1
printf 'agent 2.0.0, a newer release\n' > "$TMP/out-cm5/target/usr/bin/orchestrator-agent"
touch "$TMP/out-cm5/target/bin/busybox"
pack_rootfs "$TMP/out-cm5" rev
cp "$TMP/out-cm5/images/rootfs.cpio.gz" "$TMP/fat/rootfs.cpio.gz"
printf '# Third-party notices: agent and watcher\n\nagent 2.0.0 modules\n' > "$TMP/agent2.md"
offer_env "$TMP/rebake.env" "buildroot-$BR_VER+br2-$C+20990301"
sh "$GENERATOR" --out "$TMP/fat" --env "$TMP/rebake.env" --agent-notices "$TMP/agent2.md" >/dev/null 2>&1
expect 0 "an agent-only rebake keeps the base (FAT root)" "ok, base" check_fat
expect 0 "an agent-only rebake keeps the base (rootfs alone)" "ok, base" sm check --rootfs "$TMP/fat/rootfs.cpio.gz"
python3 -I -c 'import sys; a, b = (open(p, "rb").read() for p in sys.argv[1:]); sys.exit(a == b)' \
  "$TMP/fat/rootfs.cpio.gz" "$TMP/fat.good/rootfs.cpio.gz" || fail "6: precondition: the repacked archive should differ in bytes"
restore

# 7. The image's kernels and the rest of its FAT root.
printf 'other kernel\n' > "$TMP/fat/kernel_2712.img"
expect 1 "a different kernel in the image is refused" "kernel bcm2712" check_fat
restore
printf 'dtb, rebuilt\n' > "$TMP/fat/bcm2712-rpi-cm5-cm5io.dtb"
expect 1 "a changed device tree is refused" "fat_base_sha256" check_fat
restore
printf 'x' > "$TMP/fat/extra.bin"
expect 1 "an extra file in the FAT root is refused" "fat_base_files" check_fat
restore

# 8. A kernel or an initramfs that is not the corpus, booted through LICENSES/
#    or the board files: every probe is refused.
printf 'not the corpus kernel' > "$TMP/fat/LICENSES/k.img"
sed 's#^kernel=kernel_2712.img#kernel=LICENSES/k.img#' "$TMP/fat/config.txt" > "$TMP/c" && mv "$TMP/c" "$TMP/fat/config.txt"
expect 1 "a kernel under LICENSES/ named by config.txt kernel= is refused" "licence k.img" check_fat
grep -qF 'board_file config.txt' "$TMP/out" || fail "8: the changed config.txt is not named"
restore
printf 'not the corpus kernel' > "$TMP/fat/LICENSES/k.img"
expect 1 "a stray file under LICENSES/ is refused on its own" "licence k.img" check_fat
restore
printf 'junk' | gzip > "$TMP/fat/LICENSES/r.cpio.gz"
sed 's#^initramfs rootfs.cpio.gz#initramfs LICENSES/r.cpio.gz#' "$TMP/fat/config.txt" > "$TMP/c" && mv "$TMP/c" "$TMP/fat/config.txt"
expect 1 "an initramfs under LICENSES/ is refused" "licence r.cpio.gz" check_fat
restore
mkdir -p "$TMP/fat/LICENSES/x"; cp "$TMP/fat/kernel8.img" "$TMP/fat/LICENSES/x/kernel8.img"
printf '[all]\nos_prefix=LICENSES/x/\n' >> "$TMP/fat/config.txt"
expect 1 "os_prefix= into LICENSES/ is refused" "licence x/kernel8.img" check_fat
grep -qF 'board_file config.txt' "$TMP/out" || fail "8: the os_prefix line is not caught in config.txt"
restore
printf 'console=tty1 rdinit=/bin/sh\n' > "$TMP/fat/cmdline.txt"
expect 1 "cmdline.txt with rdinit= is refused" "board_file cmdline.txt" check_fat
restore
for arg in 'init=/bin/sh' 'root=/dev/sda1'; do
  printf 'console=tty1 loglevel=7 %s\n' "$arg" > "$TMP/fat/cmdline.txt"
  expect 1 "cmdline.txt with $arg is refused" "board_file cmdline.txt" check_fat
  restore
done
printf 'GPL, abridged\n' > "$TMP/fat/LICENSES/GPL-2.0.txt"
expect 1 "a changed licence text is refused" "licence GPL-2.0.txt" check_fat
restore
rm "$TMP/fat/LICENSES/LGPL-2.1.txt"
expect 1 "a missing licence text is refused" "licence LGPL-2.1.txt is absent" check_fat
restore
printf '# Third-party notices: agent and watcher\n\nanother agent\n' > "$TMP/fat/LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md"
expect 0 "the agent's own notices are bound by name, not content" "ok, base" check_fat
restore

# 9. The overlay files are bound: only the agent path is
#    free. A changed S99agent or inittab in the image is refused.
printf '#!/bin/sh\necho start something else\n' > "$TMP/out-cm5/target/etc/init.d/S99agent"; pack_rootfs "$TMP/out-cm5"
cp "$TMP/out-cm5/images/rootfs.cpio.gz" "$TMP/fat/rootfs.cpio.gz"
expect 1 "a changed overlay init script in the image is refused" "overlay etc/init.d/S99agent" check_fat
expect 1 "... and in the rootfs alone" "overlay etc/init.d/S99agent" sm check --rootfs "$TMP/fat/rootfs.cpio.gz"
restore
chmod 0755 "$TMP/out-cm5/target/etc/inittab"; pack_rootfs "$TMP/out-cm5"
expect 1 "an overlay file with another mode is refused" "overlay etc/inittab" check_outs
restore
rm "$TMP/out-cm5/target/etc/inittab"; pack_rootfs "$TMP/out-cm5"
expect 1 "a missing overlay file is refused" "overlay etc/inittab is absent" check_outs
restore

# 10. Missing, malformed, another format or pending is never a pass.
rm "$M"
expect 1 "a missing manifest is refused" "no source manifest" check_outs
restore
sed 's/^format 2$/format 1/' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 1 "a manifest of an older format is refused as a different format" "different format" check_outs
restore
grep -v '^overlay etc/inittab ' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 1 "an excluded overlay path bound by nothing is malformed" "bound by nothing" check_outs
restore
sed 's/^rootfs_stripped_sha256 .*/rootfs_stripped_sha256 pending/' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 3 "a pending rootfs digest is not a pass (build outputs)" "NOT a pass" check_outs
expect 3 "a pending rootfs digest is not a pass (FAT root)" "PENDING rootfs_stripped_sha256" check_fat
restore
sed 's/^board_commit .*/board_commit pending/' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 3 "a pending board commit is not a pass (FAT root)" "PENDING board_commit" check_fat
expect 3 "a pending board commit is not a pass (build outputs)" "PENDING board_commit" check_outs
expect 3 "a pending board commit is not a pass (show)" "PENDING board_commit" sm show
restore
expect 0 "generate without an image leaves the FAT digest pending" "pending: fat_base_sha256" \
  sm generate --out-cm4 "$TMP/out-cm4" --out-cm5 "$TMP/out-cm5"
expect 0 "the build check does not need the FAT digest" "ok, base" check_outs
expect 3 "but the image check does, and says so" "PENDING fat_base_sha256" check_fat
restore

# 11. The label, the exclusions and the tree's own files are bound too.
offer_env "$TMP/other.env" "buildroot-$BR_VER+br2-$C+20990302"
expect 1 "an env naming another base is refused" "source-offer.env names base" \
  python3 -I "$SM" check --manifest "$M" --env "$TMP/other.env" --tree "$TREE" --fat-dir "$TMP/fat"
mkdir -p "$BOARD/rootfs-overlay/bin"
printf 'a busybox the overlay ships\n' > "$BOARD/rootfs-overlay/bin/busybox"
git -C "$REPO" add br2-orchestrator && git -C "$REPO" commit -q -m shadow
expect 1 "an overlay file that would hide a corpus path from the digest is refused" "the overlay installs" check_fat
grep -qF 'the overlay tracks' "$TMP/out" || fail "11: the unbound new overlay file is not named"
git -C "$REPO" rm -q -r br2-orchestrator/board/orchestrator/rootfs-overlay/bin && git -C "$REPO" commit -q -m unshadow
# shellcheck disable=SC2016 # the assemble script's own variables, literally
printf 'cp "$BOARD_DIR/extra.bin" "$STAGE/extra.bin"\n' >> "$BOARD/assemble-boot-img.sh"
expect 1 "a new board file in the FAT root changes the derived exclusions" "FAT exclusions" check_fat
git -C "$REPO" checkout -q -- br2-orchestrator/board/orchestrator/assemble-boot-img.sh
sed "s/^board_commit .*/board_commit $(git -C "$REPO" rev-parse HEAD)/" "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 0 "a later commit with the same board files is an acceptable board_commit" "ok, base" check_fat
printf '::sysinit:/etc/init.d/rcS\n# edited\n' > "$BOARD/rootfs-overlay/etc/inittab"
git -C "$REPO" commit -q -am "edit inittab"
sed "s/^board_commit .*/board_commit $(git -C "$REPO" rev-parse HEAD)/" "$M" > "$TMP/m" && mv "$TMP/m" "$M"
expect 1 "the manifest's overlay must be the tree's file at board_commit" "tree: overlay etc/inittab" check_fat
restore
expect 0 "the board_commit's files stay the binding after the tree moves on" "ok, base" check_fat

# 12. A bundle cut from the same build matches; its archive is hashed and
#     bound to the env and to SHA256SUMS; one with another config does not.
fake_bundle "$TMP/bundle" "$TMP/out-cm4" "$TMP/out-cm5" "buildroot-$BR_VER+br2-$C+20990301" "$TMP/fat"
(cd "$TMP" && tar -cf "recovery-image-source-buildroot-$BR_VER+br2-$C+20990301.tar" bundle)
TAR="$TMP/recovery-image-source-buildroot-$BR_VER+br2-$C+20990301.tar"
printf 'toolchain source snapshot\n' > "$TMP/tc-src.tar.xz"
TARSHA=$(sha256 < "$TAR"); TCSHA=$(sha256 < "$TMP/tc-src.tar.xz")
sed "s/^SOURCE_BUNDLE_SHA256=.*/SOURCE_BUNDLE_SHA256='$TARSHA'/" "$BOARD/source-offer.env" > "$TMP/e"
printf "SOURCE_TOOLCHAIN_FILE='tc-src.tar.xz'\nSOURCE_TOOLCHAIN_SHA256='%s'\n" "$TCSHA" >> "$TMP/e"
mv "$TMP/e" "$BOARD/source-offer.env"
expect 0 "a bundle of the same build matches (directory)" "bundle: base_id, board_file, buildroot_version, config, fat, kernel" \
  sm check --bundle "$TMP/bundle"
expect 0 "generate from the bundle TAR binds the archives and writes SHA256SUMS" "wrote" \
  sm generate --bundle "$TAR" --toolchain "$TMP/tc-src.tar.xz"
grep -q "^archive bundle recovery-image-source-.* $TARSHA [0-9]*\$" "$M" || fail "12: the bundle archive is not recorded"
grep -q "^archive toolchain tc-src.tar.xz $TCSHA " "$M" || fail "12: the toolchain archive is not recorded"
grep -q "^board_commit $CFULL\$" "$M" || fail "12: the bundle did not find the board commit"
grep -q "^$TARSHA  recovery-image-source-" "$BOARD/source-SHA256SUMS" || fail "12: source-SHA256SUMS not written"
[ "$(grep '^rootfs_stripped_sha256' "$M")" = "$(grep '^rootfs_stripped_sha256' "$TMP/manifest.good")" ] ||
  fail "12: the bundle's listing (device numbers from cpio.mk) does not measure to the build's digest"
expect 0 "the bundle TAR and the toolchain check" "toolchain: archive" \
  sm check --bundle "$TAR" --toolchain "$TMP/tc-src.tar.xz"
expect 0 "show: archives agree with the env and SHA256SUMS" "archives against source-SHA256SUMS" sm show
cp "$TAR" "$TMP/tar.good"; printf 'x' >> "$TAR"
expect 1 "a bundle TAR that is not the archive the manifest records is refused" "archive bundle" \
  sm check --bundle "$TAR"
cp "$TMP/tar.good" "$TAR"
printf '%s  %s\n' "$(printf 0 | sha256)" "tc-src.tar.xz" > "$TMP/sums"
expect 1 "a SHA256SUMS that serves another toolchain is refused" "tc-src.tar.xz" sm show --sums "$TMP/sums"
sed "s/^SOURCE_TOOLCHAIN_SHA256=.*/SOURCE_TOOLCHAIN_SHA256='$(printf 1 | sha256)'/" "$BOARD/source-offer.env" > "$TMP/e2"
expect 1 "an env naming another toolchain is refused" "source-offer.env names toolchain" \
  python3 -I "$SM" show --manifest "$M" --env "$TMP/e2" --tree "$TREE"
mkdir -p "$TMP/nodev" && cp -R "$TMP/bundle/." "$TMP/nodev/" && rm "$TMP/nodev/buildroot-$BR_VER.tar"
expect 2 "a listing whose device numbers nothing in the bundle names cannot be measured" "dev/console" \
  sm check --bundle "$TMP/nodev"
printf 'BR2_PACKAGE_DROPBEAR=y\n' >> "$TMP/bundle/configs/buildroot-out-cm4.config"
expect 1 "a bundle whose config is not the build's is refused" "config buildroot-cm4" \
  sm check --bundle "$TMP/bundle"

# 13. The notices make-notices.sh writes are exactly the FAT exclusions the
#     script treats as always outside the FAT digest (besides the rootfs archive).
offer_env "$TMP/offer.env" "buildroot-2099.01.1+br2-0abc1234+20990102"
mkdir -p "$TMP/notices-out"
sh "$REAL_BOARD/notices/make-notices.sh" --out "$TMP/notices-out" --env "$TMP/offer.env" >/dev/null 2>&1 ||
  fail "13: make-notices.sh did not run"
written=$(cd "$TMP/notices-out" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | sort | tr '\n' ' ')
[ "$written" = "LICENSES SOURCE-OFFER.txt " ] ||
  fail "13: make-notices.sh writes '$written'; update FAT_ALWAYS_EXCLUDED in source-manifest.py"
echo "ok: make-notices.sh writes exactly the notices the FAT digest leaves out"

# 14. The committed manifest of THIS repository is well-formed, names the
#     committed base and archives, agrees with source-SHA256SUMS, and records
#     the exclusions, overlay and board files this tree derives at its
#     board_commit and the licence set the generator writes.
expect 0 "the committed manifest is consistent with this tree" "ok, base" \
  python3 -I "$SM" show --tree "$(CDPATH= cd -- "$REAL_BOARD/../.." && pwd)"

echo "ALL PASS"
