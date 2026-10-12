# Setup file for Unix V6 (6th Edition) RK05 based system
#
# Disk images: retux/unix-v6-on-simh (disk0.rk .. disk2.rk), SimH PDP-11/40 kit
#
# Usage:
#
# console_starter -d DL0 &
# ti_w11 -xxx @u6ed_rk_boot.tcl        ( -xxx depends on sim or fpga connect)
#

# setup w11 cpu
rutil::dohook "preinithook"
puts [rlw]

# setup tt,lp (uses 7 bit mode)
rw11::setup_tt "cpu0" ndl 1 dlrxrlim 5 to7bit 1
rw11::setup_lp

# mount disks
cpu0rka0 att u6ed_rk0.dsk
cpu0rka1 att u6ed_rk1.dsk
cpu0rka2 att u6ed_rk2.dsk

# and boot
# switch register = 1: V6 kernel printf (putchar) is silent while SR == 0
#   (same as "d sr 1" in the SimH setup)
cpu0 cp -wibr sdreg 1

rutil::dohook "preboothook"
cpu0 boot rka0
