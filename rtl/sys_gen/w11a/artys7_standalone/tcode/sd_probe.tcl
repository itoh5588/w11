# SPDX-License-Identifier: GPL-3.0-or-later
#
# Read-only probe of the Pmod MicroSD card via sdspi_rbus (rbus 0xfd10):
#   ti_w11 -tuD,12M,break,xon @sd_probe.tcl
# The block layer has no write command, the card is never modified.

set sdb 0xfd10

proc sd_op {op} {
  global sdb
  rlc exec -wreg $sdb $op
  set t0 [clock milliseconds]
  while {1} {
    rlc exec -rreg $sdb st
    if {($st & 1) == 0} break
    if {[clock milliseconds] - $t0 > 3000} {
      puts "SD-E: op $op still busy after 3 s"
      break
    }
  }
  return $st
}

proc sd_stat {st} {
  return [format "err=%d init=%d v2=%d hc=%d cd=%d" [expr {($st>>8)&0xff}] \
            [expr {($st>>1)&1}] [expr {($st>>2)&1}] [expr {($st>>3)&1}] \
            [expr {($st>>4)&1}]]
}

# read n buffer bytes (little-endian words) into a list
proc sd_bytes {n} {
  global sdb
  rlc exec -wreg [expr {$sdb+3}] 0
  set bl {}
  for {set i 0} {$i < $n/2} {incr i} {
    rlc exec -rreg [expr {$sdb+4}] w
    lappend bl [expr {$w & 0xff}] [expr {($w >> 8) & 0xff}]
  }
  return $bl
}

proc sd_read {lba} {
  global sdb
  rlc exec -wreg [expr {$sdb+1}] [expr {$lba & 0xffff}] \
           -wreg [expr {$sdb+2}] [expr {($lba >> 16) & 0xffff}]
  return [sd_op 4]
}

rlc exec -rreg $sdb st
puts "SD before init: [sd_stat $st]"

set st [sd_op 1]
rlc exec -rreg [expr {$sdb+5}] r1 -rreg [expr {$sdb+7}] ocrh
puts "SD init:        [sd_stat $st] r1=[format 0x%02x [expr {$r1&0xff}]] ocr_hi=[format 0x%04x $ocrh]"
if {($st >> 8) != 0} {
  puts "SD-E: init failed"
  return
}

set st [sd_op 2]
set cid [sd_bytes 16]
set pnm ""
foreach b [lrange $cid 3 7] {append pnm [format %c $b]}
set oid [format %c%c [lindex $cid 1] [lindex $cid 2]]
set psn [expr {([lindex $cid 9]<<24)|([lindex $cid 10]<<16)|([lindex $cid 11]<<8)|[lindex $cid 12]}]
set mdt [expr {(([lindex $cid 13]&0xf)<<8)|[lindex $cid 14]}]
puts [format "SD CID: [sd_stat $st] mid=0x%02x oid=%s pnm=%s rev=%d.%d psn=0x%08x date=%d-%02d" \
        [lindex $cid 0] $oid $pnm [expr {[lindex $cid 8]>>4}] \
        [expr {[lindex $cid 8]&0xf}] $psn [expr {2000+($mdt>>4)}] [expr {$mdt&0xf}]]

set st [sd_op 3]
set csd [sd_bytes 16]
set csdv [expr {[lindex $csd 0] >> 6}]
if {$csdv == 1} {
  set csize [expr {(([lindex $csd 7]&0x3f)<<16)|([lindex $csd 8]<<8)|[lindex $csd 9]}]
  set nblk [expr {($csize+1)*1024}]
} else {
  set rbl [expr {[lindex $csd 5] & 0xf}]
  set csize [expr {(([lindex $csd 6]&0x3)<<10)|([lindex $csd 7]<<2)|([lindex $csd 8]>>6)}]
  set mult [expr {(([lindex $csd 9]&0x3)<<1)|([lindex $csd 10]>>7)}]
  set nblk [expr {($csize+1)*(1<<($mult+2))*(1<<$rbl)/512}]
}
puts [format "SD CSD: [sd_stat $st] csd_v%d blocks=%d (%.1f MiB) rp07_fits=%s" \
        [expr {$csdv+1}] $nblk [expr {$nblk/2048.}] \
        [expr {$nblk >= 1008000 ? "yes" : "NO"}]]

foreach lba {0 1} {
  set st [sd_read $lba]
  set b [sd_bytes 512]
  set line ""
  for {set i 0} {$i < 16} {incr i 2} {
    append line [format " %06o" [expr {[lindex $b $i] | ([lindex $b [expr {$i+1}]]<<8)}]]
  }
  set nz 0
  foreach x $b {if {$x != 0} {incr nz}}
  puts "SD LBA $lba: [sd_stat $st] words0-7:$line nonzero_bytes=$nz"
}

if {$nblk >= 1008000} {
  set st [sd_read 1007999]
  puts "SD LBA 1007999 (last RP07 block): [sd_stat $st]"
}

# repeat reads of LBA 0 and compare
set st [sd_read 0]
set ref [sd_bytes 512]
set bad 0
for {set i 0} {$i < 20} {incr i} {
  set st [sd_read 0]
  if {($st >> 8) != 0 || [sd_bytes 512] ne $ref} {incr bad}
}
puts "SD repeat LBA 0 x20: mismatches/errors=$bad"
