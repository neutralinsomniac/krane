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
