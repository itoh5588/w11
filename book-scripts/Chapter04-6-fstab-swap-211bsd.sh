#!/bin/sh
# 第4章「区画とスワップの参照をそろえる」
# 実行場所: SimH 内で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# 最後の halt で 2.11BSD を停止する。
cat > /etc/fstab <<'EOF'
/dev/xp0a:/:rw:1:1
/dev/xp0b:none:sw:0:0
/dev/xp0c:/usr:rw:1:2
EOF
cd /dev
ls -l xp0b swap drum
rm swap drum
ln xp0b swap
ln xp0b drum
ls -l xp0b swap drum

cd /
umount /usr
sync
sync
halt
