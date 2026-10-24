#!/bin/sh
# 第2章「Vivado 2022.1 を導入する」
# 実行場所: Ubuntu の端末。Vivado の導入先が違う場合は XTWV_PATH を設定してから実行する。
export XTWV_PATH="${XTWV_PATH:-$HOME/Xilinx/Vivado/2022.1}"
test -f "$XTWV_PATH/settings64.sh"
echo $?
"$XTWV_PATH/bin/vivado" -version
