#!/bin/sh
# qemu-e2e.sh — end-to-end smoke test of the built image.
#
# QEMU cannot run depthcharge (it needs the krane SPI firmware), so the
# image is booted with U-Boot directly from -bios. That still exercises
# everything downstream of depthcharge: the GPT, the ESP layout
# (shim/grub → /boot/grub/grub.cfg on the `writable` rootfs), the
# kernel and the desktop init.
#
# The image's kernel cmdline is aimed at the krane hardware
# (console=ttyS0…), which does not exist on the qemu `virt` machine —
# so this test boots a sparse COPY with console=ttyAMA0 appended to the
# grub linux line; the original image is not modified.
#
# Success: the serial log reaches a login prompt within TIMEOUT seconds.
set -e

IMG="$1"
TIMEOUT="${TIMEOUT:-900}"
LOG="${LOG:-qemu-e2e-serial.log}"
TESTIMG=/tmp/krane-e2e.img

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "usage: $0 <disk-image>" >&2
	exit 1
fi

echo "==> copying image (sparse) for the test run"
rm -f "$TESTIMG"
cp --sparse=always "$IMG" "$TESTIMG"

# make the serial console visible on the qemu virt machine
LOOP=$(losetup -Pf --show "$TESTIMG")
cleanup() {
	umount "$MNT" 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
	rm -f "$TESTIMG"
	kill $QPID 2>/dev/null || true
}
trap cleanup EXIT
MNT=$(mktemp -d)
mount "${LOOP}p3" "$MNT"
sed -i '/^\s*linux\s/s/$/ console=ttyAMA0/' "$MNT/boot/grub/grub.cfg"
umount "$MNT"
losetup -d "$LOOP"

rm -f "$LOG"
echo "==> booting (copy of) $IMG in qemu-system-aarch64 (serial → $LOG)"
qemu-system-aarch64 \
	-M virt -cpu cortex-a76 -m 4G -smp 4 \
	-display none \
	-serial file:"$LOG" \
	-bios /usr/lib/u-boot/qemu_arm64/u-boot.bin \
	-device virtio-rng-pci \
	-drive file="$TESTIMG",format=raw,if=virtio &
QPID=$!

echo "==> waiting up to ${TIMEOUT}s for a login prompt"
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
	if grep -q "login:" "$LOG" 2>/dev/null; then
		echo "==> PASS: login prompt reached after ${i}s"
		grep -E "Booting|login:" "$LOG" | tail -5
		trap - EXIT
		rm -f "$TESTIMG"
		kill $QPID 2>/dev/null || true
		exit 0
	fi
	sleep 5
	i=$((i + 5))
done

echo "==> FAIL: no login prompt within ${TIMEOUT}s — last serial output:" >&2
tail -30 "$LOG" >&2
exit 1
