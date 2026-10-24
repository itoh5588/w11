#!/bin/sh
# 第5章「Ubuntu で端末を開く場合」（装置名と権限の確認）
# 実行場所: Ubuntu の端末
# id -nG に dialout がなければ、次の行の # を外して一度だけ実行し、
# ログインし直してから再度確かめる。
# sudo usermod -aG dialout "$USER"
ls -l /dev/serial/by-id/
id -nG
