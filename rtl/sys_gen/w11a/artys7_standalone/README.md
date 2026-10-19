# Arty S7-50 standalone w11 (RP07, RK05, RL01/RL02)

This directory adds a standalone PDP-11/70 configuration to W. F. J. Müller's
[w11](https://github.com/wfjm/w11). The fork starts from upstream commit
`4b16e761`. The CPU and DDR3 memory controller come from w11; the additions
provide native RH70/RP07, RK11/RK05 and RL11/RL01/RL02 controllers for a raw
microSD card, DMA, a local DL11 console, and a bootstrap that starts after
FPGA configuration. The normal OS path uses no PC I/O backend. The repository
is licensed under `GPL-3.0-or-later`, as is the upstream project.

One bitstream, `sys_w11a_sa_as7`, serves all three disk types. It reads a
label in block 0 of the card and selects the controller from it; a card
without a label is an RP07 card. See [Select the disk](#select-the-disk).

## Hardware and tested configuration

- Digilent Arty S7-50 (XC7S50) with its onboard DDR3L memory.
- Digilent Pmod MicroSD (410-380) on JD.
- A **3.3 V TTL** serial adapter on JC: JC1 is FPGA TX to adapter RX, JC2 is
  FPGA RX from adapter TX, and JC5 is ground. Set the terminal to 9600 8N1.
- BTN3 reads the card label again and restarts the bootstrap.
- SW3 = 1 gives the on-board USB-UART to an optional front panel instead of
  rlink (see [Front panel](#front-panel)). Leave SW3 = 0 for normal use.
- Vivado 2022.1 was used for the recorded builds and hardware tests. The
  system clock is 75 MHz.

The original w11 Arty S7 design in `../artys7/` uses a PC backend. The
standalone top level is `sys_w11a_sa_as7`; keep those two builds distinct.

## Build and load the FPGA

From the repository root, set the w11 build environment. `XTWV_PATH` is the
Vivado directory containing `settings64.sh`; see [w11 installation notes](../../../../doc/INSTALL.md)
for prerequisites.

```sh
export RETROBASE="$PWD"
export PATH="$RETROBASE/tools/bin:$PATH"
export XTWV_PATH=/path/to/Vivado/2022.1
cd "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone"
make sys_w11a_sa_as7.bit
```

Read the Vivado implementation timing report
(`sys_w11a_sa_as7_rou_tim.rpt`) before loading the bitstream. Do not use a
build with timing violations. The 2026-10-13 build of this revision reported
WNS `+0.078 ns` and WHS `+0.025 ns`; that small margin is a result for that
build, not a guarantee for another run.

After connecting the board's JTAG USB interface, load the verified bitstream:

```sh
make sys_w11a_sa_as7.vconfig
```

JTAG configures volatile FPGA memory. It does not write the configuration
flash; removing power restores whichever image is stored in flash. To boot at
power-on, convert the bitstream to an MCS file (`write_cfgmem -format mcs
-size 16 -interface SPIx1`) and program it with the Vivado Hardware Manager.
The tested board has a Micron MT25QL128 (`mt25ql128-spi-x1_x2_x4`); check the
part on your board.

## Select the disk

At configuration and on BTN3, the FPGA reads block 0 of the microSD card and
looks for a card label written by
[tools/oskit/sd_label.py](../../../../tools/oskit/sd_label.py):

| Label type | Controller | Bootstrap | Typical system |
| --- | --- | --- | --- |
| none | RH70/RP07, disk at LBA 0 | `70Boot from xp(0,0,0)` | 2.11BSD |
| `rp07` | RH70/RP07, disk at the label's LBA | as above | 2.11BSD |
| `rk05` | RK11/RK05 | `@` | Unix V6 |
| `rl` | RL11/RL01/RL02, RL02 and present masks from the label | RL0 | 2.11BSD on RL02 |

A missing label, a label with another version or type, or a card that cannot
be read selects RP07 at LBA 0, so existing 2.11BSD RP07 cards work unchanged.
The two controllers that were not selected stay in reset and do not answer on
the ibus; 2.11BSD reports them as `No CSR`. A labeled card has its disk data
after the label, at LBA 2048 by default. The label layout and the commands
are described in [the oskit overview](../../../../tools/oskit/README.md).

BTN3 probes the card again and restarts the bootstrap, so a card can be
exchanged without a new FPGA configuration. Halt the running system before
removing a card.

## OS media and boot

The controllers treat the card as a **raw disk image**, not as a FAT file.
Use a dedicated card and verify the target device before writing any image.

- **2.11BSD on RP07.** The RP07 geometry is 630 cylinders, 32 tracks per
  cylinder, 50 sectors per track and 512 bytes per sector: 1,008,000 sectors
  or 516,096,000 bytes. The tested image is built in SimH from the TUHS
  2.11BSD patch level 481 distribution tape only, with a kernel rebuilt for
  `FPSIM YES` because w11 has no FP11. It is used without a label. The image
  is not distributed here; the build steps, hashes and SD card writing
  procedure are in [SD_CARD.md](SD_CARD.md).
- **Unix V6 on RK05.** Pack the three RK05 volumes as described in
  [u6ed_rk](../../../../tools/oskit/u6ed_rk/README.md), then add a label with
  `sd_label.py --type rk05`.
- **RL01/RL02.** The card layout is described in
  [rl_sd](../../../../tools/oskit/rl_sd/README.md); add a label with
  `sd_label.py --type rl` and the RL02 and present masks.

With an unlabeled 2.11BSD card inserted, the bootstrap displays
`70Boot from xp(0,0,0)` about two seconds after FPGA configuration and boots
`unix` after a short countdown (press Enter to boot at once). The system
checks its file systems and continues to multi-user `login:`; log in as
`root` (no password). To stop, run `sync; sync; halt` and wait for `halting`
before resetting or removing power.

With a labeled RK05 card, the V6 bootstrap prints `@`; enter `unix` to reach
`login:`.

## Hardware test status

| Date | Bitstream | Card | Result |
| --- | --- | --- | --- |
| 2026-09-27 | RP07-only build, JTAG | earlier 2.11BSD RP07 image | file writes, `halt`, reboot, `fsck -n` and `sum` readback |
| 2026-10-04 | RP07-only build | 2.11BSD RP07 from the TUHS tape | multi-user `login:` and `halt` |
| 2026-10-13 | this revision, JTAG | 2.11BSD RP07, unlabeled | multi-user `login:`; RK11 and RL11 reported as `No CSR` |
| 2026-10-13 | this revision, JTAG | Unix V6 RK05, labeled | `@unix` reached `login:` |
| 2026-10-13 | this revision, flash | — | programmed and verified; `DONE` after `boot_hw_device` |
| 2026-10-15 | this revision, flash | 2.11BSD RP07, unlabeled | file writes to `/` and `/usr`, `halt`, BTN3 reboot, `cmp` and `sum` readback, single-user `fsck -n` on `rxp0a` and `rxp0c` without errors |
| 2026-10-15 | this revision, flash | Unix V6 RK05, labeled | cold power-on to `login:`; file writes to RK0 and RK1, `sync`, BTN3 reboot, `cmp` and `sum` readback; `icheck`/`dcheck` clean on RK1 and RK2 |
| 2026-10-16 | this revision, flash | both cards | card exchange with BTN3 only, V6 to 2.11BSD and 2.11BSD to V6 |
| 2026-10-16 | this revision, flash | 2.11BSD RP07, unlabeled | cold power-on to multi-user `login:` with no button pressed |

On the V6 RK0 volume, `icheck` reports block 2683 as a duplicate and 11
missing blocks, and `dcheck` reports link count mismatches. The same
findings are already in `u6ed_rk0.dsk` from the SimH kit, before any
hardware run; RK0 has not been repaired.

Not yet tested with this revision: any RL card on hardware.

## Front panel

With SW3 = 1, the on-board USB-UART (115200 bps) is connected to a PDP-11/70
front panel drawn in the browser by [tcode/panel.html](tcode/panel.html)
(Web Serial). It provides HALT, LOAD ADRS, EXAM/DEP, CONT and START, and
shows the address, data and status lamps. The panel is not needed to boot or
run an OS.

Implementation details and test evidence for the RP07 path are in
[the design notes](../../../../Docs/artys7_standalone_rp07_design.md).
