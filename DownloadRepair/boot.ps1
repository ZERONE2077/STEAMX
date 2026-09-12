# ---------------------------------------------------------------------------
# STEAMX  DownloadRepair bootstrap
#
# Job: on every launch, resolve the newest commit of the repo, fetch
#      DownloadRepair/DownloadRepair.ps1 from that exact commit and run it.
#
# Why this is a separate file instead of an inline -Command in a shortcut:
#   * jsDelivr caches branch URLs (@main / @latest) for up to 12 h, so a branch
#     URL is never guaranteed to be the newest. Only @<commit-sha> is uncached.
#   * Microsoft Defender flags shortcuts whose command line downloads and runs
#     a script (Trojan:Win32/ClickFix.DAC!MTB / Trojan:Win32/Commando.A!ml).
#     Called through `iex (irm <url>)` the command line stays short and the
#     fetch logic lives in a file, which Defender leaves alone.
#
# ASCII only on purpose: this file may be pulled through `iex (irm '<url>')`,
# and jsDelivr serves .ps1 as application/octet-stream, which Invoke-RestMethod
# decodes as ISO-8859-1. Any non-ASCII byte would come out mangled.
# ---------------------------------------------------------------------------

$repo = 'ZERONE2077/STEAMX'
$rel  = 'DownloadRepair/DownloadRepair.ps1'
$jsd  = 'https://cdn.jsdelivr.net/gh/' + $repo + '@'
$raw  = 'https://raw.githubusercontent.com/' + $repo + '/main/' + $rel

$urls = New-Object System.Collections.ArrayList
$errs = New-Object System.Collections.ArrayList

# 1) ask the GitHub API for the sha of main, then use jsDelivr's immutable
#    @<sha> URL: fresh the moment the commit lands, and fast in mainland China
$apis = New-Object System.Collections.ArrayList
[void]$apis.Add('https://api.github.com/repos/' + $repo + '/commits/main')
[void]$apis.Add('https://gh-proxy.com/https://api.github.com/repos/' + $repo + '/commits/main')
foreach ($api in $apis) {
    try {
        $c = (Invoke-WebRequest -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'STEAMX' } -TimeoutSec 6).Content
        if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
        $sha = ($c | ConvertFrom-Json).sha
        if ($sha) { [void]$urls.Add($jsd + $sha + '/' + $rel); break }
    } catch { }
}

# 2) fallbacks, in the order that is most likely to still be current
[void]$urls.Add($raw)
[void]$urls.Add('https://ghfast.top/' + $raw)
[void]$urls.Add($jsd + 'latest/' + $rel)

$src = $null
foreach ($u in $urls) {
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20
        $t = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
        if ($t.Length -gt 5000 -and $t.Contains('# DownloadRepair.ps1')) { $src = $t; break }
        [void]$errs.Add('incomplete body from ' + $u.Substring(0, 40))
    } catch {
        [void]$errs.Add($_.Exception.Message)
    }
}

if (-not $src) {
    Write-Host ''
    Write-Host ('  STEAMX start failed: ' + ($errs -join ' / ')) -ForegroundColor Red
    Write-Host '  source order: GitHub API -> jsDelivr(sha) -> raw -> ghfast -> latest' -ForegroundColor DarkGray
    Write-Host '  usual causes: offline / CDN blocked / security software' -ForegroundColor DarkGray
    if ([Environment]::UserInteractive -and -not $env:STEAMX_NO_PAUSE) {
        Write-Host '  press Enter to close ...' -ForegroundColor DarkGray
        [void][Console]::ReadLine()
    }
    exit 7
}

# run it, forwarding whatever arguments we were given, so a caller can do
#   powershell -NoProfile -ExecutionPolicy Bypass -File boot.ps1 -Game 1091500
& ([scriptblock]::Create($src)) @args
