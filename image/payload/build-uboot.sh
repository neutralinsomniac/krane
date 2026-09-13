#!/bin/sh
# build-uboot.sh — build the krane U-Boot from source.
#
#   upstream u-boot tag v2026.10-rc4 + the patch series in ../../u-boot
#   (board support, display, USB, EFI boot, kernel-handoff fixups).
#
# The series is applied with `patch -l --fuzz=3` rather than `git am`:
# patch 0007's boot/image-fdt.c context drifted after the series' base
# (527115ef, contained in rc4); with fuzz it applies unchanged. See
# the -EEXIST hunk in boot/image-fdt.c to confirm the intent survived.
#
# Idempotent: skips everything when build/u-boot/u-boot.bin is newer
# than the newest patch in the series, and the patch application is
# stamped (a re-run on a patched tree would otherwise prompt on
# already-applied hunks).
#
# Output: build/u-boot/u-boot.bin (+ u-boot.sym, u-boot.dtb), consumed
# by build-uboot-payload.sh. The symbol sanity checks (PIE constraints)
# live there; this script just warns if they fail.
set -e
cd "$(dirname "$0")"

UPSTREAM_URL="${UPSTREAM_URL:-https://git.u-boot-project.org/u-boot/u-boot.git}"
UPSTREAM_REF="${UPSTREAM_REF:-v2026.10-rc4}"
PATCHES_DIR="${PATCHES_DIR:-../../u-boot}"
SRC_DIR="${SRC_DIR:-build/u-boot}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

NEWEST_PATCH=$(ls -t "$PATCHES_DIR"/*.patch | head -1)
if [ -f "$SRC_DIR/u-boot.bin" ] && [ "$SRC_DIR/u-boot.bin" -nt "$NEWEST_PATCH" ]; then
	echo "==> $SRC_DIR/u-boot.bin up to date with $PATCHES_DIR — skipping"
	exit 0
fi

if [ ! -d "$SRC_DIR" ]; then
	mkdir -p "$(dirname "$SRC_DIR")"
	git init -q "$SRC_DIR"
	git -C "$SRC_DIR" remote add origin "$UPSTREAM_URL"
	echo "==> fetching upstream u-boot ref $UPSTREAM_REF"
	git -C "$SRC_DIR" fetch --depth 1 -q origin "refs/tags/$UPSTREAM_REF:refs/tags/$UPSTREAM_REF"
	git -C "$SRC_DIR" checkout -q "$UPSTREAM_REF"
fi

if [ ! -f "$SRC_DIR/.patched" ]; then
	echo "==> applying patch series from $PATCHES_DIR onto $UPSTREAM_REF"
	for p in "$PATCHES_DIR"/*.patch; do
		patch -d "$SRC_DIR" -p1 -s -l --fuzz=3 --forward < "$p"
	done
	touch "$SRC_DIR/.patched"
fi

echo "==> building (defconfig: mt8183_kukui_krane)"
make -C "$SRC_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm mrproper
make -C "$SRC_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm mt8183_kukui_krane_defconfig
make -C "$SRC_DIR" CROSS_COMPILE="$CROSS_COMPILE" ARCH=arm -j"$(nproc)"

START=$(awk '$NF == "_start" {print $1}' "$SRC_DIR/u-boot.sym")
COPY=$(awk '$NF == "__image_copy_start" {print $1}' "$SRC_DIR/u-boot.sym")
echo "==> _start=$START __image_copy_start=$COPY"
if [ "$START" != "$COPY" ] || [ "$START" != "000000004c001000" ]; then
	echo "WARNING: PIE constraint violated (_start must equal __image_copy_start and be 0x4c001000) — build-uboot-payload.sh will fail." >&2
fi

echo "==> done: $SRC_DIR/u-boot.bin"
