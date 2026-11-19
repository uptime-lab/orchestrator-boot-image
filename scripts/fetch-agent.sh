#!/bin/sh
#
# Put a RELEASED Orchestrator agent into the rootfs overlay, so the image is
# built from a published, signed artifact rather than from whatever binary
# happens to lie in the tree. The agent is not built here: its source is the
# public mirror https://github.com/uptime-lab/orchestrator-agent, one commit and
# one GitHub Release per version, and the recovery image carries the same
# binary the release's .deb installs.
#
# Usage: scripts/fetch-agent.sh [options] <version>          e.g. 0.8.1
#
#   --deb FILE         use this package instead of downloading it; its detached
#                      signature is FILE.sig
#   --keys DIR         the trusted public keys, one PEM per file (default:
#                      br2-orchestrator/board/orchestrator/agent-keys)
#   --dest FILE        where the binary goes (default: the overlay's
#                      usr/bin/orchestrator-agent)
#   --write-notices    also replace notices/THIRD-PARTY-NOTICES-orchestrator-agent.md
#                      with the copy inside the package, so the notices the
#                      image carries are the baked release's; commit the result
#   --notices-dest FILE  write those notices there instead
#   --release-url URL  an https:// base URL releases are downloaded from
#                      (default: the mirror's GitHub Releases)
#
# The package is accepted only if its detached signature (ECDSA P-384 over
# SHA-384, what the agent itself checks before an update) verifies against one
# of the trusted keys, AND its control file names the package
# orchestrator-agent, the requested version and the arm64 architecture, AND
# the binary it carries is a 64-bit little-endian AArch64 executable. A valid
# signature alone proves only that some release was signed; the control file
# binds it to the version asked for, so an older signed package cannot be
# passed off under a newer label. Any refusal writes nothing: neither the
# binary nor the notices. A fork that signs its own agents replaces the keys
# in --keys.
#
# Requires: openssl, ar, tar, od, and curl unless --deb is given.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOARD="$HERE/../br2-orchestrator/board/orchestrator"

VERSION=""
DEB=""
KEYS="$BOARD/agent-keys"
DEST="$BOARD/rootfs-overlay/usr/bin/orchestrator-agent"
NOTICES_DEST="$BOARD/notices/THIRD-PARTY-NOTICES-orchestrator-agent.md"
WRITE_NOTICES=0
RELEASE_URL="https://github.com/uptime-lab/orchestrator-agent/releases/download"
# A release package is a few tens of MiB; anything far larger is not one.
MAX_BYTES=268435456

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "fetch-agent: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --deb|--keys|--dest|--notices-dest|--release-url)
      [ $# -ge 2 ] || { echo "fetch-agent: $1 needs a value" >&2; usage; }
      case "$1" in
        --deb) DEB=$2 ;;
        --keys) KEYS=$2 ;;
        --dest) DEST=$2 ;;
        --notices-dest) NOTICES_DEST=$2; WRITE_NOTICES=1 ;;
        --release-url) RELEASE_URL=$2 ;;
      esac
      shift 2 ;;
    --write-notices) WRITE_NOTICES=1; shift ;;
    -h|--help) usage ;;
    -*) echo "fetch-agent: unknown option $1" >&2; usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION=$1; shift ;;
  esac
done
[ -n "$VERSION" ] || usage
VERSION=${VERSION#v}
case "$VERSION" in
  *[!0-9A-Za-z.+~-]*|''|[!0-9]*) die "not a version: $VERSION" ;;
esac
case "$RELEASE_URL" in
  https://?*) ;;
  *) die "--release-url must be an https:// URL, got: $RELEASE_URL (use --deb for a local package)" ;;
esac
[ ! -d "$DEST" ] || die "--dest is a directory, not a file: $DEST"
if [ "$WRITE_NOTICES" = 1 ]; then
  [ ! -d "$NOTICES_DEST" ] || die "--notices-dest is a directory, not a file: $NOTICES_DEST"
fi

for tool in openssl ar tar od; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# The temporary directory and the staged copies beside the destinations go on
# every exit, an interrupted one included.
TMP=$(mktemp -d)
STAGED_BIN=""
STAGED_NOTICES=""
cleanup() { rm -rf "$TMP"; rm -f ${STAGED_BIN:+"$STAGED_BIN"} ${STAGED_NOTICES:+"$STAGED_NOTICES"}; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

NAME="orchestrator-agent_${VERSION}_linux_arm64.deb"
if [ -n "$DEB" ]; then
  [ -f "$DEB" ] || die "not a file: $DEB"
  [ -f "$DEB.sig" ] || die "no detached signature beside the package: $DEB.sig"
  cp -- "$DEB" "$TMP/agent.deb"
  cp -- "$DEB.sig" "$TMP/agent.deb.sig"
else
  command -v curl >/dev/null 2>&1 || die "curl is required (or pass --deb)"
  base="${RELEASE_URL%/}/agent-v$VERSION"
  echo ">> fetch-agent: $base/$NAME"
  for f in "$NAME" "$NAME.sig"; do
    case "$f" in *.sig) out="$TMP/agent.deb.sig" ;; *) out="$TMP/agent.deb" ;; esac
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-filesize "$MAX_BYTES" \
      --retry 3 -o "$out" -- "$base/$f" || die "download failed: $base/$f"
  done
fi
[ -s "$TMP/agent.deb" ] || die "empty package"
[ -s "$TMP/agent.deb.sig" ] || die "empty signature"

# Any ONE trusted key is enough, as in the agent's own verifier.
[ -d "$KEYS" ] || die "no key directory: $KEYS"
signer=""
for key in "$KEYS"/*.pem; do
  [ -f "$key" ] || continue
  if openssl dgst -sha384 -verify "$key" -signature "$TMP/agent.deb.sig" "$TMP/agent.deb" >/dev/null 2>&1; then
    signer=$(basename "$key")
    break
  fi
done
[ -n "$signer" ] || die "the signature matches no trusted key in $KEYS; nothing written"
echo ">> fetch-agent: signature verified against $signer"

# untar ARCHIVE DIR: unpack a member of the package by its compression suffix.
untar() {
  case "$1" in
    *.gz) tar -xzf "$1" -C "$2" ;;
    *.xz) tar -xJf "$1" -C "$2" ;;
    *.zst) command -v zstd >/dev/null 2>&1 || die "zstd is required for $(basename "$1")"
           zstd -dc "$1" | tar -xf - -C "$2" ;;
    *) tar -xf "$1" -C "$2" ;;
  esac
}

# first FILE...: the first argument that is a file (a glob that matched nothing
# stays literal and is skipped).
first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 0; }

mkdir "$TMP/deb" "$TMP/control" "$TMP/data"
(cd "$TMP/deb" && ar x ../agent.deb) || die "the package is not an ar archive"

# The control file binds the signed package to the version that was asked for.
ctl=$(first "$TMP/deb"/control.tar*)
[ -n "$ctl" ] || die "the package has no control archive"
untar "$ctl" "$TMP/control" || die "the package's control archive does not unpack"
[ -f "$TMP/control/control" ] || die "the package has no control file"
field() {
  sed -n "s/^$1:[[:space:]]*//p" "$TMP/control/control" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}
pkg=$(field Package)
ver=$(field Version)
arch=$(field Architecture)
[ "$pkg" = "orchestrator-agent" ] || die "the package is '${pkg:-<none>}', not orchestrator-agent; nothing written"
# A release 1.2.3-rc1 is packaged as Debian version 1.2.3~rc1 (a tilde sorts
# before the final release); both spellings name the same release.
case "$VERSION" in
  *-*) deb_version="${VERSION%%-*}~${VERSION#*-}" ;;
  *) deb_version=$VERSION ;;
esac
[ "${ver#v}" = "$VERSION" ] || [ "${ver#v}" = "$deb_version" ] \
  || die "the package is version '${ver:-<none>}', not the requested $VERSION; nothing written"
[ "$arch" = "arm64" ] || die "the package is for architecture '${arch:-<none>}', not arm64; nothing written"
echo ">> fetch-agent: package $pkg $ver ($arch)"

data=$(first "$TMP/deb"/data.tar*)
[ -n "$data" ] || die "the package has no data archive"
untar "$data" "$TMP/data" || die "the package's data archive does not unpack"
bin="$TMP/data/usr/bin/orchestrator-agent"
[ -f "$bin" ] && [ -s "$bin" ] || die "the package carries no usr/bin/orchestrator-agent"

# The image is arm64-only; a binary of another architecture would build and
# then fail on the device. ELF magic, EI_CLASS 2 (64-bit), EI_DATA 1 (little-
# endian), e_type ET_EXEC or ET_DYN, e_machine 0xB7 (AArch64).
hex() { od -An -tx1 -j"$1" -N"$2" "$bin" | tr -d ' \n'; }
[ "$(hex 0 4)" = "7f454c46" ] || die "usr/bin/orchestrator-agent is not an ELF file"
[ "$(hex 4 1)" = "02" ] || die "usr/bin/orchestrator-agent is not a 64-bit ELF file"
[ "$(hex 5 1)" = "01" ] || die "usr/bin/orchestrator-agent is not a little-endian ELF file"
case "$(hex 16 2)" in
  0200|0300) ;;
  *) die "usr/bin/orchestrator-agent is not an executable (ELF type $(hex 16 2))" ;;
esac
[ "$(hex 18 2)" = "b700" ] || die "usr/bin/orchestrator-agent is not a 64-bit Arm executable (machine $(hex 18 2))"

if [ "$WRITE_NOTICES" = 1 ]; then
  notices="$TMP/data/usr/share/doc/orchestrator-agent/THIRD-PARTY-NOTICES.md"
  [ -f "$notices" ] || die "the package carries no THIRD-PARTY-NOTICES.md"
  grep -q '^# Third-party notices: agent and watcher' "$notices" || die "the package's THIRD-PARTY-NOTICES.md is not the generated file"
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Every check has passed. Both files are staged beside their destinations
# first and renamed only then, so a failure while staging writes neither, and
# an interrupted run never leaves half a binary where the build would pick it up.
mkdir -p "$(dirname -- "$DEST")" || die "cannot create the directory of $DEST"
[ "$WRITE_NOTICES" = 0 ] || mkdir -p "$(dirname -- "$NOTICES_DEST")" || die "cannot create the directory of $NOTICES_DEST"
STAGED_BIN="$DEST.tmp.$$"
cp "$bin" "$STAGED_BIN" || die "cannot stage $DEST"
chmod 0755 "$STAGED_BIN"
if [ "$WRITE_NOTICES" = 1 ]; then
  STAGED_NOTICES="$NOTICES_DEST.tmp.$$"
  cp "$notices" "$STAGED_NOTICES" || die "cannot stage $NOTICES_DEST"
fi
mv "$STAGED_BIN" "$DEST"
STAGED_BIN=""
echo ">> fetch-agent: agent $VERSION -> $DEST"
echo "   sha256 $(sha256_of "$DEST")"
if [ "$WRITE_NOTICES" = 1 ]; then
  mv "$STAGED_NOTICES" "$NOTICES_DEST"
  STAGED_NOTICES=""
  echo ">> fetch-agent: notices -> $NOTICES_DEST (commit it with the build)"
fi
