#!/bin/sh
#
# Assert that a boot.img carries the licence notices, that its written source
# offer names the base recorded in source-offer.env, and that the image IS
# that base: its kernels, its rootfs apart from the agent (the overlay's other
# files byte for byte, device numbers included), its config.txt and
# cmdline.txt, a LICENSES/ that is exactly the generator's set, and the rest
# of its FAT root measure to what the committed source-manifest records
# (br2-orchestrator/board/orchestrator/notices/source-manifest.py). The offer is generated from source-offer.env, so the
# label check alone only proves the offer was generated from that file; the
# corpus check is what ties the image to the bundle the offer names. This is
# the check to run on a rebaked image before signing it: the SD provisioning
# payload is extracted from the image, so an offer naming the wrong base, or a
# base the image is not, would be copied onto every card.
#
# Usage: scripts/check-notices.sh [--env FILE] [--manifest FILE] <boot.img>
#
#   --env FILE       source-offer.env (default: the committed one)
#   --manifest FILE  the source manifest (default: source-manifest beside the env)
#
# Requires: mtools (mdir, mtype, mcopy) and python3. Exit 0 when every notice
# is present, the base matches and the corpus is the manifest's; 1 otherwise;
# 2 on usage or a missing tool; 3 when nothing failed but a manifest field is
# still pending (not measured yet), which is not a pass.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$HERE/../br2-orchestrator/board/orchestrator/source-offer.env"
MANIFEST=""
CORPUS="$HERE/../br2-orchestrator/board/orchestrator/notices/source-manifest.py"
IMG=""

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_FILE=${2:?--env needs a file}; shift 2 ;;
    --manifest) MANIFEST=${2:?--manifest needs a file}; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "check-notices: unknown option $1" >&2; usage ;;
    *) [ -z "$IMG" ] || usage; IMG=$1; shift ;;
  esac
done
[ -n "$IMG" ] || usage
[ -f "$IMG" ] || { echo "check-notices: not a file: $IMG" >&2; exit 2; }
[ -f "$ENV_FILE" ] || { echo "check-notices: offer facts not found: $ENV_FILE" >&2; exit 2; }
[ -n "$MANIFEST" ] || MANIFEST="$(dirname -- "$ENV_FILE")/source-manifest"
for tool in mdir mtype mcopy; do
  command -v "$tool" >/dev/null 2>&1 || { echo "check-notices: $tool (mtools) is not installed" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "check-notices: python3 is required for the corpus check" >&2; exit 2; }
[ -f "$CORPUS" ] || { echo "check-notices: the corpus check is missing: $CORPUS" >&2; exit 2; }

# shellcheck disable=SC1090
. "$ENV_FILE"
: "${SOURCE_BASE_ID:?SOURCE_BASE_ID missing from $ENV_FILE}"

rc=0
for f in GPL-2.0.txt GPL-3.0.txt LGPL-2.1.txt Apache-2.0.txt LICENCE.broadcom NOTICE-orchestrator-agent.txt THIRD-PARTY-NOTICES.txt THIRD-PARTY-NOTICES-orchestrator-agent.md; do
  if ! mdir -i "$IMG" "::LICENSES/$f" >/dev/null 2>&1; then
    echo "check-notices: missing LICENSES/$f" >&2
    rc=1
  fi
done

if ! offer=$(mtype -i "$IMG" ::SOURCE-OFFER.txt 2>/dev/null); then
  echo "check-notices: SOURCE-OFFER.txt is not in the image" >&2
  exit 1
fi
named=$(printf '%s\n' "$offer" | sed -n 's/^Base id: *//p' | tr -d '\r' | head -1)
if [ "$named" != "$SOURCE_BASE_ID" ]; then
  echo "check-notices: the image's offer names base '${named:-<none>}', source-offer.env says '$SOURCE_BASE_ID'" >&2
  rc=1
fi

# The corpus. The manifest's own base id is compared with the env inside.
set +e
corpus=$(python3 -I "$CORPUS" check --manifest "$MANIFEST" --env "$ENV_FILE" --image "$IMG" 2>&1)
crc=$?
set -e
printf '%s\n' "$corpus" | sed 's/^/check-notices: /' >&2
case "$crc" in
  0) ;;
  3) [ "$rc" -eq 0 ] && rc=3 ;;
  *) rc=1 ;;
esac

case "$rc" in
  0) echo "check-notices: ok, base $SOURCE_BASE_ID with all notices in $IMG, and the image is the corpus $(basename -- "$MANIFEST") records" ;;
  3) echo "check-notices: notices in place, but the corpus check is incomplete (a manifest field is pending): NOT a pass" >&2 ;;
esac
exit "$rc"
