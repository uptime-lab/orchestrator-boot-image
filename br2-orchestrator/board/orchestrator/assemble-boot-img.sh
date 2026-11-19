#!/bin/sh
#
# Assemble a single FAT32 boot.img for CM4+CM5 HTTP-boot from two buildroot
# output trees (one per SoC). Run on the build host (Linux) after both
# `make O=out-cm4` and `make O=out-cm5` have completed.
#
# Usage: assemble-boot-img.sh <out-cm4-dir> <out-cm5-dir> [output-boot.img]
#
# Requires: mtools (mcopy, mmd), dosfstools (mkfs.fat), truncate.

set -eu

OUT_CM4=${1:?need cm4 output dir}
OUT_CM5=${2:?need cm5 output dir}
BOOT_IMG=${3:-boot.img}
BOARD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo ">> collecting kernels"
cp "$OUT_CM4/images/Image" "$STAGE/kernel8.img"       # CM4 / BCM2711
cp "$OUT_CM5/images/Image" "$STAGE/kernel_2712.img"   # CM5 / BCM2712

# Every DTB config.txt can name, and every firmware file a board needs. This
# list is the contract between three files that must agree: the DTS names in
# configs/*-delta.fragment (what gets BUILT), the device_tree= values in
# config.txt (what gets ASKED FOR), and this (what gets SHIPPED). Only this
# script can check it, so it must FAIL rather than warn.
#
# A missing tree is an error, not a warning: a requested but absent
# bcm2712-rpi-5-b.dtb still yields an image that signs and serves, and the miss
# shows up only as a rainbow screen on a real device.
REQUIRED_CM4_FILES="bcm2711-rpi-cm4.dtb bcm2711-rpi-cm4s.dtb bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb"
# The CM5 Lite trees are shipped so a Lite CAN load its own, but note that
# shipping them is not sufficient on its own: config.txt forces
# bcm2712-rpi-cm5-cm5io.dtb globally, so a Lite only gets its own tree via the
# [board-type=0x1a] override. A Lite boots the forced tree whether or not its
# own trees are present.
REQUIRED_CM5_FILES="bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2712-rpi-cm5-cm4io.dtb bcm2712-rpi-cm5l-cm4io.dtb bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-rpi-500.dtb"

echo ">> collecting device trees (fail-closed)"
missing=""
for f in $REQUIRED_CM4_FILES; do
  if [ -f "$OUT_CM4/images/$f" ]; then
    cp "$OUT_CM4/images/$f" "$STAGE/"
  else
    missing="$missing $f"
  fi
done
for f in $REQUIRED_CM5_FILES; do
  if [ -f "$OUT_CM5/images/$f" ]; then
    cp "$OUT_CM5/images/$f" "$STAGE/"
  else
    missing="$missing $f"
  fi
done
if [ -n "$missing" ]; then
  echo "ERROR: device trees missing from the build output:$missing" >&2
  echo "       add them to BR2_LINUX_KERNEL_INTREE_DTS_NAME in configs/*-delta.fragment" >&2
  exit 1
fi

echo ">> GPU firmware (CM4/BCM2711 second-stage: start4.elf + fixup4.dat)"
# Required for CM4 — the bootloader loads start4.elf from the ramdisk to bring
# up the GPU/firmware and load the kernel. CM5/BCM2712 does not use these
# (its firmware lives in the bootloader) and simply ignores them. Fatal if
# absent: without start4.elf no BCM2711 board boots this image at all.
for f in start4.elf fixup4.dat; do
  if [ ! -f "$OUT_CM4/images/rpi-firmware/$f" ]; then
    echo "ERROR: $f missing from $OUT_CM4/images/rpi-firmware/" >&2
    exit 1
  fi
  cp "$OUT_CM4/images/rpi-firmware/$f" "$STAGE/"
done

echo ">> collecting overlays (ALL of them — do not trim)"
# Ship the COMPLETE overlay set. Trimming it to the two config.txt references
# looked free — 0.85 MB out of an image with 31 MB spare — and cost a board
# class: the firmware AUTO-APPLIES bcm2712d0.dtbo on D0-stepping BCM2712, and
# without it a 16GB CM5 Lite ran a non-D0 device tree and died writing pinctrl
# registers that do not exist at those addresses:
#
#   pc : bcm2712_pull_config_set / brcmuart_init / pinctrl_bind_pins
#   Kernel panic - not syncing: Asynchronous SError Interrupt
#
# Nothing in config.txt references that overlay, because nothing has to — the
# firmware decides. So "which overlays does this image reference" is the wrong
# question, and any future trim needs to answer "which overlays might the
# FIRMWARE apply on hardware we have not tested", which is unanswerable.
if [ ! -d "$OUT_CM4/images/rpi-firmware/overlays" ]; then
  echo "ERROR: overlays directory missing from the CM4 build output" >&2
  exit 1
fi
mkdir -p "$STAGE/overlays"
cp -a "$OUT_CM4"/images/rpi-firmware/overlays/* "$STAGE/overlays/"
# The D0 overlay is the one with a known failure mode; assert it explicitly.
if [ ! -f "$STAGE/overlays/bcm2712d0.dtbo" ]; then
  echo "ERROR: bcm2712d0.dtbo missing — D0-stepping BCM2712 boards will panic" >&2
  exit 1
fi

echo ">> shared rootfs (initramfs)"
# Both builds should produce an identical userspace; take CM5's.
cp "$OUT_CM5/images/rootfs.cpio.gz" "$STAGE/rootfs.cpio.gz"

echo ">> firmware config"
cp "$BOARD_DIR/config.txt"  "$STAGE/config.txt"
cp "$BOARD_DIR/cmdline.txt" "$STAGE/cmdline.txt"

echo ">> licence notices and the written source offer"
# LICENSES/ and SOURCE-OFFER.txt go into the FAT root, so they travel with the
# image wherever it goes: the HTTP-boot fetch, and every SD provisioning bundle,
# which is extracted from this same root. The component list comes from the
# CM5 tree's legal-info output when `make legal-info` was run (the README's
# recipe does), and from the committed list otherwise; the Broadcom licence
# comes from the firmware package of THIS build, so a firmware bump carries its
# own text rather than a copy that stopped matching.
# The agent in the rootfs is the one in the overlay, so no separate licence
# step exists for it: its NOTICE is one of the committed notice files.
# The base the offer will name must be the base that was BUILT: the Buildroot
# release in both output trees' .config and the commit of this tree. Comparing
# the image's offer with source-offer.env (below, and in check-notices.sh) only
# proves the offer was generated from that file; it cannot see a clean rebuild
# whose env still names the previous base and the previous bundle's sha256.
# ALLOW_UNCOMMITTED_MANIFEST=1 is the first build of a new base only, while the
# manifest `source-manifest.py generate` just wrote is not yet committed.
if [ "${ALLOW_UNCOMMITTED_MANIFEST:-0}" = 1 ]; then
  "$BOARD_DIR/notices/check-built-base.sh" --allow-uncommitted-manifest "$OUT_CM4" "$OUT_CM5"
else
  "$BOARD_DIR/notices/check-built-base.sh" "$OUT_CM4" "$OUT_CM5"
fi

# The firmware's licence text. Buildroot's rpi-firmware package does not
# install it into images/; `make legal-info` saves it under the package's
# versioned directory, and a tree that carries it beside start4.elf is
# accepted too. Exactly one candidate, or the build stops.
FIRMWARE_LICENCE=""
for f in "$OUT_CM4/images/rpi-firmware/LICENCE.broadcom" \
         "$OUT_CM4"/legal-info/licenses/rpi-firmware-*/boot/LICENCE.broadcom; do
  [ -f "$f" ] || continue
  if [ -n "$FIRMWARE_LICENCE" ] && ! cmp -s "$f" "$FIRMWARE_LICENCE"; then
    echo "ERROR: more than one LICENCE.broadcom under $OUT_CM4 and they differ: $FIRMWARE_LICENCE, $f" >&2
    exit 1
  fi
  FIRMWARE_LICENCE=$f
done
if [ -z "$FIRMWARE_LICENCE" ]; then
  echo "ERROR: no LICENCE.broadcom under $OUT_CM4 (images/rpi-firmware/ or legal-info/licenses/rpi-firmware-*/boot/); run 'make legal-info' in that output tree first" >&2
  exit 1
fi
"$BOARD_DIR/notices/make-notices.sh" --out "$STAGE" \
  --legal-info "$OUT_CM5/legal-info" --firmware-licence "$FIRMWARE_LICENCE"

echo ">> checking config.txt against what was staged"
# Catch the mismatch this script exists to catch: a device_tree= naming a file
# nobody built. Cheap, and it fails the build instead of a device.
for dt in $(sed -n 's/^[[:space:]]*device_tree=\([^[:space:]]*\).*/\1/p' "$BOARD_DIR/config.txt"); do
  if [ ! -f "$STAGE/$dt" ]; then
    echo "ERROR: config.txt names device_tree=$dt, which is not in the image" >&2
    exit 1
  fi
done

echo ">> building FAT32 image: $BOOT_IMG"
# 94 MiB. The oft-repeated "96 MB is the bootloader's hard ramdisk limit" has
# no citation in the RPi documentation, usbboot or either rpi-eeprom
# release-notes file, and an image of exactly 96 MiB has booted. Treat the
# number as an unproven convention rather than a documented limit — and if
# headroom is ever needed, the two UNCOMPRESSED 23 MiB kernel Images are where
# ~28 MiB is hiding.
truncate -s 94M "$BOOT_IMG"
mkfs.fat -F 32 -n BOOT "$BOOT_IMG" >/dev/null

# Copy everything in. Recreate the subdirectories (overlays/, LICENSES/) first:
# mcopy without -s refuses a directory, and the rest of the stage is flat.
for sub in overlays LICENSES; do
  if [ -d "$STAGE/$sub" ]; then
    mmd   -i "$BOOT_IMG" "::$sub"
    mcopy -i "$BOOT_IMG" -s "$STAGE/$sub"/* "::$sub/"
    rm -rf "${STAGE:?}/$sub"
  fi
done
mcopy -i "$BOOT_IMG" "$STAGE"/* ::

echo ">> checking that the image names the base in source-offer.env"
# Read back from the image rather than trusting the stage: this is the line
# scripts/check-notices.sh asserts before signing, and it must hold for the
# bytes that get signed.
# Inline rather than scripts/check-notices.sh so a build host that carries only
# the br2-orchestrator directory can still run this script.
# shellcheck disable=SC1091
. "$BOARD_DIR/source-offer.env"
if ! mtype -i "$BOOT_IMG" ::SOURCE-OFFER.txt | grep -q "^Base id: *${SOURCE_BASE_ID}\$"; then
  echo "ERROR: SOURCE-OFFER.txt in $BOOT_IMG does not name base $SOURCE_BASE_ID" >&2
  exit 1
fi

echo ">> done. contents:"
mdir -i "$BOOT_IMG" ::
ls -la "$BOOT_IMG"
