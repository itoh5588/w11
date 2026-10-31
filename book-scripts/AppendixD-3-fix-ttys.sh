#!/bin/sh
# 付録D「端末の設定を直す」
# 実行場所: Ubuntu の端末。SimH が起動したら、@ に unix、login: に root と答え、
# 本文に従って /etc/ttys を直す（任意で RK2 の空きリストも直す）。
# sync の後、Ctrl-E と quit で SimH を終えると、DC11 を外した v6.ini で
# もう一度起動する。login: から # まで進めば修正できている。
cd "$HOME/v6-card" || exit 1
cat > v6-fix.ini <<'EOF'
set cpu 11/40
set dci enabled
attach rk0 disk0.rk
attach rk1 disk1.rk
attach rk2 disk2.rk
dep sr 1
boot rk0
EOF
cat v6-fix.ini
pdp11 v6-fix.ini
sed '/^set dci enabled$/d' v6-fix.ini > v6.ini
cat v6.ini
pdp11 v6.ini
