#!/bin/sh
# 第2章「JTAG のケーブルドライバ」
# 実行場所: Ubuntu の端末
export XTWV_PATH="${XTWV_PATH:-$HOME/Xilinx/Vivado/2022.1}"
cd "$XTWV_PATH/data/xicom/cable_drivers/lin64/install_script/install_drivers"
ls -l install_drivers
sudo ./install_drivers
printf '基板の USB をつなぎ直してから Enter: '
read dummy
lsusb
