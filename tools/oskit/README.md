This directory tree contains **OS disk/tape image kits** and is organized in

| Directory | Content |
| --------- | ------- |
| [doc](doc)   | auxiliary documentation |
| [hook](hook) | `ti_w11` startup hook files |
| [test](test) | `ostest` configuration files |
| _all other_  | folders with individual OS kits |

The available OS kits are summarized in the table below with
- **DL**: number of DL11 lines supported by OS (for BSD also with active `ttys`)
- **DZ**: number of DZ11 lines supported by OS (for BSD also with active `ttys`)
- **PC**: PC11 (paper tape reader/puncher) support
- **XU**: DEUNA support
- **MinMem**: minimal required memory size

| Directory | DL  | DZ  | PC  | XU  | MinMem | Content |
| --------- | --: | --: | --: | --: | -----: | :------ |
| [211bsd_rk](211bsd_rk)         | 2/2 | 2/8 | n | n | 1024k | 2.11BSD system on RK05 volumes |
| [211bsd_rl](211bsd_rl)         | 2/2 | 2/8 | n | n | 1024k | 2.11BSD system on RL02 volumes |
| [211bsd_rp](211bsd_rp)         | 2/2 | 4/8 | n | n | 1024k | 2.11BSD system on RP06 volume |
| [211bsd_rpeth](211bsd_rpeth)   | 2/2 | 4/8 | n | y | 1024k | 2.11BSD system on RP06 volume with Ethernet |
| [211bsd_rpmin](211bsd_rpmin)   | 1/2 | 1/8 | n | n | 512k | 2.11BSD system on RP06 volume - minimal memory system |
| [211bsd_tm](211bsd_tm)         | 1/2 | 0/8 | n | n | 1024k | 2.11BSD system on a TM11 tape distribution kit |
| [rsx11m-31_rk](rsx11m-31_rk)   |   2 |   8 | y | n | 176k | RSX-11M V3.1 system on RK05 volumes |
| [rsx11m-40_rk](rsx11m-40_rk)   |   2 |   8 | y | n | 176k | RSX-11M V4.0 system on RK05 volumes |
| [rsx11mp-30_rp](rsx11mp-30_rp) |   2 |   8 | y | n | 672k | RSX-11Mplus V3.0 system on RP06 volume |
| [rt11-40_rk](rt11-40_rk)       |   1 |   - | y | n | 64k | RT-11 V4.0 system on RK05 volumes |
| [rt11-53_rl](rt11-53_rl)       |   1 |   - | y | n | 64k | RT-11 V5.3 system on a RL02 volume |
| [u5ed_rk](u5ed_rk)             |   1 |   - | n | n | 672k | Unix 5th Edition system on RK05 volumes |
| [u6ed_rk](u6ed_rk)             |   1 |   - | n | n | 256k | Unix 6th Edition system on RK05 volumes; local disk copy required |
| [u7ed_rp](u7ed_rp)             |   1 |   - | n | n | 672k | Unix 7th Edition system on RP04 volume |
| [xxdp_rl](xxdp_rl)             |   1 |   - | y | n | 64k | XXDP V2.2 and V2.5 system on RL02 volumes |

The standalone Arty S7 native RL11 microSD layout and image packer are
documented in [rl_sd](rl_sd/README.md).

### One bitstream for all standalone Arty S7 cards

`sys_w11a_sa_as7` contains the native RH70/RP07, RK11/RK05 and RL11/RL01/RL02
controllers. At configuration and on BTN3 the FPGA reads block 0 of the
microSD card and selects one of them from a card label written by
[sd_label.py](sd_label.py). The label also gives the first LBA of the disk
data and, for RL, which units are RL02 and which are present. A card
without a label is used as an RP07 card with the disk at LBA 0, so existing
2.11BSD RP07 cards keep working unchanged. The bootstrap of the selected disk
is then loaded and started; the two other controllers stay in reset and do not
answer on the ibus. BTN3 probes the card again, so a card can be exchanged
and booted without reconfiguring the FPGA.

The label shifts the disk data, so an RK05 or RL card must be rewritten
from a labeled image. The default data start is LBA 2048 (1 MiB):

```sh
python3 tools/oskit/sd_label.py --type rk05 \
  tools/oskit/u6ed_rk/v6_rk_card_fixed.img v6_rk_card_labeled.img
python3 tools/oskit/sd_label.py --type rl --rl02-mask 0011 --present-mask 0011 \
  211bsd-rl-card.img 211bsd-rl-card-labeled.img
python3 tools/oskit/sd_label.py --type rp07 rp07.img rp07-labeled.img
```

The label occupies block 0 (little-endian words): `W11SDLBL`, version 1,
type (1 RP07, 2 RK05, 3 RL), the first data LBA as two words, the RL02 mask
and the present mask (bit 0 = unit 0). Bytes 446 to 511 stay free for an MBR
partition table. A label with another version or type is ignored, and so is
the card: it is then treated as an unlabeled RP07 card.
