#!/bin/sh
# 第4章「FP11 なし、テープなしで確認する」
# 実行場所: Ubuntu の端末。SimH が起動したら、ログイン後の 2.11BSD で
# Chapter04-7-fp-check-211bsd.sh の一行を入力する。
cd "$HOME/w11-media"
cat > verify.ini <<'EOF'
set cpu 11/70
set cpu 4M
set cpu nofpp
set rp0 rp07
attach rp0 rp07-build.img
boot rp0
EOF
pdp11 verify.ini
