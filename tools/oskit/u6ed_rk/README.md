## Notes on oskit: Unix 6th Edition system on RK05 volumes

Unix V6 is the edition discussed in John Lions' commentary. This kit uses
the original w11 RK05 backend path, with `ti_w11` running on the host PC.
It does not use the standalone Arty S7 RP07/microSD path.

### General remarks
See notes on
- [I/O emulation setup](../../../doc/w11a_io_emulation.md)
- [FPGA Board setup](../../../doc/w11a_board_connection.md)
- [Rlink and Backend Server setup](../../../doc/w11a_backend_setup.md)
- [Legal terms](../../../doc/w11a_os_guide.md)

### Disk images
The disk images are taken from
https://github.com/retux/unix-v6-on-simh
(`disk0.rk`, `disk1.rk`, `disk2.rk`, a PDP-11/40 SimH kit built along
http://a.papnet.eu/UNIX/v6/installation). Copy them as
```
       disk0.rk -> u6ed_rk0.dsk
       disk1.rk -> u6ed_rk1.dsk
       disk2.rk -> u6ed_rk2.dsk
```

**One change is required for the w11:** the `/unix` kernel of this kit
contains a DC11 driver, and `/etc/ttys` enables `tty0`..`tty7` on it.
The w11 has no DC11, so `init` opening these lines causes a bus error and
a `panic: trap`. Disable these lines in `/etc/ttys` (e.g. under SimH with
`set dci en` before the change), so that only the console `tty8` is used:
```
       # {ed /etc/ttys}
       {1,8s/^1/0/}
       {w}
       {q}
       # {sync}
```

The `.dsk` files are local working copies and are ignored by Git. This
repository does not distribute them. The tested modified root image had
SHA-256 `f80c422712d9d7b14b8ce96604232733e18298623008ee456be8f2e81a2eeb01`.
The unmodified `disk1.rk` and `disk2.rk` copies had SHA-256
`8bdc4e518782d47b2ba094ded56ffa1bf21b0e621536d50e230b34b3ace78fd3`
and `a2f4241598eb141492e076b7fba71a5143f8e0db77f0ea4a3f061348f966f2ec` respectively.
These hashes identify the tested copies; other builds of V6 can differ.

### Standalone RK05 media layout

The standalone design uses a **dedicated** microSD card, separate from
the RP07/2.11BSD card. The raw card begins with RK0 at LBA 0, RK1 at
LBA 4872, and RK2 at LBA 9744. One RK05 occupies 203 cylinders x 2
surfaces x 12 sectors x 512 bytes = 2,494,464 bytes. Short source images
are zero padded to the next unit boundary. The complete three-unit file is
7,483,392 bytes. This layout follows `tools/bin/create_disk`'s RK05 geometry.

Create a **regular file** for inspection, using the prepared disk copies:

```
python3 pack_sd.py u6ed_rk0.dsk u6ed_rk1.dsk u6ed_rk2.dsk v6_rk_card.img
```

`pack_sd.py` refuses an existing output and never opens a block device. It
does not write a microSD card. The current single standalone bitstream
`sys_w11a_sa_as7` needs this image with a card label in front, made by
`../sd_label.py --type rk05` (see [the kit overview](../README.md)); the
history below refers to the earlier separate `sys_w11a_sa_rk_as7` bitstream,
which read an unlabeled card. The native RK11 controller and RK05 autostart
are implemented in `sys_w11a_sa_rk_as7`. The controller and boot-code loading
passed simulation; the Arty S7 bitstream was generated with routed WNS
+0.019 ns and WHS +0.035 ns. Its SHA-256 is
`1ac05dfe19fa4221f0f2c2445ddea4a012d228a751fb721fccaa593b1580f85e`.
This small setup margin is specific to that build. On 2026-10-03, the complete
7,483,392-byte file (SHA-256
`ed962fe90b5332a2ab34612493c903c5f2785295e35ec1ca08dac65d6de50a9e`)
was written from WSL2 Ubuntu to a 512-byte-sector microSD card. After a cache
flush, all 7,483,392 bytes read back from the card matched the file. With the
Pmod MicroSD on JD, a 3.3 V UART on JC/Windows COM5 at 9600 8N1, and SW3 = 0,
`sys_w11a_sa_rk_as7.bit` was loaded by volatile JTAG. The autostarted RK05
bootstrap printed `@`; entering `unix` reached `login:`. A root login, `ls /`,
`date`, and `sync` also worked. A repeat JTAG configuration reached `login:`
without manually setting the switch register over rlink. The first attempt
stopped after the `unix` input; matching input to the `@` prompt succeeded on
later attempts, but the first stop has not been diagnosed. Configuration flash
and a continuous cold power-on boot have not been tested.

### RK2 free-list repair

The original `u6ed_rk2.dsk` has a damaged free-block chain. On the FPGA,
`df` printed `/dev/rk2 bad free count` while RK0 and RK1 reported 1063 and
940 free blocks. The same error was present in the source image: V6
`icheck /dev/rrk2` on a disposable SimH copy reported `bad freeblock`,
`missing 1499`, `used 2222`, and only 192 reachable free blocks.

After unmounting `/dev/rk2` in SimH, `icheck -s /dev/rrk2` rebuilt its free
list from allocated inodes. A second `icheck` reported `used 2222`,
`free 1691`, with no errors; `dcheck /dev/rrk2` also reported no errors.
After remounting, `df` printed `/dev/rk2 1691`. The repaired working file is
`u6ed_rk2_fixed.dsk` (SHA-256
`a698384f168dae0f459c18f01d3f91f10707503c1ec7545ac51d9a2e9b8dead3`).
Compared with the original RK2, only the superblock and 16 free-list sectors
changed. The original image remains available unchanged.

`pack_sd.py` combines RK0, RK1, and the repaired RK2 into
`v6_rk_card_fixed.img` (7,483,392 bytes, SHA-256
`7ffff0e42441a894703527aa34b77728f36c7206aa088363aadbb2e64f6387bd`).
Its RK0 and RK1 slots exactly match the first card image. The physical card's
RK2 still matched the original image before repair. Its RK2 region was then
written from `u6ed_rk2_fixed.dsk`, flushed, and read back byte for byte.
The RK0 boot sector and complete RK1 region were also checked on the card.
After reinserting the card and reloading the volatile V6 bitstream by JTAG,
BTN3 restarted the RK05 bootstrap. The FPGA reached `login:`; a root login
and `df` reported RK0 1063, RK1 940, and RK2 1691 free blocks. The first
post-reinsertion attempt had displayed `@` but accepted no further input;
the fresh BTN3 bootstrap and input synchronized to its new `@` succeeded.

### Persistent FPGA configuration

The tested V6 bitstream was also converted to a 16 MiB, SPIx1 MCS file
(`sys_w11a_sa_rk_as7.mcs`, SHA-256
`14379ea8f3933db18fd6c3468eeebbb7a0071fa6ff1202943317e2e74fce6fe7`).
The installed configuration flash identified itself as `mt25ql128` (ID
`20 ba 18`), so Vivado 2022.1 used the compatible
`mt25ql128-spi-x1_x2_x4` part. The original 16 MiB flash contents were read
back to `flash_before_v6_20261003.bin` (SHA-256
`aa57de63ac456c99debb59b93294823e1698c4550c1db282b15374850b2b5d0e`).
Vivado then erased the MCS address range, passed its blank check, programmed
and verified the V6 MCS. `boot_hw_device` reconfigured the FPGA from flash;
DONE was HIGH and `USR_ACCESS` was `1d345c01`. After a full power cycle,
JTAG again read `USR_ACCESS=1d345c01`, confirming that the FPGA loaded the
saved circuit from flash. In the first cold boot observation no `@` was
visible on COM5, and the CPU was later at PC `000002`. Pressing BTN3
restarted the bootstrap; the fresh `@unix` sequence reached `login:`.
A second full power cycle was captured with COM5 already open. With no BTN3
press, `@` appeared; sending `unix` at that prompt reached `mem = 1027` and
`login:`. The first missing prompt may have been lost because of the terminal
connection timing; its exact cause is not established. The ordinary V6 boot
prompt still requires `unix` input. The SD card content was not rewritten
in this step.

### Usage

- Start backend server and boot system (see section Rlink in
  [w11a_os_guide](../../../doc/w11a_os_guide.md#user-content-rlink))
  ```
       boot script:  u6ed_rk_boot.tcl
       example:      ti_w11 <opt> @u6ed_rk_boot.tcl
                     where <opt> is the proper option set for the board.
  ```
  The same three prepared images can be checked in SimH with
  `pdp11 u6ed_rk_boot.scmd` from this directory. Use a disposable copy if
  the disk content must remain unchanged.

- The boot script sets the switch register to 1. The V6 kernel `putchar`
  is silent while the switch register is 0, so without this all kernel
  messages (including `panic:`) are suppressed.

- Hit `<ENTER>` in the xterm window to connect to backend server.
  The boot dialog in the console `xterm` window will look like
  (required input is in `{..}`, with `{<CR>}` denoting a carriage return:
  ```
       @{unix}
       mem = 1027
       RESTRICTED RIGHTS

       Use, duplication or disclosure is subject to
       restrictions stated in Contract with Western
       Electric Company, Inc.

       login: {root}
  ```

  Now you are at the shell prompt and can exercise the system, e.g.
  ```
       # {ls /usr/sys/ken}
       alloc.c
       clock.c
       ...
       trap.c
       # {chdir /tmp}
       # {cc sq.c}
       # {a.out}
  ```

  There is no `halt` or `shutdown` command. Enter `sync` and terminate
  the server session with a
  ```
       .qq
  ```

### Tested
- Arty S7-50 Rev E, 2026-09-24: boot, login, `ls`, `date`, `cc` compile and
  run OK on both designs
  - `sys_w11a_br_as7` (BRAM, 256 kB)
  - `sys_w11a_as7` (DDR3, 3840 kB; V6 runs in 18-bit mode)
