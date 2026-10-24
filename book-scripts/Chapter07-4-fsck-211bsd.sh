#!/bin/sh
# 第7章「起動時の検査を読む」
# 実行場所: 基板で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# -n なので修復はせず、検査結果だけを表示する。
fsck -n -t /tmp/f1.tmp /dev/rxp0c
fsck -n -t /tmp/f2.tmp /dev/rxp0a
