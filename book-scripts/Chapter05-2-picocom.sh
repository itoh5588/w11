#!/bin/sh
# 第5章「Ubuntu で端末を開く場合」（端末を開く）
# 実行場所: Ubuntu の端末
# 使い方: ./Chapter05-2-picocom.sh /dev/serial/by-id/確認したUSB-UART変換器の名前
# 終了は Ctrl-A Ctrl-X。
if [ $# -ne 1 ]; then
  echo "使い方: $0 /dev/serial/by-id/確認したUSB-UART変換器の名前" >&2
  ls -l /dev/serial/by-id/ >&2
  exit 1
fi
CONSOLE=$1
picocom --baud 9600 --databits 8 --parity n --stopbits 1 \
  --flow n "$CONSOLE"
