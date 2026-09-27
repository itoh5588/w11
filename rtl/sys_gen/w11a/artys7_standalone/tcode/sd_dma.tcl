# SPDX-License-Identifier: GPL-3.0-or-later
#
# SD multi-block read (CMD18) speed and SD -> memory DMA check, read only:
#   ti_w11 -tuD,12M,break,xon @sd_dma.tcl
# 1. speed of single (CMD17) and multi-block (CMD18) reads, hardware timed
# 2. DMA of 64 blocks to byte 0x100000; compared word by word with the same
#    blocks read one by one through the rbus buffer
# 3. odd word start (byte 0x140002) with untouched guard words
# 4. SD DMA repeated while the CPU/DMA ping-pong test runs

set sdb 0xfd10
set clkmhz 75.

proc sd_op {op} {
  global sdb
  rlc exec -wreg $sdb $op
  set t0 [clock milliseconds]
  while {1} {
    rlc exec -rreg $sdb st
    if {($st & 1) == 0} break
    if {[clock milliseconds] - $t0 > 5000} {
      puts "SDDMA-E: op $op still busy after 5 s"
      break
    }
  }
  return $st
}
proc sd_err {st} {return [expr {($st >> 8) & 0xff}]}
proc sd_cycles {} {
  global sdb
  rlc exec -rreg [expr {$sdb+11}] cl -rreg [expr {$sdb+12}] ch
  return [expr {($ch << 16) | $cl}]
}
proc sd_setup {lba nblk maddr} {
  global sdb
  rlc exec -wreg [expr {$sdb+1}] [expr {$lba & 0xffff}] \
           -wreg [expr {$sdb+2}] [expr {($lba >> 16) & 0xffff}] \
           -wreg [expr {$sdb+8}] $nblk \
           -wreg [expr {$sdb+9}] [expr {$maddr & 0xffff}] \
           -wreg [expr {$sdb+10}] [expr {($maddr >> 16) & 0x3f}]
}
# 256 words of the rbus buffer
proc sd_buf {} {
  global sdb
  rlc exec -wreg [expr {$sdb+3}] 0
  set wl {}
  for {set i 0} {$i < 256} {incr i} {
    rlc exec -rreg [expr {$sdb+4}] w
    lappend wl $w
  }
  return $wl
}
# n words of memory at byte address a (22 bit), in chunks (-brm <= 2040)
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

set nfail 0
set st [sd_op 1]
if {[sd_err $st] != 0} {
  puts "SDDMA-E: init failed, err=[sd_err $st]"
  return
}

# 1. speed
sd_setup 0 1 0
set st [sd_op 4]
set c1 [sd_cycles]
sd_setup 0 256 0
set st6 [sd_op 6]
set c256 [sd_cycles]
puts [format "SDDMA speed: CMD17 1 block %.0f us (%.2f MB/s); CMD18 256 blocks %.1f ms (%.2f MB/s) err=%d" \
        [expr {$c1/$clkmhz}] [expr {512.*$clkmhz/$c1}] \
        [expr {$c256/$clkmhz/1000.}] [expr {256*512.*$clkmhz/$c256}] [sd_err $st6]]
if {[sd_err $st] || [sd_err $st6]} {incr nfail}

# reference: blocks 0..63 one by one through the buffer
set ref {}
for {set b 0} {$b < 64} {incr b} {
  sd_setup $b 1 0
  set st [sd_op 4]
  if {[sd_err $st]} {incr nfail; puts "SDDMA-E: ref block $b err=[sd_err $st]"}
  lappend ref {*}[sd_buf]
}

# 2. DMA of 64 blocks
set base 0x100000
sd_setup 0 64 $base
set st [sd_op 5]
set c [sd_cycles]
rlc exec -rreg [expr {$sdb+13}] nw
set mem [mem_read $base 16384]
set bad 0
for {set i 0} {$i < 16384} {incr i} {
  if {[lindex $mem $i] != [lindex $ref $i]} {incr bad}
}
puts [format "SDDMA 64 blocks -> 0x%06x: err=%d words=%d mismatches=%d time=%.1f ms (%.2f MB/s)" \
        $base [sd_err $st] $nw $bad [expr {$c/$clkmhz/1000.}] \
        [expr {64*512.*$clkmhz/$c}]]
if {[sd_err $st] || $bad || $nw != 16384} {incr nfail}

# 3. odd word start with guards
set a 0x140002
mem_write [expr {$a-2}] [list 0125252]
mem_write [expr {$a+3*512}] [list 0052525]
sd_setup 10 3 $a
set st [sd_op 5]
set mem [mem_read $a 768]
set bad 0
for {set i 0} {$i < 768} {incr i} {
  if {[lindex $mem $i] != [lindex $ref [expr {10*256+$i}]]} {incr bad}
}
set g0 [mem_read [expr {$a-2}] 1]
set g1 [mem_read [expr {$a+3*512}] 1]
puts [format "SDDMA 3 blocks -> 0x%06x (odd word): err=%d mismatches=%d guards=%06o,%06o" \
        $a [sd_err $st] $bad $g0 $g1]
if {[sd_err $st] || $bad || $g0 != 0125252 || $g1 != 0052525} {incr nfail}

# 4. SD DMA while the ping-pong test runs (CPU + second DMA master)
set ppdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]
rlc exec -wreg 0xfd00 0x0002
cpu0 ldasm -file [file join $ppdir dma_pingpong.mac] -sym pp
rw11::asmrun cpu0 pp
after 50
rlc exec -wreg 0xfd00 0x0001
set bad 0
set nerr 0
set t0 [clock milliseconds]
for {set k 0} {$k < 20} {incr k} {
  sd_setup 0 64 $base
  set st [sd_op 5]
  rlc exec -rreg [expr {$sdb+13}] nw
  if {[sd_err $st] || $nw != 16384} {incr nerr}
  set mem [mem_read $base 16384]
  if {$mem ne $ref} {incr bad}
}
rlc exec -wreg 0xfd00 0x0000
after 100
rlc exec -rreg 0xfd02 iter -rreg 0xfd03 pperr
cpu0 cp -stop
cpu0 cp -wal 0102000 -rmi mseq -rmi mack -rmi merrc
puts [format "SDDMA with ping-pong: 20 x 64 blocks sd_err=%d mismatching_runs=%d; ping-pong err=%d cpuerr=%d seq=%d ack=%d (%.1f s)" \
        $nerr $bad $pperr $merrc $mseq $mack \
        [expr {([clock milliseconds]-$t0)/1000.}]]
if {$nerr || $bad || $pperr || $merrc || $mseq != $mack} {incr nfail}

if {$nfail == 0} {
  puts "SDDMA-I: PASS"
} else {
  puts "SDDMA-E: FAIL ($nfail)"
}
