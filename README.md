# krane - experiments on the Lenovo 'kukui-krane' IdeaPad Duet

See https://vhaudiquet.fr/blog/duet-ubuntu.

This repository contains my personal experiments on my `kukui-krane` tablet.

With it, you can build a fully working Ubuntu preinstalled desktop image (default username/password `ubuntu/ubuntu`). ~~That image is also available in the Releases section.~~

It also contains U-Boot patches to be able to build U-Boot with full support for the device.

DISCLAIMER: This image is not official in any way, and not affiliated to Canonical

## Building the image

I wanted to make the image available in release, but it is 9 GiB and GitHub does not let me upload it.
So for now, you will have to build it yourself, sorry.
For this, you should only need to `cd image && make image`, if you have the right dependencies (`git snapd qemu-user ubuntu-dev-tools` and classic snap `ubuntu-image`).
See also: https://ubuntu.com/hardware/docs/image-cookbook/tutorial/create_image/

## NixOS

The same boot chain is packaged as a NixOS hardware profile in
[nixos-hardware](https://github.com/neutralinsomniac/nixos-hardware/tree/lenovo-ideapad-duet) under
`lenovo/ideapad/duet` (flake module `lenovo-ideapad-duet`): the U-Boot
build with the `u-boot/` patch series, the signed depthcharge payload, the
device quirks (MT6358 PMIC chain, mtu3-before-xhci ordering, display
chain, serial console) and a bootable installer image.

This flake builds those from *this* tree's `u-boot/` series rather than
the copy vendored into nixos-hardware:

```sh
nix build .#payload            # signed depthcharge payload (aarch64)
nix build .#packages.x86_64-linux.payload   # same, cross-compiled
nix build .#installerImage     # bootable NixOS USB image for the device
```

`nixosConfigurations.duet` is a minimal installed system (root only,
NetworkManager, sshd) that imports `nixosModules.krane`; import that
module from your own flake instead if you want more than a starting
point. See `lenovo/ideapad/duet/README.md` in nixos-hardware for the
boot chain and the known issues.

### Building the installer image

The image is a full aarch64 NixOS system, so it has to be built on an
aarch64 machine or through an aarch64 remote builder; only the payload
cross-compiles.

```sh
nix build .#installerImage
zstd -d < result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

The stick carries the same three partitions as the eMMC layout below:
the depthcharge partition with the payload already stamped in, an ESP
labelled `ESP`, and an ext4 root labelled `NIXOS_SD`.

Boot it: put the device in developer mode, run
`crossystem dev_boot_usb=1` once from a ChromeOS shell, and press
Ctrl+U at the "OS verification is OFF" screen. The image logs in as
`nixos` with no password, and `sudo` is free; `nmtui` gets it on WiFi.

### Installing to the internal eMMC

This overwrites ChromeOS. From the running installer, lay the eMMC out
like the image: a 16 MiB ChromeOS kernel partition first (depthcharge
only looks at partitions of that type), then the ESP, then the root.
The labels differ from the USB stick's on purpose, since both are
plugged in while installing, and they are the ones
`nixosConfigurations.duet` mounts.

```sh
sudo sfdisk /dev/mmcblk0 <<EOF
label: gpt
unit: sectors
sector-size: 512

start=2048, size=32768, name="depthcharge", type=FE3A2A5D-4F32-41A7-B725-ACCC3285A309
size=262144, name="ESP", type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name="root", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

sudo mkfs.vfat -F 32 -n KRANE_ESP /dev/mmcblk0p2
sudo mkfs.ext4 -L krane-nixos /dev/mmcblk0p3
```

Write the bootloader payload. `krane-install-uboot` dd's it into the
kernel partition and sets the GPT attributes depthcharge insists on
(`successful=1`, `tries=15`, `priority=15`); without them the partition
is skipped:

```sh
sudo krane-install-uboot /dev/mmcblk0          # partition 1 by default
```

Mount the target and install:

```sh
sudo mount /dev/disk/by-label/krane-nixos /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/KRANE_ESP /mnt/boot

sudo nixos-install --flake github:neutralinsomniac/krane#duet
```

A local checkout works as well (`--flake /path/to/krane#duet`), as does
any flake whose configuration imports `nixosModules.krane` and mounts
the same labels. The payload is the same derivation the installer image
was built from, so it is already in the installer's store and U-Boot is
not rebuilt on the device; the rest of the system comes from the binary
cache. `nixos-install` asks for the root password at the end.

Reboot, remove the stick, and press Ctrl+D at the developer screen to
boot from the eMMC. `systemd-boot` on `/boot` takes over from there,
and `nixos-rebuild switch` manages it as usual.

### Updating U-Boot

With `hardware.lenovo.ideapad.duet.uboot.enable = true` (already set in
`nixosConfigurations.duet`), the installed system carries the payload
built from this tree's `u-boot/` series and the installer for it.
Rebuild with the new patches, then rewrite partition 1:

```sh
sudo nixos-rebuild switch --flake .#duet
sudo krane-install-uboot /dev/mmcblk0
```

`krane-install-uboot --payload FILE` writes a specific payload instead,
e.g. one cross-built on another machine with
`nix build .#packages.x86_64-linux.payload` and copied over.
