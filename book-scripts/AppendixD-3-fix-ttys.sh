#!/bin/sh
# 付録D「端末の設定を直す」
# 実行場所: Ubuntu の端末。SimH が起動したら、@ に unix、login: に root と答え、
# 本文に従って /etc/ttys を直す（任意で RK2 の空きリストも直す）。
cd "$HOME/v6-card"
cat > v6-fix.ini <<'EOF'
set cpu 11/40
set dci enabled
attach rk0 disk0.rk
attach rk1 disk1.rk
attach rk2 disk2.rk
dep sr 1
boot rk0
EOF
pdp11 v6-fix.ini
