#!/bin/sh
# stamp-depthcharge.sh — write the U-Boot depthcharge payload into the
# kernel partition and mark it bootable.
#
# 1. dd the payload into the raw depthcharge partition (ubuntu-image
#    leaves filesystem-less structures zeroed)
# 2. repair the GPT (ubuntu-image can leave the backup header/entries
#    CRC-inconsistent; repair is a no-op when already consistent)
# 3. set the ChromeOS kernel GPT attributes: successful=1, tries=15,
#    priority=15 — depthcharge ignores kernel partitions without them
#
# The payload is signed with the ChromeOS devkeys, so the device must
# be in developer mode.
set -e

IMG="$1"
PAYLOAD="$2"
PART="${3:-1}"

if [ -z "$IMG" ] || [ ! -f "$IMG" ] || [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
	echo "usage: $0 <disk-image> <krane-uboot-payload.bin> [partition-number]" >&2
	exit 1
fi

PART_START=$(sgdisk "$IMG" -p 2>/dev/null | awk -v p="$PART" '$1 == p {print $2}')
PART_SIZE_S=$(sgdisk "$IMG" -p 2>/dev/null | awk -v p="$PART" '$1 == p {print $4}')
if [ -z "$PART_START" ]; then
	echo "ERROR: partition $PART not found in $IMG" >&2
	exit 1
fi

PAYLOAD_S=$(( ($(stat -c%s "$PAYLOAD") + 511) / 512 ))
if [ "$PAYLOAD_S" -gt "$PART_SIZE_S" ]; then
	echo "ERROR: payload ($PAYLOAD_S sectors) does not fit partition $PART ($PART_SIZE_S sectors)" >&2
	exit 1
fi

echo "==> dd $PAYLOAD into partition $PART (sector $PART_START)"
dd if="$PAYLOAD" of="$IMG" bs=512 seek="$PART_START" conv=notrunc,fsync

# The partition type must be the exact ChromeOS kernel GUID that
# vboot/depthcharge scan for (cgpt's "-t kernel", U-Boot's
# PARTITION_CROS_KERNEL). Enforce it here so a gadget.yaml typo can
# never ship a partition depthcharge ignores.
sgdisk "$IMG" --typecode="$PART:FE3A2A5D-4F32-41A7-B725-ACCC3285A309"

echo "==> setting kernel GPT attributes (successful=1 tries=15 priority=15)"
cgpt repair "$IMG"
cgpt add -i "$PART" -S 1 -T 15 -P 15 "$IMG"
echo "---- GPT after stamping ----"
cgpt show "$IMG"
# cgpt show hides the attribute bits on some versions; sgdisk prints them
# (expect 01FF000000000000 = priority 15, tries 15, successful 1)
sgdisk -i "$PART" "$IMG" 2>/dev/null | grep -i "Attribute flags" || true
echo "==> done"
