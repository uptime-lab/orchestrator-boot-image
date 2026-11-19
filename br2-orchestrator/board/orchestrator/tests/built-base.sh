#!/bin/sh
#
# Exercises notices/check-built-base.sh against a throwaway git repository
# and fake Buildroot output trees: the base id in source-offer.env must name
# the Buildroot release in each .config and the commit of the external tree,
# with source-offer.env the only file allowed to be uncommitted (the manifest
# too, but only with --allow-uncommitted-manifest, the generator's first run),
# HEAD the build commit or a descendant that changed only the base's records,
# and the build must be the corpus source-manifest records.
# Run from anywhere:  sh br2-orchestrator/board/orchestrator/tests/built-base.sh
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/../notices/check-built-base.sh"
SM="$HERE/../notices/source-manifest.py"
# shellcheck source-path=SCRIPTDIR source=lib-fake-build.sh
. "$HERE/lib-fake-build.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

command -v git >/dev/null 2>&1 || { echo "skip: no git"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: no python3"; exit 0; }
command -v cpio >/dev/null 2>&1 || { echo "skip: no cpio"; exit 0; }

fake_repo "$TMP/repo"
C1=$(git -C "$REPO" rev-parse --short=8 HEAD)
fake_out "$TMP/out-cm4" cm4
fake_out "$TMP/out-cm5" cm5

write_env() { printf "SOURCE_BASE_ID='%s'\n" "$1" > "$BOARD/source-offer.env"; }
run_strict() { sh "$CHECK" --env "$BOARD/source-offer.env" --tree "$TREE" "$TMP/out-cm4" "$TMP/out-cm5"; }
run() { sh "$CHECK" --allow-uncommitted-manifest --env "$BOARD/source-offer.env" --tree "$TREE" "$TMP/out-cm4" "$TMP/out-cm5"; }
generate() {
  python3 -I "$SM" generate --env "$BOARD/source-offer.env" --tree "$TREE" \
    --out-cm4 "$TMP/out-cm4" --out-cm5 "$TMP/out-cm5" >/dev/null
}

# 1. The env names what was built and the manifest records it. An uncommitted
#    manifest is accepted only with --allow-uncommitted-manifest (the
#    generator's first run); committed on top of the build commit, the two
#    records are accepted without it.
write_env "buildroot-$BR_VER+br2-$C1+20990301"
generate
run >/dev/null 2>"$TMP/err" || fail "1: a matching base was refused: $(cat "$TMP/err")"
git -C "$REPO" add br2-orchestrator/board/orchestrator/source-offer.env && git -C "$REPO" commit -q -m env-only
run_strict >/dev/null 2>"$TMP/err" && fail "1: an uncommitted manifest was accepted without the flag"
grep -q 'allow-uncommitted-manifest' "$TMP/err" || fail "1: the refusal does not name the flag: $(cat "$TMP/err")"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m records
run_strict >/dev/null 2>"$TMP/err" || fail "1: the committed records on top of the build were refused: $(cat "$TMP/err")"
echo "ok 1: the built base is accepted; an uncommitted manifest only on the first run, committed records always"

# 2. The env still names the previous commit: refused.
printf 'echo changed\n' > "$BOARD/post-build.sh"
git -C "$REPO" commit -q -am two
run >/dev/null 2>"$TMP/err" && fail "2: an env naming the previous commit was accepted"
grep -q 'make-source-bundle.sh --write-env' "$TMP/err" || fail "2: refusal does not name the remedy: $(cat "$TMP/err")"
echo "ok 2: a stale commit in the env is refused"

# 3. A different Buildroot release: refused.
C2=$(git -C "$REPO" rev-parse --short=8 HEAD)
write_env "buildroot-2098.11.0+br2-$C2+20990301"
run >/dev/null 2>"$TMP/err" && fail "3: a different Buildroot release was accepted"
grep -q "built with Buildroot $BR_VER" "$TMP/err" || fail "3: wrong refusal: $(cat "$TMP/err")"
echo "ok 3: a different Buildroot release is refused"

# 4. An uncommitted change elsewhere in the tree: refused.
write_env "buildroot-$BR_VER+br2-$C2+20990301"
generate
run >/dev/null 2>&1 || fail "4: precondition: the matching base should pass"
printf 'echo dirty\n' > "$BOARD/post-build.sh"
run >/dev/null 2>"$TMP/err" && fail "4: a dirty tree was accepted"
grep -q 'uncommitted changes' "$TMP/err" || fail "4: wrong refusal: $(cat "$TMP/err")"
git -C "$REPO" checkout -q -- br2-orchestrator/board/orchestrator/post-build.sh
echo "ok 4: an uncommitted change outside the base's records is refused"

# 5. The version header and the commit are unchanged, but the .config and the
#    rootfs content are not: the labels alone would pass, the corpus check
#    refuses each on its own.
run >/dev/null 2>&1 || fail "5: precondition: the matching base should pass"
cp "$TMP/out-cm5/.config" "$TMP/config.good"
printf 'BR2_PACKAGE_DROPBEAR=y\n' >> "$TMP/out-cm5/.config"
run >/dev/null 2>"$TMP/err" && fail "5: a changed .config with the same header and commit was accepted"
grep -q 'not the corpus the manifest records' "$TMP/err" || fail "5: wrong refusal: $(cat "$TMP/err")"
cp "$TMP/config.good" "$TMP/out-cm5/.config"
printf 'busybox 1.37.0 patched\n' > "$TMP/out-cm5/target/bin/busybox"; pack_rootfs "$TMP/out-cm5"
run >/dev/null 2>"$TMP/err" && fail "5: a changed rootfs with the same header and commit was accepted"
grep -q 'not the corpus the manifest records' "$TMP/err" || fail "5: wrong refusal: $(cat "$TMP/err")"
printf 'busybox 1.37.0\n' > "$TMP/out-cm5/target/bin/busybox"
printf 'agent 3.0.0\n' > "$TMP/out-cm5/target/usr/bin/orchestrator-agent"; pack_rootfs "$TMP/out-cm5" rev
run >/dev/null 2>"$TMP/err" || fail "5: an agent-only change was refused: $(cat "$TMP/err")"
echo "ok 5: a config or rootfs change under the same label is refused; an agent-only change is not"

# 6. No manifest, or a pending field: refused, never waved through.
mv "$BOARD/source-manifest" "$TMP/manifest.good"
run >/dev/null 2>"$TMP/err" && fail "6: a build with no manifest was accepted"
sed 's/^rootfs_stripped_sha256 .*/rootfs_stripped_sha256 pending/' "$TMP/manifest.good" > "$BOARD/source-manifest"
run >/dev/null 2>"$TMP/err" && fail "6: a pending rootfs digest was accepted"
grep -q 'pending is not a pass' "$TMP/err" || fail "6: wrong refusal: $(cat "$TMP/err")"
mv "$TMP/manifest.good" "$BOARD/source-manifest"
echo "ok 6: a missing manifest and a pending field are refused"

# 7. Output trees from two releases, a missing .config, one output tree: refused.
printf '# Buildroot 2099.05.0 Configuration\n' > "$TMP/out-cm5/.config"
run >/dev/null 2>"$TMP/err" && fail "7: two Buildroot releases were accepted"
rm "$TMP/out-cm5/.config"
set +e; run >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || fail "7: a missing .config gave exit $rc, want 2"
set +e; sh "$CHECK" --allow-uncommitted-manifest --env "$BOARD/source-offer.env" --tree "$TREE" "$TMP/out-cm4" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || fail "7: a single output tree gave exit $rc, want 2"
echo "ok 7: mixed releases, a missing .config and a lone output tree are refused"

echo "ALL PASS"
