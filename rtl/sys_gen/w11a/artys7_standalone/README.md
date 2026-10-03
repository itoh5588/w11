# Arty S7-50 standalone w11 (RP07)

This directory adds a standalone PDP-11/70 configuration to W. F. J. Müller's
[w11](https://github.com/wfjm/w11). The fork starts from upstream commit
`4b16e761`. The CPU and DDR3 memory controller come from w11; the additions
provide a native RP07 controller for a raw microSD card, DMA, a local DL11
console, and a bootstrap that starts after FPGA configuration. The normal OS
path uses no PC I/O backend. The repository is licensed under
`GPL-3.0-or-later`, as is the upstream project.

## Hardware and tested configuration

- Digilent Arty S7-50 (XC7S50) with its onboard DDR3L memory.
- Digilent Pmod MicroSD (410-380) on JD.
- A **3.3 V TTL** serial adapter on JC: JC1 is FPGA TX to adapter RX, JC2 is
  FPGA RX from adapter TX, and JC5 is ground. Set the terminal to 9600 8N1.
- Vivado 2022.1 was used for the recorded build and hardware test. The system
  clock is 75 MHz.

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

Read the Vivado implementation timing report before loading the bitstream.
Do not use a build with timing violations. The 2026-09-27 hardware test of
this revision reported WNS `+0.022 ns`; that small margin is a result for that
build, not a guarantee for another run.

After connecting the board's JTAG USB interface, load the verified bitstream:

```sh
make sys_w11a_sa_as7.vconfig
```

JTAG configures volatile FPGA memory. It does not write the configuration
flash; removing power restores whichever image is stored in flash.

## OS media and boot

The RP07 controller treats sector zero of the microSD card as sector zero of
a **raw disk image**, not as a FAT file. Its geometry is 630 cylinders,
32 tracks per cylinder, 50 sectors per track and 512 bytes per sector:
1,008,000 sectors or 516,096,000 bytes. Use a dedicated card and verify the
target device before writing any image.

The development test used a 2.11BSD RP07 image with an FPSIM-enabled kernel.
The original supplied image required FP11 hardware and did not boot fully on
this w11 configuration. Neither the original image nor the modified copy is
distributed here. The source and redistribution terms of an OS image must be
established separately; this source release alone does not provide a complete
reader-reproducible OS boot.

With a compatible card inserted, the bootstrap displays
`70Boot from xp(0,0,0)` after FPGA configuration. Press Enter to load `unix`.
At the single-user `#` prompt, press Ctrl-D to continue to `login:`. To stop,
run `sync; sync; halt` and wait for `halting` before resetting or removing
power. The 2026-09-27 hardware record confirms this sequence using the
FPSIM-enabled copy; it does not establish a fresh-environment reproduction.

Implementation details and test evidence are in
[the design notes](../../../../Docs/artys7_standalone_rp07_design.md) and
[the 2026-09-27 worklog](../../../../Docs/Worklogs/2026-09-27.md).
