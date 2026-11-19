#!/bin/sh
#
# Produce the corresponding-source bundle for a clean build of the recovery
# image: recovery-image-source-<base id>.tar, the archive every install serves
# at /source/<name> and the one SOURCE-OFFER.txt in the image names.
#
# The bundle is Buildroot's `make legal-info` output PLUS what legal-info
# leaves out: Buildroot itself at the release used, this repository at the
# commit the build consumed (the external tree, the scripts that build,
# check and assemble the image, the Makefile, the READMEs and the licence),
# the generated defconfigs and the kernel and BusyBox .configs, and the
# firmware licence. One top-level directory named after the base id, packed
# with GNU tar in a stable order.
#
# Usage: scripts/make-source-bundle.sh --buildroot DIR --out-cm4 DIR --out-cm5 DIR
#                                      --dest DIR [options]
#
#   --buildroot DIR         Buildroot git checkout the build ran in
#   --br2 DIR               this repository (default: the one holding this script)
#   --out-cm4 DIR           Buildroot output tree of the BCM2711 build (O=)
#   --out-cm5 DIR           Buildroot output tree of the BCM2712 build (O=)
#   --dest DIR              where the bundle directory and tar are written
#   --base-id ID            override the derived buildroot-<ver>+br2-<commit>+<YYYYMMDD>
#   --date YYYYMMDD         build date for the derived id (default: today, UTC)
#   --skip-legal-info       reuse existing out-*/legal-info instead of running make
#                           (the recipe runs legal-info first, to refresh the
#                           committed notices before the base commit is named)
#   --image FILE            a boot.img to inventory (sha256 of the image and, with
#                           mtools, of every file in its FAT root); repeatable
#   --toolchain-source FILE the toolchain vendor's source snapshot, added under
#                           toolchain-source/; see the warning the script prints
#   --extra FILE            any further file to add under extra/; repeatable
#   --write-env             record the base id and bundle sha256 in
#                           br2-orchestrator/board/orchestrator/source-offer.env
#
# Requires: GNU tar, git, sha256sum (or shasum), make (unless --skip-legal-info).

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BR2=$(CDPATH= cd -- "$HERE/.." && pwd)
BUILDROOT=""; OUT_CM4=""; OUT_CM5=""; DEST=""
BASE_ID=""; DATE=""; SKIP_LEGAL=0; WRITE_ENV=0
IMAGES=""; EXTRAS=""; TOOLCHAIN_SRC=""

die() { echo "make-source-bundle: $*" >&2; exit 1; }
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --buildroot) BUILDROOT=${2:?}; shift 2 ;;
    --br2) BR2=${2:?}; shift 2 ;;
    --out-cm4) OUT_CM4=${2:?}; shift 2 ;;
    --out-cm5) OUT_CM5=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --base-id) BASE_ID=${2:?}; shift 2 ;;
    --date) DATE=${2:?}; shift 2 ;;
    --skip-legal-info) SKIP_LEGAL=1; shift ;;
    --image) IMAGES="$IMAGES
${2:?}"; shift 2 ;;
    --toolchain-source) TOOLCHAIN_SRC=${2:?}; shift 2 ;;
    --extra) EXTRAS="$EXTRAS
${2:?}"; shift 2 ;;
    --write-env) WRITE_ENV=1; shift ;;
    -h|--help) usage ;;
    *) echo "make-source-bundle: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$BUILDROOT" ] && [ -n "$OUT_CM4" ] && [ -n "$OUT_CM5" ] && [ -n "$DEST" ] || usage
for d in "$BUILDROOT" "$OUT_CM4" "$OUT_CM5" "$BR2"; do
  [ -d "$d" ] || die "not a directory: $d"
done
tar --version 2>/dev/null | grep -q GNU || die "GNU tar is required (--sort=name)"
command -v git >/dev/null 2>&1 || die "git is required"
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

# Buildroot's version from its Makefile works for a shallow or grafted clone
# where `git describe` has no tag to find; the archive still needs git.
BR_VERSION=$(sed -n 's/^export BR2_VERSION := *//p' "$BUILDROOT/Makefile" | head -1)
[ -n "$BR_VERSION" ] || die "cannot read BR2_VERSION from $BUILDROOT/Makefile"
git -C "$BUILDROOT" rev-parse --verify HEAD >/dev/null 2>&1 || die "$BUILDROOT is not a git checkout"
if [ -n "$(git -C "$BUILDROOT" status --porcelain --untracked-files=no)" ]; then
  die "$BUILDROOT has tracked modifications; the archive would not be what the base id names"
fi

# The base id names a COMMIT of this repository, and the bundle archives that
# commit; an uncommitted change in a tracked file would make the bundle differ
# from the id's claim.
BR2_COMMIT=$(git -C "$BR2" rev-parse --short=8 HEAD) || die "$BR2 is not a git checkout"
if [ -n "$(git -C "$BR2" status --porcelain --untracked-files=no)" ]; then
  die "$BR2 has uncommitted changes; commit them first"
fi

[ -n "$DATE" ] || DATE=$(date -u +%Y%m%d)
[ -n "$BASE_ID" ] || BASE_ID="buildroot-${BR_VERSION}+br2-${BR2_COMMIT}+${DATE}"
NAME="recovery-image-source-${BASE_ID}"
D="$DEST/$NAME"
[ ! -e "$D" ] || die "$D already exists; remove it first"
mkdir -p "$D"

if [ "$SKIP_LEGAL" -eq 0 ]; then
  echo ">> make legal-info (cm5, cm4)"
  make -C "$BUILDROOT" O="$OUT_CM5" BR2_EXTERNAL="$BR2/br2-orchestrator" legal-info
  make -C "$BUILDROOT" O="$OUT_CM4" BR2_EXTERNAL="$BR2/br2-orchestrator" legal-info
fi
[ -f "$OUT_CM5/legal-info/manifest.csv" ] || die "no legal-info output in $OUT_CM5"
[ -f "$OUT_CM4/legal-info/manifest.csv" ] || die "no legal-info output in $OUT_CM4"

echo ">> Buildroot $BR_VERSION and this repository at $BR2_COMMIT"
git -C "$BUILDROOT" archive --format=tar --prefix="buildroot-${BR_VERSION}/" HEAD > "$D/buildroot-${BR_VERSION}.tar"
# Every tracked file of the commit: the external tree and the scripts around
# it. The archive keeps the br2-orchestrator-<commit>.tar name the manifest
# tooling looks for (notices/source-manifest.py, Bundle.BR2_TAR).
git -C "$BR2" archive --format=tar --prefix="br2-orchestrator-${BR2_COMMIT}/" HEAD > "$D/br2-orchestrator-${BR2_COMMIT}.tar"

echo ">> legal-info trees"
cp -a "$OUT_CM5/legal-info" "$D/legal-info-cm5"
mkdir -p "$D/legal-info-cm4"
for f in README buildroot.config manifest.csv host-manifest.csv legal-info.sha256; do
  [ -f "$OUT_CM4/legal-info/$f" ] && cp "$OUT_CM4/legal-info/$f" "$D/legal-info-cm4/"
done

echo ">> configurations"
mkdir -p "$D/configs"
for soc in cm4 cm5; do
  [ -f "$BUILDROOT/configs/orchestrator_${soc}_defconfig" ] && cp "$BUILDROOT/configs/orchestrator_${soc}_defconfig" "$D/configs/"
done
cp "$OUT_CM4/.config" "$D/configs/buildroot-out-cm4.config"
cp "$OUT_CM5/.config" "$D/configs/buildroot-out-cm5.config"
copy_build_config() {  # out-dir, build-dir glob, destination name
  found=""
  for dir in "$1"/build/$2; do
    [ -f "$dir/.config" ] || continue
    found="$dir/.config"
  done
  [ -n "$found" ] || die "no .config under $1/build/$2"
  cp "$found" "$D/configs/$3"
}
copy_build_config "$OUT_CM4" "linux-[!h]*" linux-cm4-bcm2711.config
copy_build_config "$OUT_CM5" "linux-[!h]*" linux-cm5-bcm2712.config
copy_build_config "$OUT_CM4" "busybox-*" busybox-cm4.config
copy_build_config "$OUT_CM5" "busybox-*" busybox-cm5.config

echo ">> firmware licence"
if [ -f "$OUT_CM4/images/rpi-firmware/LICENCE.broadcom" ]; then
  cp "$OUT_CM4/images/rpi-firmware/LICENCE.broadcom" "$D/LICENCE.broadcom"
else
  cp "$BR2/br2-orchestrator/board/orchestrator/notices/LICENSES/LICENCE.broadcom" "$D/LICENCE.broadcom"
fi

if [ -n "$IMAGES" ]; then
  echo ">> image inventory"
  mkdir -p "$D/image-inventory"
  n=0
  printf '%s\n' "$IMAGES" | sed '/^$/d' | while IFS= read -r img; do
    n=$((n + 1))
    [ -f "$img" ] || die "image not found: $img"
    $SHA "$img" > "$D/image-inventory/image-$n.sha256"
    if command -v mcopy >/dev/null 2>&1; then
      fat=$(mktemp -d)
      mcopy -i "$img" -s "::/*" "$fat/"
      # shellcheck disable=SC2086
      (cd "$fat" && find . -type f | sort | xargs $SHA) > "$D/image-inventory/image-$n-fat-root.sha256"
      rm -rf "$fat"
    fi
  done
fi

if [ -n "$TOOLCHAIN_SRC" ]; then
  [ -f "$TOOLCHAIN_SRC" ] || die "toolchain source not found: $TOOLCHAIN_SRC"
  mkdir -p "$D/toolchain-source"
  cp "$TOOLCHAIN_SRC" "$D/toolchain-source/"
fi
printf '%s\n' "$EXTRAS" | sed '/^$/d' | while IFS= read -r f; do
  [ -f "$f" ] || die "extra file not found: $f"
  mkdir -p "$D/extra"
  cp "$f" "$D/extra/"
done

# A prebuilt external toolchain is listed by legal-info with licence "unknown"
# and only its BINARY tarball saved; the target libc, libgcc and libstdc++
# come from it, and their source has to be added by hand from the vendor.
TOOLCHAIN_GAP=""
if grep -q '^"toolchain-external[^"]*","[^"]*","unknown"' "$OUT_CM5/legal-info/manifest.csv"; then
  if [ -z "$TOOLCHAIN_SRC" ]; then
    TOOLCHAIN_GAP="yes"
    echo "make-source-bundle: WARNING: the external toolchain's source is NOT in this bundle;" >&2
    echo "                    pass --toolchain-source <vendor source snapshot> before publishing the offer" >&2
  fi
fi

echo ">> BASE.txt"
{
  echo "Base id: $BASE_ID"
  echo "Buildroot: $BR_VERSION, commit $(git -C "$BUILDROOT" rev-parse HEAD)"
  echo "External tree (orchestrator-boot-image): commit $(git -C "$BR2" rev-parse HEAD)"
  echo "Bundle produced: $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/make-source-bundle.sh"
  echo
  echo "Layout:"
  echo "  buildroot-${BR_VERSION}.tar           git archive of Buildroot at the commit above"
  echo "  br2-orchestrator-${BR2_COMMIT}.tar     git archive of orchestrator-boot-image at the commit above: the"
  echo "                                        external tree (br2-orchestrator/), scripts/, Makefile, READMEs, LICENSE"
  echo "  legal-info-cm5/                       full 'make legal-info' output of the BCM2712 build (sources, patches, licences)"
  echo "  legal-info-cm4/                       manifests and configuration of the BCM2711 build (same sources, proven by legal-info.sha256)"
  echo "  configs/                              generated defconfigs, Buildroot .configs, kernel and BusyBox .configs"
  echo "  LICENCE.broadcom                      the firmware package's licence"
  [ -n "$IMAGES" ] && echo "  image-inventory/                      sha256 of the inventoried image(s) and of every file in their FAT root"
  [ -n "$TOOLCHAIN_SRC" ] && echo "  toolchain-source/                     the toolchain vendor's source snapshot"
  echo
  if [ -n "$TOOLCHAIN_GAP" ]; then
    echo "KNOWN GAP: the target C library, libgcc and libstdc++ come from the prebuilt"
    echo "external toolchain named in legal-info-cm5/manifest.csv; its source is not in"
    echo "this archive and is published by the toolchain vendor beside the binary release."
  fi
} > "$D/BASE.txt"

echo ">> packing"
( cd "$DEST" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$NAME.tar" "$NAME" )
SUM=$($SHA "$DEST/$NAME.tar" | cut -d' ' -f1)
echo "$SUM  $NAME.tar" > "$DEST/$NAME.tar.sha256"
echo ">> $DEST/$NAME.tar"
echo ">> sha256 $SUM"
echo
echo "source-offer.env values for this base:"
echo "  SOURCE_BASE_ID='$BASE_ID'"
echo "  SOURCE_BUNDLE_SHA256='$SUM'"

if [ "$WRITE_ENV" -eq 1 ]; then
  ENV_FILE="$BR2/br2-orchestrator/board/orchestrator/source-offer.env"
  tmp=$(mktemp)
  sed -e "s|^SOURCE_BASE_ID=.*|SOURCE_BASE_ID='$BASE_ID'|" \
      -e "s|^SOURCE_BUNDLE_SHA256=.*|SOURCE_BUNDLE_SHA256='$SUM'|" "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  echo ">> wrote $ENV_FILE (base id and bundle sha256; the toolchain fields are edited by hand)"
fi
