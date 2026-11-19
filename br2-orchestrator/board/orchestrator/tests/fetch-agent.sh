#!/bin/sh
#
# Exercises scripts/fetch-agent.sh without the network: a synthetic package
# signed with a throwaway key is accepted, and every check the script makes
# has a case that is refused, with nothing written, when that check alone
# fails: the signature (tampered, missing, untrusted, no key), the control
# file (package name, version, architecture), the binary (absent, not ELF,
# 32-bit, big-endian, not an executable, another machine), the notices (not
# the generated file; a destination that cannot be written leaves no binary
# either), the arguments (a version that is not one, a non-https release URL,
# a destination that is a directory).
# Run from anywhere:  sh br2-orchestrator/board/orchestrator/tests/fetch-agent.sh
# FETCH_AGENT=<path> runs the cases against another copy of the script.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="$HERE/../../../.."
FETCH=${FETCH_AGENT:-"$ROOT/scripts/fetch-agent.sh"}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

for tool in openssl ar tar od; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done
# No AppleDouble members from a macOS tar.
COPYFILE_DISABLE=1; export COPYFILE_DISABLE

# Two throwaway P-384 keys: one trusted, one not.
mkdir "$TMP/keys" "$TMP/other"
openssl ecparam -name secp384r1 -genkey -noout -out "$TMP/trusted.key" 2>/dev/null
openssl ec -in "$TMP/trusted.key" -pubout -out "$TMP/keys/trusted.pem" 2>/dev/null
openssl ecparam -name secp384r1 -genkey -noout -out "$TMP/stranger.key" 2>/dev/null

# ar_pack OUT MEMBER...: the common ar format dpkg-deb writes (space-padded
# names with no trailing slash, members padded to an even length), written
# here byte by byte so GNU ar and BSD ar both read the fixture.
ar_pack() {
  out=$1; shift
  printf '!<arch>\n' > "$out"
  for m in "$@"; do
    s=$(wc -c < "$m" | tr -d ' ')
    printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$(basename "$m")" 0 0 0 100644 "$s" >> "$out"
    cat "$m" >> "$out"
    [ $((s % 2)) -eq 0 ] || printf '\n' >> "$out"
  done
}

# make_deb DIR [key=value...]: a .deb whose agent is a 20-byte ELF header stub.
#   class= data= type= machine=  the ELF bytes, as printf octal escapes
#   magic=                       the first four bytes (default \177ELF)
#   pkg= ver= arch=              the control file's fields
#   bin=no                       no usr/bin/orchestrator-agent at all
#   head=                        the first line of the notices file
make_deb() {
  d=$1; shift
  magic='\177ELF' class='\002' data='\001' type='\003\000' machine='\267\000'
  pkg=orchestrator-agent ver=0.0.1 arch=arm64 bin=yes head='# Third-party notices: agent and watcher'
  for kv in "$@"; do
    case "$kv" in
      magic=*) magic=${kv#*=} ;; class=*) class=${kv#*=} ;; data=*) data=${kv#*=} ;;
      type=*) type=${kv#*=} ;; machine=*) machine=${kv#*=} ;;
      pkg=*) pkg=${kv#*=} ;; ver=*) ver=${kv#*=} ;; arch=*) arch=${kv#*=} ;;
      bin=*) bin=${kv#*=} ;; head=*) head=${kv#*=} ;;
      *) fail "make_deb: unknown $kv" ;;
    esac
  done
  mkdir -p "$d/tree/usr/bin" "$d/tree/usr/share/doc/orchestrator-agent" "$d/ctl"
  if [ "$bin" = yes ]; then
    # shellcheck disable=SC2059 # the fields are printf escapes on purpose
    printf "$magic$class$data"'\001\000\000\000\000\000\000\000\000\000'"$type$machine" \
      > "$d/tree/usr/bin/orchestrator-agent"
  fi
  printf '%s\n\nsynthetic\n' "$head" > "$d/tree/usr/share/doc/orchestrator-agent/THIRD-PARTY-NOTICES.md"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test\nDescription: synthetic\n' \
    "$pkg" "$ver" "$arch" > "$d/ctl/control"
  (cd "$d/tree" && tar -czf ../data.tar.gz ./usr)
  (cd "$d/ctl" && tar -czf ../control.tar.gz ./control)
  printf '2.0\n' > "$d/debian-binary"
  ar_pack "$d/agent.deb" "$d/debian-binary" "$d/control.tar.gz" "$d/data.tar.gz"
}
sign() { openssl dgst -sha384 -sign "$1" -out "$2.sig" "$2"; }
# signed_deb NAME [key=value...]: make_deb in $TMP/NAME, signed by the trusted key.
signed_deb() { n=$1; shift; mkdir "$TMP/$n"; make_deb "$TMP/$n" "$@"; sign "$TMP/trusted.key" "$TMP/$n/agent.deb"; }

signed_deb good

# 1. A package signed by a trusted key: the binary and the notices land, and
#    a "v" before the requested version is the same version.
sh "$FETCH" --deb "$TMP/good/agent.deb" --keys "$TMP/keys" --dest "$TMP/out1/agent" \
  --notices-dest "$TMP/out1/notices.md" 0.0.1 >/dev/null 2>"$TMP/err1" || fail "1: refused a good package: $(cat "$TMP/err1")"
cmp -s "$TMP/out1/agent" "$TMP/good/tree/usr/bin/orchestrator-agent" || fail "1: the binary is not the package's"
[ -x "$TMP/out1/agent" ] || fail "1: the binary is not executable"
grep -q synthetic "$TMP/out1/notices.md" || fail "1: the notices were not written"
sh "$FETCH" --deb "$TMP/good/agent.deb" --keys "$TMP/keys" --dest "$TMP/out1v/agent" v0.0.1 \
  >/dev/null 2>"$TMP/err1" || fail "1: refused v0.0.1 for a 0.0.1 package: $(cat "$TMP/err1")"

# refused <case> <expected message fragment> <args...>: must exit non-zero,
# say why, and write nothing: no binary and no notices (every case asks for
# the notices; an argument of the case's own overrides the default). The
# version requested is $V, 0.0.1 unless set.
refused() {
  n=$1; want=$2; shift 2
  if sh "$FETCH" --notices-dest "$TMP/out$n/notices.md" "$@" --dest "$TMP/out$n/agent" "${V:-0.0.1}" \
      >/dev/null 2>"$TMP/err$n"; then
    fail "$n: accepted"
  fi
  grep -q -- "$want" "$TMP/err$n" || fail "$n: wrong reason: $(cat "$TMP/err$n")"
  [ ! -e "$TMP/out$n/agent" ] || fail "$n: wrote a binary anyway"
  [ ! -e "$TMP/out$n/notices.md" ] || fail "$n: wrote the notices anyway"
  if [ -d "$TMP/out$n" ] && [ -n "$(ls -A "$TMP/out$n")" ]; then
    fail "$n: left files behind: $(ls -A "$TMP/out$n")"
  fi
  echo "ok $n: refused ($want)"
}
K="--keys $TMP/keys"

# 2. One byte appended after signing.
mkdir "$TMP/tampered"
cp "$TMP/good/agent.deb" "$TMP/tampered/agent.deb"; cp "$TMP/good/agent.deb.sig" "$TMP/tampered/agent.deb.sig"
printf 'x' >> "$TMP/tampered/agent.deb"
# shellcheck disable=SC2086
refused 2 "matches no trusted key" --deb "$TMP/tampered/agent.deb" $K

# 3. No signature beside the package.
mkdir "$TMP/unsigned"; cp "$TMP/good/agent.deb" "$TMP/unsigned/agent.deb"
# shellcheck disable=SC2086
refused 3 "no detached signature" --deb "$TMP/unsigned/agent.deb" $K

# 4. Signed, by a key that is not trusted.
mkdir "$TMP/stranger"; cp "$TMP/good/agent.deb" "$TMP/stranger/agent.deb"
sign "$TMP/stranger.key" "$TMP/stranger/agent.deb"
# shellcheck disable=SC2086
refused 4 "matches no trusted key" --deb "$TMP/stranger/agent.deb" $K

# 5. An empty key directory trusts nobody.
refused 5 "matches no trusted key" --deb "$TMP/good/agent.deb" --keys "$TMP/other"

# 6. A correctly signed package for another machine (x86-64, 0x3e).
signed_deb amd64 machine='\076\000'
# shellcheck disable=SC2086
refused 6 "not a 64-bit Arm executable" --deb "$TMP/amd64/agent.deb" $K

# 7. The committed keys are public keys, and at least one is present.
n=0
for key in "$ROOT"/br2-orchestrator/board/orchestrator/agent-keys/*.pem; do
  [ -f "$key" ] || continue
  head -1 "$key" | grep -q '^-----BEGIN PUBLIC KEY-----$' || fail "7: $key is not a public key"
  openssl pkey -pubin -in "$key" -noout 2>/dev/null || fail "7: $key does not parse"
  n=$((n + 1))
done
[ "$n" -ge 1 ] || fail "7: no trusted key is committed"
echo "ok 7: the committed keys are public keys"

# 8-10. Validly signed, but the control file is not the package asked for: an
#    older version under the requested label, another architecture, another
#    package.
signed_deb oldver ver=0.0.0
# shellcheck disable=SC2086
refused 8 "not the requested 0.0.1" --deb "$TMP/oldver/agent.deb" $K
# 8b. A pre-release: the tag says 0.0.1-rc1, the package 0.0.1~rc1. Accepted
#     under its own name, refused under the final release's.
signed_deb prerel ver='0.0.1~rc1'
sh "$FETCH" --deb "$TMP/prerel/agent.deb" $K --dest "$TMP/out8b/agent" 0.0.1-rc1 >/dev/null 2>"$TMP/err8b" \
  || fail "8b: refused a pre-release under its own version: $(cat "$TMP/err8b")"
[ -x "$TMP/out8b/agent" ] || fail "8b: the pre-release binary was not written"
refused 8c "not the requested 0.0.1" --deb "$TMP/prerel/agent.deb" $K
signed_deb amd64ctl arch=amd64
# shellcheck disable=SC2086
refused 9 "not arm64" --deb "$TMP/amd64ctl/agent.deb" $K
signed_deb otherpkg pkg=orchestrator-agent-dbg
# shellcheck disable=SC2086
refused 10 "not orchestrator-agent" --deb "$TMP/otherpkg/agent.deb" $K

# 11-14. The ELF header, one field at a time; each stub is otherwise AArch64.
signed_deb elf32 class='\001'
# shellcheck disable=SC2086
refused 11 "not a 64-bit ELF" --deb "$TMP/elf32/agent.deb" $K
signed_deb bigend data='\002'
# shellcheck disable=SC2086
refused 12 "not a little-endian ELF" --deb "$TMP/bigend/agent.deb" $K
signed_deb reloc type='\001\000'
# shellcheck disable=SC2086
refused 13 "not an executable" --deb "$TMP/reloc/agent.deb" $K
signed_deb notelf magic='#!/b'
# shellcheck disable=SC2086
refused 14 "not an ELF file" --deb "$TMP/notelf/agent.deb" $K

# 15. A package without the binary.
signed_deb nobin bin=no
# shellcheck disable=SC2086
refused 15 "carries no usr/bin/orchestrator-agent" --deb "$TMP/nobin/agent.deb" $K

# 16. Notices asked for, but the package's file is not the generated one.
signed_deb nohead head='# Something else'
# shellcheck disable=SC2086
refused 16 "is not the generated file" --deb "$TMP/nohead/agent.deb" $K

# 17. A run refused AFTER the package unpacked (wrong version) leaves no
#     notices file where one was asked for, and the destination it would have
#     replaced keeps its bytes.
mkdir -p "$TMP/out17keep"; printf 'previous notices\n' > "$TMP/out17keep/notices.md"
# shellcheck disable=SC2086
refused 17 "not the requested 0.0.1" --deb "$TMP/oldver/agent.deb" $K
# shellcheck disable=SC2086
if sh "$FETCH" --deb "$TMP/oldver/agent.deb" $K --dest "$TMP/out17keep/agent" \
    --notices-dest "$TMP/out17keep/notices.md" 0.0.1 >/dev/null 2>&1; then
  fail "17: accepted"
fi
[ "$(cat "$TMP/out17keep/notices.md")" = "previous notices" ] || fail "17: the existing notices were replaced"
[ ! -e "$TMP/out17keep/agent" ] || fail "17: wrote a binary anyway"

# 18. A notices destination that cannot be written: refused before the
#     binary is put in place, so the two never disagree.
: > "$TMP/afile"
# shellcheck disable=SC2086
refused 18 "cannot create the directory of" --deb "$TMP/good/agent.deb" $K --notices-dest "$TMP/afile/notices.md"

# 19. A release URL that is not https is refused before any download.
# shellcheck disable=SC2086
refused 19 "must be an https:// URL" --release-url "http://127.0.0.1:9/releases" $K

# 20. A version string that is not a version.
V='0.0.1;x'
# shellcheck disable=SC2086
refused 20 "not a version" --deb "$TMP/good/agent.deb" $K
V='../0.0.1'
# shellcheck disable=SC2086
refused 20b "not a version" --deb "$TMP/good/agent.deb" $K
unset V

# 21. A destination that is an existing directory.
mkdir -p "$TMP/destdir"
# shellcheck disable=SC2086
if sh "$FETCH" --deb "$TMP/good/agent.deb" $K --dest "$TMP/destdir" 0.0.1 >/dev/null 2>"$TMP/err21"; then
  fail "21: accepted a directory as --dest"
fi
grep -q "is a directory" "$TMP/err21" || fail "21: wrong reason: $(cat "$TMP/err21")"
[ -z "$(ls -A "$TMP/destdir")" ] || fail "21: wrote into the directory: $(ls -A "$TMP/destdir")"
echo "ok 21: a directory as --dest is refused"

echo "fetch-agent: all cases passed"
