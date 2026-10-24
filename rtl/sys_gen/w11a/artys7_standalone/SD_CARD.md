# RP07 の microSD カードを用意する

日本語 | [English](SD_CARD.en.md)

単体動作版の制御回路は、カードのセクタ 0 から始まる raw の RP07 ディスクを読みます。
FAT や exFAT の区画にあるファイルは読みません。必要なディスクイメージは、512 バイトの
セクタがちょうど 1,008,000 個（516,096,000 バイト）です。この容量以上の専用カードを
使ってください。カードの先頭 516,096,000 バイトは上書きされます。

単体動作版の回路データは RK05 と RL のカードも受け付け、ブロック 0 のカードラベルで
選びます（[ディスクを選ぶ](README.md#ディスクを選ぶ)を参照）。RP07 のカードには
**ラベルは要りません**。ラベルのないカードは、セクタ 0 からの RP07 ディスクとして
読まれます。このページでは、2.11BSD のイメージをその形で書きます。
`tools/oskit/sd_label.py --type rp07` で RP07 のイメージにラベルを付けると、ディスクの
データは LBA 2048 に移り、以下のサイズとハッシュはカードに当てはまらなくなります。

## 実機試験に使ったイメージ

試験したイメージ `rp07_w11_tape481_fpsim.img` は、TUHS が公開している 2.11BSD
パッチレベル 481 の配布テープから SimH で作りました。ほかのディスクイメージは
入力に使っていません。

```text
tape:   https://www.tuhs.org/Archive/Distributions/UCB/2BSD/2.11BSD-patch481/2.11BSD-481-simh-dist.tap
size:   89762312 bytes
SHA256: 314ca00f6e0fa8d60ad4cded15ac105f7f1a9f30d6d9e17a2a60a3e47748b821
```

作成の手順（SimH V3.8-1 の `pdp11`、`set cpu 11/70`、`set cpu 4M`、空の RP07 を `rp0`
に、テープを `ts0` に付け、`boot ts0`）：

1. スタンドアロンの `disklabel`（`ts(0,1)`）を `xp(0,0)` に対して実行し、RP07 の
   ラベルを書きます。50 セクタ、32 トラック、630 シリンダ、区画 `a` は 0 から
   32,000 セクタ（ルート）、`b` は 32,000 から 51,200（スワップ）、`c` は 83,200 から
   924,800（`/usr`）です。
2. スタンドアロンの `mkfs`（`ts(0,2)`）を `xp(0,0)` に対して実行し、続いて `restor`
   （`ts(0,3)`）で `ts(0,5)` から `xp(0,0)` へ復元します。
3. `xp(0,0)unix`（配布カーネル）を起動し、`newfs xp0c` を実行して `/usr` に
   マウントし、テープの `/usr` と `/usr/src` の tar ファイル（テープのファイル 6、7、8）を
   `tar xpbf 20 /dev/rmt12` で展開します。
4. `conf/GENERIC` を `PDP11 70`、`IDENT W11TAPE`、`FPSIM YES` にして `W11TAPE` に
   写し、`./config W11TAPE` と `make` を実行して、できたカーネルを `/unix` として
   置きます（配布カーネルは `/unix.dist` として残します）。
5. `/mdec/rp07uboot` を `/dev/rxp0a` の先頭ブロックに書き、`/etc/fstab` を `xp0a`（`/`）、
   `xp0b`（スワップ）、`xp0c`（`/usr`）にして、`/dev/swap` と `/dev/drum` を
   `/dev/xp0b` へリンクし直します（配布状態では `ra0b` へのリンクです）。
6. `sync; sync; halt` で正常に停止し、ファイルを RP07 の全容量まで 0 で伸ばします。

できたイメージは、SimH の `set cpu nofpp` でも、この w11 の構成でもマルチユーザーの
`login:` まで起動します。浮動小数点のプログラムは FPSIM で動きます。

```text
image:   rp07_w11_tape481_fpsim.img
size:    516096000 bytes
SHA256:  065e68f8a66da71e2cc0092a2c2342a6162e388264e6d603e33bbad19057dc08
archive: rp07_w11_tape481_fpsim.img.xz, 20639532 bytes
SHA256:  fd3860d977d0f6b7073806e00b6bc288676ae12eca84f03924e2779e915b745c
```

上の圧縮イメージは [Release book-v1](https://github.com/itoh5588/w11/releases/tag/book-v1)
に添付しています。上の手順で作り直したイメージも動きますが、時刻などが違うので
ハッシュは同じになりません。圧縮イメージを使う場合は `xz -dk` で展開し、カードに書く前に
raw イメージのハッシュを確かめてください。公開元の `211bsd_rp` oskit の RP06 イメージを
RP07 のイメージとして使わないでください。

## カードリーダーを特定する

以下のコマンドは Linux または WSL 2 で実行します。Windows の WSL 2 では、Arty S7 の
USB/JTAG ではなく **USB カードリーダー**を WSL につなぎます。管理者の PowerShell で
リーダーの現在のバス ID を調べ、共有します。

```powershell
usbipd list
usbipd bind --busid <READER-BUSID>
```

WSL の端末を開いた状態で、通常の PowerShell からリーダーを WSL につなぎます。

```powershell
usbipd attach --wsl --busid <READER-BUSID>
```

WSL で専用カードを挿し、その**ディスク全体**を特定します。`/dev/sdX` は例の名前で、
装置をつなぐたびに変わることがあります。型番、接続方式、容量を見比べてから選びます。

```sh
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINTS
```

`device` には、確認したディスク全体（TYPE が `disk`）を設定します。`/dev/sdX1` のような
区画ではありません。その区画がどれもマウントされていないことを確かめ、マウントされて
いれば一つずつ解除してから進みます。前回の作業で同じ名前だったというだけで選ばないで
ください。

## 保存、書込み、照合

以下のコマンドは、装置とイメージのパスを書き換えて WSL/Linux のシェルで実行する
ひな形です。`lsblk` の表示を見て、装置が取り外せるカードであることを確かめてから、
書込みをするコマンドを実行します。二つのブロックは同じシェルで実行してください。
検査に失敗するとシェルが止まります。保存のコマンドは、カードの先頭の RP07 の大きさの
範囲だけを読みます。

```sh
set -euo pipefail
device=/dev/sdX
image=/path/to/rp07_w11_tape481_fpsim.img
expected=065e68f8a66da71e2cc0092a2c2342a6162e388264e6d603e33bbad19057dc08

test -b "$device"
test "$(lsblk -dn -o TYPE "$device")" = disk
test "$(lsblk -dn -o TRAN "$device")" = usb
test -z "$(lsblk -nrpo MOUNTPOINTS "$device" | tr -d '[:space:]')"
test "$(sudo blockdev --getsize64 "$device")" -ge 516096000
test "$(stat -c %s "$image")" -eq 516096000
printf '%s  %s\n' "$expected" "$image" | sha256sum -c -
lsblk -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE,MOUNTPOINTS "$device"
```

型番や容量が想定と違う、区画がマウントされている、必要なデータがカードにある、の
いずれかならここで止めます。カード以外の場所に保存してから、イメージを書きます。
保存したファイルは、先頭 516,096,000 バイトを元に戻すための控えにもなります。

```sh
sudo dd if="$device" of=card-before-rp07.img bs=512 count=1008000 iflag=fullblock status=progress
test "$(stat -c %s card-before-rp07.img)" -eq 516096000
sha256sum card-before-rp07.img
sudo dd if="$image" of="$device" bs=4M iflag=fullblock conv=fsync status=progress
sudo blockdev --flushbufs "$device"
sudo dd if="$device" bs=512 count=1008000 iflag=fullblock status=none | sha256sum
```

最後のハッシュは `expected` と一致しなければなりません。読戻しのハッシュが違う場合は
そのカードから起動せず、リーダー、カード、装置の選択を調べます。カードを抜く前に
リーダーを安全に切り離します。Windows では `usbipd detach --busid <READER-BUSID>` を
実行し、この作業のためだけに共有した場合は、管理者の PowerShell で
`usbipd unbind --busid <READER-BUSID>` を実行します。最後に `usbipd list` で確認します。

2026-10-04 に、上のイメージを同じ方法（WSL 2 から USB カードリーダー経由で `dd`、
`conv=fsync`、その後に先頭 516,096,000 バイトを読戻し）で書きました。読戻しのハッシュは
一致し、カードは基板で起動しました。このときは `bs=1M` を使い、保存の手順は省きました。
新しいカードでは毎回、読戻しの確認をしてください。

確認したカードを JD の Pmod MicroSD に挿したら、
[単体動作版の起動手順](README.md#os-の媒体と起動)に従います。2026-10-13 には、同じ
ラベルなしのカードがラベル選択版の回路データでもマルチユーザーの `login:` まで
起動しました。
