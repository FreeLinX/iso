# iso

Tooling repository for the FreeLinX bootable ISO image.

## Usage

`build-iso.sh` assembles a bootable hybrid ISO (legacy BIOS + UEFI) using
Limine, embedding a kernel and a gzip initramfs:

```
# Minimal dev ISO (small initramfs from this repo, rescue shell on boot)
./build-iso.sh

# Full desktop ISO (Desktop-test kernel + live rootfs initramfs)
./build-iso.sh -D -i ../Desktop-test/src/build/x86_64/freelinx-desktop.img.gz \
               -o freelinx-desktop.iso
```

Options:

| Flag | Meaning |
|------|---------|
| `-D` | use the Desktop-test kernel (has CONFIG_FB + DRM fbdev emulation) |
| `-k FILE` | kernel image to embed (overrides `-D`) |
| `-i FILE` | initramfs image to embed (must be gzip) |
| `-o FILE` | output ISO path (default `freelinx.iso`) |

## Requirements

* `xorriso` (ISO composition and El Torito / EFI boot records)
* `limine` (the `limine` binary from `drivers/bootloader/limine-binary`,
  or installed in `PATH`; used for `limine bios-install`)
* `gzip`, coreutils, a POSIX shell

On hosts without a packaged xorriso, stage one locally (e.g. extract the
Arch `libisoburn` package with its `libburn`/`libisofs` deps and prepend to
`PATH`/`LD_LIBRARY_PATH`).

The produced ISO is bootable as a CD/DVD or USB stick (ISOHYBRID MBR) from
both legacy BIOS and UEFI firmware; verify with e.g.:

```
qemu-system-x86_64 -enable-kvm -m 2048 -boot order=d -cdrom <iso>
```