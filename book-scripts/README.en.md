# Command scripts for the book

[日本語](README.md) | English

These scripts hold the commands from the book (written in Japanese), one file
per section. A file name has the form `chapter-section number-content` and
matches a chapter and section of the book. The commands are the same as in the
book, with these additions:

- Device names (`CARD`, `CONSOLE`) are passed as arguments instead of being
  edited in place. The example name `/dev/sdX` is refused.
- `Chapter04-9-write-card.sh`, which writes the card, stops if a partition is
  mounted, a backup file already exists or the card is too small, and writes
  nothing until you type `yes`.
- `XTWV_PATH`, `RETROBASE` and `W11` keep their values if they are already set.

The comments in the scripts are in Japanese.

## Where to run them

| Suffix | Where to run |
| --- | --- |
| `.ps1` | Windows PowerShell |
| `.sh` | an Ubuntu terminal |
| `-211bsd.sh` | the 2.11BSD `#` prompt. Do not run these on the host; type the lines or paste them |
| `.tcl` | `source` it in the Vivado Tcl Console |

If PowerShell blocks scripts, run them like this:

```powershell
powershell -ExecutionPolicy Bypass -File .\Chapter03-1-download-bit.ps1
```

## List

| File | Chapter and section |
| --- | --- |
| `Chapter02-1-ubuntu-tools.sh` | Ch. 2, install the Ubuntu tools |
| `Chapter02-2-vivado-check.sh` | Ch. 2, install Vivado 2022.1 |
| `Chapter02-3-jtag-driver.sh` | Ch. 2, JTAG cable driver |
| `Chapter03-1-download-bit.ps1` | Ch. 3, get the released `.bit` (Windows) |
| `Chapter03-1-download-bit.sh` | Ch. 3, get the released `.bit` (Ubuntu) |
| `Chapter03-2-build-tools.sh` | Ch. 3, add the build tools |
| `Chapter03-3-get-source.sh` | Ch. 3, get the source at the pinned commit |
| `Chapter03-4-build-bit.sh` | Ch. 3, build the bitstream; check timing and copy it |
| `Chapter04-1-download-image.ps1` | Ch. 4, get the released image |
| `Chapter04-2-install-etcher.ps1` | Ch. 4, write the card with balenaEtcher |
| `Chapter04-3-get-tape.sh` | Ch. 4, get the input |
| `Chapter04-4-restore-usr-src-211bsd.sh` | Ch. 4, restore /usr and the sources |
| `Chapter04-5-build-kernel-211bsd.sh` | Ch. 4, build a kernel with FPSIM |
| `Chapter04-6-fstab-swap-211bsd.sh` | Ch. 4, fix the partition and swap references |
| `Chapter04-7-verify-nofpp.sh` | Ch. 4, check without FP11 or tape (start SimH) |
| `Chapter04-7-fp-check-211bsd.sh` | Ch. 4, check without FP11 or tape (floating point) |
| `Chapter04-8-make-raw.sh` | Ch. 4, make the raw file for the card |
| `Chapter04-9-write-card.sh` | Ch. 4, identify the card; back up, write and read back |
| `Chapter05-1-serial-check.sh` | Ch. 5, terminal on Ubuntu (device name and permission) |
| `Chapter05-2-picocom.sh` | Ch. 5, terminal on Ubuntu (open the terminal) |
| `Chapter05-3-record-session.sh` | Ch. 5, terminal on Ubuntu (record the session) |
| `Chapter05-4-halt-211bsd.sh` | Ch. 5, boot to `login:` (check and halt) |
| `Chapter06-1-make-mcs.tcl` | Ch. 6, make the MCS file |
| `Chapter07-1-save-files-211bsd.sh` | Ch. 7, check partitions and free space; save to two partitions |
| `Chapter07-2-halt-211bsd.sh` | Ch. 7, halt and reboot (halt) |
| `Chapter07-3-verify-after-reboot-211bsd.sh` | Ch. 7, halt and reboot (compare after reboot) |
| `Chapter07-4-fsck-211bsd.sh` | Ch. 7, read the boot-time check |
| `AppendixD-1-download-image.ps1` | App. D, write the released image |
| `AppendixD-2-get-kit.sh` | App. D, get the kit |
| `AppendixD-3-fix-ttys.sh` | App. D, fix the terminal settings |
| `AppendixD-4-make-card-image.sh` | App. D, make the card image |
| `AppendixE-1-make-card-image.sh` | App. E, make the image (not tested on hardware) |

To write the Appendix D card, pass the image as the second argument.
`/dev/sdX` below is an example name and is refused as is. Replace it with the
actual device name you confirmed with `lsblk` in Chapter 4 (e.g. `/dev/sdb`).

```sh
./Chapter04-9-write-card.sh /dev/sdX $HOME/v6-card/v6_rk_card_labeled.img
```

The interactive steps are not scripts: the disklabel and boot `:` input in
Chapter 4, the editing with V6 `ed` in Appendix D, and the examples in
Chapter 8. Type them as the book describes.
