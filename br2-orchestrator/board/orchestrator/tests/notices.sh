#!/bin/sh
#
# Exercises the notices generator and the inject script without Buildroot or
# mtools: the files the image carries, the base id they name, the fallback
# when no legal-info is present, the size budget, and the refusal to inject
# into an image that is still the one its boot.sig signs.
# Run from anywhere:  sh br2-orchestrator/board/orchestrator/tests/notices.sh
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOARD="$HERE/.."
ROOT="$HERE/../../../.."
GEN="$BOARD/notices/make-notices.sh"
INJECT="$ROOT/scripts/inject-notices.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# A synthetic env so the test does not depend on the committed values.
cat > "$TMP/offer.env" <<'EOF'
SOURCE_BASE_ID='buildroot-2099.01.1+br2-0abc1234+20990102'
SOURCE_BUNDLE_SHA256='0000000000000000000000000000000000000000000000000000000000000001'
SOURCE_FIRST_BASE_DATE='2026-07-28'
SOURCE_OFFER_CONTACT='Example Org, https://example.org'
EOF

# 1. With a legal-info manifest: the component list comes from it.
mkdir -p "$TMP/legal-info"
cat > "$TMP/legal-info/manifest.csv" <<'EOF'
"PACKAGE","VERSION","LICENSE","LICENSE FILES","SOURCE ARCHIVE","SOURCE SITE","DEPENDENCIES WITH LICENSES"
"examplepkg","9.9","GPL-2.0+, MIT (helper, other)","COPYING","examplepkg-9.9.tar.xz","https://example.org/src","skeleton [unknown]"
"rpi-firmware","063bcab6c8a90efb0d19f69d88cbbc7ec79cab68","BSD-3-Clause","boot/LICENCE.broadcom","rpi-firmware.tar.gz","https://example.org/fw",""
"toolchain-external-arm-aarch64","14.2.rel1","unknown","","tc.tar.xz","https://example.org/tc",""
EOF
printf 'Example firmware licence\n' > "$TMP/LICENCE.broadcom"
sh "$GEN" --out "$TMP/out1" --env "$TMP/offer.env" --legal-info "$TMP/legal-info" \
  --firmware-licence "$TMP/LICENCE.broadcom" >/dev/null 2>"$TMP/err1"
offer="$TMP/out1/SOURCE-OFFER.txt"
[ -f "$offer" ] || fail "1: no SOURCE-OFFER.txt"
grep -q '^Base id: *buildroot-2099.01.1+br2-0abc1234+20990102$' "$offer" || fail "1: base id not named"
grep -q 'recovery-image-source-buildroot-2099.01.1+br2-0abc1234+20990102.tar' "$offer" || fail "1: bundle name not derived from the base id"
grep -q '^Built: *2099-01-02 ' "$offer" || fail "1: build date not derived from the base id"
grep -q '0000000000000000000000000000000000000000000000000000000000000001' "$offer" || fail "1: bundle sha256 missing"
grep -q 'examplepkg  *9.9  *GPL-2.0+, MIT (helper, other)' "$offer" || fail "1: manifest component missing or its licence list split on a comma"
grep -q '^Component list of base buildroot-2099.01.1+br2-0abc1234+20990102\.$' "$offer" || fail "1: component list not tied to the base"
grep -q 'the licence of firmware 063bcab6c8a9\.' "$offer" || fail "1: firmware licence not tied to the firmware version"
grep -q -i 'legal-info\|was not available\|no firmware package output\|committed' "$offer" && fail "1: generator state leaked into the offer"
grep 'rpi-firmware' "$offer" | grep -q 'Broadcom/Raspberry Pi binary redistribution licence' || fail "1: firmware row not relabelled"
grep 'rpi-firmware  ' "$offer" | grep -q 'BSD' && fail "1: firmware row still says BSD"
grep 'toolchain-external' "$offer" | grep -q 'LGPL-2.1+ (glibc)' || fail "1: toolchain row not relabelled"
grep 'toolchain-external' "$offer" | grep -q 'unknown' && fail "1: toolchain row still says unknown"
grep -q 'three years' "$offer" || fail "1: validity period missing"
grep -q 'for as long as spare parts or customer support are offered for the' "$offer" || fail "1: GPLv3 6(b) support-period clause missing"
grep -q '2026-07-28' "$offer" || fail "1: earliest suppliable base missing"
grep -q 'cannot be reconstructed' "$offer" || fail "1: past-version statement missing"
grep -q 'predates these notices, not its source' "$offer" || fail "1: notice-less images after the first base not covered"
grep -q 'https://<server>/source/' "$offer" || fail "1: URL pattern missing"
[ -s "$TMP/err1" ] && fail "1: unexpected warning: $(cat "$TMP/err1")"
for f in GPL-2.0.txt GPL-3.0.txt LGPL-2.1.txt Apache-2.0.txt LICENCE.broadcom NOTICE-orchestrator-agent.txt THIRD-PARTY-NOTICES.txt THIRD-PARTY-NOTICES-orchestrator-agent.md; do
  [ -s "$TMP/out1/LICENSES/$f" ] || fail "1: LICENSES/$f missing"
done
[ "$(cat "$TMP/out1/LICENSES/LICENCE.broadcom")" = "Example firmware licence" ] || fail "1: firmware licence not taken from the build"
grep -q 'GNU GENERAL PUBLIC LICENSE' "$TMP/out1/LICENSES/GPL-2.0.txt" || fail "1: GPL-2.0 text is not the licence"
grep -q 'Version 3, 29 June 2007' "$TMP/out1/LICENSES/GPL-3.0.txt" || fail "1: GPL-3.0 text is not the licence"
grep -q 'Version 2.1, February 1999' "$TMP/out1/LICENSES/LGPL-2.1.txt" || fail "1: LGPL-2.1 text is not the licence"
grep -q 'Apache License' "$TMP/out1/LICENSES/Apache-2.0.txt" || fail "1: Apache text is not the licence"
grep -q 'gRPC authors' "$TMP/out1/LICENSES/NOTICE-orchestrator-agent.txt" || fail "1: agent NOTICE lacks the gRPC attribution"
grep -q 'Copyright (c) 2023, Raspberry Pi Ltd' "$TMP/out1/LICENSES/THIRD-PARTY-NOTICES.txt" || fail "1: vcgencmd copyright notice missing"
grep -q 'Julian R Seward' "$TMP/out1/LICENSES/THIRD-PARTY-NOTICES.txt" || fail "1: bzip2 notice missing"
grep -q 'THIRD-PARTY-NOTICES.txt' "$offer" || fail "1: offer does not list the permissive notices"
grep -q 'google.golang.org/grpc' "$TMP/out1/LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md" || fail "1: agent module notices missing"
echo "ok 1: notices generated from a legal-info manifest"

# 2. Without legal-info: the committed list is used, and the offer says so.
sh "$GEN" --out "$TMP/out2" --env "$TMP/offer.env" >/dev/null 2>"$TMP/err2"
grep -q -i 'legal-info\|was not available\|no firmware package output\|committed' "$TMP/out2/SOURCE-OFFER.txt" && fail "2: generator state leaked into the offer"
grep -q '^Component list of base ' "$TMP/out2/SOURCE-OFFER.txt" || fail "2: component list not tied to the base"
grep -q 'busybox' "$TMP/out2/SOURCE-OFFER.txt" || fail "2: committed list not used"
grep -q 'WARNING' "$TMP/err2" || fail "2: no warning about the fallback"
grep -q 'Copyright (c) 2006, Broadcom' "$TMP/out2/LICENSES/LICENCE.broadcom" || fail "2: committed firmware licence not used"
echo "ok 2: committed component list is the fallback, said in the log and not in the offer"

# 2b. --agent-notices replaces the committed copy, and a wrong file is refused.
printf '# Third-party notices: agent and watcher\n\nfresh copy\n' > "$TMP/agent-notices.md"
sh "$GEN" --out "$TMP/out2b" --env "$TMP/offer.env" --agent-notices "$TMP/agent-notices.md" >/dev/null 2>&1 || fail "2b: --agent-notices refused a valid file"
grep -q 'fresh copy' "$TMP/out2b/LICENSES/THIRD-PARTY-NOTICES-orchestrator-agent.md" || fail "2b: --agent-notices was not used"
printf 'something else\n' > "$TMP/wrong.md"
sh "$GEN" --out "$TMP/out2c" --env "$TMP/offer.env" --agent-notices "$TMP/wrong.md" >/dev/null 2>&1 && fail "2b: a file that is not the agent's notices was accepted"
echo "ok 2b: the baked agent's notices can be passed in, and are checked"

# 3. The size budget is enforced.
if NOTICES_BUDGET_BYTES=1000 sh "$GEN" --out "$TMP/out3" --env "$TMP/offer.env" >/dev/null 2>&1; then
  fail "3: an over-budget notices set was accepted"
fi
echo "ok 3: over-budget notices are refused"

# 4. A malformed base id is refused before anything is written.
sed 's/^SOURCE_BASE_ID=.*/SOURCE_BASE_ID="not-a-base"/' "$TMP/offer.env" > "$TMP/bad.env"
if sh "$GEN" --out "$TMP/out4" --env "$TMP/bad.env" >/dev/null 2>&1; then
  fail "4: a malformed base id was accepted"
fi
[ ! -f "$TMP/out4/SOURCE-OFFER.txt" ] || fail "4: offer written despite the refusal"
echo "ok 4: malformed base id is refused"

# 5. inject-notices: argument handling and the dry run need no mtools.
printf 'not really a FAT image\n' > "$TMP/boot.img"
sh "$INJECT" >/dev/null 2>&1 && fail "5: no arguments accepted"
sh "$INJECT" "$TMP/missing.img" >/dev/null 2>&1 && fail "5: missing image accepted"
sh "$INJECT" --dry-run --env "$TMP/offer.env" "$TMP/boot.img" > "$TMP/dry.out" 2>&1 || fail "5: dry run failed: $(cat "$TMP/dry.out")"
grep -q 'SOURCE-OFFER.txt' "$TMP/dry.out" || fail "5: dry run did not list the offer"
grep -q 'LICENSES/GPL-2.0.txt' "$TMP/dry.out" || fail "5: dry run did not list the licences"
echo "ok 5: inject-notices argument handling and dry run"

# 6. inject-notices refuses the image its boot.sig still signs.
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$TMP/boot.img" | cut -d' ' -f1)
  else sum=$(shasum -a 256 "$TMP/boot.img" | cut -d' ' -f1); fi
  printf '%s\nts: 1\nrsa2048: x\n' "$sum" > "$TMP/boot.sig"
  sh "$INJECT" --env "$TMP/offer.env" "$TMP/boot.img" > "$TMP/sig.out" 2>&1 && fail "6: injected into the signed image"
  grep -q 're-sign' "$TMP/sig.out" || fail "6: refusal did not say why: $(cat "$TMP/sig.out")"
  echo "ok 6: the signed image is refused"
else
  echo "skip 6: no sha256 tool"
fi

# 7. Every file the rootfs overlay tracks is named in components-overlay.tsv,
#    which becomes the offer's "Other components" list, and a sha256 recorded
#    there is the file's own.
TSV="$BOARD/notices/components-overlay.tsv"
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$ROOT" ls-files -- br2-orchestrator/board/orchestrator/rootfs-overlay > "$TMP/overlay"
  [ -s "$TMP/overlay" ] || fail "7: no tracked overlay files"
  while IFS= read -r f; do
    rel=${f#br2-orchestrator/board/orchestrator/rootfs-overlay/}
    grep -v '^#' "$TSV" | grep -qF "$rel" || fail "7: the overlay's $rel is not named in components-overlay.tsv"
  done < "$TMP/overlay"
  grep -v '^#' "$TSV" | sed -n 's/.*rootfs overlay \([^,;]*\), sha256 \([0-9a-f]\{64\}\).*/\1 \2/p' > "$TMP/pinned"
  [ -s "$TMP/pinned" ] || fail "7: no overlay file carries a sha256"
  while read -r rel want; do
    f="$BOARD/rootfs-overlay/$rel"
    [ -f "$f" ] || fail "7: components-overlay.tsv pins $rel, which the overlay does not have"
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$f" | cut -d' ' -f1)
    else got=$(shasum -a 256 "$f" | cut -d' ' -f1); fi
    [ "$got" = "$want" ] || fail "7: $rel is $got, components-overlay.tsv says $want"
  done < "$TMP/pinned"
  grep -q 'ca-certificates' "$TMP/out1/SOURCE-OFFER.txt" || fail "7: the offer does not list the CA bundle"
  echo "ok 7: every tracked overlay file is named in the offer's component list, with its sha256 where pinned"
else
  echo "skip 7: not a git checkout"
fi

echo "ALL PASS"
