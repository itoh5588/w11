# SPDX-License-Identifier: GPL-3.0-or-later
#
# Start the RP07 bootstrap on sys_w11a_sa_as7; the console is the native
# DL11 on the serial cable in JC (no ti_w11 terminal relay).  Waits
# boot_secs (default 5) and leaves the system running.

if {![info exists boot_secs]} {set boot_secs 5}
set bdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $bdir rp07_boot.mac] -sym bt
cpu0 cp -stapc $bt(start)
puts "BOOTSA-I: bootstrap started"
after [expr {$boot_secs * 1000}]
