#!/bin/sh
# 付録D「キットを入手する」
# 実行場所: Ubuntu の端末。キットを本文と同じコミット 9c7a47e に移してから写す。
# 表示されたコミットとハッシュを本文の値と比べ、すべて一致したら次へ進む
# （disk0.rk は一度でも起動すると値が変わるので、取得した直後に確かめる）。
# 初めて使う $HOME/v6-card を前提とする。kit や disk*.rk が既にあれば、
# 作業中のディスクを上書きしないよう止まる。
mkdir -p "$HOME/v6-card"
cd "$HOME/v6-card" || exit 1
for f in kit disk0.rk disk1.rk disk2.rk; do
  if [ -e "$f" ]; then
    echo "$HOME/v6-card/$f が既にある。別の名前に変えてからやり直す。" >&2
    exit 1
  fi
done
git clone https://github.com/retux/unix-v6-on-simh.git kit || exit 1
git -C kit checkout 9c7a47e || exit 1
git -C kit rev-parse HEAD
cp kit/disk0.rk kit/disk1.rk kit/disk2.rk .
sha256sum disk0.rk disk1.rk disk2.rk
