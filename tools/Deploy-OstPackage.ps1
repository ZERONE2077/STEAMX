#requires -Version 5.1
<#
.SYNOPSIS
    Downloads the latest OpenSteamTool package from GitHub and deploys it into Steam.

.DESCRIPTION
    Built for users in mainland China, where reaching GitHub directly is unreliable.

    Three design goals:

    1. NEVER STALL ON A DEAD MIRROR.
       Every candidate source (official GitHub + several public GitHub proxies) is
       probed IN PARALLEL inside a single short window. The first healthy source wins,
       so one dead mirror costs the probe window (a few seconds), not a full connect
       timeout. Downloads then walk the remaining sources in measured latency order.

    2. ALWAYS THE LATEST ONLINE RELEASE.
       No zip is cached, no local copy is reused, and version discovery runs on every
       invocation. The package is fetched fresh each time so an upstream update is
       picked up automatically. Delete every scratch folder and the tool still works.

    3. LEAVE NOTHING BEHIND.
       All scratch work happens inside ONE predictable folder
       (%LOCALAPPDATA%\STEAMX\work), wiped at start and again in the finally block,
       so even an abort cannot scatter junk. Legacy transaction folders written by
       older builds are swept on startup as well.

.PARAMETER Repo
    Upstream GitHub repository in owner/name form. Default: OpenSteam001/OpenSteamTool

.PARAMETER SteamPath
    Steam install folder. Auto-detected (running process, registry, env var) when omitted.

.PARAMETER Files
    Files the package must contain. Used to validate the extracted package.

.PARAMETER ProbeTimeoutMs
    Total budget for the parallel source probe. Default 6000.

.PARAMETER ReadTimeoutMs
    Per-source read timeout once the connection is established. Default 90000.

.PARAMETER DryRun
    Resolve, download, verify and extract, but do not touch the Steam folder.

.PARAMETER KeepWork
    Keep the scratch folder after the run. For troubleshooting only.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Deploy-OstPackage.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Deploy-OstPackage.ps1 -DryRun -KeepWork

.NOTES
    Exit codes: 0 success, 1 failure, 2 bad arguments, 3 environment, 5 permission, 7 network.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'OpenSteam001/OpenSteamTool',
    [string]$AssetPattern = '*Release.zip',
    [string]$AssetNameTemplate = 'OpenSteamTool-{tag}-Release.zip',
    [string]$SteamPath = '',
    [string[]]$Files = @('dwmapi.dll', 'xinput1_4.dll', 'OpenSteamTool.dll'),
    [string]$WorkRoot = '',
    [string]$BackupRoot = '',
    [int]$KeepBackups = 3,
    [int]$ProbeTimeoutMs = 6000,
    [int]$ReadTimeoutMs = 90000,
    [int]$ApiTimeoutMs = 8000,
    [switch]$NoBackup,
    [switch]$NoStopSteam,
    [switch]$KeepWork,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Enable-Tls12 {
    try {
        $current = [System.Net.ServicePointManager]::SecurityProtocol
        if ($current.ToString() -notmatch 'Tls12') {
            [System.Net.ServicePointManager]::SecurityProtocol = $current -bor [System.Net.SecurityProtocolType]::Tls12
        }
    } catch {
    }
}
Enable-Tls12

$script:StepCount = 0

function Write-Say {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('step', 'info', 'ok', 'warn', 'err')][string]$Level = 'info'
    )
    $color = 'Gray'
    switch ($Level) {
        'step' { $color = 'Cyan' }
        'ok'   { $color = 'Green' }
        'warn' { $color = 'Yellow' }
        'err'  { $color = 'Red' }
    }
    if ($Level -eq 'step') {
        $script:StepCount++
        Write-Host ("[{0}] {1}" -f $script:StepCount, $Message) -ForegroundColor $color
    } else {
        Write-Host ("      {0}" -f $Message) -ForegroundColor $color
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

# ---------------------------------------------------------------------------
# Scratch layout: one predictable folder, always wiped.
# ---------------------------------------------------------------------------

function Get-LocalBase {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return [System.IO.Path]::GetTempPath()
    }
    return $env:LOCALAPPDATA
}

function Resolve-WorkRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    return (Join-Path (Get-LocalBase) 'STEAMX\work')
}

function Resolve-BackupRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    return (Join-Path (Get-LocalBase) 'STEAMX\backups')
}

function Remove-PathTree {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        try {
            [System.IO.Directory]::Delete($Path, $true)
        } catch {
            return $false
        }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Reset-Scratch {
    param([string]$WorkRoot)

    # Sweep scratch folders written by older builds. They used a per-run GUID
    # folder under %TEMP%, so an aborted run left an unfindable pile behind.
    foreach ($legacy in @(
        (Join-Path ([System.IO.Path]::GetTempPath()) 'STEAMX\transactions'),
        (Join-Path ([System.IO.Path]::GetTempPath()) 'STEAMX')
    )) {
        if (Test-Path -LiteralPath $legacy) {
            if (Remove-PathTree -Path $legacy) {
                Write-Say -Message ("Swept legacy scratch: {0}" -f $legacy) -Level 'warn'
            }
        }
    }

    if (Test-Path -LiteralPath $WorkRoot) {
        if (-not (Remove-PathTree -Path $WorkRoot)) {
            throw ("Unable to clear the scratch folder: {0}" -f $WorkRoot)
        }
        Write-Say -Message ("Cleared leftover scratch: {0}" -f $WorkRoot) -Level 'warn'
    }
    [void](New-Item -ItemType Directory -Path $WorkRoot -Force)
}

# ---------------------------------------------------------------------------
# Source discovery: parallel probe, latency-ordered result.
# ---------------------------------------------------------------------------

function Get-MirrorPrefixes {
    # '' means direct/official. Order only matters as a tie-breaker; the probe
    # decides the real order by measured latency.
    return @(
        '',
        'https://gh-proxy.com/',
        'https://ghfast.top/',
        'https://ghproxy.net/',
        'https://hk.gh-proxy.com/'
    )
}

function Invoke-RaceProbe {
    <#
        Fires a tiny ranged GET at every URL at once and returns the ones that
        answered with 2xx, sorted by response time. This is what turns a 30 s
        sequential timeout into a single short window.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [int]$TimeoutMs = 6000
    )

    $entries = New-Object System.Collections.ArrayList
    foreach ($url in $Urls) {
        $request = $null
        try {
            $request = [System.Net.HttpWebRequest]::Create($url)
            $request.Method = 'GET'
            $request.UserAgent = 'STEAMX'
            $request.AllowAutoRedirect = $true
            $request.Timeout = $TimeoutMs
            $request.ReadWriteTimeout = $TimeoutMs
            $request.AddRange(0, 0)
            $async = $request.BeginGetResponse($null, $null)
            [void]$entries.Add([pscustomobject]@{
                Url     = $url
                Request = $request
                Async   = $async
                Elapsed = 0
            })
        } catch {
            if ($null -ne $request) { try { $request.Abort() } catch { } }
        }
    }

    $healthy = New-Object System.Collections.ArrayList
    if ($entries.Count -gt 0) {
        $pending = @($entries)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0) {
            $remaining = $TimeoutMs - [int]$stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) { break }

            $handles = [System.Threading.WaitHandle[]]::new($pending.Count)
            for ($i = 0; $i -lt $pending.Count; $i++) {
                $handles[$i] = $pending[$i].Async.AsyncWaitHandle
            }
            $hit = [System.Threading.WaitHandle]::WaitAny($handles, $remaining)
            if ($hit -lt 0) { break }

            $entry = $pending[$hit]
            $response = $null
            $code = 0
            try {
                $response = $entry.Request.EndGetResponse($entry.Async)
                $code = [int]$response.StatusCode
            } catch {
                $code = 0
            } finally {
                if ($null -ne $response) { $response.Dispose() }
            }

            if ($code -ge 200 -and $code -lt 300) {
                $entry.Elapsed = [int]$stopwatch.ElapsedMilliseconds
                [void]$healthy.Add($entry)
            }

            $next = @()
            for ($i = 0; $i -lt $pending.Count; $i++) {
                if ($i -ne $hit) { $next += $pending[$i] }
            }
            $pending = $next
        }

        foreach ($entry in $pending) {
            try { $entry.Request.Abort() } catch { }
        }
    }

    return @($healthy | Sort-Object -Property Elapsed)
}

function Get-GitHubJson {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 8000
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.UserAgent = 'STEAMX'
    $request.Accept = 'application/vnd.github+json'
    $request.AllowAutoRedirect = $true
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $body = $reader.ReadToEnd()
        return $body | ConvertFrom-Json
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Resolve-TagFromWebRedirect {
    <#
        Fallback that needs no API call at all (and therefore no rate limit):
        github.com/<repo>/releases/latest answers with a redirect to
        .../releases/tag/<tag>. Works through any proxy that forwards redirects.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [int]$TimeoutMs = 8000
    )

    $suffix = ('https://github.com/{0}/releases/latest' -f $Repository)
    $urls = New-Object System.Collections.ArrayList
    foreach ($prefix in (Get-MirrorPrefixes)) { [void]$urls.Add($prefix + $suffix) }

    foreach ($hit in @(Invoke-RaceProbe -Urls @($urls) -TimeoutMs $TimeoutMs)) {
        $request = [System.Net.HttpWebRequest]::Create($hit.Url)
        $request.Method = 'GET'
        $request.UserAgent = 'STEAMX'
        $request.AllowAutoRedirect = $true
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $response = $null
        try {
            $response = $request.GetResponse()
            $finalUrl = [string]$response.ResponseUri.AbsoluteUri
            if ($finalUrl -match '/releases/tag/([^/?#]+)') {
                return [Uri]::UnescapeDataString($Matches[1])
            }
        } catch {
        } finally {
            if ($null -ne $response) { $response.Dispose() }
        }
    }
    return ''
}

function Resolve-LatestPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$NameTemplate,
        [int]$TimeoutMs = 8000
    )

    $apiSuffix = ('https://api.github.com/repos/{0}/releases/latest' -f $Repository)
    $apiUrls = New-Object System.Collections.ArrayList
    foreach ($prefix in (Get-MirrorPrefixes)) { [void]$apiUrls.Add($prefix + $apiSuffix) }

    $errors = New-Object System.Collections.ArrayList
    $apiHits = @(Invoke-RaceProbe -Urls @($apiUrls) -TimeoutMs $TimeoutMs)
    if ($apiHits.Count -eq 0) {
        [void]$errors.Add(('no source answered the release API probe within {0} ms' -f $TimeoutMs))
    }
    foreach ($hit in $apiHits) {
        try {
            $release = Get-GitHubJson -Url $hit.Url -TimeoutMs $TimeoutMs
            $asset = @($release.assets) | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
            if ($null -eq $asset) {
                $asset = @($release.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
            }
            if ($null -eq $asset) {
                [void]$errors.Add(("{0}: no asset matches {1}" -f $hit.Url, $Pattern))
                continue
            }
            $digest = [string]$asset.digest
            $sha = ''
            if ($digest -match '^(?i:sha256):([0-9a-f]{64})$') { $sha = $Matches[1].ToLowerInvariant() }
            return [pscustomobject]@{
                Tag         = [string]$release.tag_name
                AssetName   = [string]$asset.name
                Url         = [string]$asset.browser_download_url
                Sha256      = $sha
                PublishedAt = [string]$release.published_at
                Discovered  = $hit.Url
            }
        } catch {
            [void]$errors.Add(("{0}: {1}" -f $hit.Url, $_.Exception.Message))
        }
    }

    Write-Say -Message 'Release API unreachable through every source; falling back to the web redirect.' -Level 'warn'
    $tag = Resolve-TagFromWebRedirect -Repository $Repository -TimeoutMs $TimeoutMs
    if (-not [string]::IsNullOrWhiteSpace($tag)) {
        $assetName = $NameTemplate.Replace('{tag}', $tag)
        $url = 'https://github.com/{0}/releases/download/{1}/{2}' -f `
            $Repository, ([Uri]::EscapeDataString($tag)), ([Uri]::EscapeDataString($assetName))
        Write-Say -Message ("Resolved {0} from the web redirect (no SHA-256 metadata available)." -f $tag) -Level 'warn'
        return [pscustomobject]@{
            Tag         = $tag
            AssetName   = $assetName
            Url         = $url
            Sha256      = ''
            PublishedAt = ''
            Discovered  = 'web-redirect'
        }
    }

    throw ('Unable to resolve the latest release of {0}. {1}' -f $Repository, ($errors -join ' | '))
}

# ---------------------------------------------------------------------------
# Download with fail-fast source switching.
# ---------------------------------------------------------------------------

function Save-UrlToFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$ConnectTimeoutMs = 6000,
        [int]$ReadTimeoutMs = 90000
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.UserAgent = 'STEAMX'
    $request.Accept = 'application/octet-stream'
    $request.AllowAutoRedirect = $true
    $request.Timeout = $ConnectTimeoutMs
    $request.ReadWriteTimeout = $ReadTimeoutMs

    $response = $null
    $stream = $null
    $file = $null
    try {
        $response = $request.GetResponse()
        $expected = [long]$response.ContentLength
        $stream = $response.GetResponseStream()
        $file = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $written = 0L
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $file.Write($buffer, 0, $read)
            $written += $read
        }
        if ($expected -gt 0 -and $written -ne $expected) {
            throw ('Incomplete download: {0} of {1} bytes.' -f $written, $expected)
        }
        return $written
    } finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CandidateUrls {
    param([Parameter(Mandatory = $true)][string]$OfficialUrl)

    # Order comes from the live probe; the official URL keeps its slot even when
    # the probe could not reach it, because a reachability probe can fail while a
    # full download still succeeds (and vice versa).
    $probeUrls = New-Object System.Collections.ArrayList
    foreach ($prefix in (Get-MirrorPrefixes)) { [void]$probeUrls.Add($prefix + $OfficialUrl) }
    $probeUrls = @($probeUrls | Select-Object -Unique)

    $ordered = New-Object System.Collections.ArrayList
    foreach ($hit in @(Invoke-RaceProbe -Urls @($probeUrls) -TimeoutMs $ProbeTimeoutMs)) {
        Write-Say -Message ("  {0,6} ms  {1}" -f $hit.Elapsed, $hit.Url) -Level 'info'
        [void]$ordered.Add($hit.Url)
    }
    foreach ($url in $probeUrls) {
        if ($url -notin $ordered) { [void]$ordered.Add($url) }
    }
    return @($ordered)
}

function Get-PackageZip {
    param(
        [Parameter(Mandatory = $true)][string]$OfficialUrl,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$ExpectedSha256 = '',
        [int]$ConnectTimeoutMs = 6000,
        [int]$ReadTimeoutMs = 90000
    )

    $candidates = Get-CandidateUrls -OfficialUrl $OfficialUrl
    if ($candidates.Count -eq 0) { throw 'No download source is available.' }

    $errors = New-Object System.Collections.ArrayList
    foreach ($url in $candidates) {
        $host_ = ([Uri]$url).Host
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Write-Say -Message ("Downloading via {0} ..." -f $host_) -Level 'info'
            $bytes = Save-UrlToFile -Url $url -Destination $Destination -ConnectTimeoutMs $ConnectTimeoutMs -ReadTimeoutMs $ReadTimeoutMs
            if ($bytes -le 0) { throw 'The downloaded file is empty.' }

            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                $actual = Get-FileSha256 -Path $Destination
                if ($actual -ne $ExpectedSha256) {
                    throw ('SHA-256 mismatch. Expected {0}, received {1}.' -f $ExpectedSha256, $actual)
                }
            }
            $stopwatch.Stop()
            Write-Say -Message ("Downloaded {0} from {1} in {2} ms (integrity OK)." -f (Format-Size $bytes), $host_, $stopwatch.ElapsedMilliseconds) -Level 'ok'
            return [pscustomobject]@{ Url = $url; Bytes = $bytes; Sha256 = $ExpectedSha256 }
        } catch {
            $stopwatch.Stop()
            [void]$errors.Add(('{0}: {1}' -f $host_, $_.Exception.Message))
            Write-Say -Message ("{0} failed: {1}" -f $host_, $_.Exception.Message) -Level 'warn'
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
        }
    }

    throw ('Every download source failed. {0}' -f ($errors -join ' | '))
}

# ---------------------------------------------------------------------------
# Extraction and validation.
# ---------------------------------------------------------------------------

function Expand-Package {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) { [void](Remove-PathTree -Path $Destination) }
    [void](New-Item -ItemType Directory -Path $Destination -Force)

    $destinationRoot = [System.IO.Path]::GetFullPath($Destination)
    if (-not $destinationRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $destinationRoot += [System.IO.Path]::DirectorySeparatorChar
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = ([string]$entry.FullName).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination $relative))
            if (-not $target.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('The package contains an unsafe path: {0}' -f $relative)
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                [void](New-Item -ItemType Directory -Path $target -Force)
                continue
            }
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            $entryStream = $null
            $output = $null
            try {
                $entryStream = $entry.Open()
                $output = [System.IO.File]::Open($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $entryStream.CopyTo($output)
            } finally {
                if ($null -ne $output) { $output.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Find-PackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    return (Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

function Assert-PackageFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Required
    )
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $Required) {
        if ($null -eq (Find-PackageFile -Root $Root -FileName $name)) { [void]$missing.Add($name) }
    }
    if ($missing.Count -gt 0) {
        throw ('The package is incomplete. Missing: {0}' -f ($missing -join ', '))
    }
}

# ---------------------------------------------------------------------------
# Steam target handling.
# ---------------------------------------------------------------------------

function Test-SteamFolder {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    try {
        return [bool](Test-Path -LiteralPath (Join-Path $PathValue 'steam.exe') -PathType Leaf)
    } catch {
        return $false
    }
}

function Resolve-SteamFolder {
    param([string]$Override)

    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Override)) { [void]$candidates.Add($Override) }
    if (-not [string]::IsNullOrWhiteSpace($env:STEAM_PATH)) { [void]$candidates.Add($env:STEAM_PATH) }

    foreach ($process in @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                [void]$candidates.Add((Split-Path -Parent ([string]$process.Path)))
            }
        } catch {
        }
    }

    foreach ($registryPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\Software\WOW6432Node\Valve\Steam', 'HKLM:\Software\Valve\Steam')) {
        try {
            if (-not (Test-Path $registryPath)) { continue }
            $item = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
            foreach ($name in @('SteamPath', 'InstallPath')) {
                $value = [string]$item.$name
                if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$candidates.Add($value) }
            }
            $steamExe = [string]$item.SteamExe
            if (-not [string]::IsNullOrWhiteSpace($steamExe)) {
                [void]$candidates.Add((Split-Path -Parent $steamExe))
            }
        } catch {
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-SteamFolder -PathValue $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return ''
}

function Stop-SteamClient {
    $processes = @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $false }

    Write-Say -Message ('Steam is running (pid {0}); closing it so the files can be replaced.' -f (($processes | ForEach-Object { $_.Id }) -join ', ')) -Level 'warn'
    foreach ($process in $processes) {
        try { $process.CloseMainWindow() | Out-Null } catch { }
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count -eq 0) { break }
    }
    foreach ($process in @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 800
    if (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Steam could not be closed automatically. Close it manually and run the script again.'
    }
    Write-Say -Message 'Steam closed.' -Level 'ok'
    return $true
}

function Test-FolderWritable {
    param([Parameter(Mandatory = $true)][string]$Path)
    $probe = Join-Path $Path ('.steamx-write-{0}.tmp' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        [System.IO.File]::Delete($probe)
        return $true
    } catch {
        return $false
    }
}

function Backup-TargetFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SteamFolder,
        [Parameter(Mandatory = $true)][string[]]$Required,
        [Parameter(Mandatory = $true)][string]$BackupFolder
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $BackupFolder $stamp
    $saved = New-Object System.Collections.ArrayList
    foreach ($name in $Required) {
        $path = Join-Path $SteamFolder $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        [void](New-Item -ItemType Directory -Path $target -Force)
        Copy-Item -LiteralPath $path -Destination (Join-Path $target $name) -Force
        [void]$saved.Add($name)
    }
    if ($saved.Count -eq 0) {
        [void](Remove-PathTree -Path $target)
        return ''
    }
    return $target
}

function Remove-OldBackups {
    param(
        [Parameter(Mandatory = $true)][string]$BackupFolder,
        [int]$Keep = 3
    )
    if ($Keep -lt 1) { return }
    if (-not (Test-Path -LiteralPath $BackupFolder)) { return }
    $folders = @(Get-ChildItem -LiteralPath $BackupFolder -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    if ($folders.Count -le $Keep) { return }
    foreach ($folder in $folders[$Keep..($folders.Count - 1)]) {
        if (Remove-PathTree -Path $folder.FullName) {
            Write-Say -Message ('Removed old backup: {0}' -f $folder.Name) -Level 'info'
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$workRootPath = Resolve-WorkRoot -Override $WorkRoot
$backupRootPath = Resolve-BackupRoot -Override $BackupRoot
$exitCode = 0
$packageResult = $null
$downloadResult = $null
$extractPath = Join-Path $workRootPath 'package'
$zipPath = Join-Path $workRootPath 'package.zip'

try {
    Write-Host ''
    Write-Host '  STEAMX - OpenSteamTool online deploy' -ForegroundColor White
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Say -Message ("Scratch folder: {0}" -f $workRootPath) -Level 'info'
    Reset-Scratch -WorkRoot $workRootPath

    Write-Say -Message ('Resolving the latest release of {0} ...' -f $Repo) -Level 'step'
    $packageResult = Resolve-LatestPackage `
        -Repository $Repo `
        -Pattern $AssetPattern `
        -NameTemplate $AssetNameTemplate `
        -TimeoutMs $ApiTimeoutMs
    Write-Say -Message ('Latest online release: {0}{1}' -f $packageResult.Tag, $(if ($packageResult.PublishedAt) { ' (published ' + $packageResult.PublishedAt.Substring(0, [Math]::Min(10, $packageResult.PublishedAt.Length)) + ')' } else { '' })) -Level 'ok'
    Write-Say -Message ('Asset: {0}' -f $packageResult.AssetName) -Level 'info'
    if (-not [string]::IsNullOrWhiteSpace($packageResult.Sha256)) {
        Write-Say -Message ('Expected SHA-256: {0}' -f $packageResult.Sha256) -Level 'info'
    } else {
        Write-Say -Message 'No SHA-256 published for this asset; integrity will be checked by archive validation.' -Level 'warn'
    }

    Write-Say -Message 'Probing every source in parallel ...' -Level 'step'
    $downloadResult = Get-PackageZip `
        -OfficialUrl $packageResult.Url `
        -Destination $zipPath `
        -ExpectedSha256 $packageResult.Sha256 `
        -ConnectTimeoutMs $ProbeTimeoutMs `
        -ReadTimeoutMs $ReadTimeoutMs

    Write-Say -Message 'Extracting ...' -Level 'step'
    Expand-Package -ZipPath $zipPath -Destination $extractPath
    Assert-PackageFiles -Root $extractPath -Required $Files
    Write-Say -Message ('Package verified: {0}' -f ($Files -join ', ')) -Level 'ok'

    if ($DryRun) {
        Write-Say -Message 'Dry run: the Steam folder was not modified.' -Level 'warn'
    } else {
        Write-Say -Message 'Locating Steam ...' -Level 'step'
        $steamFolder = Resolve-SteamFolder -Override $SteamPath
        if ([string]::IsNullOrWhiteSpace($steamFolder)) {
            throw 'Steam was not found. Pass -SteamPath "<steam folder>" and run the script again.'
        }
        Write-Say -Message ('Steam folder: {0}' -f $steamFolder) -Level 'ok'

        if (-not (Test-FolderWritable -Path $steamFolder)) {
            throw ('No write permission on {0}. Re-run this script as administrator.' -f $steamFolder)
        }

        if (-not $NoStopSteam) { [void](Stop-SteamClient) }

        $backupPath = ''
        if (-not $NoBackup) {
            $backupPath = Backup-TargetFiles -SteamFolder $steamFolder -Required $Files -BackupFolder $backupRootPath
            if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
                Write-Say -Message ('Backed up existing files to {0}' -f $backupPath) -Level 'info'
            }
        }

        Write-Say -Message 'Installing files ...' -Level 'step'
        $installed = New-Object System.Collections.ArrayList
        foreach ($name in $Files) {
            $source = Find-PackageFile -Root $extractPath -FileName $name
            if ($null -eq $source) { throw ('Missing {0} in the package.' -f $name) }
            Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $steamFolder $name) -Force
            [void]$installed.Add($name)
        }
        Write-Say -Message ('Deployed {0} file(s) from version {1}: {2}' -f $installed.Count, $packageResult.Tag, ($installed -join ', ')) -Level 'ok'

        if (-not $NoBackup) { Remove-OldBackups -BackupFolder $backupRootPath -Keep $KeepBackups }
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Say -Message $_.Exception.Message -Level 'err'
    if (-not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
        Write-Say -Message ('at ' + $_.InvocationInfo.PositionMessage.Trim()) -Level 'info'
    }
} finally {
    if ($KeepWork) {
        Write-Say -Message ('Scratch kept for inspection: {0}' -f $workRootPath) -Level 'warn'
    } else {
        if (Remove-PathTree -Path $workRootPath) {
            Write-Say -Message 'Scratch folder removed.' -Level 'info'
        } else {
            Write-Say -Message ('Could not remove the scratch folder: {0}' -f $workRootPath) -Level 'warn'
        }
    }
    Write-Host ''
}

exit $exitCode
