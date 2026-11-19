#!/bin/sh
#
# Generate the notices that travel in the FAT root of boot.img: a LICENSES/
# directory and SOURCE-OFFER.txt. Used by assemble-boot-img.sh at build time
# and by scripts/inject-notices.sh for a rebake, so both paths produce the same
# files from the same inputs.
#
# Usage: make-notices.sh --out DIR [--legal-info DIR] [--firmware-licence FILE]
#                        [--agent-notices FILE] [--env FILE]
#        make-notices.sh --dump-components LEGAL_INFO_DIR
#        make-notices.sh --dump-third-party LEGAL_INFO_DIR
#
#   --out DIR              directory to write LICENSES/ and SOURCE-OFFER.txt into
#   --legal-info DIR       a Buildroot `make legal-info` output directory; its
#                          manifest.csv becomes the component list. Without it,
#                          the committed components-buildroot.tsv is used and a
#                          warning says so.
#   --firmware-licence F   LICENCE.broadcom from the firmware package output;
#                          preferred over the committed copy so a firmware bump
#                          carries its own text.
#   --agent-notices FILE   the agent's THIRD-PARTY-NOTICES.md for the agent
#                          being baked, as its release package ships it
#                          (generated in the agent's source,
#                          https://github.com/uptime-lab/orchestrator-agent);
#                          the rebake passes it. Without it, the committed copy
#                          beside this script is used.
#   --env FILE             source-offer.env to read (default: the one beside
#                          this directory).
#   --dump-components DIR  print the manifest of DIR as the TSV this script
#                          consumes, for refreshing components-buildroot.tsv.
#   --dump-third-party DIR print the permissive (BSD, MIT, ISC, 0BSD) notices
#                          of the packages in DIR/licenses plus the prebuilt
#                          vcgencmd's, for refreshing
#                          LICENSES/THIRD-PARTY-NOTICES.txt.
#
# Everything written is plain text, together well under the 200 KiB the FAT
# image is budgeted to spare for notices; the script refuses to exceed it.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOARD_DIR=$(CDPATH= cd -- "$HERE/.." && pwd)

ENV_FILE="$BOARD_DIR/source-offer.env"
OUT=""
LEGAL_INFO=""
FIRMWARE_LICENCE=""
AGENT_NOTICES=""
DUMP=""
DUMP_THIRD_PARTY=""
NOTICES_BUDGET_BYTES=${NOTICES_BUDGET_BYTES:-204800}

die() { echo "make-notices: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    --legal-info) LEGAL_INFO=${2:?--legal-info needs a directory}; shift 2 ;;
    --firmware-licence) FIRMWARE_LICENCE=${2:?--firmware-licence needs a file}; shift 2 ;;
    --agent-notices) AGENT_NOTICES=${2:?--agent-notices needs a file}; shift 2 ;;
    --env) ENV_FILE=${2:?--env needs a file}; shift 2 ;;
    --dump-components) DUMP=${2:?--dump-components needs a directory}; shift 2 ;;
    --dump-third-party) DUMP_THIRD_PARTY=${2:?--dump-third-party needs a directory}; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# manifest_to_tsv prints package, version and licence of a legal-info
# manifest.csv, one tab-separated line per package. Buildroot writes every
# field double-quoted, so the field separator is the quote-comma-quote
# sequence; a bare comma inside a licence list is therefore not a separator.
manifest_to_tsv() {
  awk -F'","' 'NR > 1 {
    p = $1; sub(/^"/, "", p)
    v = $2
    l = $3
    printf "%s\t%s\t%s\n", p, v, l
  }' "$1"
}

if [ -n "$DUMP" ]; then
  [ -f "$DUMP/manifest.csv" ] || die "no manifest.csv in $DUMP"
  manifest_to_tsv "$DUMP/manifest.csv"
  exit 0
fi

# The BSD-style licences want their notice "in the documentation and/or other
# materials provided WITH the distribution"; the source archive is offered,
# not provided with the image, so these texts travel in the image itself.
# One section per file, in a fixed order; a file a future base no longer has
# is skipped, and the committed copy is refreshed per clean rebuild like
# components-buildroot.tsv.
third_party_section() {
  # $1 title, $2 file, [$3 first N lines only]
  [ -f "$2" ] || return 0
  printf '%s\n' "------------------------------------------------------------------------"
  printf '%s\n\n' "$1"
  if [ -n "${3:-}" ]; then head -n "$3" "$2"; else cat "$2"; fi
  printf '\n'
}
if [ -n "$DUMP_THIRD_PARTY" ]; then
  L="$DUMP_THIRD_PARTY/licenses"
  [ -d "$L" ] || die "no licenses/ in $DUMP_THIRD_PARTY"
  one() { for f in "$L"/$1; do [ -f "$f" ] && { echo "$f"; return; }; done; echo ""; }
  cat <<'EOF'
PERMISSIVE-LICENCE NOTICES OF THIS IMAGE
========================================

The BSD, MIT, ISC and 0BSD notices of the programs in this image, and of the
prebuilt vcgencmd, as their packages ship them. The GPL, LGPL and Apache
texts are the other files in this directory; the source archive named in
SOURCE-OFFER.txt carries every licence file of every package.

EOF
  third_party_section "busybox: bzip2 decompressor (bzip2 licence)" "$(one 'busybox-*/archival/libarchive/bz/LICENSE')"
  third_party_section "e2fsprogs: licensing summary" "$(one 'e2fsprogs-*/NOTICE')" 22
  third_party_section "e2fsprogs: libet (MIT-style)" "$(one 'e2fsprogs-*/lib/et/internal.h')" 12
  third_party_section "e2fsprogs: libss (MIT-style)" "$(one 'e2fsprogs-*/lib/ss/mit-sipb-copyright.h')"
  third_party_section "util-linux: licensing summary" "$(one 'util-linux-*/README.licensing')"
  for lic in BSD-2-Clause BSD-3-Clause BSD-4-Clause-UC ISC MIT; do
    third_party_section "util-linux: $lic (the copyright lines are in the source file headers)" \
      "$(one "util-linux-*/Documentation/licenses/COPYING.$lic")"
  done
  third_party_section "xz: licensing summary" "$(one 'xz-*/COPYING')" 38
  third_party_section "xz: liblzma and the xz tools (0BSD)" "$(one 'xz-*/COPYING.0BSD')"
  third_party_section "vcgencmd: Raspberry Pi utils (BSD-3-Clause)" "$HERE/raspi-utils.LICENCE"
  exit 0
fi

[ -n "$OUT" ] || die "--out is required (see --help)"
[ -f "$ENV_FILE" ] || die "offer facts not found: $ENV_FILE"

# shellcheck disable=SC1090
. "$ENV_FILE"

: "${SOURCE_BASE_ID:?SOURCE_BASE_ID missing from $ENV_FILE}"
: "${SOURCE_BUNDLE_SHA256:?SOURCE_BUNDLE_SHA256 missing from $ENV_FILE}"
: "${SOURCE_FIRST_BASE_DATE:?SOURCE_FIRST_BASE_DATE missing from $ENV_FILE}"
: "${SOURCE_OFFER_CONTACT:?SOURCE_OFFER_CONTACT missing from $ENV_FILE}"

# The base id has one shape, and the bundle name and build date derive from it
# rather than being stored twice.
case "$SOURCE_BASE_ID" in
  buildroot-*+br2-*+[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) die "SOURCE_BASE_ID must look like buildroot-<ver>+br2-<commit>+<YYYYMMDD>, got: $SOURCE_BASE_ID" ;;
esac
case "$SOURCE_BUNDLE_SHA256" in
  *[!0-9a-f]*|"") die "SOURCE_BUNDLE_SHA256 must be 64 lowercase hex characters" ;;
esac
[ ${#SOURCE_BUNDLE_SHA256} -eq 64 ] || die "SOURCE_BUNDLE_SHA256 must be 64 lowercase hex characters"

BUNDLE_NAME="recovery-image-source-${SOURCE_BASE_ID}.tar"

# The toolchain source is a second archive when the env names it; an image
# built with a Buildroot-built toolchain has its libc source in the bundle.
SOURCE_TOOLCHAIN_FILE="${SOURCE_TOOLCHAIN_FILE:-}"
SOURCE_TOOLCHAIN_SHA256="${SOURCE_TOOLCHAIN_SHA256:-}"
if [ -n "$SOURCE_TOOLCHAIN_FILE" ]; then
  case "$SOURCE_TOOLCHAIN_SHA256" in
    *[!0-9a-f]*|"") die "SOURCE_TOOLCHAIN_SHA256 must be 64 lowercase hex characters" ;;
  esac
  [ ${#SOURCE_TOOLCHAIN_SHA256} -eq 64 ] || die "SOURCE_TOOLCHAIN_SHA256 must be 64 lowercase hex characters"
  ARCHIVE_COUNT="two archives"
  TOOLCHAIN_LINES="
  $SOURCE_TOOLCHAIN_FILE
  sha256: $SOURCE_TOOLCHAIN_SHA256
  (the source of the target C library, libgcc and libstdc++, as published by
  Arm for the toolchain the image was built with)
"
  TOOLCHAIN_URL="
  https://<server>/source/$SOURCE_TOOLCHAIN_FILE"
  SERVES="both archives"
  LIBC_NOTE="their source is the second archive
    named in section 1."
else
  ARCHIVE_COUNT="one archive"
  TOOLCHAIN_LINES=""
  TOOLCHAIN_URL=""
  SERVES="that archive"
  LIBC_NOTE="their source is in the archive
    named in section 1."
fi
BUILD_YMD=${SOURCE_BASE_ID##*+}
BUILD_DATE="$(echo "$BUILD_YMD" | cut -c1-4)-$(echo "$BUILD_YMD" | cut -c5-6)-$(echo "$BUILD_YMD" | cut -c7-8)"
BUILDROOT_VERSION=${SOURCE_BASE_ID#buildroot-}
BUILDROOT_VERSION=${BUILDROOT_VERSION%%+*}
BR2_COMMIT=${SOURCE_BASE_ID#*+br2-}
BR2_COMMIT=${BR2_COMMIT%%+*}

# SOURCE_DATE_EPOCH keeps the generated date stable for a reproducible build.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  GENERATED=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d 2>/dev/null || date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%d)
else
  GENERATED=$(date -u +%Y-%m-%d)
fi

mkdir -p "$OUT/LICENSES"

echo ">> notices: licence texts"
for f in GPL-2.0.txt GPL-3.0.txt LGPL-2.1.txt Apache-2.0.txt THIRD-PARTY-NOTICES.txt; do
  [ -f "$HERE/LICENSES/$f" ] || die "missing licence text: $HERE/LICENSES/$f"
  cp "$HERE/LICENSES/$f" "$OUT/LICENSES/$f"
done
cp "$HERE/NOTICE-orchestrator-agent.txt" "$OUT/LICENSES/NOTICE-orchestrator-agent.txt"
# The agent is a binary distribution too: the BSD and MIT notices of the Go
# modules compiled into it travel with it, from the file the agent's source
# generates for exactly that binary set.
if [ -n "$AGENT_NOTICES" ]; then
  [ -f "$AGENT_NOTICES" ] || die "agent notices not found: $AGENT_NOTICES"
  echo ">> notices: agent third-party notices from $AGENT_NOTICES"
else
  AGENT_NOTICES="$HERE/THIRD-PARTY-NOTICES-orchestrator-agent.md"
  echo ">> notices: agent third-party notices from the committed copy"
fi
grep -q '^# Third-party notices: agent and watcher' "$AGENT_NOTICES" || die "$AGENT_NOTICES is not the agent's generated THIRD-PARTY-NOTICES.md"
cp "$AGENT_NOTICES" "$OUT/LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md"

if [ -n "$FIRMWARE_LICENCE" ]; then
  [ -f "$FIRMWARE_LICENCE" ] || die "firmware licence not found: $FIRMWARE_LICENCE"
  cp "$FIRMWARE_LICENCE" "$OUT/LICENSES/LICENCE.broadcom"
  echo ">> notices: LICENCE.broadcom from the firmware package of this build"
else
  cp "$HERE/LICENSES/LICENCE.broadcom" "$OUT/LICENSES/LICENCE.broadcom"
  echo ">> notices: LICENCE.broadcom from the committed copy (no firmware package output given)"
fi

echo ">> notices: component list"
COMPONENTS=$(mktemp)
trap 'rm -f "$COMPONENTS"' EXIT
if [ -n "$LEGAL_INFO" ] && [ -f "$LEGAL_INFO/manifest.csv" ]; then
  manifest_to_tsv "$LEGAL_INFO/manifest.csv" > "$COMPONENTS"
  echo ">> notices: component list from the legal-info manifest in $LEGAL_INFO"
else
  [ -z "$LEGAL_INFO" ] || echo "make-notices: WARNING: no manifest.csv in $LEGAL_INFO; using the committed component list" >&2
  [ -n "$LEGAL_INFO" ] || echo "make-notices: WARNING: no --legal-info given; using the committed component list" >&2
  grep -v '^#' "$HERE/components-buildroot.tsv" > "$COMPONENTS"
fi
[ -s "$COMPONENTS" ] || die "the component list is empty"

# Two rows whose manifest licence is wrong for a legal document. Buildroot
# declares rpi-firmware "BSD-3-Clause", but the firmware is binary-only under
# LICENCE.broadcom: redistribution "without modification", for use with a
# Raspberry Pi device; a field-of-use licence, not BSD. And an external
# toolchain declares "unknown"; what reaches the target from it is glibc
# (LGPL-2.1+) and the GCC runtime (GPL-3.0+ with the Runtime Library
# Exception). The override is by package name, so it holds for every base.
OVERRIDDEN=$(mktemp)
awk -F'\t' 'BEGIN { OFS = "\t" }
  $1 == "rpi-firmware" { $3 = "Broadcom/Raspberry Pi binary redistribution licence (LICENSES/LICENCE.broadcom)" }
  $1 ~ /^toolchain-external/ { $3 = "LGPL-2.1+ (glibc), GPL-3.0+ with GCC Runtime Library Exception (libgcc, libstdc++)" }
  { print }' "$COMPONENTS" > "$OVERRIDDEN"
mv "$OVERRIDDEN" "$COMPONENTS"

# Where the inputs came from is build provenance and goes to the log above;
# the offer names only what they ARE, so a rebake on a host with no build tree
# writes the same legal text as the build did.
FIRMWARE_VERSION=$(awk -F'\t' '$1 == "rpi-firmware" { v = $2; if (v ~ /^[0-9a-f]+$/ && length(v) == 40) v = substr(v, 1, 12); print v; exit }' "$COMPONENTS")
if [ -n "$FIRMWARE_VERSION" ]; then
  BROADCOM_NOTE="the licence of firmware $FIRMWARE_VERSION"
else
  BROADCOM_NOTE="the licence of the firmware of this base"
fi

OFFER="$OUT/SOURCE-OFFER.txt"
{
  cat <<EOF
WRITTEN OFFER FOR CORRESPONDING SOURCE
======================================

Orchestrator recovery image: the HTTP-boot bootstrap for Raspberry Pi
Compute Module 4/5 class boards that the Orchestrator platform serves to
devices and ships inside every SD provisioning bundle.

Base id:          $SOURCE_BASE_ID
Built:            $BUILD_DATE (Buildroot $BUILDROOT_VERSION, external tree commit $BR2_COMMIT)
Notice generated: $GENERATED

This image aggregates programs licensed under the GNU General Public License
versions 2 and 3, the GNU Lesser General Public License version 2.1, the
Apache License 2.0, BSD-style licences and Broadcom's binary redistribution
licence. The texts are in the LICENSES/ directory beside this file. GPL and
LGPL oblige whoever distributes the binaries to make the corresponding source
available; this file is that offer.


1. WHERE THE CORRESPONDING SOURCE IS
------------------------------------

The complete corresponding source for every GPL and LGPL program in this
image, including the build configuration, the Buildroot release, this
external tree and the scripts that produced the image, is $ARCHIVE_COUNT:

  $BUNDLE_NAME
  sha256: $SOURCE_BUNDLE_SHA256
$TOOLCHAIN_LINES
Whoever distributes this image, including the operator of the Orchestrator
install that gave it to you, must make $SERVES available. An install set up
to do so serves them, without a token or an account, at

  https://<server>/source/$BUNDLE_NAME$TOOLCHAIN_URL

where <server> is the host this image was fetched from, or the platform the
SD provisioning bundle was downloaded from (the platform_url in the bundle's
node-adoption.txt). Verify the download against the sha256 above.

If that host does not serve them or is no longer reachable, a copy may be
requested from:

  $SOURCE_OFFER_CONTACT

This offer is valid for at least three years from the date you received this
image, and for as long as spare parts or customer support are offered for the
product model this image is used with, as required by GPL version 2 section
3(b) and GPL version 3 section 6(b). It is made to any third party for no more
than the cost of physically performing the distribution.


2. IMAGES BUILT BEFORE THIS BASE
--------------------------------

The first base whose corresponding source exists is dated
$SOURCE_FIRST_BASE_DATE. Images built before that date predate the build
tree this one comes from and cannot be reconstructed; their source cannot be
supplied. The base of any image is the "Base id" line of its own
SOURCE-OFFER.txt. An image built on or after $SOURCE_FIRST_BASE_DATE that
carries no SOURCE-OFFER.txt predates these notices, not its source: it was
built from a base whose corresponding source exists, and that source is
available on the same terms as this offer, from the same places.


3. WHAT THIS IMAGE CONTAINS
---------------------------

Component list of base $SOURCE_BASE_ID.
Buildroot packages (name, version, licence as declared by the package):

EOF
  # A version that is a full git commit is shown abbreviated; the manifest in
  # the source archive carries it whole.
  awk -F'\t' '{ v = $2; if (v ~ /^[0-9a-f]{40}$/) v = substr(v, 1, 12); printf "  %-32s %-16s %s\n", $1, v, $3 }' "$COMPONENTS"
  cat <<EOF

Other components (not Buildroot packages):

EOF
  grep -v '^#' "$HERE/components-overlay.tsv" | awk -F'\t' '{ printf "  %-32s %-16s %s\n      %s\n", $1, $2, $3, $4 }'
  cat <<EOF

Notes on particular components:

  - linux: the Raspberry Pi kernel (GPL-2.0 with the Linux syscall note);
    the kernel .config for each SoC is in the source archive.
  - rpi-firmware (start4.elf, fixup4.dat, overlays/): binary firmware under
    LICENSES/LICENCE.broadcom, $BROADCOM_NOTE.
    No source exists for it upstream and none is offered.
  - The target C library, libgcc and libstdc++ come from the Arm GNU
    Toolchain used to build the image; $LIBC_NOTE
  - orchestrator-agent is not GPL software; it is licensed under the Apache
    License 2.0, its notice is LICENSES/NOTICE-orchestrator-agent.txt and
    the notices of the modules compiled into it are
    LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md.
    The agent's source is published separately by Uptime Lab Inc.


4. LICENCE TEXTS IN THIS IMAGE
------------------------------

  LICENSES/GPL-2.0.txt                     GNU General Public License v2
  LICENSES/GPL-3.0.txt                     GNU General Public License v3
  LICENSES/LGPL-2.1.txt                    GNU Lesser General Public License v2.1
  LICENSES/Apache-2.0.txt                  Apache License 2.0
  LICENSES/LICENCE.broadcom                Broadcom / Raspberry Pi firmware licence
  LICENSES/NOTICE-orchestrator-agent.txt   Apache NOTICE of the Orchestrator agent
  LICENSES/THIRD-PARTY-NOTICES.txt         BSD, MIT, ISC and 0BSD notices
  LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md
                                           notices of the agent's Go modules

Every licence file of every package is also in the source archive, beside
the program it covers.
EOF
} > "$OFFER"

# The FAT image has a fixed size and the notices must never be what pushes it
# over; a text file that grew by accident is refused here, not on a device.
total=0
for f in "$OUT/LICENSES"/* "$OFFER"; do
  size=$(wc -c < "$f")
  total=$((total + size))
done
[ "$total" -le "$NOTICES_BUDGET_BYTES" ] || die "notices total $total bytes, over the $NOTICES_BUDGET_BYTES-byte budget"

echo ">> notices: $(find "$OUT/LICENSES" -type f | wc -l | tr -d ' ') licence files + SOURCE-OFFER.txt, $total bytes, base $SOURCE_BASE_ID"
