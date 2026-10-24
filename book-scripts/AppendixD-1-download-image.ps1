# 付録D「配布イメージを書く」
# 実行場所: PowerShell。最後に True と表示されればハッシュが一致している。
# カードへの書込みは第4章と同じく balenaEtcher で行う。
mkdir "$HOME\v6-card"
cd "$HOME\v6-card"
$BASE = "https://github.com/itoh5588/w11/releases/download/book-v1"
curl.exe -fLO "$BASE/v6_rk_card_labeled.img.xz"
curl.exe -fLO "$BASE/v6_rk_card_labeled.img.xz.sha256"
curl.exe -fLO "$BASE/CALDERA-LICENSE.txt"
$want = (Get-Content v6_rk_card_labeled.img.xz.sha256).Split(" ")[0]
(Get-FileHash v6_rk_card_labeled.img.xz).Hash -eq $want
