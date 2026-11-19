#!/bin/sh
#
# Exercises S99agent's per_device_adoption() against a fake card.
#
# This lives outside rootfs-overlay/ on purpose — it must not ship in the image.
# Run it from anywhere:  sh br2-orchestrator/board/orchestrator/tests/s99agent-master-card.sh
#
# What it protects: the rule that a MASTER provisioning card stays reusable.
# The agent rewrites whatever adoption file it was started with once the
# platform hands it an identity, so pointing it at the card's own blob silently
# converts a master card into one node's card — and every later device is then
# refused with a fingerprint mismatch and simply never appears. That failure is
# invisible from the platform side, which is why it is worth a test.
set -e

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$HERE/../rootfs-overlay/etc/init.d/S99agent"
[ -f "$SRC" ] || { echo "cannot find S99agent at $SRC"; exit 1; }

TMP=$(mktemp -d)
trap 'chmod 755 "$TMP/card" 2>/dev/null; rm -rf "$TMP"' EXIT

# Strip the trailing dispatch block so the file can be sourced.
sed '/^case "\$1" in/,$d' "$SRC" > "$TMP/lib.sh"
. "$TMP/lib.sh"

say() { echo "LOG: $*"; }

CARD_MNT="$TMP/card"
CARD_ADOPTION="$CARD_MNT/node-adoption.txt"
CARD_NODES_DIR="$CARD_MNT/nodes"
mkdir -p "$CARD_MNT"

blob() { printf '%s' "$1" | base64 | tr -d '\n'; }
MASTER=$(blob '{"account_id":"a","master_token":"mt-shared","platform_url":"https://example.org","grpc_endpoint":"g","created_at":1}')
NODE=$(blob '{"account_id":"a","node_id":"n1","unique_token":"ut-1","platform_url":"https://example.org","grpc_endpoint":"g","created_at":1}')

fail() { echo "FAIL: $1"; exit 1; }

# 1. Master blob + readable serial -> per-device copy, seeded from the master.
printf '%s' "$MASTER" > "$CARD_ADOPTION"
board_serial() { echo "10000000deadbeef"; }
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_NODES_DIR/10000000deadbeef.txt" ] || fail "1: got $ADOPTION"
[ -f "$ADOPTION" ] || fail "1: per-device file not created"
[ "$(cat "$ADOPTION")" = "$MASTER" ] || fail "1: per-device seed differs from master"
echo "ok 1: master card redirected to nodes/<serial>.txt"

# 2. The agent rewrites the per-device copy; the master must survive, and the
#    stored identity must not be reseeded on the next boot.
printf '%s' "$NODE" > "$ADOPTION"
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_NODES_DIR/10000000deadbeef.txt" ] || fail "2: got $ADOPTION"
[ "$(cat "$ADOPTION")" = "$NODE" ] || fail "2: per-device copy was reseeded, identity lost"
[ "$(cat "$CARD_ADOPTION")" = "$MASTER" ] || fail "2: master blob was overwritten"
echo "ok 2: identity persists and the master blob is untouched"

# 3. A second board gets its own file from the same card.
board_serial() { echo "10000000cafef00d"; }
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_NODES_DIR/10000000cafef00d.txt" ] || fail "3: got $ADOPTION"
[ "$(cat "$ADOPTION")" = "$MASTER" ] || fail "3: second board did not get the master blob"
echo "ok 3: a second board enrols from the same card"

# 4. A per-NODE card (the Re-adopt download) carries no master token and must be
#    used as-is — redirecting it would put the identity somewhere the operator
#    did not put it.
printf '%s' "$NODE" > "$CARD_ADOPTION"
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_ADOPTION" ] || fail "4: got $ADOPTION"
echo "ok 4: a per-node card is used as-is"

# 5/6. Both failure modes fall back to the master blob: enrolling and damaging
#      the card beats not enrolling at all.
printf '%s' "$MASTER" > "$CARD_ADOPTION"
board_serial() { echo ""; }
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_ADOPTION" ] || fail "5: got $ADOPTION"
echo "ok 5: no serial -> falls back to the master blob"

board_serial() { echo "1000000012345678"; }
rm -rf "$CARD_NODES_DIR"
chmod 555 "$CARD_MNT"
per_device_adoption "$CARD_ADOPTION"
chmod 755 "$CARD_MNT"
[ "$ADOPTION" = "$CARD_ADOPTION" ] || fail "6: got $ADOPTION"
echo "ok 6: unwritable card -> falls back to the master blob"

# 7. An EMPTY master_token is not a master card. The platform's encoder omits
#    the field, but a blob that carries it empty must not be misread.
EMPTY=$(blob '{"account_id":"a","node_id":"n1","unique_token":"ut","master_token":"","platform_url":"https://x","grpc_endpoint":"g"}')
printf '%s' "$EMPTY" > "$CARD_ADOPTION"
per_device_adoption "$CARD_ADOPTION"
[ "$ADOPTION" = "$CARD_ADOPTION" ] || fail "7: got $ADOPTION"
echo "ok 7: empty master_token is not treated as a master card"

echo "ALL PASS"
