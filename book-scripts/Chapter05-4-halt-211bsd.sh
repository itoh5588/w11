#!/bin/sh
# 第5章「起動して login: まで進む」（状態の確認と正常停止）
# 実行場所: 基板で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# 端末に halting と表示されてから電源を切る。
df
ps -ax
sync
sync
halt
