#!/bin/sh
# 第7章「まず区画と空きを確認する」「二つの区画へ保存する」
# 実行場所: 基板で動く 2.11BSD の # プロンプト。ホストでは実行しない。
# 二つの echo $? が 0 なら一致。sum と ls -l の表示は再起動後の比較のため記録する。
df

mkdir /book-test
mkdir /usr/book-test
cp /unix /book-test/unix.copy
cat /unix /unix /unix > /usr/book-test/big
cp /usr/book-test/big /usr/book-test/big.copy
cmp /unix /book-test/unix.copy
echo $?
cmp /usr/book-test/big /usr/book-test/big.copy
echo $?
sum /book-test/unix.copy /usr/book-test/big /usr/book-test/big.copy
ls -l /book-test/unix.copy /usr/book-test/big /usr/book-test/big.copy
