#!/bin/sh
# 第4章「/usr とソースを復元する」
# 実行場所: SimH 内で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# 一行ずつ入力するか、端末に貼り付けて使う。
cd /dev
./MAKEDEV xp0
./MAKEDEV ts0
newfs xp0c
mount /dev/xp0c /usr
cd /usr
mt -f /dev/rmt12 rew
mt -f /dev/rmt12 fsf 6
tar xpbf 20 /dev/rmt12

mkdir -p /usr/src
cd /usr/src
mt -f /dev/rmt12 rew
mt -f /dev/rmt12 fsf 7
tar xpbf 20 /dev/rmt12
mt -f /dev/rmt12 rew
mt -f /dev/rmt12 fsf 8
tar xpbf 20 /dev/rmt12
ls /usr/src/sys/conf/GENERIC
chmod 755 /usr /usr/src /usr/src/sys
