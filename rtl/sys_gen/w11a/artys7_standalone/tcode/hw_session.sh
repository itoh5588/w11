#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run one console session on the Arty S7: free the console port (tcp 8000),
# start ti_w11 with a boot script, drive <name>.cmd with hw_drive.py and log
# to <name>.log in ACCDIR (default: current directory).
#   hw_session.sh <name> [secs] [bootscript]     (EXTRA= extra ti_w11 args)
T=$(cd "$(dirname "$0")" && pwd)
name=$1; secs=${2:-220}; boot=${3:-rp07_boot.tcl}
cd ${ACCDIR:-$PWD}
freeport() {           # stop whoever holds the console port, wait until free
  for i in $(seq 1 20); do
    pids=$(ss -ltnpH 'sport = :8000' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2)
    [ -z "$pids" ] && return
    kill $pids 2>/dev/null
    sleep 1
  done
}
freeport
export RETROBASE=${RETROBASE:-$(cd $T/../../../../.. && pwd)}
export PATH=$RETROBASE/tools/bin:.:$PATH LD_LIBRARY_PATH=$RETROBASE/tools/lib
(timeout $((secs+10)) ti_w11 -tuD,12M,break,xon -b "set boot_secs $secs" $EXTRA @$T/$boot > ti$name.out 2>&1 &)
sleep 4
timeout $((secs-5)) python3 $T/hw_drive.py $name.log $name.cmd
freeport
