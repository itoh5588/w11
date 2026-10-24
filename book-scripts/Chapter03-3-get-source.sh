#!/bin/sh
# 第3章「ソースを固定した版で入手する」
# 実行場所: Ubuntu の端末。$HOME/w11-standalone に取得する（付録D・E もこの場所を前提にする）。
# export はこのスクリプトの中だけで有効なので、続けて手で操作する場合は
#   . ./Chapter03-3-get-source.sh
# のように読み込むか、第3章の export を端末で打ち直す。
cd "$HOME"
git clone https://github.com/itoh5588/w11.git w11-standalone
cd w11-standalone
git checkout --detach d6b5022b412a79ec205ed1d1932fd839bdaf4c85
git rev-parse HEAD

export RETROBASE="$PWD"
export PATH="$RETROBASE/tools/bin:.:$PATH"
export LD_LIBRARY_PATH="$RETROBASE/tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XTWV_PATH="${XTWV_PATH:-$HOME/Xilinx/Vivado/2022.1}"
test -f "$XTWV_PATH/settings64.sh"
echo $?
xtwv vivado -version

test -f "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone/sys_w11a_sa_as7.vhd"
echo $?
test -f "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone/ibdr_rp07n.vhd"
echo $?
test -f "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone/ibd_dl11n.vhd"
echo $?
test -f "$RETROBASE/rtl/sys_gen/w11a/artys7_standalone/w11_autostart.vhd"
echo $?
