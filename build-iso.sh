#!/bin/sh
#
# FreeLinX bootable ISO builder.
#
# Produces freelinx.iso from the current rootfs artifacts:
#   - kernel          : <src>/rootfs/boot/vmlinuz  (or Desktop-test kernel if -D)
#   - initramfs       : <src>/initramfs.img.gz     (or Desktop-test build)
#   - bootloader      : <drivers>/bootloader/limine-binary
#
# The ISO is bootable from both legacy BIOS (El Torito + ISOHYBRID) and
# UEFI (EFI boot image + GPT ESP partition), via Limine.
#
# Requires: xorriso, limine, coreutils, a POSIX shell.
# Without a system xorriso, one may be staged locally (see iso-tools.sh).

set -e
unset CDPATH

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

KERNEL_SRC="$ROOT/src/rootfs/boot/vmlinuz"
INITRD_SRC="$SCRIPT_DIR/initramfs.img.gz"
LIMINE_SRC="$ROOT/drivers/bootloader/limine-binary"
DESKTOP_KERNEL="$ROOT/Desktop-test/kernel/bzImage"

OUT="$SCRIPT_DIR/freelinx.iso"
WORK=""

usage() {
    cat <<EOF
Usage: $0 [-D] [-o out.iso] [-k kernel] [-i initramfs]

  -D            use the Desktop-test kernel (CONFIG_FB + DRM fbdev emulation)
  -o FILE       output ISO path (default: $OUT)
  -k FILE       kernel image to embed (overrides -D)
  -i FILE       initramfs image to embed (default: $INITRD_SRC)
EOF
}

while getopts "Do:k:i:h" opt; do
    case "$opt" in
        D) KERNEL_SRC="$DESKTOP_KERNEL" ;;
        o) OUT="$OPTARG" ;;
        k) KERNEL_SRC="$OPTARG" ;;
        i) INITRD_SRC="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: missing tool: $1" >&2; exit 1; }; }
need xorriso
need limine

[ -f "$KERNEL_SRC" ] || { echo "error: kernel not found: $KERNEL_SRC" >&2; exit 1; }
[ -f "$INITRD_SRC" ] || { echo "error: initramfs not found: $INITRD_SRC" >&2; exit 1; }

for f in limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys \
         BOOTX64.EFI BOOTIA32.EFI BOOTAA64.EFI; do
    [ -f "$LIMINE_SRC/$f" ] || { echo "error: limine missing: $LIMINE_SRC/$f" >&2; exit 1; }
done

echo "==> kernel     : $KERNEL_SRC ($(stat -c%s "$KERNEL_SRC") bytes)"
echo "==> initramfs  : $INITRD_SRC ($(stat -c%s "$INITRD_SRC") bytes)"
echo "==> output     : $OUT"

trap 'rm -rf "$WORK"' EXIT
WORK=$(mktemp -d)

mkdir -p "$WORK/boot" "$WORK/EFI/BOOT"

cp "$LIMINE_SRC/limine-bios-cd.bin" "$WORK/boot/"
cp "$LIMINE_SRC/limine-uefi-cd.bin" "$WORK/boot/"
cp "$LIMINE_SRC/limine-bios.sys"    "$WORK/boot/"
cp "$LIMINE_SRC/BOOTX64.EFI" \
   "$LIMINE_SRC/BOOTIA32.EFI" \
   "$LIMINE_SRC/BOOTAA64.EFI" "$WORK/EFI/BOOT/"
cp "$KERNEL_SRC"  "$WORK/boot/bzImage"
cp "$INITRD_SRC"  "$WORK/boot/initramfs.img.gz"

gzip -dc "$INITRD_SRC" >/dev/null 2>&1 || { echo "error: initramfs is not gzip" >&2; exit 1; }

cat > "$WORK/limine.conf" <<'CONF'
timeout: 5
serial: yes

/FreeLinX (Initramfs Desktop)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init console=tty0 console=ttyS0,115200 quiet loglevel=2

/FreeLinX (Rescue Shell)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init init=/bin/sh console=tty0 console=ttyS0,115200
CONF

echo "==> composing ISO with xorriso..."
xorriso -as mkisofs -R -r -J \
    -b boot/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -hfsplus -apm-block-size 2048 \
    --efi-boot boot/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$WORK" -o "$OUT"

echo "==> installing Limine BIOS stages onto $OUT..."
limine bios-install "$OUT"

echo "==> done: $OUT ($(stat -c%s "$OUT") bytes)"