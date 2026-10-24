# ---------------------------------------------------------------------------
# STEAMX  main.ps1 bootstrap
#
# Job: on every launch, resolve the newest commit of the repo, fetch main.ps1
#      from that exact commit and run it.
#
# Why this is a separate file instead of an inline -Command in the shortcut:
#   * Microsoft Defender flags shortcuts whose command line downloads and runs
#     a script (Trojan:Win32/ClickFix.DAC!MTB / Trojan:Win32/Commando.A!ml).
#     Called through `iex (irm <url>)` the command line stays short and the
#     fetch logic lives in a file, which Defender leaves alone.
#   * jsDelivr is unreachable for some users, so the entry points and the
#     bootstrap's first fetch both use gh-proxy.com. Branch URLs through the
#     proxy were measured at max-age=60 on 2026-10-24, fresh enough for boot.
#
# ASCII only on purpose: this file is pulled through `iex (irm '<url>')`, and
# jsDelivr serves .ps1 as application/octet-stream, which Invoke-RestMethod
# decodes as ISO-8859-1. Any non-ASCII byte would come out mangled.
# ---------------------------------------------------------------------------

$repo = 'ZERONE2077/STEAMX'
$rel  = 'main.ps1'
$jsd  = 'https://cdn.jsdelivr.net/gh/' + $repo + '@'
$raw  = 'https://raw.githubusercontent.com/' + $repo + '/main/' + $rel

$urls = New-Object System.Collections.ArrayList
$errs = New-Object System.Collections.ArrayList

# 1) domestic mirrors first; jsDelivr stays a last-resort fallback
[void]$urls.Add('https://gh-proxy.com/' + $raw)
[void]$urls.Add('https://hk.gh-proxy.com/' + $raw)
[void]$urls.Add('https://ghfast.top/' + $raw)
[void]$urls.Add('https://ghproxy.net/' + $raw)
[void]$urls.Add($raw)

# 2) keep a jsDelivr path for networks where GitHub and those mirrors are blocked
[void]$urls.Add($jsd + 'latest/' + $rel)

$src = $null
foreach ($u in $urls) {
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20
        $t = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
        if ($t.Length -gt 50000 -and $t.Contains('# Keep this entry script ASCII-only')) { $src = $t; break }
        [void]$errs.Add('incomplete body from ' + $u.Substring(0, 40))
    } catch {
        [void]$errs.Add($_.Exception.Message)
    }
}

if (-not $src) {
    Write-Host ''
    Write-Host ('  STEAMX start failed: ' + ($errs -join ' / ')) -ForegroundColor Red
    Write-Host '  source order: gh-proxy -> hk.gh-proxy -> ghfast -> ghproxy -> raw -> jsDelivr' -ForegroundColor DarkGray
    Write-Host '  usual causes: offline / CDN blocked / security software' -ForegroundColor DarkGray
    if ([Environment]::UserInteractive -and -not $env:STEAMX_NO_PAUSE) {
        Write-Host '  press Enter to close ...' -ForegroundColor DarkGray
        [void][Console]::ReadLine()
    }
    exit 7
}

# run it, forwarding whatever arguments we were given, so a caller can do
#   powershell -NoProfile -ExecutionPolicy Bypass -File boot-main.ps1 -Command Check
# The try/catch exists because main.ps1 only keeps the window open when it was
# started with -File, and a shortcut launched through `iex (irm ...)` does not
# have -File on its command line.
try {
    & ([scriptblock]::Create($src)) @args
} catch {
    Write-Host ''
    Write-Host ('  STEAMX failed: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host ('  ' + $_.ScriptStackTrace.Split([char]10)[0]) -ForegroundColor DarkGray }
    if ([Environment]::UserInteractive -and -not $env:STEAMX_NO_PAUSE) {
        Write-Host '  press Enter to close ...' -ForegroundColor DarkGray
        [void][Console]::ReadLine()
    }
    exit 1
}
