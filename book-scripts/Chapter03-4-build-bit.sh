#!/bin/sh
# 第3章「回路データを作る」「タイミング結果を確かめて置き場所へ写す」
# 実行場所: Ubuntu の端末。ソースの場所が違う場合は RETROBASE を設定してから実行する。
# タイミング結果（sys_w11a_sa_as7_rou_tim.rpt）の確認は本文に従って行う。
export RETROBASE="${RETROBASE:-$HOME/w11-standalone}"
export PATH="$RETROBASE/tools/bin:.:$PATH"
export LD_LIBRARY_PATH="$RETROBASE/tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XTWV_PATH="${XTWV_PATH:-$HOME/Xilinx/Vivado/2022.1}"

cd "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone"
make sys_w11a_sa_as7.bit
echo $?
ls -l sys_w11a_sa_as7.bit sys_w11a_sa_as7_rou_tim.rpt

git rev-parse HEAD
sha256sum sys_w11a_sa_as7.bit
mkdir -p "$HOME/w11-bitstream"
cp sys_w11a_sa_as7.bit "$HOME/w11-bitstream/"
