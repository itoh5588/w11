#!/bin/sh
# 第4章「FP11 なし、テープなしで確認する」
# 実行場所: SimH（nofpp）内で動く 2.11BSD の # プロンプト。ホストでは実行しない。
awk 'BEGIN{x=1/3; printf "fp %.6f %.6f %g\n", x, sqrt(2), exp(1)}' </dev/null
