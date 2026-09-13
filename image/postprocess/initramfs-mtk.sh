#!/bin/sh
# initramfs-mtk.sh — make the initrd bring up the MT8183 boot chain
# deterministically.
#
# Root cause (krane-fb-stub research rounds 46-48): everything defers on
# MT6358 regulators — eMMC (ldo_vio18), USB (ldo_vusb), GPU, and the
# whole MT8183 power-controller/display forest — and udev does not load
# the regulator module inside the initrd. The PMIC chain must be loaded
# explicitly, before udev coldplug:
#
#     mtk_pmic_wrap -> mt6397 (MFD) -> mt6358_regulator
#
# Also ensured: USB T-PHY + storage (the rootfs lives on a USB thumb
# drive) and the native display chain (MMSYS/mutex/DSI/panel/PWM/
# backlight) so the panel stays lit when the kernel takes over from
# U-Boot scanout instead of going dark during the initrd.
#
# Generator auto-detection:
#   dracut           — /etc/dracut.conf.d/50-mtk-boot.conf
#                      (add_drivers + install_items) and the pre-udev
#                      hook at /var/lib/dracut/hooks/pre-udev/
#                      01-mtk-pmic.sh (round 48: runtime hookdir is
#                      /var/lib/dracut/hooks; force_load does not work)
#   initramfs-tools  — /etc/initramfs-tools/modules (baked into
#                      /conf/modules; the init script's load_modules
#                      runs before init-premount/udev coldplug)
#
# Both configs persist in the rootfs, so apt-triggered initramfs
# regenerations keep the fix.
#
# usage: initramfs-mtk.sh <disk-image>    (run as root)
set -e

IMG="$1"
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "usage: $0 <disk-image>" >&2
	exit 1
fi

# modules wanted in the initrd, in load order (initramfs-tools path
# loads them in this order; modprobe normalizes -/_)
WANTED="
mtk-pmic-wrap
mt6397
mt6358-regulator
phy-mtk-tphy
usb-storage
uas
mtk-mmsys
mtk-mutex
mediatek-drm
phy-mtk-mipi-dsi-drv
panel-boe-tv101wum-nl6
pwm-mediatek
pwm-bl
"

LOOP=$(losetup -Pf --show "$IMG")
cleanup() {
	umount "$MNT/boot/efi" 2>/dev/null || true
	umount "$MNT/dev/pts" 2>/dev/null || true
	umount "$MNT/dev" 2>/dev/null || true
	umount "$MNT/proc" 2>/dev/null || true
	umount "$MNT/sys" 2>/dev/null || true
	umount "$MNT" 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

MNT=$(mktemp -d)
mount "${LOOP}p3" "$MNT"

KVER=$(ls "$MNT/lib/modules" | head -1)
echo "==> rootfs kernel: $KVER"

# resolve which of the wanted modules actually exist in this rootfs
# (kernel module filenames mix dashes and underscores — try both)
MODS=""
for m in $WANTED; do
	found=$(find "$MNT/lib/modules/$KVER" -name "$m.ko*" -o -name "$(echo "$m" | tr - _).ko*" | head -1)
	if [ -n "$found" ]; then
		MODS="$MODS $m"
	else
		echo "    (skip $m — not present)"
	fi
done
echo "==> initrd module list:$MODS"

# ---- serial console on the pogo UART (round 46 cmdline, minus earlycon)
CONSOLE_CFG="$MNT/etc/default/grub.d/60-krane-serial.cfg"
if [ ! -f "$CONSOLE_CFG" ]; then
	mkdir -p "$MNT/etc/default/grub.d"
	cat > "$CONSOLE_CFG" <<'EOF'
# krane: panel + pogo serial console. "quiet" is dropped so the serial
# UART stays verbose through plymouth/initramfs.
GRUB_CMDLINE_LINUX_DEFAULT="splash"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"
EOF
	echo "==> wrote $(basename "$CONSOLE_CFG")"
fi

# ---- generator-specific configuration
if [ -x "$MNT/usr/bin/dracut" ]; then
	GENERATOR=dracut
	echo "==> configuring dracut"
	mkdir -p "$MNT/etc/dracut.conf.d" "$MNT/var/lib/dracut/hooks/pre-udev"

	cat > "$MNT/etc/dracut.conf.d/50-mtk-boot.conf" <<EOF
# MT8183 krane boot chain — see postprocess/initramfs-mtk.sh
add_drivers+=" $MODS "
install_items+=" /var/lib/dracut/hooks/pre-udev/01-mtk-pmic.sh "
EOF

	cat > "$MNT/var/lib/dracut/hooks/pre-udev/01-mtk-pmic.sh" <<'EOF'
#!/bin/sh
# MT6358 regulators must register before udev coldplug: mmc/usb and the
# whole power-domain/display tree defer on them.
modprobe mtk_pmic_wrap 2>/dev/null
modprobe mt6397 2>/dev/null
modprobe mt6358_regulator 2>/dev/null
exit 0
EOF
	chmod +x "$MNT/var/lib/dracut/hooks/pre-udev/01-mtk-pmic.sh"

	REGENT="dracut -f --kver $KVER"
elif [ -x "$MNT/usr/sbin/update-initramfs" ]; then
	GENERATOR=initramfs-tools
	echo "==> configuring initramfs-tools"
	MODULES_FILE="$MNT/etc/initramfs-tools/modules"
	touch "$MODULES_FILE"
	{
		echo ""
		echo "# MT8183 krane boot chain — see postprocess/initramfs-mtk.sh"
		for m in $MODS; do
			grep -q "^$m\$" "$MODULES_FILE" || echo "$m"
		done
	} >> "$MODULES_FILE"

	REGENT="update-initramfs -u -k $KVER"
else
	echo "ERROR: no initramfs generator found in rootfs" >&2
	exit 1
fi

# ---- regenerate the initrd and grub.cfg inside the rootfs
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

echo "==> chroot: $REGENT"
chroot "$MNT" $REGENT

echo "==> chroot: update-grub"
chroot "$MNT" update-grub

echo "==> done ($GENERATOR)"
