# Arty S7 standalone RL01/RL02 on microSD

The single standalone bitstream `sys_w11a_sa_as7` contains a native RL11
controller and boots from RL0 when the card carries an RL card label, made
by `../sd_label.py --type rl` with the RL02 and present masks of the packed
drives (see [the kit overview](../README.md)). The label replaces the
`RL02_MASK` and `PRESENT_MASK` generics of the earlier separate
`sys_w11a_sa_rl_as7` bitstream, to which the rest of this page refers. That
variant connected the RL11 controller to the
standalone PDP-11 memory/DMA path and booted from RL0. The console is the JC
UART. This variant uses a **dedicated raw microSD card**; its contents are
not a filesystem and are not compatible with the RP07 or RK05 card layouts.

The RL01 has 256 cylinders; the RL02 has 512. Both have two heads, 40 sectors
per track, and 256 bytes per sector. The controller accepts up to four drives.
Each RL sector is expanded to one 512-byte SD block, with the upper 256 bytes
set to zero. This makes each write independent; it does not need to read and
rewrite an adjacent RL sector. Every drive reserves one RL02-sized slot:

| Drive | First SD LBA | Last SD LBA | Slot size |
| --- | ---: | ---: | ---: |
| RL0 | 0 | 40959 | 20,971,520 bytes |
| RL1 | 40960 | 81919 | 20,971,520 bytes |
| RL2 | 81920 | 122879 | 20,971,520 bytes |
| RL3 | 122880 | 163839 | 20,971,520 bytes |

For drive `u`, cylinder `c`, head `h`, sector `s`, the SD LBA is
`u × 40960 + (c × 2 + h) × 40 + s`. RL01 uses only the first 20480 blocks
of its slot. The complete packed image is 83,886,080 bytes.
A card must provide at least that many addressable bytes.

Create the packed image on Windows 11 in a WSL2 Ubuntu terminal. Use raw
RL images with 256-byte sectors; `pack_rl_sd.py` rejects files larger than
the selected drive type or files not aligned to 256 bytes. It only creates a
new regular file; it never opens a physical card or overwrites an existing
output file.

```sh
python3 tools/oskit/pack_rl_sd.py rl-card.img \
  --unit 0:RL02:rl0.dsk --unit 1:RL01:rl1.dsk
```

For the repository's `211bsd_rl` kit, the input file names are
`211bsd_rl_root.dsk` (RL0) and `211bsd_rl_usr.dsk` (RL1). Both use RL02;
obtain them through the kit's own [setup instructions](../211bsd_rl/README.md)
before packing. A packed image can be prepared with:

```sh
python3 tools/oskit/pack_rl_sd.py 211bsd-rl-card.img \
  --unit 0:RL02:tools/oskit/211bsd_rl/211bsd_rl_root.dsk \
  --unit 1:RL02:tools/oskit/211bsd_rl/211bsd_rl_usr.dsk
```

The default RTL mask declares all four drives RL02 and present. For a card
packed as above, set `RL02_MASK` to `"0001"` and `PRESENT_MASK` to `"0011"`
on `sys_w11a_sa_rl_as7`. Bit 0 corresponds to RL0. The type mask in the
bitstream must agree with the input image type; the packer does not configure
the FPGA. An RL01 image can also occupy an RL02 drive slot, but software will
see an RL02 drive.

The controller and packer have been checked in simulation. The Arty S7
standalone RL variant completed placement and routing with setup slack
+0.046 ns and hold slack +0.030 ns in Vivado 2022.1. Physical card behavior
and operating-system boot have not yet been verified.
The generated `sys_w11a_sa_rl_as7.bit` in the standalone RTL directory uses
the default masks (all four drives present and RL02). This build has SHA-256
`f2b8a7c5d47a397455058eeb262e22d561f9529835b6b36665a66f31080300fe`.
Rebuilding or editing the masks changes the hash.
The controller currently implements GET STATUS, SEEK, READ HEADER, READ,
WRITE, and READ WITHOUT HEADER CHECK. WRITE CHECK is not implemented and
returns a controller error. READ HEADER returns the current position and a
zero placeholder for its CRC word; software that checks that CRC needs a
follow-up implementation.

Geometry reference: [DEC RL01/RL02 Disk Drive Technical Manual](https://bitsavers.org/pdf/dec/disc/rl01_rl02/EK-RL012-TM-PRE_RL01_RL02_Disk_Drive_Technical_Manual_Preliminary_Dec79.pdf).
