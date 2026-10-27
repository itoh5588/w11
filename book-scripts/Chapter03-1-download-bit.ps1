# 第3章「配布 .bit を入手する」（Windows）
# 実行場所: PowerShell。最後に True と表示されればハッシュが一致している。
mkdir "$HOME\w11-bitstream"
cd "$HOME\w11-bitstream"
$BASE = "https://github.com/itoh5588/w11/releases/download/book-v2"
curl.exe -fLO "$BASE/sys_w11a_sa_as7.bit"
curl.exe -fLO "$BASE/sys_w11a_sa_as7.bit.sha256"
$want = (Get-Content sys_w11a_sa_as7.bit.sha256).Split(" ")[0]
(Get-FileHash sys_w11a_sa_as7.bit).Hash -eq $want
