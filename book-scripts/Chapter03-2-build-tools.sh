#!/bin/sh
# 第3章「ビルドに使う道具を追加する」
# 実行場所: Ubuntu の端末
sudo apt install git build-essential perl libusb-1.0-0-dev \
  tcl tcl-dev tcllib tclreadline
git --version
make --version
perl -v
