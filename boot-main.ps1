# ---------------------------------------------------------------------------
# STEAMX  main.ps1 bootstrap
#
# Job: on every launch, download the current main.ps1 to a temp file and run it
#      with -File. Download is byte-for-byte (iwr -OutFile), so the file's UTF-8
#      BOM survives and PowerShell 5.1 decodes the Chinese text correctly. This
#      is the same shape other Steam tools use (iwr -OutFile + -File) and it is
#      why main.ps1 can carry Chinese directly instead of base64.
#
# Why download-to-file instead of `iex (irm <url>)`:
#   * irm decodes the response body as a String using the HTTP charset. jsDelivr
#     serves .ps1 as application/octet-stream, which 5.1 decodes as ISO-8859-1,
#     so any non-ASCII byte comes out mangled. Writing bytes to a file avoids
#     that decode step entirely.
#   * A file with a BOM is always read as UTF-8 by 5.1, so Chinese is safe.
#   * Running the saved file with -File also makes main.ps1's own Wait-BeforeExit
#     see -File on its command line and hold the window open (as before).
#
# ASCII only on purpose: this file is pulled through `iex (irm '<url>')`, and that
# path is the one that mangles non-ASCII. Keep it pure ASCII.
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

# Download to a temp file, byte-for-byte. Validate by size and by reading its
# first bytes back as UTF-8 (BOM or the known header comment).
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('STEAMX-main-' + [Guid]::NewGuid().ToString('N') + '.ps1')
$got = $false
foreach ($u in $urls) {
    try {
        # Cache-bust: gh-proxy/CDN caches the raw file for ~60s, so a fresh push
        # would otherwise be invisible until the TTL expires. Send no-cache and a
        # unique query token so the mirror revalidates against GitHub every run.
        $bustUrl = $u + $(if ($u.Contains('?')) { '&' } else { '?' }) + 't=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Invoke-WebRequest -Uri $bustUrl -UseBasicParsing -TimeoutSec 20 -OutFile $tmp -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
        if (-not (Test-Path -LiteralPath $tmp)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        if ($bytes.Length -lt 50000) {
            [void]$errs.Add('incomplete body from ' + $u.Substring(0, [Math]::Min(40, $u.Length)))
            continue
        }
        $head = [Text.Encoding]::UTF8.GetString($bytes)
        if ($head.Contains('main.ps1') -and ($head.Contains('STEAMX') -or $head.Contains('STEAMX  main.ps1'))) {
            $got = $true
            break
        }
        [void]$errs.Add('unexpected body from ' + $u.Substring(0, [Math]::Min(40, $u.Length)))
    } catch {
        [void]$errs.Add($_.Exception.Message)
    }
}

if (-not $got) {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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

# Run the downloaded file with -File and forward our arguments, so a caller can do
#   powershell -NoProfile -ExecutionPolicy Bypass -File boot-main.ps1 -Command Check
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp @args
    $code = $LASTEXITCODE
} catch {
    Write-Host ''
    Write-Host ('  STEAMX failed: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host ('  ' + $_.ScriptStackTrace.Split([char]10)[0]) -ForegroundColor DarkGray }
    if ([Environment]::UserInteractive -and -not $env:STEAMX_NO_PAUSE) {
        Write-Host '  press Enter to close ...' -ForegroundColor DarkGray
        [void][Console]::ReadLine()
    }
    $code = 1
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

exit $code
