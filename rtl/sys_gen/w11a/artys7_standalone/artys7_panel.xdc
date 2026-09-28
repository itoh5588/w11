# -*- tcl -*-
# SPDX-License-Identifier: GPL-3.0-or-later
#
# front panel (w11_panel) on the on-board USB-UART, sys_w11a_sa_as7:
# the serial lines and SW3 cross between CLK and CLKS through 2-stage
# synchronizers (115200 bps, SW3 static)
#
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *PN_TXD_S0_reg}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *PN_MODE_S0_reg}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *PN_RXD_S0_reg}]
