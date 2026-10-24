#!/bin/sh
# 第4章「書込み先のカードを特定する」「保存、書込み、読戻し」
# 実行場所: Ubuntu の端末
#
# 使い方:
#   ./Chapter04-9-write-card.sh               … カードの一覧を表示するだけ
#   ./Chapter04-9-write-card.sh /dev/sdX [IMAGE]
#
# CARD を間違えると、そのディスクの内容が失われる。本文の手順でカードを
# 特定してから実行する。IMAGE を省略すると第4章のイメージを書く。
# 付録D の V6 カードは IMAGE に $HOME/v6-card/v6_rk_card_labeled.img を指定する。
if [ $# -eq 0 ]; then
  lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINTS
  exit 0
fi

CARD=$1
IMAGE=${2:-$HOME/w11-media/rp07_w11_tape481_fpsim.img}
if [ "$CARD" = /dev/sdX ]; then
  echo "/dev/sdX は例の名前である。lsblk で確かめた実際の名前を指定する。" >&2
  exit 1
fi
if [ ! -b "$CARD" ] || [ ! -f "$IMAGE" ]; then
  echo "カード $CARD またはイメージ $IMAGE が見つからない。" >&2
  exit 1
fi

lsblk -o NAME,PATH,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS "$CARD"
if lsblk -nro MOUNTPOINTS "$CARD" | grep -q .; then
  echo "マウント中の区画がある。sudo umount /dev/sdX1 のように外してから実行する。" >&2
  exit 1
fi
printf '%s に %s を書く。よければ yes と入力: ' "$CARD" "$IMAGE"
read ans
[ "$ans" = yes ] || exit 1

# 保存。失敗したらここで止める。既存のバックアップは上書きしない。
if [ -e card-before.img ]; then
  echo "card-before.img が既にある。別の場所で実行するか名前を変える。" >&2
  exit 1
fi
sudo dd if="$CARD" of=card-before.img bs=4M iflag=fullblock \
  conv=fsync status=progress || exit 1
sudo blockdev --getsize64 "$CARD"
stat -c %s card-before.img
sha256sum card-before.img
[ "$(sudo blockdev --getsize64 "$CARD")" -eq "$(stat -c %s card-before.img)" ] || {
  echo "カード容量と保存ファイルの大きさが合わない。" >&2; exit 1; }

# 容量の確認
sudo blockdev --getsize64 "$CARD"
stat -c %s "$IMAGE"
[ "$(sudo blockdev --getsize64 "$CARD")" -ge "$(stat -c %s "$IMAGE")" ] || {
  echo "カードがイメージより小さい。" >&2; exit 1; }

# 書込みと読戻し。echo $? が 0 なら一致、1 なら不一致、2 なら実行上のエラー。
sudo dd if="$IMAGE" of="$CARD" bs=4M iflag=fullblock \
  conv=fsync status=progress || exit 1
sudo blockdev --flushbufs "$CARD"
sudo cmp -n "$(stat -c %s "$IMAGE")" "$IMAGE" "$CARD"
echo $?
