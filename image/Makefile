# Top-level Makefile for the krane Ubuntu 26.10 "stonking" desktop image.
#
# Layout of the produced disk (GPT):
#   p1 depthcharge  — ChromeOS kernel partition: U-Boot depthcharge payload
#                     (arm64 Image header + entry shim + u-boot.bin, signed
#                     with devkeys; kernel GPT attrs set post-build)
#   p2 ESP          — GRUB (arm64-efi) + EFI/ubuntu/grub.cfg
#   p3 rootfs       — Ubuntu 26.10 XFCE desktop ("writable", ext4)
#
# Boot chain on the device:
#   BootROM → coreboot → TF-A → depthcharge → U-Boot payload (p1)
#           → EFI boot manager → GRUB (p2) → Linux (p3)
#
# Prereqs: sudo ubuntu-image (snap), vboot-utils (cgpt/futility),
#          ubuntu-dev-tools (pull-lp-debs), gcc-aarch64-linux-gnu,
#          git, python3. A prebuilt U-Boot tree at ../u-boot-krane is
#          used when present; otherwise ./payload/build-uboot.sh builds
#          upstream + the patch series in ../u-boot.

SERIES ?= stonking
GRUB_EFI := gadget/grub/grubaa64.efi
PAYLOAD := gadget/u-boot/krane-uboot-payload.bin
IMG := out/ubuntu-26.10-preinstalled-desktop-krane-arm64.img

# Prebuilt U-Boot to use (overridable: make UBOOT_BIN=... payload).
# ../u-boot-krane is a sibling of this repository.
UBOOT_BIN ?= $(if $(wildcard ../../u-boot-krane/u-boot.bin),../../u-boot-krane/u-boot.bin,)

.PHONY: all image payload grub test-qemu clean distclean

all: image

payload:
	@if [ -z "$(UBOOT_BIN)" ]; then \
		echo "==> no prebuilt u-boot.bin — building from source (build/u-boot)"; \
		./payload/build-uboot.sh; \
	fi
	UBOOT_BIN=$(UBOOT_BIN) ./payload/build-uboot-payload.sh
	mkdir -p gadget/u-boot
	cp payload/build/krane-uboot-payload.bin $(PAYLOAD)

grub:
	rm -rf build/grub && mkdir -p build/grub
	cd build/grub && pull-lp-debs -a arm64 grub-efi-arm64-unsigned $(SERIES)
	cd build/grub && dpkg -x grub-efi-arm64-unsigned_*.deb extract/
	mkdir -p gadget/grub
	cp build/grub/extract/usr/lib/grub/arm64-efi/monolithic/grubaa64.efi $(GRUB_EFI)

image: payload grub
	sudo rm -rf workdir out
	sudo ubuntu-image classic --workdir workdir --output-dir out image-definition.yaml
	sudo ./postprocess/stamp-depthcharge.sh "$(IMG)" payload/build/krane-uboot-payload.bin
	sudo ./postprocess/initramfs-mtk.sh "$(IMG)"
	@echo "==> image ready: $(IMG)"

# Boot the finished image in QEMU (U-Boot from -bios; depthcharge itself
# cannot run outside the device). Passes when a login prompt appears.
test-qemu: image
	./test/qemu-e2e.sh "$(IMG)"

clean:
	rm -rf build gadget/grub gadget/u-boot \
		payload/build $(GRUB_EFI) $(PAYLOAD) \
		qemu-e2e-serial.log

distclean: clean
	sudo rm -rf workdir out
