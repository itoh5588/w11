# Prepare an RP07 microSD card

The standalone controller reads a raw RP07 disk starting at sector 0 of the
card. It does not read a file from a FAT or exFAT partition. The required disk
image is exactly 1,008,000 sectors of 512 bytes (516,096,000 bytes). Use a
dedicated card with at least that capacity. The first 516,096,000 bytes of the
card will be overwritten.

## Image used for the hardware test

The tested image `rp07_w11_tape481_fpsim.img` was built in SimH from the
2.11BSD patch level 481 distribution tape published by TUHS. No other disk
image was used as input.

```text
tape:   https://www.tuhs.org/Archive/Distributions/UCB/2BSD/2.11BSD-patch481/2.11BSD-481-simh-dist.tap
size:   89762312 bytes
SHA256: 314ca00f6e0fa8d60ad4cded15ac105f7f1a9f30d6d9e17a2a60a3e47748b821
```

Build steps (SimH V3.8-1 `pdp11`, `set cpu 11/70`, `set cpu 4M`, an empty
RP07 attached as `rp0`, the tape on `ts0`, `boot ts0`):

1. Run the standalone `disklabel` (`ts(0,1)`) on `xp(0,0)` and write an RP07
   label: 50 sectors, 32 tracks, 630 cylinders, partition `a` 32,000 sectors
   at 0 (root), `b` 51,200 at 32,000 (swap), `c` 924,800 at 83,200 (`/usr`).
2. Run the standalone `mkfs` (`ts(0,2)`) on `xp(0,0)`, then `restor`
   (`ts(0,3)`) from `ts(0,5)` to `xp(0,0)`.
3. Boot `xp(0,0)unix` (the distribution kernel), `newfs xp0c`, mount it on
   `/usr` and extract the tape's `/usr` and `/usr/src` tar files (tape files
   6, 7 and 8) with `tar xpbf 20 /dev/rmt12`.
4. Copy `conf/GENERIC` to `W11TAPE` with `PDP11 70`, `IDENT W11TAPE` and
   `FPSIM YES`, run `./config W11TAPE` and `make`, and install the result as
   `/unix` (the distribution kernel is kept as `/unix.dist`).
5. Write `/mdec/rp07uboot` to the first block of `/dev/rxp0a`, set
   `/etc/fstab` to `xp0a` (`/`), `xp0b` (swap) and `xp0c` (`/usr`), and
   relink `/dev/swap` and `/dev/drum` to `/dev/xp0b` (the distribution links
   them to `ra0b`).
6. Shut down cleanly with `sync; sync; halt`, then extend the file with zeros
   to the full RP07 size.

The result boots to multi-user `login:` in SimH with `set cpu nofpp` and on
this w11 configuration; floating-point programs run through FPSIM.

```text
image:   rp07_w11_tape481_fpsim.img
size:    516096000 bytes
SHA256:  065e68f8a66da71e2cc0092a2c2342a6162e388264e6d603e33bbad19057dc08
archive: rp07_w11_tape481_fpsim.img.xz, 20639532 bytes
SHA256:  fd3860d977d0f6b7073806e00b6bc288676ae12eca84f03924e2779e915b745c
```

The image is not distributed here. An image rebuilt by the steps above will
work but will not have the same hash (time stamps differ). If you obtain the
archive above, unpack it with `xz -dk` and verify the raw image hash before
writing a card. Do not use the upstream `211bsd_rp` oskit's RP06 image as an
RP07 image.

## Identify the card reader

The commands below run on Linux or WSL 2. On Windows with WSL 2, connect the
**USB card reader**, not the Arty S7 USB/JTAG device, to WSL. In an
Administrator PowerShell, find the reader's current bus ID and share it:

```powershell
usbipd list
usbipd bind --busid <READER-BUSID>
```

In a regular PowerShell, attach the reader while a WSL terminal is open:

```powershell
usbipd attach --wsl --busid <READER-BUSID>
```

In WSL, insert the dedicated card and identify its **whole disk**. The
`/dev/sdX` name is an example; it can change whenever a device is attached.
Compare the model, transport and capacity before choosing a device:

```sh
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINTS
```

Set `device` to the confirmed whole disk (TYPE `disk`), not a partition such
as `/dev/sdX1`. Verify that no partition on it is mounted. Unmount any mounted
partitions individually before proceeding. Do not accept a name solely because
it matched a previous session.

## Back up, write and verify

These commands are templates to run in a WSL/Linux shell after replacing the
device path and image path. Inspect the output of `lsblk` and confirm the
device is the removable card before running any command that writes to it.
Run both blocks in the same shell. The checks stop the shell if they fail.
The backup command reads only the first RP07-sized region of the card.

```sh
set -euo pipefail
device=/dev/sdX
image=/path/to/rp07_w11_tape481_fpsim.img
expected=065e68f8a66da71e2cc0092a2c2342a6162e388264e6d603e33bbad19057dc08

test -b "$device"
test "$(lsblk -dn -o TYPE "$device")" = disk
test "$(lsblk -dn -o TRAN "$device")" = usb
test -z "$(lsblk -nrpo MOUNTPOINTS "$device" | tr -d '[:space:]')"
test "$(sudo blockdev --getsize64 "$device")" -ge 516096000
test "$(stat -c %s "$image")" -eq 516096000
printf '%s  %s\n' "$expected" "$image" | sha256sum -c -
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINTS "$device"
```

Stop here if the model or capacity is unexpected, any partition is mounted,
or the disk contains data you need. Save a backup outside the card, then write
the image. The backup command also provides a recovery copy of the first
516,096,000 bytes:

```sh
sudo dd if="$device" of=card-before-rp07.img bs=512 count=1008000 iflag=fullblock status=progress
test "$(stat -c %s card-before-rp07.img)" -eq 516096000
sha256sum card-before-rp07.img
sudo dd if="$image" of="$device" bs=4M iflag=fullblock conv=fsync status=progress
sudo blockdev --flushbufs "$device"
sudo dd if="$device" bs=512 count=1008000 iflag=fullblock status=none | sha256sum
```

The final hash must equal `expected`. If the readback hash differs, do not
boot from the card; investigate the reader, card, and device selection.
Safely detach the reader before removing the card. On Windows, use
`usbipd detach --busid <READER-BUSID>`; if the device was shared only for this
operation, an Administrator PowerShell can then run
`usbipd unbind --busid <READER-BUSID>`. Check `usbipd list` afterward.

On 2026-10-04 the image above was written the same way (`dd` from WSL 2
through a USB card reader, `conv=fsync`, then a readback of the first
516,096,000 bytes); the readback hash matched and the card booted on the
board. That write used `bs=1M` and skipped the backup step. Repeat the
readback check for every new card.

After inserting a verified card into the Pmod MicroSD on JD, follow the
[standalone boot instructions](README.md#os-media-and-boot).
