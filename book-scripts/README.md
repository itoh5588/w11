# 本書のコマンド集

日本語 | [English](README.en.md)

本文のコマンドを、節ごとに一つのファイルへ切り出したものである。ファイル名は
`章-節の順番-内容` で、本文の章と節に対応する。コマンドは本文と同じで、
次の点だけを加えている。

- 装置名（`CARD`、`CONSOLE`）は書き換えずに引数で渡す。`/dev/sdX` のままでは動かない。
- カードへ書く `Chapter04-9-write-card.sh` は、マウント中の区画、既存のバックアップ、
  容量不足のときに止まり、`yes` と入力するまで書き込まない。
- `XTWV_PATH`、`RETROBASE`、`W11` は、設定済みならその値を使う。

## 実行する場所

| 末尾 | 実行する場所 |
| --- | --- |
| `.ps1` | Windows の PowerShell |
| `.sh` | Ubuntu の端末 |
| `-211bsd.sh` | 2.11BSD の `#` プロンプト。ホストでは実行せず、一行ずつ入力するか貼り付ける |
| `.tcl` | Vivado の Tcl Console で `source` する |

PowerShell でスクリプトの実行が止められている場合は、次のように実行する。

```powershell
powershell -ExecutionPolicy Bypass -File .\Chapter03-1-download-bit.ps1
```

## 一覧

| ファイル | 章・節 |
| --- | --- |
| `Chapter02-1-ubuntu-tools.sh` | 第2章 Ubuntu の道具を入れる |
| `Chapter02-2-vivado-check.sh` | 第2章 Vivado 2022.1 を導入する |
| `Chapter02-3-jtag-driver.sh` | 第2章 JTAG のケーブルドライバ |
| `Chapter03-1-download-bit.ps1` | 第3章 配布 `.bit` を入手する（Windows） |
| `Chapter03-1-download-bit.sh` | 第3章 配布 `.bit` を入手する（Ubuntu） |
| `Chapter03-2-build-tools.sh` | 第3章 ビルドに使う道具を追加する |
| `Chapter03-3-get-source.sh` | 第3章 ソースを固定した版で入手する |
| `Chapter03-4-build-bit.sh` | 第3章 回路データを作る／タイミング結果を確かめて置き場所へ写す |
| `Chapter04-1-download-image.ps1` | 第4章 配布イメージを入手する |
| `Chapter04-2-install-etcher.ps1` | 第4章 balenaEtcher でカードに書く |
| `Chapter04-3-get-tape.sh` | 第4章 入力を取得する |
| `Chapter04-4-restore-usr-src-211bsd.sh` | 第4章 /usr とソースを復元する |
| `Chapter04-5-build-kernel-211bsd.sh` | 第4章 FPSIM 入りのカーネルを作る |
| `Chapter04-6-fstab-swap-211bsd.sh` | 第4章 区画とスワップの参照をそろえる |
| `Chapter04-7-verify-nofpp.sh` | 第4章 FP11 なし、テープなしで確認する（SimH の起動） |
| `Chapter04-7-fp-check-211bsd.sh` | 第4章 FP11 なし、テープなしで確認する（浮動小数点の確認） |
| `Chapter04-8-make-raw.sh` | 第4章 カード用の raw ファイルにする |
| `Chapter04-9-write-card.sh` | 第4章 書込み先のカードを特定する／保存、書込み、読戻し |
| `Chapter05-1-serial-check.sh` | 第5章 Ubuntu で端末を開く場合（装置名と権限） |
| `Chapter05-2-picocom.sh` | 第5章 Ubuntu で端末を開く場合（端末を開く） |
| `Chapter05-3-record-session.sh` | 第5章 Ubuntu で端末を開く場合（記録を残す） |
| `Chapter05-4-halt-211bsd.sh` | 第5章 起動して `login:` まで進む（確認と正常停止） |
| `Chapter06-1-make-mcs.tcl` | 第6章 MCS ファイルを作る |
| `Chapter07-1-save-files-211bsd.sh` | 第7章 まず区画と空きを確認する／二つの区画へ保存する |
| `Chapter07-2-halt-211bsd.sh` | 第7章 正常停止して起動し直す（停止） |
| `Chapter07-3-verify-after-reboot-211bsd.sh` | 第7章 正常停止して起動し直す（再起動後の比較） |
| `Chapter07-4-fsck-211bsd.sh` | 第7章 起動時の検査を読む |
| `AppendixD-1-download-image.ps1` | 付録D 配布イメージを書く |
| `AppendixD-2-get-kit.sh` | 付録D キットを入手する |
| `AppendixD-3-fix-ttys.sh` | 付録D 端末の設定を直す |
| `AppendixD-4-make-card-image.sh` | 付録D カード用のイメージにする |
| `AppendixE-1-make-card-image.sh` | 付録E イメージを作る |

付録Dのカードは、イメージを二つ目の引数で渡して書く。次の `/dev/sdX` は例の名前で、
そのままでは拒否される。第4章の手順で `lsblk` を使って確かめた実際の装置名
（例: `/dev/sdb`）に置き換える。

```sh
./Chapter04-9-write-card.sh /dev/sdX $HOME/v6-card/v6_rk_card_labeled.img
```

disklabel やブートの `:` での入力（第4章）、V6 の `ed` による編集（付録D）、
第8章の操作例は対話なので、スクリプトにしていない。本文に従って入力する。
