# harmless probe used to check whether a launch path is blocked by security
# software before wiring it into a shortcut. Writes one marker file and exits.
$p = Join-Path $env:TEMP 'steamx-probe-ran.txt'
[IO.File]::WriteAllText($p, 'probe ok ' + (Get-Date).ToString('s'))
Write-Output 'STEAMX-PROBE-OK'
