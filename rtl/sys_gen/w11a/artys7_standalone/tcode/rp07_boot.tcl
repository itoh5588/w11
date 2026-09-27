# SPDX-License-Identifier: GPL-3.0-or-later
#
# Boot the RP07 image on the microSD card through the native controller
# (sys_w11a_rp07_as7).  The console DL11 is on tcp port 8000 and logged in
# tirri_tta0.log.  Runs for boot_secs seconds (default 60).
#   ti_w11 -tuD,12M,break,xon @rp07_boot.tcl

if {![info exists boot_secs]} {set boot_secs 60}
rw11::setup_tt "cpu0" ndl 2 dlrxrlim 5 ndz 2 dzrxrlim 5 to7bit 1
set bdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $bdir rp07_boot.mac] -sym bt
cpu0 cp -stapc $bt(start)
puts "BOOT-I: started, waiting $boot_secs s"
after [expr {$boot_secs * 1000}]
cpu0 cp -rstat st -rpc pc
puts [format "BOOT-I: after %d s: cpu stat=%06o pc=%06o" $boot_secs $st $pc]
