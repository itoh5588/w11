#!/bin/sh
# 第5章「Ubuntu で端末を開く場合」（端末の記録を残す）
# 実行場所: Ubuntu の端末。記録の中で Chapter05-2-picocom.sh を実行し、
# 終わったら exit で記録を閉じる。
mkdir -p "$HOME/w11-records"
script -q -f "$HOME/w11-records/console-session.txt"
