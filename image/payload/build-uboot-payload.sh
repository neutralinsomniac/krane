#!/bin/sh
# build-uboot-payload.sh — assemble the krane U-Boot depthcharge payload.
#
# Layout (LOAD-BEARING, see ../../../krane-fb-stub/U-BOOT.md):
#
#   0x0000  64-byte arm64 Image header (code0 = b +0x40, image_size,
#           flags bit3, magic at 0x38 — booting.rst contract, verified
#           against depthcharge src/arch/arm/boot64.c)
#   0x0040  uboot-wrapper.S entry shim (single `b` patched to U-Boot).
#           depthcharge jumps to payload+0x40; U-Boot's PIE fixup needs
#           a 4K-aligned entry, so the shim hands off to payload+0x1000.
#           It must not touch ANY register: x0 carries the handoff FDT.
#   0x1000  u-boot.bin contiguous (NO interior padding)
#
# Then packs with mkdepthcharge (ChromeOS devkeys) and verifies with
# futility, leaving krane-uboot-payload.bin under build/.
#
# Inputs:
#   UBOOT_BIN  u-boot.bin           (default: build/u-boot/u-boot.bin,
#                                    i.e. built by ./build-uboot.sh)
#   UBOOT_SYM  u-boot.sym           (default: derived from UBOOT_BIN)
#   DTB        handoff FDT          (default: the U-Boot build's own
#                                    u-boot.dtb — the patched upstream
#                                    krane-sku176 devicetree, SSUSB bits
#                                    included; override to pass another)
#   SHIM_DIR   wrapper source dir   (default: ../../krane-shim-loader)
#   DEPTHCHARGE_TOOLS  checkout of github.com/alpernebbi/depthcharge-tools
#                                   (default: build/depthcharge-tools,
#                                    cloned automatically if missing)
set -e
CALLER_DIR="$PWD"
cd "$(dirname "$0")"

BUILD_DIR=build
mkdir -p "$BUILD_DIR"

# caller-relative paths (build/u-boot/u-boot.bin is relative to this
# script's directory; anything else comes from the invoking Makefile)
case "$UBOOT_BIN" in
"") UBOOT_BIN=build/u-boot/u-boot.bin ;;
*/*)
	if [ -f "$CALLER_DIR/$UBOOT_BIN" ]; then
		UBOOT_BIN="$CALLER_DIR/$UBOOT_BIN"
	else
		echo "ERROR: UBOOT_BIN='$UBOOT_BIN' not found (relative to $CALLER_DIR)" >&2
		exit 1
	fi
	;;
esac
UBOOT_SYM="${UBOOT_SYM:-${UBOOT_BIN%.bin}.sym}"
DTB="${DTB:-${UBOOT_BIN%.bin}.dtb}"
if [ ! -f "$DTB" ]; then
	echo "ERROR: DTB='$DTB' not found" >&2
	exit 1
fi
SHIM_DIR="${SHIM_DIR:-../../krane-shim-loader}"
DEPTHCHARGE_TOOLS="${DEPTHCHARGE_TOOLS:-$BUILD_DIR/depthcharge-tools}"
WRAP_SRC="$SHIM_DIR/uboot-wrapper.S"
WRAP_IMG="$BUILD_DIR/krane-uboot-wrap.img"
OUT_PAYLOAD="$BUILD_DIR/krane-uboot-payload.bin"

if [ ! -f "$DEPTHCHARGE_TOOLS/src/depthcharge_tools/__init__.py" ] && \
   [ ! -f "$DEPTHCHARGE_TOOLS/depthcharge_tools/__init__.py" ]; then
	echo "==> cloning depthcharge-tools into $DEPTHCHARGE_TOOLS"
	mkdir -p "$(dirname "$DEPTHCHARGE_TOOLS")"
	git clone -q https://github.com/alpernebbi/depthcharge-tools.git "$DEPTHCHARGE_TOOLS"
fi
# mkdepthcharge resolves its bundled devkeys relative to the package,
# so PYTHONPATH must point at the checkout's src/ tree (fall back to
# the repo root for flat layouts).
DC_PKG_DIR="$DEPTHCHARGE_TOOLS/src/depthcharge_tools"
if [ -d "$DC_PKG_DIR" ]; then
	DC_ROOT="$DEPTHCHARGE_TOOLS/src"
else
	DC_ROOT="$DEPTHCHARGE_TOOLS"
fi

# 1. assemble the wrapper (raw binary, no relocations)
aarch64-linux-gnu-gcc -c "$WRAP_SRC" -o uboot-wrapper.o
aarch64-linux-gnu-objcopy -O binary uboot-wrapper.o uboot-wrapper.bin
WRAP_LEN=$(stat -c %s uboot-wrapper.bin)

# 2. header + wrapper + u-boot, patch the wrapper's `b .` branch
python3 - "$UBOOT_BIN" "$UBOOT_SYM" "$WRAP_IMG" "$WRAP_LEN" <<'EOF'
import struct, sys

uboot_path, sym_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
wrap_len = int(sys.argv[4])
uboot = open(uboot_path, 'rb').read()
wrapper = open('uboot-wrapper.bin', 'rb').read()
assert len(wrapper) == wrap_len

# u-boot.bin starts at __image_copy_start (the lowest output VMA);
# _start's file offset is its delta from that base. The PIE fixup in
# start.S loads the link base from _TEXT_BASE and the run base from
# adr _start, so _start MUST equal __image_copy_start (a 4-byte
# linker fill sneaks in when CONFIG_TEXT_BASE is not 8-aligned —
# start.o's .text input section is 8-aligned — and then every
# relocated pointer is skewed by 4). Fail loudly instead.
copy_vma = None
start_vma = None
for line in open(sym_path):
    parts = line.split()
    if len(parts) >= 2 and parts[-1] == '__image_copy_start':
        copy_vma = int(parts[0], 16)
    elif len(parts) >= 2 and parts[-1] == '_start':
        start_vma = int(parts[0], 16)
if copy_vma is None or start_vma is None:
    raise SystemExit('symbols not found in u-boot.sym')
assert start_vma == copy_vma, \
    ("_start 0x%x != __image_copy_start 0x%x: CONFIG_TEXT_BASE is not "
     "8-aligned and a linker fill shifted _start" %
     (start_vma, copy_vma))
assert start_vma % 0x1000 == 0, \
    "link _start 0x%x not 4K-aligned" % start_vma
start_file_off = start_vma - copy_vma
wrap_off = 0x40
uboot_off = 0x1000
while (uboot_off + start_file_off) % 0x1000:
    uboot_off += 0x1000
pad = uboot_off - wrap_off - wrap_len
assert pad >= 0
total = uboot_off + len(uboot)
assert (0x40000000 + uboot_off + start_file_off) % 0x1000 == 0
hdr = bytearray(64)
hdr[0:4] = struct.pack('<I', (0x40 >> 2) | 0x14000000)  # code0: b +0x40
struct.pack_into('<Q', hdr, 0x10, total)                # image_size
struct.pack_into('<Q', hdr, 0x18, 1 << 3)               # flags: bit3
hdr[0x38:0x3c] = b'ARM\x64'                             # magic

# patch the wrapper's `b .` — searched, NOT assumed to be the last
# instruction (the shim must stay a single branch; patching blind
# would clobber anything following it)
hits = [i for i in range(0, len(wrapper), 4)
        if struct.unpack_from('<I', wrapper, i)[0] == 0x14000000]
assert len(hits) == 1, \
    "expected exactly one `b .` in wrapper, found %d" % len(hits)
br_off = wrap_off + hits[0]
imm = (uboot_off + start_file_off - br_off) // 4
wrapper = bytearray(wrapper)
wrapper[hits[0]:hits[0] + 4] = \
    struct.pack('<I', (imm & 0x03ffffff) | 0x14000000)
with open(out, 'wb') as f:
    f.write(hdr)
    f.write(wrapper)
    f.write(bytes(pad))
    f.write(uboot)
print("layout: header 64, wrapper %d (0x40..0x%x), uboot %d @0x%x, "
      "total %d, runtime _start 0x%x" %
      (wrap_len, uboot_off, len(uboot), uboot_off, total,
       0x40000000 + uboot_off + start_file_off))
EOF

# 3. pack + verify
#
# PATH shim: mkdepthcharge's decompress heuristic runs every compression
# tool over the kernel image; on this system `lzma -cd` exits 0 with
# EMPTY output on non-lzma data (xz-utils compat wrapper), which
# destroys the payload (0-byte FIT kernel that still "verifies"). An
# lzma stub that always fails makes decompress() keep the file as-is —
# what the known-good payload flow does.
mkdir -p build/shims
printf '%s\n' '#!/bin/sh' \
	'echo "lzma disabled (mkdepthcharge decompress heuristic would truncate raw images)" >&2' \
	'exit 1' > build/shims/lzma
chmod +x build/shims/lzma

PATH="$PWD/build/shims:$PATH" PYTHONPATH="$DC_ROOT" python3 -m depthcharge_tools.mkdepthcharge \
    -A arm64 \
    -o "$OUT_PAYLOAD" \
    -n "krane u-boot ubuntu payload" \
    -d "$WRAP_IMG" \
    -b "$DTB"

echo "---- verify ----"
futility vbutil_kernel --verify "$OUT_PAYLOAD"
sha256sum "$OUT_PAYLOAD"
