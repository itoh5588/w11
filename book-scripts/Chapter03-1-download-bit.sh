#!/bin/sh
# 第3章「配布 .bit を入手する」（Ubuntu）
# 実行場所: Ubuntu の端末。最後に OK と表示されればハッシュが一致している。
mkdir -p "$HOME/w11-bitstream"
cd "$HOME/w11-bitstream"
TAG=book-v1
BASE=https://github.com/itoh5588/w11/releases/download/$TAG
curl -fLO "$BASE/sys_w11a_sa_as7.bit"
curl -fLO "$BASE/sys_w11a_sa_as7.bit.sha256"
sha256sum -c sys_w11a_sa_as7.bit.sha256
