# SPDX-License-Identifier: GPL-3.0-or-later
#
# Digilent Pmod MicroSD (410-380) in Arty S7 header JD, SPI mode.
# Pins from Digilent Arty-S7-50-Master.xdc (Rev E):
#   jd1 V15 CS (DAT3), jd2 U12 MOSI (CMD), jd3 V13 MISO (DAT0),
#   jd4 T12 SCLK, jd9 T11 CD (card detect); DAT1/DAT2 (jd7/jd8) unused.
#
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports O_SD_CS_N]
set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports O_SD_MOSI]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports I_SD_MISO]
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports O_SD_SCLK]
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports I_SD_CD]
set_property PULLUP true [get_ports {I_SD_MISO I_SD_CD}]
set_property DRIVE 8 [get_ports {O_SD_CS_N O_SD_MOSI O_SD_SCLK}]
#
# SCLK is a fabric register (<= 12.5 MHz); MISO is sampled through two
# synchronizer flops in the middle of the SCLK high phase (sdspi_phy).
set_false_path -to [get_ports {O_SD_CS_N O_SD_MOSI O_SD_SCLK}]
set_false_path -from [get_ports {I_SD_MISO I_SD_CD}]
