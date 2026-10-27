#!/bin/sh
# 付録E「イメージを作る」
# 実行場所: Ubuntu の端末。211bsd_rl_root.dsk と 211bsd_rl_usr.dsk を置いた
# ディレクトリで実行する。ソースの場所が違う場合は W11 を設定してから実行する。
# Release book-v2 以降の .bit が必要（book-v1 ではカーネルが panic: swsiz で止まる。付録E）。
# 書込みは Chapter04-9-write-card.sh に IMAGE として 211bsd-rl-card-labeled.img を渡す。
W11=${W11:-$HOME/w11-standalone}
python3 "$W11/tools/oskit/pack_rl_sd.py" 211bsd-rl-card.img \
  --unit 0:RL02:211bsd_rl_root.dsk \
  --unit 1:RL02:211bsd_rl_usr.dsk
python3 "$W11/tools/oskit/sd_label.py" --type rl \
  --rl02-mask 0011 --present-mask 0011 \
  211bsd-rl-card.img 211bsd-rl-card-labeled.img
