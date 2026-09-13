# Gadget tree Makefile — executed by ubuntu-image (plain `make`, with
# ARCH/SERIES in the environment) inside a copy of this directory.
#
# The two blobs placed into install/ are prebuilt by the top-level
# image/Makefile before ubuntu-image runs:
#   grub/grubaa64.efi          — monolithic GRUB arm64-efi (grub-efi-arm64-unsigned)
#   u-boot/krane-uboot-payload.bin — depthcharge payload (header + shim + u-boot.bin)
#
# Note: no dtb/ directory — the FDT that Linux boots with comes from the
# depthcharge handoff (carried through U-Boot's control DTB), not from the ESP.

DESTDIR ?= install

all:
	mkdir -p $(DESTDIR)
	make install/grub
	make install/u-boot
	make meta

meta:
	mkdir -p $(DESTDIR)/meta
	cp gadget.yaml $(DESTDIR)/meta/

install/grub:
	mkdir -p $(DESTDIR)/grub
	cp grub/grubaa64.efi $(DESTDIR)/grub/
	cp grub.cfg $(DESTDIR)/grub/

install/u-boot:
	mkdir -p $(DESTDIR)/u-boot
	cp u-boot/krane-uboot-payload.bin $(DESTDIR)/u-boot/
