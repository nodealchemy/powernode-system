# rpi4-firmware module

Broadcom GPU firmware for the Raspberry Pi 4. Sourced from upstream
[raspberrypi/firmware](https://github.com/raspberrypi/firmware) at the
ref pinned in `manifest.yaml` → `build.firmware_ref`.

## Why this exists

Pi 4 hardware boots in two stages:

1. The Broadcom SoC ROM loads `start4.elf` from the FAT32 boot partition.
2. `start4.elf` reads `config.txt`, sets up RAM, loads the kernel + DTB,
   then jumps to the kernel.

The first-stage firmware is closed-source and ships outside Debian/Ubuntu
package channels. It also can't legally be committed to a third-party
repo under Broadcom's redistribution license — so we fetch at CI time.

## How it's used

The `disk-image-rpi4` build variant (in `initramfs/build.sh`) consumes
this module's rootfs:

```bash
build-disk-image-rpi4.sh --firmware-dir /path/to/rpi4-firmware/rootfs/boot/firmware
```

The script copies the firmware files onto the FAT32 boot partition
root (the GPU bootloader looks for `/start4.elf`, not
`/boot/firmware/start4.elf`).

## Bumping the firmware version

1. Pick a new ref from <https://github.com/raspberrypi/firmware/releases>
2. Update `build.firmware_ref` in `manifest.yaml`.
3. Trigger the disk-image CI workflow.
4. Test the resulting `.img` on an actual Pi 4 — older silicon revisions
   sometimes have incompatibilities with newer firmware.

## License

The manifest, README, and Containerfile are MIT. The firmware blobs the
Containerfile fetches are governed by Broadcom's redistribution terms
(see `LICENCE.broadcom` inside the firmware bundle).
