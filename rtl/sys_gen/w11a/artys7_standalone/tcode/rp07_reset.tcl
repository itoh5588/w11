# SPDX-License-Identifier: GPL-3.0-or-later
#
# Boot from the native RP07, reset the CPU after reset_secs (default 50,
# meant to hit disk I/O of the running system), then boot again.  Waits
# boot_secs in total.  Console on tcp port 8000.

if {![info exists reset_secs]} {set reset_secs 50}
if {![info exists boot_secs]} {set boot_secs 200}
rw11::setup_tt "cpu0" ndl 2 dlrxrlim 5 ndz 2 dzrxrlim 5 to7bit 1
set bdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $bdir rp07_boot.mac] -sym bt
cpu0 cp -stapc $bt(start)
after [expr {$reset_secs * 1000}]
cpu0 cp -stop -creset
puts "RESET-I: cpu stopped and reset after $reset_secs s"
cpu0 ldasm -file [file join $bdir rp07_boot.mac] -sym bt
cpu0 cp -stapc $bt(start)
after [expr {($boot_secs - $reset_secs) * 1000}]
