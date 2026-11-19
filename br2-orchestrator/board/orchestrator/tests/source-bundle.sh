#!/bin/sh
#
# Exercises scripts/make-source-bundle.sh against a throwaway repository and
# fake Buildroot output trees (--skip-legal-info, so no Buildroot runs): the
# bundle carries what the written offer says it carries -- this repository at
# the base commit, the external tree AND the scripts that produce the image --
# under the archive name the manifest tooling reads, and a repository with an
# uncommitted change anywhere is refused.
# Needs git and python3; GNU tar where available, else a shim over the
# system tar that drops GNU tar's ordering flags (the contents are what is
# tested here, not byte-for-byte reproducibility).
# Run from anywhere:  sh br2-orchestrator/board/orchestrator/tests/source-bundle.sh
# SOURCE_BUNDLE=<path> runs the cases against another copy of the script.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
BUNDLE_SCRIPT=${SOURCE_BUNDLE:-"$ROOT/scripts/make-source-bundle.sh"}
SM="$HERE/../notices/source-manifest.py"
# shellcheck source-path=SCRIPTDIR source=lib-fake-build.sh
. "$HERE/lib-fake-build.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
for tool in git python3 tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: no $tool"; exit 0; }
done
COPYFILE_DISABLE=1; export COPYFILE_DISABLE

if ! tar --version 2>/dev/null | grep -q GNU; then
  REAL_TAR=$(command -v tar)
  mkdir "$TMP/bin"
  cat > "$TMP/bin/tar" <<SHIM
#!/bin/sh
[ "\$1" = --version ] && { echo "tar (GNU tar) test shim"; exit 0; }
for a do
  shift
  case "\$a" in --sort=name|--owner=0|--group=0|--numeric-owner) continue ;; esac
  set -- "\$@" "\$a"
done
exec "$REAL_TAR" "\$@"
SHIM
  chmod +x "$TMP/bin/tar"
  PATH="$TMP/bin:$PATH"; export PATH
fi

# This repository, as the bundle should carry it: the external tree plus the
# files around it.
fake_repo "$TMP/repo"
mkdir -p "$REPO/scripts"
printf '#!/bin/sh\necho fetch\n' > "$REPO/scripts/fetch-agent.sh"
printf 'test:\n\t@true\n' > "$REPO/Makefile"
printf '# readme\n' > "$REPO/README.md"
printf 'GPL\n' > "$REPO/LICENSE"
git -C "$REPO" add scripts Makefile README.md LICENSE
git -C "$REPO" commit -q -m around
C=$(git -C "$REPO" rev-parse --short=8 HEAD)

# A Buildroot checkout, as far as the script reads one.
BRT="$TMP/buildroot"
mkdir -p "$BRT/configs"
printf 'export BR2_VERSION := %s\n' "$BR_VER" > "$BRT/Makefile"
printf 'BR2_aarch64=y\n' > "$BRT/configs/orchestrator_cm5_defconfig"
git init -q "$BRT"
git -C "$BRT" config user.email test@example.org
git -C "$BRT" config user.name test
git -C "$BRT" config commit.gpgsign false
git -C "$BRT" add .
git -C "$BRT" commit -q -m br

fake_out "$TMP/out-cm4" cm4
fake_out "$TMP/out-cm5" cm5
mkdir -p "$TMP/out-cm4/images/rpi-firmware"
printf 'firmware licence\n' > "$TMP/out-cm4/images/rpi-firmware/LICENCE.broadcom"

run() {
  sh "$BUNDLE_SCRIPT" --buildroot "$BRT" --br2 "$REPO" --out-cm4 "$TMP/out-cm4" --out-cm5 "$TMP/out-cm5" \
    --dest "$TMP/dist" --date 20990301 --skip-legal-info "$@"
}

# 1. The bundle: one top directory named after the base id, this repository
#    at the base commit under the name the manifest tooling reads.
run --write-env >"$TMP/log" 2>&1 || { cat "$TMP/log"; fail "1: the bundle was not produced"; }
ID="buildroot-$BR_VER+br2-$C+20990301"
TAR="$TMP/dist/recovery-image-source-$ID.tar"
[ -f "$TAR" ] || fail "1: no $TAR"
grep -q "^SOURCE_BASE_ID='$ID'\$" "$BOARD/source-offer.env" || fail "1: --write-env did not record the base id"
mkdir "$TMP/x"
tar -xf "$TAR" -C "$TMP/x"
INNER="$TMP/x/recovery-image-source-$ID/br2-orchestrator-$C.tar"
[ -f "$INNER" ] || fail "1: the bundle has no br2-orchestrator-$C.tar"
tar -tf "$INNER" > "$TMP/members"
for p in scripts/fetch-agent.sh Makefile README.md LICENSE .gitignore \
         br2-orchestrator/board/orchestrator/assemble-boot-img.sh \
         br2-orchestrator/board/orchestrator/rootfs-overlay/etc/init.d/S99agent; do
  grep -qx "br2-orchestrator-$C/$p" "$TMP/members" || fail "1: the repository archive lacks $p"
done
grep -q 'scripts/, Makefile' "$TMP/x/recovery-image-source-$ID/BASE.txt" || fail "1: BASE.txt does not say what the archive holds"
echo "ok 1: the bundle carries this repository at the base commit: the external tree and the scripts"

# 2. The written offer promises the scripts; the bundle above is what keeps
#    that promise.
offer_env "$TMP/offer.env" "$ID"
sh "$GENERATOR" --out "$TMP/notices" --env "$TMP/offer.env" >/dev/null 2>&1 || fail "2: make-notices.sh did not run"
tr '\n' ' ' < "$TMP/notices/SOURCE-OFFER.txt" | grep -q 'this external tree and the scripts that produced the image' ||
  fail "2: the offer no longer says what the bundle carries; keep the two in step"
echo "ok 2: the offer names the external tree and the scripts, and the bundle carries both"

# 3. The manifest tooling still reads the bundle: the base id from BASE.txt and
#    the base commit from the archive's name.
python3 -I -B - "$SM" "$TAR" "$C" "$ID" <<'PY' || fail "3: source-manifest.py does not read the bundle"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("source_manifest", sys.argv[1])
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)
b = sm.Bundle(sys.argv[2])
assert b.br2_commits == [sys.argv[3]], b.br2_commits
assert b.get("BASE.txt").decode().startswith("Base id: %s\n" % sys.argv[4])
PY
echo "ok 3: source-manifest.py reads the base commit and the base id from the bundle"

# 4. An uncommitted change anywhere in the repository is refused: the archive
#    is of the commit, so the change would not be in it.
rm -rf "$TMP/dist"
git -C "$REPO" checkout -q -- br2-orchestrator/board/orchestrator/source-offer.env
printf 'echo changed\n' >> "$REPO/scripts/fetch-agent.sh"
if run >"$TMP/log" 2>&1; then fail "4: a dirty scripts/ was accepted"; fi
grep -q 'uncommitted changes' "$TMP/log" || fail "4: wrong refusal: $(cat "$TMP/log")"
echo "ok 4: an uncommitted change outside the external tree is refused too"

echo "ALL PASS"
