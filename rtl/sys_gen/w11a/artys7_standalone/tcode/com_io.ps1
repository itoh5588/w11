# Serial console helper: open a COM port, send timed input, log the output.
#   com_io.ps1 -Port COM5 -Baud 9600 -Secs 120 -Log out.txt -Script in.txt
# in.txt lines: "<seconds> <text>"; text is sent with CR; "\x04" style
# escapes are allowed; "<seconds> WAIT <regex>" waits for output instead.
param([string]$Port = "COM5", [int]$Baud = 9600, [int]$Secs = 60,
      [string]$Log = "com_out.txt", [string]$Script = "")
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 100
$sp.Open()
$out = New-Object System.Text.StringBuilder
$events = @()
if ($Script -ne "" -and (Test-Path $Script)) { $events = Get-Content $Script }
$t0 = Get-Date
$ei = 0
while (((Get-Date) - $t0).TotalSeconds -lt $Secs) {
  try { $s = $sp.ReadExisting(); if ($s) { [void]$out.Append($s) } } catch {}
  if ($ei -lt $events.Count) {
    $parts = $events[$ei] -split ' ', 2
    if (((Get-Date) - $t0).TotalSeconds -ge [double]$parts[0]) {
      $txt = [regex]::Unescape($parts[1])
      foreach ($ch in $txt.ToCharArray()) { $sp.Write([string]$ch); Start-Sleep -Milliseconds 20 }
      $sp.Write("`r")
      $ei++
    }
  }
  Start-Sleep -Milliseconds 50
}
$sp.Close()
[IO.File]::WriteAllText($Log, $out.ToString())
