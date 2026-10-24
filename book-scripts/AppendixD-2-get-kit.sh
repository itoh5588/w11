#!/bin/sh
# 付録D「キットを入手する」
# 実行場所: Ubuntu の端末。表示されたハッシュを本文の値と比べる
# （disk0.rk は一度でも起動すると値が変わるので、取得した直後に確かめる）。
mkdir -p "$HOME/v6-card"
cd "$HOME/v6-card"
git clone https://github.com/retux/unix-v6-on-simh.git kit
cp kit/disk0.rk kit/disk1.rk kit/disk2.rk .
sha256sum disk0.rk disk1.rk disk2.rk
