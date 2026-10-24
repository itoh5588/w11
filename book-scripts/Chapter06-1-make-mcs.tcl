# 第6章「MCS ファイルを作る」
# 実行場所: Vivado（Lab Edition でもよい）の Tcl Console。
#   source <このファイルのパス>
# で読み込む。$HOME/w11-bitstream の .bit から同じ場所に .mcs を作る。
set book_build [file normalize [file join $env(HOME) w11-bitstream]]
set book_bit [file join $book_build sys_w11a_sa_as7.bit]
set book_mcs [file join $book_build sys_w11a_sa_as7.mcs]
write_cfgmem -format mcs -size 16 -interface SPIx1 \
  -loadbit "up 0x0 $book_bit" -file $book_mcs
