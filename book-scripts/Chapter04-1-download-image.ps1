# 第4章「配布イメージを入手する」
# 実行場所: PowerShell。最後に True と表示されればハッシュが一致している。
mkdir "$HOME\w11-media"
cd "$HOME\w11-media"
$BASE = "https://github.com/itoh5588/w11/releases/download/book-v1"
curl.exe -fLO "$BASE/rp07_w11_tape481_fpsim.img.xz"
curl.exe -fLO "$BASE/rp07_w11_tape481_fpsim.img.xz.sha256"
$want = (Get-Content rp07_w11_tape481_fpsim.img.xz.sha256).Split(" ")[0]
(Get-FileHash rp07_w11_tape481_fpsim.img.xz).Hash -eq $want
