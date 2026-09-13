# krane Ubuntu 26.10 "Stonking Stingray" desktop image

A preinstalled Ubuntu desktop image (GNOME, `desktop-minimal` seed) for
the MediaTek MT8183 **krane** (Lenovo IdeaPad Duet ChromeBook)
Chromebook, booted through the ChromeOS firmware chain:

```
BootROM → coreboot → TF-A → depthcharge
        → U-Boot payload (p1, depthcharge partition)
        → EFI boot manager → GRUB (p2, ESP) → Linux (p3, rootfs)
```

The SPI flash is never touched: depthcharge loads the U-Boot payload
from the first GPT partition, exactly like a ChromeOS kernel.

## Disk layout (GPT)

| # | name          | type                          | fs   | size  | content                                          |
|---|---------------|-------------------------------|------|-------|--------------------------------------------------|
| 1 | `depthcharge` | ChromeOS kernel `FE3A2A5D-…`  | raw  | 16M   | U-Boot depthcharge payload (devkeys-signed vboot) |
| 2 | `esp`         | EFI System `C12A7328-…`       | vfat | 100M  | GRUB arm64-efi + `EFI/ubuntu/grub.cfg`            |
| 3 | `writable`    | Linux fs `0FC63DAF-…`         | ext4 | 4G+   | Ubuntu 26.10 rootfs (GNOME desktop)               |

The kernel partition's content and GPT attributes (payload dd'd in,
successful=1, tries=15, priority=15) are stamped by
`postprocess/stamp-depthcharge.sh` after `ubuntu-image` runs — without
this step depthcharge ignores the partition.

## U-Boot payload

`payload/build-uboot-payload.sh` assembles the payload:

```
0x0000  64-byte arm64 Image header (code0 = b +0x40, image_size, flags
        bit3, magic "ARM\x64") — depthcharge's arm64 boot contract
0x0040  entry shim (single `b` patched to U-Boot; touches no register)
0x1000  u-boot.bin contiguous (NO interior padding)
```

Everything is packed with `mkdepthcharge` (ChromeOS **devkeys**: the
device must be in developer mode) and verified with `futility`.

The U-Boot build itself is the upstream **`v2026.10-rc4`** tag plus the
patch series in [`../u-boot`](../u-boot). The series
is applied with `patch --fuzz=3`: patch 0007's `boot/image-fdt.c`
context drifted inside rc4, the `-EEXIST` hunk applies unchanged.

## Building

Prerequisites:

- `sudo snap install ubuntu-image --classic`
- `sudo apt install vboot-utils ubuntu-dev-tools gcc-aarch64-linux-gnu git python3 patch`
  (`vboot-utils` provides `cgpt`/`futility`, `ubuntu-dev-tools` provides
  `pull-lp-debs`)
- passwordless sudo for root steps (ubuntu-image needs root for
  debootstrap and loop mounts)

Then, from this directory:

```sh
make            # payload + grub + ubuntu-image + GPT stamping
```

Useful variations:

```sh
make payload                          # just the depthcharge payload
make payload UBOOT_BIN=/path/u-boot.bin   # use a specific prebuilt U-Boot
make grub                             # just fetch the stonking GRUB monolithic
make image                            # payload+grub+ubuntu-image+stamp
make test-qemu                        # build, then boot the image in QEMU†
make clean / distclean
```

† QEMU cannot run depthcharge (it lives in the SPI firmware), so the
test boots the image with U-Boot from `-bios` and waits for a login
prompt on serial. It still exercises the GPT, ESP, GRUB chain, kernel
and systemd, i.e. everything downstream of depthcharge.

Output: `out/ubuntu-26.10-preinstalled-desktop-krane-arm64.img`
(grows beyond 4G if the rootfs needs it).

### Note on mkdepthcharge

`payload/build-uboot-payload.sh` puts an `lzma` stub on `PATH` while
calling `mkdepthcharge`: its decompress heuristic runs every decompressor
over the kernel image, and xz-utils' `lzma` compat wrapper exits 0 with
**empty output** on non-lzma data, silently packing a 0-byte kernel.
