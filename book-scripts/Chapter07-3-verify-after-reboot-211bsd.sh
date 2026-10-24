#!/bin/sh
# 第7章「正常停止して起動し直す」（再起動後の比較）
# 実行場所: 基板で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# sum と ls -l の表示を、保存した直後の記録と比べる。
cmp /unix /book-test/unix.copy
echo $?
cmp /usr/book-test/big /usr/book-test/big.copy
echo $?
sum /book-test/unix.copy /usr/book-test/big /usr/book-test/big.copy
ls -l /book-test/unix.copy /usr/book-test/big /usr/book-test/big.copy
