#!/bin/sh
#
# Buildroot post-build hook. Runs against $TARGET_DIR after the rootfs is
# assembled and before it is packed into rootfs.cpio.gz.
#
# Drops /lib/modules. Nothing in this image can load a module: there is no udev
# and no mdev.conf, /etc/modules-load.d does not exist so S11modules exits
# immediately, and the agent never shells out to modprobe or insmod. Everything
# the bootstrap uses — nvme, ext4, vfat, loop, xhci, dwc2, usbhid, evdev,
# simplefb, fbcon — is built into the kernel. The tree cost ~24 MB of a 94 MiB
# image, roughly 70% of the compressed rootfs, and assemble-boot-img.sh takes
# the rootfs from the CM5 build for both SoCs, so the CM4 kernel never had a
# matching module tree to load from in the first place.

set -eu

TARGET_DIR="${1:?post-build.sh needs TARGET_DIR}"

if [ -d "$TARGET_DIR/lib/modules" ]; then
    echo ">> post-build: removing unusable /lib/modules ($(du -sh "$TARGET_DIR/lib/modules" | cut -f1))"
    rm -rf "$TARGET_DIR/lib/modules"
fi
