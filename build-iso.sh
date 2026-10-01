#!/bin/sh
#
# FreeLinX bootable ISO builder.
#
# Produces freelinx-desktop.iso from the DESKTOP rootfs artifacts:
#   - kernel          : Desktop-test/kernel/bzImage (the one with CONFIG_FB + DRM)
#   - initramfs       : Desktop-test/src/build/x86_64/freelinx-desktop.img.gz
#   - bootloader      : <drivers>/bootloader/limine-binary
#
# The ISO is bootable from both legacy BIOS (El Torito + ISOHYBRID) and
# UEFI (EFI boot image + GPT ESP partition), via Limine.
#
# Requires: xorriso, limine, coreutils, a POSIX shell.
# Without a system xorriso, one may be staged locally (see iso-tools.sh).
#
# WHY THIS USES THE DESKTOP ROOTFS
# The base src/rootfs image has no /var/service/greetd, and its /init never
# reads /proc/cmdline.  An ISO built from it therefore always lands on a root
# shell on tty1 no matter what the kernel command line says.  The desktop
# /init reads flx.desktop=gui, writes /etc/flx-desktop, and greetd then execs
# flx-session.  verify_desktop_image() below turns any regression of that
# chain into a build error instead of a silently headless ISO.

set -e
unset CDPATH

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

DESKTOP_DIR="$ROOT/Desktop-test"
KERNEL_SRC="$DESKTOP_DIR/kernel/bzImage"
INITRD_SRC="$DESKTOP_DIR/src/build/x86_64/freelinx-desktop.img.gz"
LIMINE_SRC="$ROOT/drivers/bootloader/limine-binary"

OUT="$SCRIPT_DIR/freelinx-desktop.iso"
WORK=""

usage() {
    cat <<EOF
Usage: $0 [-o out.iso] [-k kernel] [-i initramfs] [-B] [-h]

  -o FILE       output ISO path (default: $OUT)
  -k FILE       kernel image to embed
  -i FILE       initramfs image to embed (default: $INITRD_SRC)
  -B            base image: use src/rootfs kernel/initramfs (installer, no desktop)
  -h            this help

Without -B the desktop initramfs is rebuilt automatically when missing.
EOF
}

BASE=0
while getopts "o:k:i:Bh" opt; do
    case "$opt" in
        B) BASE=1
           KERNEL_SRC="$ROOT/src/rootfs/boot/vmlinuz"
           INITRD_SRC="$SCRIPT_DIR/initramfs.img.gz" ;;
        o) OUT="$OPTARG" ;;
        k) KERNEL_SRC="$OPTARG" ;;
        i) INITRD_SRC="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: missing tool: $1" >&2; exit 1; }; }

# The desktop initramfs is zstd (despite its .gz name); older images are gzip.
decompress() {
    zstd -dc "$1" 2>/dev/null || gzip -dc "$1" 2>/dev/null || xz -dc "$1" 2>/dev/null
}
need xorriso

# The limine *installer* is a host binary that ships in-tree; fall back to PATH.
if [ -x "$LIMINE_SRC/limine" ]; then
    LIMINE="$LIMINE_SRC/limine"
else
    need limine
    LIMINE=limine
fi

# Build the desktop initramfs on demand so a fresh clone produces a real
# desktop ISO rather than embedding a stale committed artifact.
if [ ! -f "$INITRD_SRC" ] && [ "$BASE" -eq 0 ] && [ -x "$DESKTOP_DIR/build-image.sh" ]; then
    echo "==> initramfs missing, building from Desktop-test/src/rootfs ..."
    "$DESKTOP_DIR/build-image.sh"
fi

[ -f "$KERNEL_SRC" ] || { echo "error: kernel not found: $KERNEL_SRC" >&2; exit 1; }
[ -f "$INITRD_SRC" ] || { echo "error: initramfs not found: $INITRD_SRC" >&2; exit 1; }

for f in limine-bios-cd.bin limine-uefi-cd.bin limine-bios.sys \
         BOOTX64.EFI BOOTIA32.EFI BOOTAA64.EFI; do
    [ -f "$LIMINE_SRC/$f" ] || { echo "error: limine missing: $LIMINE_SRC/$f" >&2; exit 1; }
done

# verify_desktop_image FILE - fail unless FILE can actually reach a GUI.
verify_desktop_image() {
    _img="$1"
    _tmp=$(mktemp -d)
    decompress "$_img" | (cd "$_tmp" && cpio -idm --quiet 2>/dev/null) || true

    _missing=""
    if [ -f "$_tmp/init" ]; then
        grep -q 'proc/cmdline' "$_tmp/init" \
            || _missing="$_missing 'init reads /proc/cmdline'"
    else
        _missing="$_missing init"
    fi
    [ -x "$_tmp/var/service/greetd/run" ] || _missing="$_missing var/service/greetd/run"
    [ -x "$_tmp/usr/bin/flx-session" ]    || _missing="$_missing usr/bin/flx-session"
    [ -x "$_tmp/usr/bin/Xorg" ]           || _missing="$_missing usr/bin/Xorg"
    rm -rf "$_tmp"

    if [ -n "$_missing" ]; then
        echo "error: $INITRD_SRC cannot boot a desktop; missing:$_missing" >&2
        echo "       build it with Desktop-test/build-image.sh, or pass -B for a" >&2
        echo "       text-only installer ISO, or -i <your-desktop-initramfs>." >&2
        exit 1
    fi
}

if [ "$BASE" -eq 0 ]; then
    verify_desktop_image "$INITRD_SRC"
fi

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

decompress "$INITRD_SRC" >/dev/null || { echo "error: cannot decompress initramfs (zstd/gzip/xz)" >&2; exit 1; }

# flx.desktop=gui + flx.autologin=1 are what make /init write
# /etc/flx-desktop=gui and greetd exec flx-session.  Without them the image
# drops to a root shell on tty1.
#
# The rescue entry uses flx.rescue=1 and NOT init=/bin/sh: /init is reached
# through rdinit=, so a second init= on the command line does not override
# it and "Rescue Shell" silently booted the normal system instead.
cat > "$WORK/limine.conf" <<'CONF'
timeout: 5
serial: yes

/FreeLinX Desktop (Openbox)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 console=ttyS0,115200 quiet loglevel=2 flx.desktop=gui flx.autologin=1

/FreeLinX Text Console (installer)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 console=ttyS0,115200 quiet loglevel=2

/FreeLinX Rescue Shell
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/initramfs.img.gz
    cmdline: rdinit=/init rootfstype=ramfs console=tty0 console=ttyS0,115200 flx.rescue=1
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
"$LIMINE" bios-install "$OUT"

echo "==> done: $OUT ($(stat -c%s "$OUT") bytes)"
