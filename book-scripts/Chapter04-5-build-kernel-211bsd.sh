#!/bin/sh
# 第4章「FPSIM 入りのカーネルを作る」
# 実行場所: SimH 内で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# grep の三行が PDP11 70、IDENT W11TAPE、FPSIM YES になっていることを確かめてから先へ進む。
cd /usr/src/sys/conf
sed -e '/^PDP11/s/.*/PDP11 70/' \
    -e '/^IDENT/s/.*/IDENT W11TAPE/' \
    -e '/^FPSIM/s/.*/FPSIM YES/' GENERIC > W11TAPE
grep '^PDP11' W11TAPE
grep '^IDENT' W11TAPE
grep '^FPSIM' W11TAPE
./config W11TAPE
cd /usr/src/sys/W11TAPE
make

cp /unix /unix.dist
cp unix /unix
ls -l /unix /unix.dist
dd if=/mdec/rp07uboot of=/dev/rxp0a bs=512 count=1
