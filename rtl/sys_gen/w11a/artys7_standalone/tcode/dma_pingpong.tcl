# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hardware ping-pong coherence test for sys_w11a_dma_as7:
#   ti_w11 -tuD,12M,break,xon @dma_pingpong.tcl
# Runs for pp_secs seconds (default 20), then prints a PINGPONG summary.

if {![info exists pp_secs]} {set pp_secs 20}
set ppbase 0xfd00
set ppdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]

proc pp_regs {} {
  rlc exec -rreg 0xfd01 stat -rreg 0xfd02 iter -rreg 0xfd03 err \
           -rreg 0xfd04 seq
  return [list $stat $iter $err $seq]
}

rlc exec -wreg $ppbase 0x0002;          # stopped, counters cleared
cpu0 ldasm -file [file join $ppdir dma_pingpong.mac] -sym pp
rw11::asmrun cpu0 pp
after 100
rlc exec -wreg $ppbase 0x0001;          # run

# the iteration counter is 16 bit; sample it at least every 2 s (well
# below 65536 iterations) and accumulate the differences
set t0 [clock milliseconds]
set last 0
set total 0
proc pp_count {iter} {
  global last total
  incr total [expr {($iter - $last) & 0xffff}]
  set last $iter
}
while {[clock milliseconds] - $t0 < $pp_secs * 1000} {
  after 2000
  lassign [pp_regs] stat iter err seq
  pp_count $iter
  cpu0 cp -rr5 cpuerr
  puts [format "t=%5.1fs iter=%7d seq=%5d err=%d cpuerr=%d stat=0x%02x" \
          [expr {([clock milliseconds] - $t0) / 1000.}] $total $seq $err \
          $cpuerr $stat]
}

rlc exec -wreg $ppbase 0x0000;          # stop after current iteration
set t1 [clock milliseconds]
while {1} {
  lassign [pp_regs] stat iter err seq
  pp_count $iter
  if {($stat & 0x1) == 0} break
  if {[clock milliseconds] - $t1 > 5000} {
    puts "PINGPONG-E: exerciser did not reach idle, stat=[format 0x%02x $stat]"
    break
  }
  after 10
}
cpu0 cp -stop
cpu0 cp -rr4 cpuseq -rr5 cpuerr
cpu0 cp -wal 0102000 -rmi mseq -rmi mack -rmi merrc
rlc exec -rreg 0xfd05 eadr -rreg 0xfd06 edlo -rreg 0xfd07 edhi \
         -rreg 0xfd08 wlat -rreg 0xfd09 rlat
set secs [expr {([clock milliseconds] - $t0) / 1000.}]
puts [format "PINGPONG iter=%d err=%d cpuerr=%d cpu_seq=%d mem_seq=%d mem_ack=%d mem_errc=%d time=%.1fs rate=%.1f/s" \
        $total $err $cpuerr $cpuseq $mseq $mack $merrc $secs \
        [expr {$total / $secs}]]
puts [format "PINGPONG max DMA latency: write %d read %d cycles" $wlat $rlat]
if {$err != 0} {
  puts [format "PINGPONG last error: word 0x%04x data 0x%04x%04x" \
          $eadr $edhi $edlo]
}
if {$total > 0 && $err == 0 && $cpuerr == 0 && $mseq == $mack} {
  puts "PINGPONG-I: PASS"
} else {
  puts "PINGPONG-E: FAIL"
}
