# SPDX-License-Identifier: GPL-3.0-or-later
#
# RP07 WRITE test on the real card (sys_w11a_rp07w_as7, write enabled):
#   IMGFILE=<backup image> ti_w11 -tuD,12M,break,xon @rp07_write.tcl
# Area lba0-1 .. lba0+12 (default lba0 = 1000000).  The blocks are checked
# against the backup image first (no write if they differ), written with a
# pattern, read back with their neighbours, and finally restored from the
# backup image and checked again.

if {![info exists lba0]} {set lba0 1000000}
set tdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $tdir rp07_xfer.mac] -sym rp

set imgf [open $::env(IMGFILE) rb]
proc img_block {lba} {
  global imgf
  seek $imgf [expr {$lba * 512}]
  binary scan [read $imgf 512] s256 wl
  set res {}
  foreach w $wl {lappend res [expr {$w & 0xffff}]}
  return $res
}
proc img_blocks {lba n} {
  set res {}
  for {set i 0} {$i < $n} {incr i} {lappend res {*}[img_block [expr {$lba+$i}]]}
  return $res
}
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
  while {[llength $wl] > 0} {
    set k [expr {[llength $wl] > 1024 ? 1024 : [llength $wl]}]
    cpu0 cp -wal [expr {$a & 0xffff}] -wah [expr {0x40 | (($a >> 16) & 0x3f)}] \
            -bwm [lrange $wl 0 [expr {$k-1}]]
    set wl [lrange $wl $k end]
    incr a [expr {2*$k}]
  }
}
proc chs {lba} {
  return [list [expr {$lba / 1600}] [expr {($lba % 1600) / 50}] \
            [expr {$lba % 50}]]
}

set nfail 0
# one transfer; func 071 READ / 061 WRITE; checks the completion
proc xfer {name func lba nw addr} {
  global rp nfail
  lassign [chs $lba] c t s
  cpu0 cp -wal $rp(pdc) -bwm [list $c [expr {$t*256+$s}] \
          [expr {$addr & 0xffff}] [expr {$addr >> 16}] \
          [expr {(65536-$nw) & 0xffff}]]
  cpu0 cp -wal $rp(pfunc) -bwm [list $func]
  set t0 [clock milliseconds]
  cpu0 cp -stapc $rp(start)
  set dt [cpu0 wtcpu -reset 30.]
  set ms [expr {[clock milliseconds]-$t0}]
  cpu0 cp -wal $rp(rcs1) -brm 9 res
  lassign $res rcs1 rcs2 rer1 rwc rba rda rdc ras flag
  lassign [chs [expr {$lba + ($nw+255)/256}]] ec et es
  set errs {}
  if {$dt < 0} {lappend errs "no halt"}
  if {$flag != 1} {lappend errs "interrupts=$flag"}
  if {($rcs1 & 0140200) != 0200} {lappend errs [format "cs1=%06o" $rcs1]}
  if {$rer1 != 0} {lappend errs [format "er1=%06o" $rer1]}
  if {($rcs2 & 0074000) != 0} {lappend errs [format "cs2=%06o" $rcs2]}
  if {$rwc != 0} {lappend errs [format "wc=%06o" $rwc]}
  if {$rdc != $ec || $rda != $et*256+$es} {lappend errs "dc/da"}
  if {[llength $errs]} {
    incr nfail
    puts "RP07W-E $name: [join $errs {, }]"
    return 0
  }
  puts [format "RP07W %-34s ok: lba %7d %5d words, %d ms" $name $lba $nw $ms]
  return 1
}
proc compare {name got exp} {
  global nfail
  set bad 0
  for {set i 0} {$i < [llength $exp]} {incr i} {
    if {[lindex $got $i] != [lindex $exp $i]} {incr bad}
  }
  if {$bad} {
    incr nfail
    puts "RP07W-E $name: $bad of [llength $exp] words differ"
    return 0
  }
  puts "RP07W $name: [llength $exp] words match"
  return 1
}

set l0 [expr {$lba0 - 1}]
set nb 14
# T0: the area must still hold the backup image, otherwise nothing is written
xfer "T0 read area" 071 $l0 [expr {$nb*256}] 0x10000
if {![compare "T0 area = backup image" [mem_read 0x10000 [expr {$nb*256}]] \
        [img_blocks $l0 $nb]]} {
  puts "RP07W-E: area differs from the backup image, no write done"
  return
}

# T1/T2: 4 blocks with a pattern, read back with both neighbours
set pat {}
for {set i 0} {$i < 1025} {incr i} {lappend pat [expr {($i*13 + 0x5a5a) & 0xffff}]}
mem_write 0x20000 $pat
xfer "T1 write 4 blocks" 061 $lba0 1024 0x20000
xfer "T2 read back 6 blocks" 071 $l0 1536 0x30000
set got [mem_read 0x30000 1536]
compare "T2 block before unchanged" [lrange $got 0 255] [img_block $l0]
compare "T2 4 blocks = pattern" [lrange $got 256 1279] [lrange $pat 0 1023]
compare "T2 block after unchanged" [lrange $got 1280 1535] \
  [img_block [expr {$lba0+4}]]

# T3: 300 words from an odd word address, zero filled, neighbours unchanged
set lp [expr {$lba0 + 10}]
xfer "T3 write 300 words (odd address)" 061 $lp 300 0x20002
xfer "T3 read back 4 blocks" 071 [expr {$lp-1}] 1024 0x30000
set got [mem_read 0x30000 1024]
set exp [lrange $pat 1 300]
for {set i 0} {$i < 212} {incr i} {lappend exp 0}
compare "T3 block before unchanged" [lrange $got 0 255] \
  [img_block [expr {$lp-1}]]
compare "T3 300 words + zero fill" [lrange $got 256 767] $exp
compare "T3 block after unchanged" [lrange $got 768 1023] \
  [img_block [expr {$lp+2}]]

# T4: restore from the backup image
mem_write 0x20000 [img_blocks $lba0 4]
xfer "T4 restore 4 blocks" 061 $lba0 1024 0x20000
mem_write 0x20000 [img_blocks $lp 2]
xfer "T4 restore 2 blocks" 061 $lp 512 0x20000

# T5: the whole area equals the backup image again
xfer "T5 read area" 071 $l0 [expr {$nb*256}] 0x10000
compare "T5 area = backup image" [mem_read 0x10000 [expr {$nb*256}]] \
  [img_blocks $l0 $nb]

close $imgf
if {$nfail == 0} {puts "RP07W-I: PASS"} else {puts "RP07W-E: FAIL ($nfail)"}
