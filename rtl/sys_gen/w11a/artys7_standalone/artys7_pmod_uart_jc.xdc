# SPDX-License-Identifier: GPL-3.0-or-later
#
# 3.3 V TTL serial cable (FTDI FT232R) on Arty S7 header JC, jumper wires:
#   jc1 U15 = FPGA TXD (to cable RXD), jc2 V16 = FPGA RXD (from cable TXD),
#   jc5 = GND.  Pins from Digilent Arty-S7-50-Master.xdc (Rev E).
#
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports O_JC_TXD]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports I_JC_RXD]
set_property PULLUP true [get_ports I_JC_RXD]
set_property DRIVE 8 [get_ports O_JC_TXD]
set_false_path -to [get_ports O_JC_TXD]
set_false_path -from [get_ports I_JC_RXD]
