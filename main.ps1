# Keep this entry script UTF-8 without BOM for Windows PowerShell 5.1 web execution.
[CmdletBinding()]
param(
    [ValidateSet("Menu", "Check", "EnableUnlockMode", "DeployOst", "SetManifestSource", "UninstallOst", "UninstallOstAndLua")]
    [string]$Command = "Menu",
    [string]$ManifestSource,
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8Encoding = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8Encoding
[Console]::OutputEncoding = $utf8Encoding
$OutputEncoding = $utf8Encoding
Clear-Host
$script:OstReleaseCache = @{}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

function Write-UiLine {
    param(
        [AllowEmptyString()][string]$Text = "",
        [System.ConsoleColor]$ForegroundColor
    )

    if ([string]::IsNullOrEmpty($Text)) {
        Write-Host ""
        return
    }
    if ($PSBoundParameters.ContainsKey("ForegroundColor")) {
        Write-Host $Text -ForegroundColor $ForegroundColor
    } else {
        Write-Host $Text
    }
}

function Read-UiInput {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    return Read-Host $Prompt
}

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }

    $commandPath = [string](Get-Variable -Name PSCommandPath -ValueOnly -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        $pathProperty = $MyInvocation.MyCommand.PSObject.Properties["Path"]
        if ($null -ne $pathProperty) {
            $commandPath = [string]$pathProperty.Value
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
        return (Split-Path -Parent $commandPath)
    }
    return (Get-Location).Path
}

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Get-DisplayPath {
    param([AllowEmptyString()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
    $fullPath = [System.IO.Path]::GetFullPath($PathValue)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $displayPath = $root.Substring(0, 1).ToUpperInvariant() + $root.Substring(1)
    $currentPath = $root
    $relativePath = $fullPath.Substring($root.Length)
    try {
        foreach ($segment in @($relativePath.Split("\", [System.StringSplitOptions]::RemoveEmptyEntries))) {
            $actualName = $segment
            if (Test-Path -LiteralPath $currentPath -PathType Container) {
                $matchingItem = Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $segment } |
                    Select-Object -First 1
                if ($null -ne $matchingItem) {
                    $actualName = $matchingItem.Name
                }
            }
            $displayPath = Join-Path $displayPath $actualName
            $currentPath = Join-Path $currentPath $segment
        }
    } catch {
        $displayPath = $fullPath
        if ($displayPath -match '^[a-z]:\\') {
            $displayPath = $displayPath.Substring(0, 1).ToUpperInvariant() + $displayPath.Substring(1)
        }
    }
    return $displayPath
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Get-ConfigValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Timestamp {
    return Get-Date -Format "yyyyMMdd-HHmmss"
}

function New-DefaultConfig {
    return [pscustomobject]@{
        steamPath  = ""
        network    = [pscustomobject]@{
            timeoutSeconds = 30
        }
        manifest   = [pscustomobject]@{
            source = "wudrm"
        }
        ost        = [pscustomobject]@{
            sourceType                  = "github-release"
            sourcePath                  = "./ost"
            githubRepo                  = "OpenSteam001/OpenSteamTool"
            assetPattern                = "*Release.zip"
            assetNameTemplate           = "OpenSteamTool-{tag}-Release.zip"
            # Try the GitHub mirror first. The official URL is always appended as fallback.
            downloadUrlTemplates        = @(
                "https://ghfast.top/{official}"
            )
            targetPath                  = ""
            configPath                  = "opensteamtool.toml"
            files                       = @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll")
            requireSteamClosed          = $true
            autoCloseSteam              = $true
            restartSteamAfterDeploy     = $true
        }
    }
}

function Get-Config {
    param([string]$ConfigOverride)

    $scriptRoot = Get-ScriptRoot
    if ([string]::IsNullOrWhiteSpace($ConfigOverride)) {
        $config = New-DefaultConfig
        $config | Add-Member -NotePropertyName "__configFile" -NotePropertyValue "" -Force
        return $config
    }

    $configFile = Resolve-LocalPath -PathValue $ConfigOverride -BasePath $scriptRoot
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Config file not found: $configFile"
    }
    $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $config | Add-Member -NotePropertyName "__configFile" -NotePropertyValue $configFile -Force
    return $config
}

function New-RunContext {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    $scriptRoot = Get-ScriptRoot
    $operationId = "{0}-{1}" -f (Get-Timestamp), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    $transactionDir = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\transactions\{0}" -f $operationId)

    return [pscustomobject]@{
        ScriptRoot       = $scriptRoot
        OperationId      = $operationId
        LogFile          = ""
        BackupDir        = Join-Path $transactionDir "backup"
        TransactionDir   = $transactionDir
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARN", "ERROR")][string]$Level = "INFO",
        [string]$LogFile = ""
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($Level -eq "SUCCESS") {
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host $line
    }
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Write-SteampXLogo {
    $host.UI.RawUI.WindowTitle = "STEAMX - OpenSteamTools Deploy"
    Write-Host ""

    $lowerBlock = [string][char]0x2584
    $fullBlock = [string][char]0x2588
    $upperBlock = [string][char]0x2580
    $logoIndent = "  "
    $logo = @(
        " DDDDDDD DDDDDDDDD  DDDDDDD   DDDD   DDD      DDD DDD   DDD",
        "RRRRRTTT TTTRRRTTT RRRTTTTT DRRTTRRD RRRRD  DRRRR RRRRDRRRR",
        " TRRRRD     RRR    RRRDD    RRR  RRR RRRTRRRRTRRR  TRRRRRT",
        "   TRRRR    RRR    RRR      RRRTTRRR RRR  TT  RRR DRRRRRRRD",
        "RRRRRRRT    RRR    TRRRRRRR RRR  RRR RRR      RRR RRRT TRRR"
    )

    $blue = @(56, 189, 248)
    $green = @(34, 197, 94)
    $reset = "$([char]27)[0m"
    $steamColumns = 49

    foreach ($line in $logo) {
        $rendered = $line.Replace("D", $lowerBlock).Replace("R", $fullBlock).Replace("T", $upperBlock)
        $steamPart = $rendered.Substring(0, [Math]::Min($steamColumns, $rendered.Length))
        $xStart = $steamPart.Length
        $xPart = if ($xStart -lt $rendered.Length) { $rendered.Substring($xStart) } else { "" }

        if ($env:NO_COLOR) {
            Write-Host ("{0}{1}{2}" -f $logoIndent, $steamPart, $xPart)
            continue
        }

        $lineBuilder = [System.Text.StringBuilder]::new()
        [void]$lineBuilder.Append($logoIndent)
        [void]$lineBuilder.Append("$([char]27)[38;2;$($blue[0]);$($blue[1]);$($blue[2])m$steamPart")
        [void]$lineBuilder.Append("$([char]27)[38;2;$($green[0]);$($green[1]);$($green[2])m$xPart")
        [void]$lineBuilder.Append($reset)
        Write-Host $lineBuilder.ToString()
    }

    Write-Host ""
    Write-Host ($logoIndent + "OpenSteamTools deploy and Lua manifest helper") -ForegroundColor Gray
    Write-Host ""
}

function Get-GitHubHeaders {
    return @{
        "Accept"     = "application/vnd.github+json"
        "User-Agent" = "STEAMX"
    }
}

function Get-HttpErrorDetail {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties["Response"]
    $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
    if ($null -eq $response) { return $message }

    try {
        $statusCode = [int]$response.StatusCode
        $statusDescription = [string]$response.StatusDescription
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Dispose()
        if ([string]::IsNullOrWhiteSpace($body)) {
            return "{0} HTTP {1} {2}" -f $message, $statusCode, $statusDescription
        }
        return "{0} HTTP {1} {2}. Response: {3}" -f $message, $statusCode, $statusDescription, $body
    } catch {
        return $message
    }
}

function Get-LatestOstRelease {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $networkConfig = Get-ConfigValue -Object $Config -Name "network" -DefaultValue $null
    $repo = [string](Get-ConfigValue -Object $ostConfig -Name "githubRepo" -DefaultValue "OpenSteam001/OpenSteamTool")
    $timeoutSeconds = [int](Get-ConfigValue -Object $networkConfig -Name "timeoutSeconds" -DefaultValue 30)
    if ($script:OstReleaseCache.ContainsKey($repo)) {
        return $script:OstReleaseCache[$repo]
    }

    $apiUrl = "https://api.github.com/repos/{0}/releases/latest" -f $repo
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers (Get-GitHubHeaders) -TimeoutSec $timeoutSeconds
        $script:OstReleaseCache[$repo] = $release
        return $release
    } catch {
        $apiError = Get-HttpErrorDetail -ErrorRecord $_
    }

    $latestUrl = "https://github.com/{0}/releases/latest" -f $repo
    $request = [System.Net.HttpWebRequest]::Create($latestUrl)
    $request.UserAgent = "STEAMX"
    $request.AllowAutoRedirect = $true
    $request.Timeout = $timeoutSeconds * 1000
    $request.ReadWriteTimeout = $timeoutSeconds * 1000
    $response = $null
    try {
        $response = $request.GetResponse()
        $finalUrl = [string]$response.ResponseUri.AbsoluteUri
        if ($finalUrl -notmatch '/releases/tag/([^/?#]+)') {
            throw "GitHub latest release redirect did not contain a tag."
        }
        $tagName = [Uri]::UnescapeDataString($Matches[1])
        $assetNameTemplate = [string](Get-ConfigValue -Object $ostConfig -Name "assetNameTemplate" -DefaultValue "OpenSteamTool-{tag}-Release.zip")
        $assetName = $assetNameTemplate.Replace("{tag}", $tagName)
        $assetUrl = "https://github.com/{0}/releases/download/{1}/{2}" -f $repo, ([Uri]::EscapeDataString($tagName)), ([Uri]::EscapeDataString($assetName))
        $release = [pscustomobject]@{
            tag_name     = $tagName
            published_at = ""
            assets       = @(
                [pscustomobject]@{
                    name                 = $assetName
                    browser_download_url = $assetUrl
                }
            )
        }
        $script:OstReleaseCache[$repo] = $release
        return $release
    } catch {
        $fallbackError = $_.Exception.Message
        throw ("Unable to fetch the latest OST release. GitHub API: {0}. GitHub web fallback: {1}" -f $apiError, $fallbackError)
    } finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-SteamPath {
    param([pscustomobject]$Config)

    $configuredPath = [string](Get-ConfigValue -Object $Config -Name "steamPath" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($configuredPath) -and (Test-Path -LiteralPath (Join-Path $configuredPath "steam.exe"))) {
        return [System.IO.Path]::GetFullPath($configuredPath)
    }

    $candidates = @()
    foreach ($registryPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\Software\WOW6432Node\Valve\Steam",
        "HKLM:\Software\Valve\Steam"
    )) {
        if (Test-Path $registryPath) {
            $item = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
            $steamPathValue = Get-ObjectPropertyValue -Object $item -Name "SteamPath"
            $installPathValue = Get-ObjectPropertyValue -Object $item -Name "InstallPath"
            if (-not [string]::IsNullOrWhiteSpace($steamPathValue)) { $candidates += $steamPathValue }
            if (-not [string]::IsNullOrWhiteSpace($installPathValue)) { $candidates += $installPathValue }
        }
    }

    $candidates += @(
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam",
        "D:\Steam",
        "E:\Steam"
    )

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $candidate "steam.exe")) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "Steam path not found. Set steamPath in New-DefaultConfig inside main.ps1."
}

function Get-SteamVersionInfo {
    param([Parameter(Mandatory = $true)][string]$SteamPath)

    $info = [ordered]@{
        ClientVersion = ""
        ApiVersion    = ""
        BuildDate     = ""
        PackageVersion = ""
        FileVersion   = ""
    }

    $steamExe = Join-Path $SteamPath "steam.exe"
    if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
        $fileVersion = (Get-Item -LiteralPath $steamExe).VersionInfo.FileVersion
        $info.FileVersion = [string]$fileVersion
    }

    $webHelperLog = Join-Path $SteamPath "logs\webhelper_js.txt"
    if (Test-Path -LiteralPath $webHelperLog -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $webHelperLog -Tail 4000 -ErrorAction SilentlyContinue)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            if ($line -notmatch "Updated Steam Version Info:\s*(\{.*\})") { continue }
            try {
                $versionInfo = $Matches[1] | ConvertFrom-Json
                if ($null -ne $versionInfo.nSteamVersion) {
                    $info.ClientVersion = [string]$versionInfo.nSteamVersion
                }
                $info.ApiVersion = [string]$versionInfo.sSteamAPI
                $info.BuildDate = [string]$versionInfo.sSteamBuildDate
                break
            } catch {
                continue
            }
        }
    }

    $bootstrapLog = Join-Path $SteamPath "logs\bootstrap_log.txt"
    if (Test-Path -LiteralPath $bootstrapLog -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $bootstrapLog -Tail 4000 -ErrorAction SilentlyContinue)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            if ($line -match "steam_client_win64 version (\d+)") {
                $info.PackageVersion = [string]$Matches[1]
                if ([string]::IsNullOrWhiteSpace($info.ClientVersion)) {
                    $info.ClientVersion = $info.PackageVersion
                }
                break
            }
        }
    }

    return [pscustomobject]$info
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OstConfigPath {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$SteamPath
    )

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $configuredPath = [string](Get-ConfigValue -Object $ostConfig -Name "configPath" -DefaultValue "opensteamtool.toml")
    $fileName = Split-Path -Leaf $configuredPath
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "opensteamtool.toml" }
    return Join-Path $SteamPath $fileName
}

function Get-OstLocalVersion {
    param([Parameter(Mandatory = $true)][string]$SteamPath)

    $dllPath = Join-Path $SteamPath "OpenSteamTool.dll"
    if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) { return "" }
    $version = (Get-Item -LiteralPath $dllPath).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = (Get-Item -LiteralPath $dllPath).VersionInfo.FileVersion
    }
    return [string]$version
}

function Test-VersionOlder {
    param(
        [string]$LocalVersion,
        [string]$RemoteVersion
    )

    if ([string]::IsNullOrWhiteSpace($LocalVersion) -or [string]::IsNullOrWhiteSpace($RemoteVersion)) { return $false }
    try {
        $local = [version]($LocalVersion.TrimStart("vV") -replace '[^0-9\.].*$', '')
        $remote = [version]($RemoteVersion.TrimStart("vV") -replace '[^0-9\.].*$', '')
        return $local -lt $remote
    } catch {
        return $false
    }
}

function Get-SteamRelatedProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -eq "steam" } |
            Sort-Object Id
    )
}

function Get-SteamRunningSummary {
    $processes = @(Get-SteamRelatedProcesses)
    if ($processes.Count -eq 0) { return "No" }
    return ($processes | ForEach-Object { "{0}({1})" -f $_.ProcessName, $_.Id }) -join ", "
}

function Stop-SteamProcesses {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $processes = @(Get-SteamRelatedProcesses)
    if ($processes.Count -eq 0) { return }

    Write-Log -Message ("Steam is running; closing related processes before continuing: {0}" -f (Get-SteamRunningSummary)) -Level "INFO" -LogFile $RunContext.LogFile
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }
    Start-Sleep -Seconds 2
    if (@(Get-SteamRelatedProcesses).Count -gt 0) {
        $taskKill = Start-Process -FilePath "cmd.exe" -ArgumentList "/c taskkill /f /im steam.exe" -WindowStyle Hidden -Wait -PassThru -ErrorAction SilentlyContinue
        if ($null -ne $taskKill -and $taskKill.ExitCode -ne 0) {
            Write-Log -Message "Steam could not be terminated automatically. Waiting for the user to exit Steam." -Level "WARN" -LogFile $RunContext.LogFile
        }
    }

    while (@(Get-SteamRelatedProcesses).Count -gt 0) {
        Write-UiLine -Text "Please exit the Steam client to continue." -ForegroundColor Red
        Start-Sleep -Milliseconds 1500
    }
}

function Start-Steam {
    param(
        [pscustomobject]$RunContext,
        [Parameter(Mandatory = $true)][string]$SteamPath
    )

    $steamExe = Join-Path $SteamPath "steam.exe"
    if (-not (Test-Path -LiteralPath $steamExe)) {
        Write-Log -Message "steam.exe not found; skip restart." -Level "WARN" -LogFile $RunContext.LogFile
        return
    }

    Start-Process -FilePath $steamExe -WorkingDirectory $SteamPath | Out-Null
    Write-Log -Message "Steam restarted." -LogFile $RunContext.LogFile
}

function Get-LatestOstReleaseInfo {
    param(
        [pscustomobject]$Config,
        [switch]$AllowFailure
    )

    try {
        $release = Get-LatestOstRelease -Config $Config
        return [pscustomobject]@{
            Available     = $true
            Version       = [string]$release.tag_name
            PublishedDate = [string]$release.published_at
            Error         = ""
        }
    } catch {
        if (-not $AllowFailure) { throw }
        return [pscustomobject]@{
            Available     = $false
            Version       = ""
            PublishedDate = ""
            Error         = Get-HttpErrorDetail -ErrorRecord $_
        }
    }
}

function Get-OstKernelState {
    param(
        [pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$SteamPath
    )

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $files = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    $present = @()
    $missing = @()
    foreach ($fileName in $files) {
        $target = Join-Path $SteamPath $fileName
        if (Test-Path -LiteralPath $target) { $present += $fileName } else { $missing += $fileName }
    }

    $localVersion = Get-OstLocalVersion -SteamPath $SteamPath
    $fileDates = @(
        foreach ($fileName in $present) {
            $target = Join-Path $SteamPath $fileName
            try { (Get-Item -LiteralPath $target).LastWriteTimeUtc.Date } catch { }
        }
    )
    $localFileDate = if ($fileDates.Count -gt 0) {
        ($fileDates | Sort-Object -Descending | Select-Object -First 1).ToString("yyyy-MM-dd")
    } else {
        ""
    }
    $legacyPaths = @(
        (Join-Path $SteamPath "config\st-plugin"),
        (Join-Path $SteamPath "config\stplug-in")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $status = if ($present.Count -eq 0) {
        "NotInstalled"
    } elseif ($missing.Count -gt 0) {
        "Incomplete"
    } elseif ([string]::IsNullOrWhiteSpace($localVersion)) {
        "VersionUnknown"
    } else {
        "Ready"
    }

    return [pscustomobject]@{
        Present      = $present
        Missing      = $missing
        IsReady      = ($missing.Count -eq 0)
        Version      = $localVersion
        FileDate     = $localFileDate
        Status       = $status
        LegacyPaths  = @($legacyPaths)
    }
}

function Get-OstSourceDirectory {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $sourceType = [string](Get-ConfigValue -Object $ostConfig -Name "sourceType" -DefaultValue "local")

    if ($sourceType -eq "github-release") {
        return Get-OstSourceDirectoryFromGitHub -Config $Config -RunContext $RunContext
    }

    $sourcePath = [string](Get-ConfigValue -Object $ostConfig -Name "sourcePath" -DefaultValue "./ost")
    $localPath = Resolve-LocalPath -PathValue $sourcePath -BasePath $RunContext.ScriptRoot
    if (-not (Test-Path -LiteralPath $localPath)) {
        throw "OST local source path not found: $localPath"
    }
    Assert-OstSourceFiles -Config $Config -SourcePath $localPath
    return [pscustomobject]@{
        SourcePath    = $localPath
        Version       = "local"
        PublishedDate = ""
        AssetName     = Split-Path -Leaf $localPath
        Source        = "local"
    }
}

function Assert-OstSourceFiles {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $files = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    $missing = @()
    foreach ($fileName in $files) {
        $sourceFile = Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $sourceFile) { $missing += $fileName }
    }
    if ($missing.Count -gt 0) {
        throw ("OST package is incomplete. Missing: {0}" -f ($missing -join ", "))
    }
}

function Assert-SafeZipArchive {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
            $normalized = $entryPath.Replace("/", "\")
            if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|\\)\.\.(\\|$)') {
                throw "OST archive contains an unsafe path: $entryPath"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0} B" -f $Bytes
}

function Format-DateStamp {
    param([AllowEmptyString()][string]$DateValue)

    if ([string]::IsNullOrWhiteSpace($DateValue)) { return "" }
    if ($DateValue -match '^(\d{4})-(\d{2})-(\d{2})') {
        return "{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]
    }
    try {
        return ([DateTime]$DateValue).ToString("yyyy.MM.dd")
    } catch {
        return ""
    }
}

function Format-VersionWithDate {
    param(
        [AllowEmptyString()][string]$Version,
        [AllowEmptyString()][string]$DateValue
    )

    $versionText = if ([string]::IsNullOrWhiteSpace($Version)) { "unknown" } else { $Version }
    $dateStamp = Format-DateStamp -DateValue $DateValue
    if ([string]::IsNullOrWhiteSpace($dateStamp)) { return $versionText }
    return "{0}-{1}" -f $dateStamp, $versionText
}

function Invoke-DownloadFileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$TimeoutSeconds = 30
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = "STEAMX"
    $request.Accept = "application/octet-stream"
    $request.AllowAutoRedirect = $true
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $response = $request.GetResponse()
        $totalBytes = [long]$response.ContentLength
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $downloaded = 0L
        while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloaded * 100) / $totalBytes))
                $status = "{0} / {1}" -f (Format-FileSize $downloaded), (Format-FileSize $totalBytes)
            } else {
                $percent = 0
                $status = "{0} downloaded" -f (Format-FileSize $downloaded)
            }
            Write-Progress -Id 1 -Activity "Downloading OpenSteamTool" -Status $status -PercentComplete $percent
        }
    } finally {
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if ($null -ne $responseStream) { $responseStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        Write-Progress -Id 1 -Activity "Downloading OpenSteamTool" -Completed
    }
}

function Get-OstDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]$OstConfig,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][string]$OfficialUrl
    )

    $templates = @(Get-ConfigValue -Object $OstConfig -Name "downloadUrlTemplates" -DefaultValue @("{official}"))
    $urls = @()
    foreach ($template in $templates) {
        $templateText = [string]$template
        if ([string]::IsNullOrWhiteSpace($templateText)) { continue }
        $url = $templateText.Replace("{repo}", $Repo).Replace("{tag}", $Tag).Replace("{asset}", $AssetName).Replace("{official}", $OfficialUrl)
        if ($url -notin $urls) { $urls += $url }
    }
    if ($OfficialUrl -notin $urls) { $urls += $OfficialUrl }
    return $urls
}

function Get-Sha256FromAssetDigest {
    param($Asset)

    if ($null -eq $Asset) { return "" }
    $digest = [string](Get-ObjectPropertyValue -Object $Asset -Name "digest")
    if ($digest -match '^(?i:sha256):([0-9a-f]{64})$') {
        return $Matches[1].ToLowerInvariant()
    }
    return ""
}

function Assert-OstDownloadSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadedPath,
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [Parameter(Mandatory = $true)][string]$OfficialUrl,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedSha256 = "",
        [string]$LogFile = ""
    )

    $downloadedSha256 = Get-FileSha256 -PathValue $DownloadedPath
    if ([string]::IsNullOrWhiteSpace($downloadedSha256)) {
        throw "Unable to calculate the downloaded OST SHA-256."
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        if ($downloadedSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
            throw ("OST SHA-256 mismatch. Expected {0}, received {1}." -f $ExpectedSha256, $downloadedSha256)
        }
        Write-Log -Message ("OST SHA-256 verified against GitHub release metadata: {0}" -f $downloadedSha256) -LogFile $LogFile
        return
    }

    if ($DownloadUrl -eq $OfficialUrl) {
        Write-Log -Message ("GitHub release metadata has no SHA-256 digest; official asset SHA-256: {0}" -f $downloadedSha256) -Level "WARN" -LogFile $LogFile
        return
    }

    $officialVerificationPath = "$DownloadedPath.official"
    try {
        Write-Log -Message "Release metadata has no SHA-256 digest; downloading the official asset for comparison." -Level "WARN" -LogFile $LogFile
        Invoke-DownloadFileWithProgress -Url $OfficialUrl -Destination $officialVerificationPath -TimeoutSeconds $TimeoutSeconds
        $officialSha256 = Get-FileSha256 -PathValue $officialVerificationPath
        if ([string]::IsNullOrWhiteSpace($officialSha256)) {
            throw "Unable to calculate the official OST SHA-256."
        }
        if ($downloadedSha256 -ne $officialSha256) {
            throw ("Mirror OST SHA-256 does not match the official asset. Mirror {0}, official {1}." -f $downloadedSha256, $officialSha256)
        }
        Write-Log -Message ("OST SHA-256 verified against the official asset: {0}" -f $downloadedSha256) -LogFile $LogFile
    } finally {
        if (Test-Path -LiteralPath $officialVerificationPath) {
            Remove-Item -LiteralPath $officialVerificationPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Expand-ZipArchiveWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Assert-SafeZipArchive -ZipPath $ZipPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Ensure-Directory -PathValue $DestinationPath
    $destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd("\") + "\"
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($archive.Entries)
        $total = [Math]::Max(1, $entries.Count)
        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]
            $relativePath = ([string]$entry.FullName).Replace("/", "\")
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relativePath))
            if (-not $targetPath.StartsWith($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "OST archive contains an unsafe path: $relativePath"
            }

            $percent = [int]((($index + 1) * 100) / $total)
            Write-Progress -Id 2 -Activity "Extracting OpenSteamTool" -Status $relativePath -PercentComplete $percent
            if ([string]::IsNullOrEmpty($entry.Name)) {
                Ensure-Directory -PathValue $targetPath
                continue
            }

            Ensure-Directory -PathValue (Split-Path -Parent $targetPath)
            $entryStream = $null
            $outputStream = $null
            try {
                $entryStream = $entry.Open()
                $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $entryStream.CopyTo($outputStream)
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
        }
    } finally {
        $archive.Dispose()
        Write-Progress -Id 2 -Activity "Extracting OpenSteamTool" -Completed
    }
}

function Get-OstSourceDirectoryFromGitHub {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $networkConfig = Get-ConfigValue -Object $Config -Name "network" -DefaultValue $null
    $repo = [string](Get-ConfigValue -Object $ostConfig -Name "githubRepo" -DefaultValue "OpenSteam001/OpenSteamTool")
    $timeoutSeconds = [int](Get-ConfigValue -Object $networkConfig -Name "timeoutSeconds" -DefaultValue 30)
    $cacheRoot = Join-Path $RunContext.TransactionDir "opensteamtools"
    Ensure-Directory -PathValue $cacheRoot

    $apiUrl = "https://api.github.com/repos/{0}/releases/latest" -f $repo
    Write-Log -Message ("Resolving latest OST release: {0}" -f $repo) -LogFile $RunContext.LogFile
    try {
        $release = Get-LatestOstRelease -Config $Config
    } catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        throw ("Unable to fetch the latest OST release: {0}" -f $detail)
    }

    $assetPattern = [string](Get-ConfigValue -Object $ostConfig -Name "assetPattern" -DefaultValue "*Release.zip")
    $asset = @($release.assets) | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
    if ($null -eq $asset) {
        $asset = @($release.assets) | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    }
    if ($null -eq $asset) {
        throw "No matching zip asset found in latest OST release."
    }

    $tagName = [string]$release.tag_name
    $officialDownloadUrl = [string]$asset.browser_download_url
    $expectedSha256 = Get-Sha256FromAssetDigest -Asset $asset
    $downloadUrls = @(Get-OstDownloadUrls `
        -OstConfig $ostConfig `
        -Repo $repo `
        -Tag $tagName `
        -AssetName ([string]$asset.name) `
        -OfficialUrl $officialDownloadUrl)
    $releaseRoot = Join-Path $cacheRoot "release"
    $zipPath = Join-Path $releaseRoot $asset.name
    $extractRoot = Join-Path $releaseRoot "extracted"
    Ensure-Directory -PathValue $releaseRoot

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        $partialPath = "$zipPath.partial"
        try {
            $downloaded = $false
            $errors = @()
            foreach ($downloadUrl in $downloadUrls) {
                try {
                    Write-Log -Message ("Downloading OST asset from: {0}" -f $downloadUrl) -LogFile $RunContext.LogFile
                    Invoke-DownloadFileWithProgress -Url $downloadUrl -Destination $partialPath -TimeoutSeconds $timeoutSeconds
                    if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf) -or (Get-Item -LiteralPath $partialPath).Length -eq 0) {
                        throw "Downloaded OST asset is empty."
                    }
                    Assert-OstDownloadSha256 `
                        -DownloadedPath $partialPath `
                        -DownloadUrl $downloadUrl `
                        -OfficialUrl $officialDownloadUrl `
                        -TimeoutSeconds $timeoutSeconds `
                        -ExpectedSha256 $expectedSha256 `
                        -LogFile $RunContext.LogFile
                    $downloaded = $true
                    break
                } catch {
                    $errors += ("{0}: {1}" -f $downloadUrl, $_.Exception.Message)
                    if (Test-Path -LiteralPath $partialPath) {
                        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    }
                    Write-Log -Message ("Download candidate failed: {0}" -f $_.Exception.Message) -Level "WARN" -LogFile $RunContext.LogFile
                }
            }
            if (-not $downloaded) {
                throw ("Unable to download OST asset from any configured source. {0}" -f ($errors -join " | "))
            }
            Move-Item -LiteralPath $partialPath -Destination $zipPath -Force
        } finally {
            if (Test-Path -LiteralPath $partialPath) {
                Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    Ensure-Directory -PathValue $extractRoot
    try {
        Expand-ZipArchiveWithProgress -ZipPath $zipPath -DestinationPath $extractRoot
    } catch {
        throw "OST archive is invalid or cannot be extracted: $($_.Exception.Message)"
    }

    Assert-OstSourceFiles -Config $Config -SourcePath $extractRoot
    return [pscustomobject]@{
        SourcePath    = $extractRoot
        Version       = $tagName
        PublishedDate = [string]$release.published_at
        AssetName     = [string]$asset.name
        Source        = "github-release"
    }
}

function Get-CachedOstSourceDirectory {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$CacheRoot
    )

    if (-not (Test-Path -LiteralPath $CacheRoot)) { return $null }
    $candidates = Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($candidate in $candidates) {
        $extractRoot = Join-Path $candidate.FullName "extracted"
        if (-not (Test-Path -LiteralPath $extractRoot -PathType Container)) { continue }
        try {
            Assert-OstSourceFiles -Config $Config -SourcePath $extractRoot
            $metadataPath = Join-Path $candidate.FullName "metadata.json"
            $metadata = $null
            if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            return [pscustomobject]@{
                SourcePath    = $extractRoot
                Version       = if ($null -ne $metadata) { [string]$metadata.version } else { $candidate.Name }
                PublishedDate = if ($null -ne $metadata) { [string]$metadata.publishedDate } else { "" }
                AssetName     = if ($null -ne $metadata) { [string]$metadata.assetName } else { "" }
                Source        = "validated-cache"
            }
        } catch {
            continue
        }
    }
    return $null
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [AllowEmptyString()][string]$BackupDir
    )

    if ([string]::IsNullOrWhiteSpace($BackupDir)) { throw "Backup directory is required." }
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return "" }

    Ensure-Directory -PathValue $BackupDir
    $backupName = "{0}-{1}" -f ([Guid]::NewGuid().ToString("N").Substring(0, 8)), (Split-Path -Leaf $SourceFile)
    $backupPath = Join-Path $BackupDir $backupName
    Copy-Item -LiteralPath $SourceFile -Destination $backupPath -Force
    if ((Get-FileSha256 -PathValue $SourceFile) -ne (Get-FileSha256 -PathValue $backupPath)) {
        throw "Backup verification failed: $SourceFile"
    }
    return $backupPath
}

function Set-OstManifestSourceInToml {
    param(
        [Parameter(Mandatory = $true)][string]$TomlPath,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $validSources = @("opensteamtool", "wudrm", "steamrun")
    if ($Source -notin $validSources) {
        throw ("Invalid manifest source: {0}. Valid: {1}" -f $Source, ($validSources -join ", "))
    }

    Ensure-Directory -PathValue (Split-Path -Parent $TomlPath)
    $line = 'url = "{0}"' -f $Source
    if (-not (Test-Path -LiteralPath $TomlPath)) {
        Set-Content -LiteralPath $TomlPath -Encoding UTF8 -Value @(
            "[manifest]",
            $line,
            "timeout_resolve_ms = 5000",
            "timeout_connect_ms = 5000",
            "timeout_send_ms    = 10000",
            "timeout_recv_ms    = 10000"
        )
        return
    }

    # Preserve an existing OpenSteamTool configuration supplied by the user.
    return
}

function Invoke-Check {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $steamPath = Get-SteamPath -Config $Config
    $kernelState = Get-OstKernelState -Config $Config -SteamPath $steamPath
    $remote = Get-LatestOstReleaseInfo -Config $Config -AllowFailure
    $steamCfg = Join-Path $steamPath "steam.cfg"
    $steamCfgBackup = Join-Path $steamPath "steam.cfg.bak"
    $cfgState = if ((Test-Path -LiteralPath $steamCfg) -and (Test-Path -LiteralPath $steamCfgBackup)) {
        "Conflict"
    } elseif (Test-Path -LiteralPath $steamCfg) {
        "Locked"
    } elseif (Test-Path -LiteralPath $steamCfgBackup) {
        "BackedUp"
    } else {
        "None"
    }
    if ($kernelState.Status -eq "Ready" -and $remote.Available -and (Test-VersionOlder -LocalVersion $kernelState.Version -RemoteVersion $remote.Version)) {
        $kernelState.Status = "UpdateAvailable"
    }
    if ([string]::IsNullOrWhiteSpace($kernelState.Version) -and $remote.Available -and
        -not [string]::IsNullOrWhiteSpace($kernelState.FileDate) -and
        $remote.PublishedDate.StartsWith($kernelState.FileDate)) {
        $kernelState.Version = $remote.Version
        $kernelState.Status = "ReadyByDate"
    }

    Write-UiLine
    Write-UiLine -Text "STEAMX Environment Status" -ForegroundColor Cyan
    Write-UiLine -Text ("{0,-14}{1}" -f "Steam Path", (Get-DisplayPath -PathValue $steamPath))
    $steamVersion = Get-SteamVersionInfo -SteamPath $steamPath
    $steamBuildDisplay = Format-DateStamp -DateValue $steamVersion.BuildDate
    if ([string]::IsNullOrWhiteSpace($steamBuildDisplay)) { $steamBuildDisplay = "unknown" }
    Write-UiLine -Text ("{0,-14}{1}" -f "Steam Build", $steamBuildDisplay)
    $localOstDisplay = if ([string]::IsNullOrWhiteSpace($kernelState.Version)) {
        Format-VersionWithDate -Version "" -DateValue $kernelState.FileDate
    } else {
        Format-VersionWithDate -Version $kernelState.Version -DateValue $kernelState.FileDate
    }
    $latestOstDisplay = if (-not $remote.Available) {
        "unavailable"
    } else {
        Format-VersionWithDate -Version $remote.Version -DateValue $remote.PublishedDate
    }
    Write-UiLine -Text ("{0,-14}{1} ({2})" -f "Local OST", $localOstDisplay, $kernelState.Status)
    Write-UiLine -Text ("{0,-14}{1}" -f "Latest OST", $latestOstDisplay)
    Write-UiLine -Text ("{0,-14}{1}" -f "Legacy Paths", $(if ($kernelState.LegacyPaths.Count -gt 0) { @($kernelState.LegacyPaths | ForEach-Object { Get-DisplayPath -PathValue $_ }) -join ", " } else { "none" }))
    if ($cfgState -ne "None") {
        Write-UiLine -Text ("{0,-14}{1}" -f "Steam.cfg", $cfgState)
    }
    Write-UiLine -Text ("{0,-14}{1}" -f "OST Config", (Get-DisplayPath -PathValue (Get-OstConfigPath -Config $Config -SteamPath $steamPath)))

    if (-not $remote.Available) {
        Write-Log -Message ("Remote OST status unavailable: {0}" -f $remote.Error) -Level "WARN" -LogFile $RunContext.LogFile
    }
}

function Invoke-DeployOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $steamPath = Get-SteamPath -Config $Config
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $package = Get-OstSourceDirectory -Config $Config -RunContext $RunContext
    $sourcePath = $package.SourcePath
    $files = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    $targetPathValue = [string](Get-ConfigValue -Object $ostConfig -Name "targetPath" -DefaultValue "")
    $targetPath = if ([string]::IsNullOrWhiteSpace($targetPathValue)) {
        $steamPath
    } else {
        Resolve-LocalPath -PathValue $targetPathValue -BasePath $steamPath
    }

    Ensure-Directory -PathValue $targetPath
    Ensure-Directory -PathValue $RunContext.BackupDir
    Ensure-Directory -PathValue $RunContext.TransactionDir

    $stagedFiles = @()
    foreach ($fileName in $files) {
        $sourceFile = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $sourceFile) {
            throw "Required OST file not found in source: $fileName"
        }
        $stagedFile = Join-Path $RunContext.TransactionDir $fileName
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $stagedFile -Force
        if ((Get-FileSha256 -PathValue $sourceFile.FullName) -ne (Get-FileSha256 -PathValue $stagedFile)) {
            throw "Staged OST file verification failed: $fileName"
        }
        $stagedFiles += [pscustomobject]@{
            Name       = $fileName
            SourcePath = $sourceFile.FullName
            StagedPath = $stagedFile
            TargetPath = Join-Path $targetPath $fileName
        }
    }

    if ([bool](Get-ConfigValue -Object $ostConfig -Name "requireSteamClosed" -DefaultValue $true)) {
        if ([bool](Get-ConfigValue -Object $ostConfig -Name "autoCloseSteam" -DefaultValue $true)) {
            Stop-SteamProcesses -Config $Config -RunContext $RunContext
        } elseif (@(Get-SteamRelatedProcesses).Count -gt 0) {
            throw ("Steam related processes are still running: {0}" -f (Get-SteamRunningSummary))
        }
    }

    $fileRecords = @()
    $steamCfgRecord = $null
    $steamCfgRenamedThisRun = $false
    $configRecord = $null
    try {
        $steamCfg = Join-Path $steamPath "steam.cfg"
        $steamCfgBak = Join-Path $steamPath "steam.cfg.bak"
        if ((Test-Path -LiteralPath $steamCfg) -and (Test-Path -LiteralPath $steamCfgBak)) {
            throw "Both steam.cfg and steam.cfg.bak exist. Resolve this conflict before deployment."
        }
        if (Test-Path -LiteralPath $steamCfg -PathType Leaf) {
            $steamCfgHash = Get-FileSha256 -PathValue $steamCfg
            Rename-Item -LiteralPath $steamCfg -NewName "steam.cfg.bak"
            $steamCfgRecord = [pscustomobject]@{
                renamed     = $true
                originalPath = $steamCfg
                backupPath   = $steamCfgBak
                sha256       = $steamCfgHash
            }
            $steamCfgRenamedThisRun = $true
            Write-Log -Message "Renamed steam.cfg to steam.cfg.bak." -LogFile $RunContext.LogFile
        }

        foreach ($item in $stagedFiles) {
            $targetExisted = Test-Path -LiteralPath $item.TargetPath -PathType Leaf
            $rollbackBackup = if ($targetExisted) { Backup-ExistingFile -SourceFile $item.TargetPath -BackupDir $RunContext.BackupDir } else { "" }
            Copy-Item -LiteralPath $item.StagedPath -Destination $item.TargetPath -Force
            $installedHash = Get-FileSha256 -PathValue $item.TargetPath
            if ($installedHash -ne (Get-FileSha256 -PathValue $item.StagedPath)) {
                throw "Deployed OST file verification failed: $($item.Name)"
            }
            $fileRecords += [pscustomobject]@{
                relativePath = $item.Name
                targetPath   = $item.TargetPath
                sha256       = $installedHash
                rollbackBackupPath = $rollbackBackup
            }
            Write-Log -Message ("Deployed: {0}" -f $item.TargetPath) -LogFile $RunContext.LogFile
        }

        $tomlPath = Get-OstConfigPath -Config $Config -SteamPath $steamPath
        $configExisted = Test-Path -LiteralPath $tomlPath -PathType Leaf
        $configRollbackBackup = if ($configExisted) { Backup-ExistingFile -SourceFile $tomlPath -BackupDir $RunContext.BackupDir } else { "" }
        Set-OstManifestSourceInToml -TomlPath $tomlPath -Source ([string](Get-ConfigValue -Object (Get-ConfigValue -Object $Config -Name "manifest" -DefaultValue $null) -Name "source" -DefaultValue "wudrm"))
        $configRecord = [pscustomobject]@{
            path       = $tomlPath
            rollbackBackupPath = $configRollbackBackup
            sha256     = Get-FileSha256 -PathValue $tomlPath
        }

        $kernelState = Get-OstKernelState -Config $Config -SteamPath $steamPath
        if (-not $kernelState.IsReady) {
            throw ("OST validation failed. Missing: {0}" -f ($kernelState.Missing -join ", "))
        }

    } catch {
        Write-Log -Message ("Deployment failed; rolling back: {0}" -f $_.Exception.Message) -Level "ERROR" -LogFile $RunContext.LogFile
        for ($index = $fileRecords.Count - 1; $index -ge 0; $index--) {
            $record = $fileRecords[$index]
            if (-not [string]::IsNullOrWhiteSpace([string]$record.rollbackBackupPath) -and (Test-Path -LiteralPath $record.rollbackBackupPath)) {
                Copy-Item -LiteralPath $record.rollbackBackupPath -Destination $record.targetPath -Force
            } elseif (Test-Path -LiteralPath $record.targetPath) {
                Remove-Item -LiteralPath $record.targetPath -Force
            }
        }
        if ($null -ne $configRecord) {
            if (-not [string]::IsNullOrWhiteSpace([string]$configRecord.rollbackBackupPath) -and (Test-Path -LiteralPath $configRecord.rollbackBackupPath)) {
                Copy-Item -LiteralPath $configRecord.rollbackBackupPath -Destination $configRecord.path -Force
            } elseif (-not $configExisted -and (Test-Path -LiteralPath $configRecord.path)) {
                Remove-Item -LiteralPath $configRecord.path -Force
            }
        }
        if ($steamCfgRenamedThisRun -and $null -ne $steamCfgRecord -and (Test-Path -LiteralPath $steamCfgRecord.backupPath) -and -not (Test-Path -LiteralPath $steamCfgRecord.originalPath)) {
            Rename-Item -LiteralPath $steamCfgRecord.backupPath -NewName "steam.cfg"
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $RunContext.TransactionDir) {
            Remove-Item -LiteralPath $RunContext.TransactionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $restartSteam = [bool](Get-ConfigValue -Object $ostConfig -Name "restartSteamAfterDeploy" -DefaultValue $true)
    if ($restartSteam) {
        Start-Steam -RunContext $RunContext -SteamPath $steamPath
    }
    $successMessage = if ($restartSteam) {
        ConvertFrom-Utf8Base64 "T1NUIOmDqOe9suaIkOWKn++8jFN0ZWFtIOato+WcqOiHquWKqOWQr+WKqOOAgg=="
    } else {
        ConvertFrom-Utf8Base64 "T1NUIOmDqOe9suaIkOWKn+OAgg=="
    }
    Write-Log -Message $successMessage -Level "SUCCESS" -LogFile $RunContext.LogFile
}

function Invoke-SetManifestSource {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        $manifestConfig = Get-ConfigValue -Object $Config -Name "manifest" -DefaultValue $null
        $Source = [string](Get-ConfigValue -Object $manifestConfig -Name "source" -DefaultValue "wudrm")
    }

    $steamPath = Get-SteamPath -Config $Config
    $tomlPath = Get-OstConfigPath -Config $Config -SteamPath $steamPath
    $backupPath = ""
    if (Test-Path -LiteralPath $tomlPath -PathType Leaf) {
        Ensure-Directory -PathValue $RunContext.BackupDir
        $backupPath = Backup-ExistingFile -SourceFile $tomlPath -BackupDir $RunContext.BackupDir
    }
    try {
        Set-OstManifestSourceInToml -TomlPath $tomlPath -Source $Source
        Write-Log -Message ("Manifest source set to: {0}" -f $Source) -LogFile $RunContext.LogFile
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($backupPath) -and (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $tomlPath -Force
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $RunContext.TransactionDir) {
            Remove-Item -LiteralPath $RunContext.TransactionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-EnableUnlockMode {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestSource)) {
        $manifestConfig = Get-ConfigValue -Object $Config -Name "manifest" -DefaultValue $null
        $manifestConfig.source = $ManifestSource
    }
    Invoke-DeployOst -Config $Config -RunContext $RunContext
}

function Confirm-DestructiveAction {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-UiLine
    Write-UiLine -Text $Message -ForegroundColor Yellow
    $answer = Read-UiInput -Prompt "Press Enter to continue, or type anything else to cancel"
    return ([string]::IsNullOrWhiteSpace($answer))
}

function Invoke-UninstallOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [switch]$RemoveLua
    )

    $steamPath = Get-SteamPath -Config $Config
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $cacheRootValue = [string](Get-ConfigValue -Object $ostConfig -Name "cacheRoot" -DefaultValue "./cache/opensteamtools")
    $cacheRoot = Resolve-LocalPath -PathValue $cacheRootValue -BasePath $RunContext.ScriptRoot
    $cachedPackage = Get-CachedOstSourceDirectory -Config $Config -CacheRoot $cacheRoot
    if ($null -eq $cachedPackage) {
        throw "No validated OST cache was found. Automatic uninstall cannot safely identify the installed files."
    }

    $legacyFileRecords = @()
    $configuredFiles = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    foreach ($fileName in $configuredFiles) {
        $targetFile = Join-Path $steamPath $fileName
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { continue }
        $sourceFile = Get-ChildItem -LiteralPath $cachedPackage.SourcePath -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $sourceFile -or (Get-FileSha256 -PathValue $targetFile) -ne (Get-FileSha256 -PathValue $sourceFile.FullName)) {
            throw "The installed file cannot be verified against the validated OST cache: $targetFile"
        }
        $legacyFileRecords += [pscustomobject]@{
            relativePath = $fileName
            targetPath   = $targetFile
            sha256       = Get-FileSha256 -PathValue $targetFile
            originalHash = ""
            backupPath   = ""
            existed      = $false
        }
    }
    if ($legacyFileRecords.Count -eq 0) {
        throw "No verified OST files were found in the Steam directory."
    }
    $uninstallPlan = [pscustomobject]@{
        files = @($legacyFileRecords)
    }

    $message = if ($RemoveLua) {
        "This will remove STEAMX-managed OST files and back up then clear Lua manifests in: {0}" -f (Join-Path $steamPath "config\lua")
    } else {
        "This will remove only STEAMX-managed OST files from: {0}" -f $steamPath
    }
    if (-not (Confirm-DestructiveAction -Message $message)) {
        Write-Log -Message "Uninstall cancelled by user." -Level "WARN" -LogFile $RunContext.LogFile
        return
    }

    Stop-SteamProcesses -Config $Config -RunContext $RunContext
    Ensure-Directory -PathValue $RunContext.BackupDir
    $warnings = @()

    foreach ($fileRecord in @($uninstallPlan.files)) {
        $targetFile = [string]$fileRecord.targetPath
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { continue }
        $currentHash = Get-FileSha256 -PathValue $targetFile
        if ($currentHash -ne [string]$fileRecord.sha256) {
            $warnings += "Skipped externally modified file: $targetFile"
            Write-Log -Message $warnings[-1] -Level "WARN" -LogFile $RunContext.LogFile
            continue
        }

        [void](Backup-ExistingFile -SourceFile $targetFile -BackupDir $RunContext.BackupDir)
        Remove-Item -LiteralPath $targetFile -Force
        if ([bool]$fileRecord.existed) {
            $originalBackup = [string]$fileRecord.backupPath
            if ([string]::IsNullOrWhiteSpace($originalBackup) -or -not (Test-Path -LiteralPath $originalBackup -PathType Leaf)) {
                $warnings += "Original backup is missing; cannot restore: $targetFile"
                Write-Log -Message $warnings[-1] -Level "WARN" -LogFile $RunContext.LogFile
            } else {
                Copy-Item -LiteralPath $originalBackup -Destination $targetFile -Force
                Write-Log -Message ("Restored original file: {0}" -f $targetFile) -LogFile $RunContext.LogFile
            }
        } else {
            Write-Log -Message ("Removed: {0}" -f $targetFile) -LogFile $RunContext.LogFile
        }
    }

    if ($RemoveLua) {
        $luaPath = Join-Path $steamPath "config\lua"
        $expectedLuaPath = [System.IO.Path]::GetFullPath((Join-Path $steamPath "config\lua"))
        $actualLuaPath = [System.IO.Path]::GetFullPath($luaPath)
        if ($actualLuaPath -ne $expectedLuaPath) {
            throw "Refusing to clear Lua path because it is not the default Steam config lua path: $luaPath"
        }

        if (Test-Path -LiteralPath $luaPath -PathType Container) {
            $luaItem = Get-Item -LiteralPath $luaPath -Force
            if (($luaItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to clear Lua path because it is a symbolic link or directory junction: $luaPath"
            }
            $luaBackup = Join-Path $RunContext.BackupDir "lua"
            Ensure-Directory -PathValue $luaBackup
            foreach ($item in @(Get-ChildItem -LiteralPath $luaPath -Force -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $item.FullName -Destination $luaBackup -Recurse -Force
            }
            foreach ($item in @(Get-ChildItem -LiteralPath $luaPath -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            }
            Write-Log -Message ("Cleared Lua manifests: {0}" -f $luaPath) -LogFile $RunContext.LogFile
        }
    }

    if ($warnings.Count -eq 0) {
        if ($RemoveLua) {
            Write-Log -Message ("Lua backup retained at: {0}" -f (Join-Path $RunContext.BackupDir "lua")) -Level "WARN" -LogFile $RunContext.LogFile
        } elseif (Test-Path -LiteralPath $RunContext.TransactionDir) {
            Remove-Item -LiteralPath $RunContext.TransactionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log -Message "Uninstall completed." -LogFile $RunContext.LogFile
    } else {
        Write-Log -Message ("Uninstall completed with warnings. {0}" -f ($warnings -join " | ")) -Level "WARN" -LogFile $RunContext.LogFile
    }
}

function Invoke-Menu {
    param([pscustomobject]$Config)

    Write-SteampXLogo
    $initialContext = New-RunContext -Config $Config
    try {
        Invoke-Check -Config $Config -RunContext $initialContext
    } catch {
        Write-UiLine -Text ("Environment check failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    while ($true) {
        Write-UiLine
        Write-UiLine -Text "----------------------------------------" -ForegroundColor DarkGray
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "MS4g5byA5ZCvIC8g5pu05paw6Kej6ZSB5qih5byP") -ForegroundColor White
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "Mi4g546v5aKD5qOA5rWL5LiO5L+u5aSN") -ForegroundColor White
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "My4g5ri45oiP5YWl5bqT77yI5byA5Y+R5Lit77yJ") -ForegroundColor DarkGray
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "NC4g57O757uf5LyY5YyW77yI5byA5Y+R5Lit77yJ") -ForegroundColor DarkGray
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "NS4g5Y246L29") -ForegroundColor White
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "Ni4g6LWe6LWP77yI5byA5Y+R5Lit77yJ") -ForegroundColor DarkGray
        Write-UiLine -Text (ConvertFrom-Utf8Base64 "MC4g6YCA5Ye6") -ForegroundColor White
        Write-UiLine

        $choice = Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "6K+36YCJ5oup")
        $runContext = New-RunContext -Config $Config

        if ($choice -eq "1") {
            Write-UiLine
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "U1RFQU1YIOWwhuS4i+i9veW5tuagoemqjCBPU1TjgIHlhbPpl60gU3RlYW3jgIHlpIfku73lubbpg6jnvbLmlofku7bvvIzlrozmiJDlkI7lj6rlkK/liqjkuIDmrKEgU3RlYW3jgII=") -ForegroundColor Yellow
            $answer = Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOe7p+e7re+8jOi+k+WFpeWFtuS7luWGheWuueWPlua2iA==")
            if ([string]::IsNullOrWhiteSpace($answer)) {
                Invoke-EnableUnlockMode -Config $Config -RunContext $runContext
            } else {
                Write-UiLine -Text (ConvertFrom-Utf8Base64 "5pON5L2c5bey5Y+W5raI44CC") -ForegroundColor Yellow
            }
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "2") {
            Invoke-Check -Config $Config -RunContext $runContext
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "3") {
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "5ri45oiP5YWl5bqT5Yqf6IO95byA5Y+R5Lit44CC") -ForegroundColor Yellow
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "4") {
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "57O757uf5LyY5YyW5Yqf6IO95byA5Y+R5Lit44CC") -ForegroundColor Yellow
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "5") {
            Write-UiLine
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "MS4g5LuF5Y246L29IE9TVA==") -ForegroundColor White
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "Mi4g5Y246L29IE9TVCDlubbmuIXnkIbmuLjmiI/muIXljZU=") -ForegroundColor White
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "MC4g6L+U5Zue") -ForegroundColor White
            $uninstallChoice = Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "6K+36YCJ5oup")
            if ($uninstallChoice -eq "1") {
                Invoke-UninstallOst -Config $Config -RunContext $runContext
            } elseif ($uninstallChoice -eq "2") {
                Invoke-UninstallOst -Config $Config -RunContext $runContext -RemoveLua
            }
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "6") {
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "6LWe6LWP5Yqf6IO95byA5Y+R5Lit44CC") -ForegroundColor Yellow
            Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJIEVudGVyIOi/lOWbnuiPnOWNlQ==") | Out-Null
        } elseif ($choice -eq "0") {
            return
        } else {
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "5peg5pWI6YCJ5oup44CC") -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $config = Get-Config -ConfigOverride $ConfigPath
        $runContext = New-RunContext -Config $config

        switch ($Command) {
            "Menu" { Invoke-Menu -Config $config }
            "Check" { Invoke-Check -Config $config -RunContext $runContext }
            "DeployOst" { Invoke-DeployOst -Config $config -RunContext $runContext }
            "EnableUnlockMode" { Invoke-EnableUnlockMode -Config $config -RunContext $runContext }
            "SetManifestSource" { Invoke-SetManifestSource -Config $config -RunContext $runContext -Source $ManifestSource }
            "UninstallOst" { Invoke-UninstallOst -Config $config -RunContext $runContext }
            "UninstallOstAndLua" { Invoke-UninstallOst -Config $config -RunContext $runContext -RemoveLua }
        }

    } catch {
        Write-UiLine -Text ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
