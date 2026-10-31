#!/bin/sh
# 第4章「入力を取得する」
# 実行場所: Ubuntu の端末。最後に SimH が起動するので、以降は本文の
# 「RP07 の形と区画を設定する」「ルートを復元する」に従って入力する。
mkdir -p "$HOME/w11-media"
cd "$HOME/w11-media"
curl -fL -o 2.11BSD-481-simh-dist.tap \
  https://www.tuhs.org/Archive/Distributions/UCB/2BSD/2.11BSD-patch481/2.11BSD-481-simh-dist.tap
stat -c %s 2.11BSD-481-simh-dist.tap
sha256sum 2.11BSD-481-simh-dist.tap

cat > install.ini <<'EOF'
set cpu 11/70
set cpu 4M
set cpu fpp
set rp0 rp07
set tm disabled
set ts enabled
attach rp0 rp07-build.img
attach -r ts0 2.11BSD-481-simh-dist.tap
boot ts0
EOF
pdp11 install.ini
