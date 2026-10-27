#!/bin/sh
# 付録D「カード用のイメージにする」
# 実行場所: Ubuntu の端末。ソースの場所が違う場合は W11 を設定してから実行する。
# 書込みは Chapter04-9-write-card.sh に IMAGE を渡して行う。/dev/sdX は
# lsblk で確かめた実際の装置名に置き換える:
#   ./Chapter04-9-write-card.sh /dev/sdX $HOME/v6-card/v6_rk_card_labeled.img
cd "$HOME/v6-card"
W11=${W11:-$HOME/w11-standalone}
python3 "$W11/tools/oskit/u6ed_rk/pack_sd.py" \
  disk0.rk disk1.rk disk2.rk v6_rk_card.img
python3 "$W11/tools/oskit/sd_label.py" --type rk05 \
  v6_rk_card.img v6_rk_card_labeled.img
ls -l v6_rk_card_labeled.img
