# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bring the card to the content of a new RP07 image through the native RP07
# controller (sys_w11a_rp07w_as7, write enabled), writing only blocks that
# change.  Blocks to write: the list DIFFFILE (new image vs old image) plus
# every block in 0..SCANN-1 where the card differs from the old image.
#   IMGNEW=.. IMGOLD=.. DIFFFILE=.. [SCANN=40000]
#   ti_w11 -tuD,12M,break,xon -b @rp07_sync.tcl

set scann [expr {[info exists ::env(SCANN)] ? $::env(SCANN) : 40000}]
set tdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
cpu0 ldasm -file [file join $tdir rp07_xfer.mac] -sym rp
set fnew [open $::env(IMGNEW) rb]
set fold [open $::env(IMGOLD) rb]
set buf 0x10000

proc img {f lba n} {
  seek $f [expr {$lba * 512}]
  return [read $f [expr {$n * 512}]]
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
  return [binary format s* $res]
}
proc mem_write {a bytes} {
  binary scan $bytes s* wl
  set out {}
  foreach w $wl {lappend out [expr {$w & 0xffff}]}
  while {[llength $out] > 0} {
    set k [expr {[llength $out] > 1024 ? 1024 : [llength $out]}]
    cpu0 cp -wal [expr {$a & 0xffff}] -wah [expr {0x40 | (($a >> 16) & 0x3f)}] \
            -bwm [lrange $out 0 [expr {$k-1}]]
    set out [lrange $out $k end]
    incr a [expr {2*$k}]
  }
}
proc chs {lba} {
  return [list [expr {$lba / 1600}] [expr {($lba % 1600) / 50}] \
            [expr {$lba % 50}]]
}
# one transfer of n blocks, func 071 READ / 061 WRITE; error if not clean
proc xfer {func lba n} {
  global rp buf
  lassign [chs $lba] c t s
  cpu0 cp -wal $rp(pdc) -bwm [list $c [expr {$t*256+$s}] \
          [expr {$buf & 0xffff}] [expr {$buf >> 16}] \
          [expr {(65536 - $n*256) & 0xffff}]]
  cpu0 cp -wal $rp(pfunc) -bwm [list $func]
  cpu0 cp -stapc $rp(start)
  set dt [cpu0 wtcpu -reset 30.]
  cpu0 cp -wal $rp(rcs1) -brm 9 res
  lassign $res rcs1 rcs2 rer1 rwc rba rda rdc ras flag
  if {$dt < 0 || $flag != 1 || ($rcs1 & 0140200) != 0200 || $rer1 != 0 ||
      $rwc != 0} {
    error [format "xfer %o lba %d n %d failed: cs1=%06o cs2=%06o er1=%06o wc=%06o flag=%d" \
             $func $lba $n $rcs1 $rcs2 $rer1 $rwc $flag]
  }
}

set t0 [clock seconds]
# 1. scan: card vs old image
set wset {}
set nscan 0
for {set l 0} {$l < $scann} {incr l 64} {
  set n [expr {min(64, $scann - $l)}]
  xfer 071 $l $n
  set got [mem_read $buf [expr {$n*256}]]
  set old [img $fold $l $n]
  for {set i 0} {$i < $n} {incr i} {
    if {[string range $got [expr {$i*512}] [expr {$i*512+511}]] ne
        [string range $old [expr {$i*512}] [expr {$i*512+511}]]} {
      lappend wset [expr {$l+$i}]
      incr nscan
    }
  }
}
puts "SYNC scan 0..[expr {$scann-1}]: $nscan blocks differ from the old image"

# 2. write set: diff list + scan result, as runs of <= 64 blocks
set f [open $::env(DIFFFILE) r]
foreach l [split [string trim [read $f]] "\n"] {lappend wset $l}
close $f
set wset [lsort -integer -unique $wset]
set runs {}
foreach l $wset {
  if {[llength $runs] && $l == [lindex $runs end 1] + 1 &&
      $l - [lindex $runs end 0] < 64} {
    lset runs end 1 $l
  } else {
    lappend runs [list $l $l]
  }
}
puts "SYNC writing [llength $wset] blocks in [llength $runs] transfers"
foreach r $runs {
  lassign $r a b
  set n [expr {$b - $a + 1}]
  mem_write $buf [img $fnew $a $n]
  xfer 061 $a $n
}
puts "SYNC write done after [expr {[clock seconds]-$t0}] s"

# 3. verify: written runs and the scanned area against the new image
set bad 0
foreach r $runs {
  lassign $r a b
  set n [expr {$b - $a + 1}]
  xfer 071 $a $n
  if {[mem_read $buf [expr {$n*256}]] ne [img $fnew $a $n]} {
    incr bad
    puts "SYNC-E: run $a..$b differs after write"
  }
}
for {set l 0} {$l < $scann} {incr l 64} {
  set n [expr {min(64, $scann - $l)}]
  xfer 071 $l $n
  if {[mem_read $buf [expr {$n*256}]] ne [img $fnew $l $n]} {
    incr bad
    puts "SYNC-E: scan area $l.. differs from the new image"
  }
}
close $fnew
close $fold
if {$bad == 0} {
  puts "SYNC-I: PASS ([llength $wset] blocks written, [expr {[clock seconds]-$t0}] s)"
} else {
  puts "SYNC-E: FAIL ($bad)"
}
