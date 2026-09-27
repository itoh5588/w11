# SPDX-License-Identifier: GPL-3.0-or-later
#
# GRESET (rbus init) while the DMA ping-pong test runs on sys_w11a_dma_as7:
#   ti_w11 -tuD,12M,break,xon @dma_pingpong_greset.tcl
# GRESET stops the CPU but must not abort a DMA transfer or drop a cache
# invalidation.  After each GRESET the CPU restarts at 'loop' with the last
# acknowledged seq, re-checks the buffer through its cache and goes on.

if {![info exists pp_nreset]} {set pp_nreset 200}
set ppdir [file join $::env(RETROBASE) rtl sys_gen w11a artys7_standalone tcode]

rlc exec -wreg 0xfd00 0x0002
cpu0 ldasm -file [file join $ppdir dma_pingpong.mac] -sym pp
rw11::asmrun cpu0 pp
after 50
rlc exec -wreg 0xfd00 0x0001

set total 0
set last 0
set nstall 0
set nrun 0
for {set i 0} {$i < $pp_nreset} {incr i} {
  after [expr {int(rand() * 20)}]
  rlc exec -init 0x0000 0x0001;         # GRESET
  cpu0 cp -rstat cstat
  cpu0 cp -wal 0102000 -rmi mseq -rmi mack -rmi merrc
  if {$cstat & 0x10} {incr nrun};      # cpugo after GRESET
  rw11::asmrun cpu0 pp pc $pp(loop) r4 $mack r5 $merrc
  after 5
  rlc exec -rreg 0xfd02 iter
  set d [expr {($iter - $last) & 0xffff}]
  set last $iter
  incr total $d
  if {$d == 0} {
    after 50
    rlc exec -rreg 0xfd02 iter
    set d [expr {($iter - $last) & 0xffff}]
    set last $iter
    incr total $d
    if {$d == 0} {incr nstall}
  }
}

rlc exec -wreg 0xfd00 0x0000
after 100
rlc exec -rreg 0xfd01 stat -rreg 0xfd03 err -rreg 0xfd02 iter
incr total [expr {($iter - $last) & 0xffff}]
cpu0 cp -stop
cpu0 cp -wal 0102000 -rmi mseq -rmi mack -rmi merrc
puts [format "GRESET resets=%d stillrun=%d iter=%d err=%d cpuerr=%d stalls=%d mem_seq=%d mem_ack=%d stat=0x%02x" \
        $pp_nreset $nrun $total $err $merrc $nstall $mseq $mack $stat]
if {$nrun == 0 && $err == 0 && $merrc == 0 && $nstall == 0 && $mseq == $mack} {
  puts "GRESET-I: PASS"
} else {
  puts "GRESET-E: FAIL"
}
