# SPDX-License-Identifier: GPL-3.0-or-later
#
# RP07 reads through the native controller, run by the PDP-11 CPU
# (rp07_read.mac), compared with reference blocks read before through
# sdspi_rbus (file $env(REFFILE): "<lba> <256 words>" per line):
#   REFFILE=... ti_w11 -tuD,12M,break,xon @rp07_read.tcl
# The card is only read.

set ppdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $ppdir rp07_read.mac] -sym rp

array set ref {}
set f [open $::env(REFFILE) r]
while {[gets $f line] >= 0} {
  set ref([lindex $line 0]) [lrange $line 1 end]
}
close $f

proc mem_read {a n} {
  set res {}
  while {$n > 0} {
    set k [expr {$n > 1024 ? 1024 : $n}]
    cpu0 cp -wal [expr {$a & 0xffff}] -wah [expr {0x40 | (($a >> 16) & 0x3f)}] \
            -brm $k wl
    lappend res {*}$wl
    incr a [expr {2*$k}]
    incr n -$k
  }
  return $res
}
proc mem_write {a wl} {
  cpu0 cp -wal [expr {$a & 0xffff}] -wah [expr {0x40 | (($a >> 16) & 0x3f)}] \
          -bwm $wl
}
proc chs {lba} {
  return [list [expr {$lba / 1600}] [expr {($lba % 1600) / 50}] \
            [expr {$lba % 50}]]
}

set nfail 0
# one READ: lba, words, byte address; expected ER1 and word count
proc rp_read {name lba nw addr {eer1 0} {ewc 0}} {
  global rp ref nfail
  lassign [chs $lba] c t s
  mem_write [expr {$addr-2}] [list 0125252]
  mem_write [expr {$addr+2*$nw}] [list 0052525]
  cpu0 cp -wal $rp(pdc) -bwm [list $c [expr {$t*256+$s}] \
          [expr {$addr & 0xffff}] [expr {$addr >> 16}] \
          [expr {(65536-$nw) & 0xffff}]]
  set t0 [clock milliseconds]
  cpu0 cp -stapc $rp(start)
  set dt [cpu0 wtcpu -reset 20.]
  set ms [expr {[clock milliseconds]-$t0}]
  cpu0 cp -rpc pc
  cpu0 cp -wal $rp(rcs1) -brm 9 res
  lassign $res rcs1 rcs2 rer1 rwc rba rda rdc ras flag
  # expected data: reference blocks, as far as the disk goes
  set ndata $nw
  if {$lba*256 + $nw > 1008000*256} {set ndata [expr {(1008000-$lba)*256}]}
  set exp {}
  for {set b 0} {$b*256 < $ndata} {incr b} {
    lappend exp {*}$ref([expr {$lba+$b}])
  }
  set exp [lrange $exp 0 [expr {$ndata-1}]]
  set mem [mem_read $addr $ndata]
  set bad 0
  for {set i 0} {$i < $ndata} {incr i} {
    if {[lindex $mem $i] != [lindex $exp $i]} {incr bad}
  }
  set g0 [mem_read [expr {$addr-2}] 1]
  set g1 [mem_read [expr {$addr+2*$nw}] 1]
  set nblk [expr {($ndata+255)/256}]
  lassign [chs [expr {$lba+$nblk}]] ec et es
  set errs {}
  if {$dt < 0} {lappend errs "no halt"}
  if {$flag != 1} {lappend errs "interrupts=$flag"}
  if {($rcs1 & 0200) == 0} {lappend errs "RDY=0"}
  if {$rer1 != $eer1} {lappend errs [format "er1=%06o" $rer1]}
  if {($rcs2 & 0074000) != 0} {lappend errs [format "cs2=%06o" $rcs2]}
  if {$rwc != $ewc} {lappend errs [format "wc=%06o" $rwc]}
  if {$rdc != $ec || $rda != $et*256+$es} {
    lappend errs [format "dc/da=%d/%06o expected %d/%06o" $rdc $rda $ec \
                    [expr {$et*256+$es}]]
  }
  set eba [expr {($addr + 2*$ndata) & 0xffff}]
  if {$rba != $eba} {lappend errs [format "ba=%06o" $rba]}
  if {$bad} {lappend errs "data mismatches=$bad"}
  if {$g0 != 0125252 || $g1 != 0052525} {lappend errs "guard changed"}
  if {[llength $errs]} {
    incr nfail
    puts "RP07-E $name: [join $errs {, }]"
  } else {
    puts [format "RP07 %-26s ok: lba %7d %5d words -> 0x%06x, %d ms" \
            $name $lba $nw $addr $ms]
  }
}

rp_read "T1 boot block + label" 0 512 0x1000
rp_read "T2 64 blocks (32 kB)" 0 16384 0x10000
rp_read "T3 odd word address" 1000 1024 0x30002
rp_read "T4 middle of disk" 500000 512 0x1000
rp_read "T5 last two blocks" 1007998 512 0x1000
rp_read "T6 AOE at end of disk" 1007999 512 0x1000 01000 0177400

if {$nfail == 0} {puts "RP07-I: PASS"} else {puts "RP07-E: FAIL ($nfail)"}
