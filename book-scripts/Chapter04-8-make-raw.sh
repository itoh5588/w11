#!/bin/sh
# 第4章「カード用の raw ファイルにする」
# 実行場所: Ubuntu の端末
cd "$HOME/w11-media"
cp rp07-build.img rp07_w11_tape481_fpsim.img
IMAGE="$HOME/w11-media/rp07_w11_tape481_fpsim.img"
stat -c %s "$IMAGE"

truncate -s 516096000 "$IMAGE"
stat -c %s "$IMAGE"
sha256sum "$IMAGE"
