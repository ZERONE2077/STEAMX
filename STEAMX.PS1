[CmdletBinding()]
param(
    [ValidateSet("Menu", "Check", "DeployOst", "EnableUnlockMode", "SetManifestSource", "UninstallOst", "UninstallOstAndLua", "DownloadLua", "DownloadManifestHub")]
    [string]$Command = "Menu",
    [string]$AppId,
    [string]$Url,
    [string]$ApiKey,
    [string]$DepotId,
    [string]$ManifestId,
    [string]$ManifestSource,
    [string]$ConfigPath = "",
    [string]$ResultPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-ScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSteamxCommand {
    param(
        [pscustomobject]$Config,
        [Parameter(Mandatory = $true)][string]$ElevatedCommand,
        [string[]]$ExtraArguments = @(),
        [string]$Prompt = "This action requires administrator permission. Approve the UAC prompt to continue."
    )

    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $PSCommandPath
    } else {
        $MyInvocation.MyCommand.Path
    }

    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        throw "Cannot locate current script path for elevation."
    }

    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\{0}-result-{1}.json" -f $ElevatedCommand.ToLowerInvariant(), (Get-Timestamp))
    Ensure-Directory -PathValue (Split-Path -Parent $resultPath)

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $scriptPath),
        "-Command", $ElevatedCommand,
        "-ConfigPath", ('"{0}"' -f $Config.__configFile),
        "-ResultPath", ('"{0}"' -f $resultPath)
    )
    $arguments += $ExtraArguments

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Yellow
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        $detail = ""
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $detail = [string]$result.error
            } catch {
                $detail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8
            }
        }

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "No detail was returned. UAC may have been cancelled or the elevated process exited before writing a result file."
        }

        throw "Elevated $ElevatedCommand failed with exit code $($process.ExitCode). $detail"
    }

    Write-Host "Elevated action completed." -ForegroundColor Green
}

function Invoke-ElevatedDeployOst {
    param([pscustomobject]$Config)

    Invoke-ElevatedSteamxCommand `
        -Config $Config `
        -ElevatedCommand "DeployOst" `
        -Prompt "Deploy OST requires administrator permission. Approve the UAC prompt to continue."
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-Timestamp {
    return Get-Date -Format "yyyyMMdd-HHmmss"
}

function New-RunContext {
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)

    $scriptRoot = Get-ScriptRoot
    $configuredLogRoot = Get-ConfigValue -Object $Config -Name "logRoot" -DefaultValue ""
    $logRoot = if ([string]::IsNullOrWhiteSpace($configuredLogRoot)) {
        Join-Path ([System.IO.Path]::GetTempPath()) "STEAMX\logs"
    } else {
        Resolve-LocalPath -PathValue $configuredLogRoot -BasePath $scriptRoot
    }
    Ensure-Directory -PathValue $logRoot

    $runId = Get-Timestamp
    $backupDir = ""
    if ($Config.ost.backup -or $Config.lua.overwriteMode -eq "backup") {
        $configuredBackupRoot = Get-ConfigValue -Object $Config -Name "backupRoot" -DefaultValue ""
        $backupRoot = if ([string]::IsNullOrWhiteSpace($configuredBackupRoot)) {
            Join-Path ([System.IO.Path]::GetTempPath()) "STEAMX\backup"
        } else {
            Resolve-LocalPath -PathValue $configuredBackupRoot -BasePath $scriptRoot
        }
        Ensure-Directory -PathValue $backupRoot
        $backupDir = Join-Path $backupRoot $runId
        Ensure-Directory -PathValue $backupDir
    }

    return [pscustomobject]@{
        ScriptRoot = $scriptRoot
        LogFile    = Join-Path $logRoot ("steamx-{0}.log" -f $runId)
        BackupDir  = $backupDir
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [string]$LogFile = ""
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Write-GradientText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int[]]$From = @(45, 212, 255),
        [int[]]$To = @(110, 231, 183)
    )

    if ($env:NO_COLOR) {
        Write-Host $Text
        return
    }

    $chars = $Text.ToCharArray()
    $steps = [Math]::Max(1, $chars.Count - 1)
    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $t = $i / $steps
        $r = [int]($From[0] + (($To[0] - $From[0]) * $t))
        $g = [int]($From[1] + (($To[1] - $From[1]) * $t))
        $b = [int]($From[2] + (($To[2] - $From[2]) * $t))
        [void]$builder.Append("$([char]27)[38;2;$r;$g;${b}m$($chars[$i])")
    }
    [void]$builder.Append("$([char]27)[0m")
    Write-Host $builder.ToString()
}

function Write-RainbowText {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($env:NO_COLOR) {
        Write-Host $Text
        return
    }

    $palette = @(
        @(255, 214, 0),
        @(142, 255, 0),
        @(0, 255, 126),
        @(0, 191, 255),
        @(45, 106, 255),
        @(174, 61, 255),
        @(255, 36, 173),
        @(255, 68, 32),
        @(255, 170, 0)
    )

    $chars = $Text.ToCharArray()
    $steps = [Math]::Max(1, $chars.Count - 1)
    $segments = $palette.Count - 1
    $builder = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $chars.Count; $i++) {
        $position = ($i / $steps) * $segments
        $index = [Math]::Min([int][Math]::Floor($position), $segments - 1)
        $t = $position - $index
        $from = $palette[$index]
        $to = $palette[$index + 1]

        $r = [int]($from[0] + (($to[0] - $from[0]) * $t))
        $g = [int]($from[1] + (($to[1] - $from[1]) * $t))
        $b = [int]($from[2] + (($to[2] - $from[2]) * $t))
        [void]$builder.Append("$([char]27)[38;2;$r;$g;${b}m$($chars[$i])")
    }

    [void]$builder.Append("$([char]27)[0m")
    Write-Host $builder.ToString()
}

function Write-SteampXLogo {
    Clear-Host
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

        $lineBuilder = [System.Text.StringBuilder]::new()
        [void]$lineBuilder.Append($logoIndent)
        [void]$lineBuilder.Append("$([char]27)[38;2;$($blue[0]);$($blue[1]);$($blue[2])m$steamPart")
        [void]$lineBuilder.Append("$([char]27)[38;2;$($green[0]);$($green[1]);$($green[2])m$xPart")
        [void]$lineBuilder.Append($reset)
        Write-Host $lineBuilder.ToString()
    }

    Write-Host ""
    Write-Host "  OpenSteamTools deploy and Lua manifest helper" -ForegroundColor Gray
    Write-Host ""
}

function Get-Config {
    param([string]$ConfigOverride)

    $scriptRoot = Get-ScriptRoot
    $configFile = if ([string]::IsNullOrWhiteSpace($ConfigOverride)) {
        Join-Path $scriptRoot "steamx.config.json"
    } else {
        Resolve-LocalPath -PathValue $ConfigOverride -BasePath $scriptRoot
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "Config file not found: $configFile"
    }

    $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $config | Add-Member -NotePropertyName "__configFile" -NotePropertyValue $configFile -Force
    return $config
}

function Resolve-DisplayPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue)) {
        return $PathValue
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($PathValue)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($root)) {
            return $fullPath
        }

        $current = $root.TrimEnd('\')
        $relative = $fullPath.Substring($root.Length).Trim('\')
        if ([string]::IsNullOrWhiteSpace($relative)) {
            return $root
        }

        foreach ($part in ($relative -split '\\')) {
            $parent = if ($current.EndsWith(':')) { "$current\" } else { $current }
            $match = Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
                Where-Object { $_.Name -ieq $part } |
                Select-Object -First 1

            if ($null -eq $match) {
                $current = Join-Path $parent $part
            } else {
                $current = Join-Path $parent $match.Name
            }
        }

        return $current
    } catch {
        return $PathValue
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-LuaAppIdInput {
    param([string]$InputValue)

    if ([string]::IsNullOrWhiteSpace($InputValue)) {
        return $InputValue
    }

    $trimmed = $InputValue.Trim()
    if ($trimmed -match '^\d+$') {
        return $trimmed
    }

    $appMatch = [System.Text.RegularExpressions.Regex]::Match($trimmed, '(?i)store\.steampowered\.com/app/(\d+)')
    if ($appMatch.Success) {
        return $appMatch.Groups[1].Value
    }

    $subMatch = [System.Text.RegularExpressions.Regex]::Match($trimmed, '(?i)store\.steampowered\.com/sub/(\d+)')
    if ($subMatch.Success) {
        return $subMatch.Groups[1].Value
    }

    throw "Invalid AppId input. Provide a numeric AppId or a Steam store URL."
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
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $message
    }

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

function Get-OstSourceDirectory {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $sourceType = Get-ConfigValue -Object $Config.ost -Name "sourceType" -DefaultValue "local"

    if ($sourceType -eq "github-release") {
        return Get-OstSourceDirectoryFromGitHub -Config $Config -RunContext $RunContext
    }

    $localPath = Resolve-LocalPath -PathValue $Config.ost.sourcePath -BasePath $RunContext.ScriptRoot
    if (-not (Test-Path -LiteralPath $localPath)) {
        throw "OST local source path not found: $localPath"
    }

    return $localPath
}

function Get-OstSourceDirectoryFromGitHub {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $repo = [string](Get-ConfigValue -Object $Config.ost -Name "githubRepo" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($repo)) {
        throw "ost.githubRepo is empty in steamx.config.json."
    }

    $cacheRoot = Resolve-LocalPath -PathValue (Get-ConfigValue -Object $Config.ost -Name "cacheRoot" -DefaultValue "./cache/opensteamtools") -BasePath $RunContext.ScriptRoot
    Ensure-Directory -PathValue $cacheRoot

    $apiUrl = "https://api.github.com/repos/{0}/releases/latest" -f $repo
    Write-Log -Message ("Fetching latest OST release: {0}" -f $apiUrl) -LogFile $RunContext.LogFile
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers (Get-GitHubHeaders) -TimeoutSec ([int]$Config.network.timeoutSeconds)
    } catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        $cachedSource = Get-CachedOstSourceDirectory -CacheRoot $cacheRoot
        if (-not [string]::IsNullOrWhiteSpace($cachedSource)) {
            Write-Log -Message ("GitHub latest request failed: {0}" -f $detail) -Level "WARN" -LogFile $RunContext.LogFile
            Write-Log -Message ("Using cached OST extraction: {0}" -f $cachedSource) -Level "WARN" -LogFile $RunContext.LogFile
            return $cachedSource
        }

        throw $detail
    }

    $assetPattern = [string](Get-ConfigValue -Object $Config.ost -Name "assetPattern" -DefaultValue "*Release.zip")
    $assets = @($release.assets)
    $asset = $assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
    if ($null -eq $asset) {
        $asset = $assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    }
    if ($null -eq $asset) {
        throw "No matching zip asset found in latest OST release."
    }

    $tagName = [string]$release.tag_name
    $releaseRoot = Join-Path $cacheRoot $tagName
    $zipPath = Join-Path $releaseRoot $asset.name
    $extractRoot = Join-Path $releaseRoot "extracted"

    Ensure-Directory -PathValue $releaseRoot

    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Log -Message ("Downloading OST asset: {0}" -f $asset.browser_download_url) -LogFile $RunContext.LogFile
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers (Get-GitHubHeaders) -TimeoutSec ([int]$Config.network.timeoutSeconds)
    } else {
        Write-Log -Message ("Using cached OST asset: {0}" -f $zipPath) -LogFile $RunContext.LogFile
    }

    if (-not (Test-Path -LiteralPath $extractRoot)) {
        Ensure-Directory -PathValue $extractRoot
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
        Write-Log -Message ("Extracted OST asset to: {0}" -f $extractRoot) -LogFile $RunContext.LogFile
    } else {
        Write-Log -Message ("Using cached OST extraction: {0}" -f $extractRoot) -LogFile $RunContext.LogFile
    }

    return $extractRoot
}

function Get-CachedOstSourceDirectory {
    param([Parameter(Mandatory = $true)][string]$CacheRoot)

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "extracted") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return (Join-Path $candidate.FullName "extracted")
}

function Get-SteamPath {
    param([pscustomobject]$Config)

    if (-not [string]::IsNullOrWhiteSpace($Config.steamPath) -and (Test-Path -LiteralPath $Config.steamPath)) {
        return (Resolve-DisplayPath -PathValue $Config.steamPath)
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
            return (Resolve-DisplayPath -PathValue $candidate)
        }
    }

    throw "Steam path not found. Set steamPath in steamx.config.json."
}

function Get-LuaPath {
    param(
        [pscustomobject]$Config,
        [string]$SteamPath
    )

    if (-not [string]::IsNullOrWhiteSpace($Config.luaPath)) {
        return $Config.luaPath
    }

    return (Join-Path $SteamPath "config\lua")
}

function Get-SteamRelatedProcesses {
    $result = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessName -imatch "^steam" -and
                $_.ProcessName -notmatch "^steam\+\+"
            } |
            Sort-Object ProcessName, Id -Unique
    )
    return $result
}

function Get-SteamActiveProcessIdFromRegistry {
    foreach ($registryPath in @(
        "HKCU:\Software\Valve\Steam\ActiveProcess",
        "HKLM:\Software\WOW6432Node\Valve\Steam\ActiveProcess",
        "HKLM:\Software\Valve\Steam\ActiveProcess"
    )) {
        if (Test-Path $registryPath) {
            $item = Get-ItemProperty -Path $registryPath -Name "pid" -ErrorAction SilentlyContinue
            $pidValue = Get-ObjectPropertyValue -Object $item -Name "pid"
            if ($null -ne $pidValue -and [int]$pidValue -gt 0) {
                return [int]$pidValue
            }
        }
    }

    return $null
}

function Test-SteamRunning {
    $processes = @(Get-SteamRelatedProcesses)
    return $processes.Count -gt 0
}

function Get-SteamRunningSummary {
    $processes = @(Get-SteamRelatedProcesses)
    if ($processes.Count -eq 0) {
        return "False"
    }

    return ($processes | ForEach-Object { "{0}({1})" -f $_.ProcessName, $_.Id }) -join ", "
}

function Stop-SteamProcesses {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $processes = @(Get-SteamRelatedProcesses)
    if ($processes.Count -eq 0) {
        Write-Log -Message "No Steam related processes are running." -LogFile $RunContext.LogFile
        return
    }

    Write-Log -Message ("Stopping Steam related processes: {0}" -f (Get-SteamRunningSummary)) -Level "WARN" -LogFile $RunContext.LogFile

    $activePid = Get-SteamActiveProcessIdFromRegistry
    if ($null -ne $activePid) {
        $activeProcess = Get-Process -Id $activePid -ErrorAction SilentlyContinue
        if ($null -ne $activeProcess -and $activeProcess.ProcessName -imatch "^steam") {
            try {
                Stop-Process -Id $activePid -ErrorAction SilentlyContinue
                Write-Log -Message ("Requested stop for registry Steam pid: {0}({1})" -f $activeProcess.ProcessName, $activePid) -LogFile $RunContext.LogFile
            } catch {
                Write-Log -Message ("Registry Steam pid stop request failed for {0}: {1}" -f $activePid, $_.Exception.Message) -Level "WARN" -LogFile $RunContext.LogFile
            }
        }
    }

    $steamMainProcesses = @($processes | Where-Object { $_.ProcessName -eq "steam" })
    foreach ($process in $steamMainProcesses) {
        try {
            if ($process.MainWindowHandle -ne 0 -and $process.CloseMainWindow()) {
                Write-Log -Message ("Requested graceful close: {0}({1})" -f $process.ProcessName, $process.Id) -LogFile $RunContext.LogFile
            }
        } catch {
            Write-Log -Message ("Graceful close request failed for {0}({1}): {2}" -f $process.ProcessName, $process.Id, $_.Exception.Message) -Level "WARN" -LogFile $RunContext.LogFile
        }
    }

    Start-Sleep -Seconds 2

    $processes = @(Get-SteamRelatedProcesses)
    foreach ($process in $processes | Sort-Object Id -Descending) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Log -Message ("Stopped process: {0}({1})" -f $process.ProcessName, $process.Id) -LogFile $RunContext.LogFile
        } catch {
            $stillExists = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if ($null -eq $stillExists) {
                Write-Log -Message ("Process already exited: {0}({1})" -f $process.ProcessName, $process.Id) -LogFile $RunContext.LogFile
            } else {
                throw ("Failed to stop process {0}({1}): {2}" -f $process.ProcessName, $process.Id, $_.Exception.Message)
            }
        }
    }

    $waitSeconds = [int](Get-ConfigValue -Object $Config.ost -Name "steamShutdownTimeoutSeconds" -DefaultValue 15)
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-SteamRelatedProcesses)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw ("Steam related processes did not exit in time: {0}" -f (($remaining | ForEach-Object { "{0}({1})" -f $_.ProcessName, $_.Id }) -join ", "))
    }

    Write-Log -Message "All Steam related processes have been stopped." -LogFile $RunContext.LogFile
}

function Start-Steam {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$SteamPath
    )

    $steamExe = Join-Path $SteamPath "steam.exe"
    if (-not (Test-Path -LiteralPath $steamExe)) {
        throw "steam.exe not found: $steamExe"
    }

    Start-Process -FilePath $steamExe -WorkingDirectory $SteamPath | Out-Null
    Write-Log -Message ("Started Steam: {0}" -f $steamExe) -LogFile $RunContext.LogFile
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return
    }

    $fileName = Split-Path -Leaf $SourcePath
    $target = Join-Path $BackupRoot $fileName
    Copy-Item -LiteralPath $SourcePath -Destination $target -Force
}

function Invoke-Check {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $steamPath = Get-SteamPath -Config $Config
    $luaPath = Get-LuaPath -Config $Config -SteamPath $steamPath
    $sourceType = Get-ConfigValue -Object $Config.ost -Name "sourceType" -DefaultValue "local"
    $ostSource = if ($sourceType -eq "github-release") {
        "GitHub latest release: https://github.com/{0}/releases/latest" -f $Config.ost.githubRepo
    } else {
        Resolve-LocalPath -PathValue $Config.ost.sourcePath -BasePath $RunContext.ScriptRoot
    }
    $ostTarget = if ([string]::IsNullOrWhiteSpace($Config.ost.targetPath)) { $steamPath } else { $Config.ost.targetPath }

    Write-Log -Message ("Config file: {0}" -f $Config.__configFile) -LogFile $RunContext.LogFile
    Write-Log -Message ("Steam path: {0}" -f $steamPath) -LogFile $RunContext.LogFile
    Write-Log -Message ("Lua path: {0}" -f $luaPath) -LogFile $RunContext.LogFile
    Write-Log -Message ("Steam running: {0}" -f (Get-SteamRunningSummary)) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST source type: {0}" -f $sourceType) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST source path: {0}" -f $ostSource) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST target path: {0}" -f $ostTarget) -LogFile $RunContext.LogFile
    Write-Log -Message ("Lua URL template: {0}" -f $Config.lua.urlTemplate) -LogFile $RunContext.LogFile
}

function Get-SteamVersion {
    param([string]$SteamPath)

    $steamExe = Join-Path $SteamPath "steam.exe"
    if (-not (Test-Path -LiteralPath $steamExe)) {
        return "Unknown"
    }

    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($steamExe)
        if (-not [string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) {
            return $versionInfo.ProductVersion
        }
        if (-not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
            return $versionInfo.FileVersion
        }
    } catch {
    }

    return "Unknown"
}

function Get-SteamKernelState {
    param(
        [pscustomobject]$Config,
        [string]$SteamPath
    )

    $ostFiles = @($Config.ost.files) + @("opensteamtool.toml")
    $existingOstFiles = @(
        $ostFiles |
            Where-Object { Test-Path -LiteralPath (Join-Path $SteamPath $_) }
    )

    $knownKernelFiles = @(
        "version.dll",
        "user32.dll",
        "wtsapi32.dll",
        "hid.dll",
        "zlib1.dll",
        "steam_api.dll",
        "steam_api64.dll"
    )
    $otherKernelFiles = @(
        $knownKernelFiles |
            Where-Object { Test-Path -LiteralPath (Join-Path $SteamPath $_) }
    )

    $steamToolsPluginPath = Join-Path $SteamPath "config\stplug-in"
    $hasSteamToolsPlugin = Test-Path -LiteralPath $steamToolsPluginPath

    $kind = "None"
    if ($existingOstFiles.Count -gt 0) {
        $kind = "OpenSteamTools"
    } elseif ($hasSteamToolsPlugin -or $otherKernelFiles.Count -gt 0) {
        $kind = "SteamToolsOrOther"
    }

    return [pscustomobject]@{
        Kind                 = $kind
        OstFiles             = $existingOstFiles
        OtherKernelFiles     = $otherKernelFiles
        SteamToolsPluginPath = $steamToolsPluginPath
        HasSteamToolsPlugin  = $hasSteamToolsPlugin
    }
}

function Write-SteamUnlockSummary {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$SteamPath,
        [pscustomobject]$KernelState
    )

    $luaPath = Get-LuaPath -Config $Config -SteamPath $SteamPath
    Write-Log -Message ("Steam path: {0}" -f $SteamPath) -LogFile $RunContext.LogFile
    Write-Log -Message ("Steam version: {0}" -f (Get-SteamVersion -SteamPath $SteamPath)) -LogFile $RunContext.LogFile
    Write-Log -Message ("Lua path: {0}" -f $luaPath) -LogFile $RunContext.LogFile
    Write-Log -Message ("Kernel state: {0}" -f $KernelState.Kind) -LogFile $RunContext.LogFile

    if ($KernelState.OstFiles.Count -gt 0) {
        Write-Log -Message ("Existing OST files: {0}" -f ($KernelState.OstFiles -join ", ")) -LogFile $RunContext.LogFile
    }
    if ($KernelState.OtherKernelFiles.Count -gt 0) {
        Write-Log -Message ("Possible legacy kernel files: {0}" -f ($KernelState.OtherKernelFiles -join ", ")) -Level "WARN" -LogFile $RunContext.LogFile
    }
    if ($KernelState.HasSteamToolsPlugin) {
        Write-Log -Message ("SteamTools plugin directory found: {0}" -f $KernelState.SteamToolsPluginPath) -Level "WARN" -LogFile $RunContext.LogFile
    }
}

function Move-SteamToolsManifestsToLua {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$SteamPath
    )

    $sourceDir = Join-Path $SteamPath "config\stplug-in"
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        return
    }

    $luaPath = Get-LuaPath -Config $Config -SteamPath $SteamPath
    Ensure-Directory -PathValue $luaPath

    $files = @(
        Get-ChildItem -LiteralPath $sourceDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".lua", ".manifest") }
    )

    if ($files.Count -eq 0) {
        Write-Log -Message ("No Lua or manifest files found in: {0}" -f $sourceDir) -LogFile $RunContext.LogFile
        return
    }

    foreach ($file in $files) {
        $targetFile = Join-Path $luaPath $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $targetFile -Force
        Write-Log -Message ("Migrated: {0} -> {1}" -f $file.FullName, $targetFile) -LogFile $RunContext.LogFile
    }
}

function Get-ConfiguredManifestSource {
    param([pscustomobject]$Config)

    $manifestConfig = Get-ConfigValue -Object $Config -Name "manifest" -DefaultValue $null
    if ($null -ne $manifestConfig) {
        $source = [string](Get-ConfigValue -Object $manifestConfig -Name "source" -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            return $source
        }
    }

    return "wudrm"
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

    $line = 'url = "{0}"' -f $Source
    if (-not (Test-Path -LiteralPath $TomlPath)) {
        $content = @(
            "[manifest]",
            $line,
            "timeout_resolve_ms = 5000",
            "timeout_connect_ms = 5000",
            "timeout_send_ms    = 10000",
            "timeout_recv_ms    = 10000",
            "",
            "[stats]",
            "enable_api = true",
            "",
            "[lua]",
            "# paths = []"
        )
        Set-Content -LiteralPath $TomlPath -Value $content -Encoding UTF8
        return
    }

    $lines = @(Get-Content -LiteralPath $TomlPath -Encoding UTF8)
    $manifestStart = -1
    $manifestEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[manifest\]\s*$') {
            $manifestStart = $i
            continue
        }
        if ($manifestStart -ge 0 -and $i -gt $manifestStart -and $lines[$i] -match '^\s*\[.+\]\s*$') {
            $manifestEnd = $i
            break
        }
    }

    if ($manifestStart -lt 0) {
        $updated = @("[manifest]", $line, "") + $lines
        Set-Content -LiteralPath $TomlPath -Value $updated -Encoding UTF8
        return
    }

    $urlLineIndex = -1
    for ($i = $manifestStart + 1; $i -lt $manifestEnd; $i++) {
        if ($lines[$i] -match '^\s*url\s*=') {
            $urlLineIndex = $i
            break
        }
    }

    if ($urlLineIndex -ge 0) {
        $lines[$urlLineIndex] = $line
    } else {
        $before = if ($manifestStart -ge 0) { $lines[0..$manifestStart] } else { @() }
        $after = if ($manifestStart + 1 -lt $lines.Count) { $lines[($manifestStart + 1)..($lines.Count - 1)] } else { @() }
        $lines = @($before) + @($line) + @($after)
    }

    Set-Content -LiteralPath $TomlPath -Value $lines -Encoding UTF8
}

function Invoke-SetManifestSource {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        $Source = Get-ConfiguredManifestSource -Config $Config
    }

    $Source = $Source.Trim().ToLowerInvariant()
    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedSteamxCommand `
            -Config $Config `
            -ElevatedCommand "SetManifestSource" `
            -ExtraArguments @("-ManifestSource", $Source) `
            -Prompt "Manifest source setting requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $tomlPath = Join-Path $steamPath "opensteamtool.toml"
    Set-OstManifestSourceInToml -TomlPath $tomlPath -Source $Source
    Write-Log -Message ("Updated OST manifest source: {0} ({1})" -f $Source, $tomlPath) -LogFile $RunContext.LogFile
    Write-Host ("Manifest source updated: {0}" -f $Source) -ForegroundColor Green
}

function Invoke-EnableOrUpdateUnlockMode {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedSteamxCommand `
            -Config $Config `
            -ElevatedCommand "EnableUnlockMode" `
            -Prompt "Enable or update unlock mode requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $kernelState = Get-SteamKernelState -Config $Config -SteamPath $steamPath
    Write-SteamUnlockSummary -Config $Config -RunContext $RunContext -SteamPath $steamPath -KernelState $kernelState

    if ($kernelState.HasSteamToolsPlugin) {
        Move-SteamToolsManifestsToLua -Config $Config -RunContext $RunContext -SteamPath $steamPath
    }

    Invoke-DeployOst -Config $Config -RunContext $RunContext

    $manifestSource = Get-ConfiguredManifestSource -Config $Config
    $tomlPath = Join-Path $steamPath "opensteamtool.toml"
    Set-OstManifestSourceInToml -TomlPath $tomlPath -Source $manifestSource
    Write-Log -Message ("Ensured OST manifest source: {0}" -f $manifestSource) -LogFile $RunContext.LogFile
}

function Invoke-DeployOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedDeployOst -Config $Config
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $sourcePath = Get-OstSourceDirectory -Config $Config -RunContext $RunContext
    $targetPath = if ([string]::IsNullOrWhiteSpace($Config.ost.targetPath)) { $steamPath } else { $Config.ost.targetPath }

    if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath)) {
        throw "OST source path not found: $sourcePath"
    }

    Ensure-Directory -PathValue $targetPath

    if ($Config.ost.requireSteamClosed -and (Test-SteamRunning)) {
        if (Get-ConfigValue -Object $Config.ost -Name "autoCloseSteam" -DefaultValue $false) {
            Stop-SteamProcesses -Config $Config -RunContext $RunContext
        } else {
            throw ("Steam related processes are still running: {0}. Close all Steam processes before deploying OST." -f (Get-SteamRunningSummary))
        }
    }

    foreach ($fileName in $Config.ost.files) {
        $sourceFile = Join-Path $sourcePath $fileName
        if (-not (Test-Path -LiteralPath $sourceFile)) {
            $matched = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter $fileName | Select-Object -First 1
            if ($matched) {
                $sourceFile = $matched.FullName
            }
        }
        $targetFile = Join-Path $targetPath $fileName

        if (-not (Test-Path -LiteralPath $sourceFile)) {
            throw "Missing OST file: $sourceFile"
        }

        if ($Config.ost.backup -and (Test-Path -LiteralPath $targetFile)) {
            Backup-ExistingFile -SourcePath $targetFile -BackupRoot $RunContext.BackupDir
            Write-Log -Message ("Backed up: {0}" -f $targetFile) -LogFile $RunContext.LogFile
        }

        Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force:$Config.ost.overwrite
        Write-Log -Message ("Copied: {0} -> {1}" -f $sourceFile, $targetFile) -LogFile $RunContext.LogFile
    }

    Write-Log -Message ("OST deployment completed successfully to: {0}" -f $targetPath) -LogFile $RunContext.LogFile
    Write-Host ""
    Write-Host ("OST deployment completed successfully.`nTarget: {0}" -f $targetPath) -ForegroundColor Green

    if (Get-ConfigValue -Object $Config.ost -Name "restartSteamAfterDeploy" -DefaultValue $true) {
        Start-Steam -Config $Config -RunContext $RunContext -SteamPath $steamPath
        Write-Host "Steam has been restarted." -ForegroundColor Green
    }
}

function Get-LuaDownloadUrl {
    param(
        [pscustomobject]$Config,
        [string]$AppId,
        [string]$DirectUrl
    )

    if (-not [string]::IsNullOrWhiteSpace($DirectUrl)) {
        return $DirectUrl
    }

    $resolvedAppId = Resolve-LuaAppIdInput -InputValue $AppId

    if ([string]::IsNullOrWhiteSpace($resolvedAppId)) {
        throw "Provide -AppId or -Url."
    }

    if ([string]::IsNullOrWhiteSpace($Config.lua.urlTemplate)) {
        throw "lua.urlTemplate is empty in steamx.config.json."
    }

    return $Config.lua.urlTemplate.Replace("{appid}", $resolvedAppId)
}

function Get-LuaFileName {
    param(
        [pscustomobject]$Config,
        [string]$AppId,
        [string]$DirectUrl
    )

    $resolvedAppId = Resolve-LuaAppIdInput -InputValue $AppId

    if (-not [string]::IsNullOrWhiteSpace($resolvedAppId) -and -not [string]::IsNullOrWhiteSpace($Config.lua.fileNameTemplate)) {
        return $Config.lua.fileNameTemplate.Replace("{appid}", $resolvedAppId)
    }

    if (-not [string]::IsNullOrWhiteSpace($DirectUrl)) {
        $leaf = Split-Path -Leaf ([Uri]$DirectUrl).AbsolutePath
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            return $leaf
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedAppId)) {
        return "$resolvedAppId.lua"
    }

    return "manifest.lua"
}

function Invoke-DownloadLua {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$AppId,
        [string]$DirectUrl
    )

    $steamPath = Get-SteamPath -Config $Config
    $luaPath = Get-LuaPath -Config $Config -SteamPath $steamPath
    $downloadUrl = Get-LuaDownloadUrl -Config $Config -AppId $AppId -DirectUrl $DirectUrl
    $fileName = Get-LuaFileName -Config $Config -AppId $AppId -DirectUrl $DirectUrl
    $targetFile = Join-Path $luaPath $fileName

    if ($Config.lua.requireSteamClosed -and (Test-SteamRunning)) {
        throw ("Steam related processes are still running: {0}. Close all Steam processes before writing Lua files." -f (Get-SteamRunningSummary))
    }

    Ensure-Directory -PathValue $luaPath

    if ($Config.lua.overwriteMode -eq "backup" -and (Test-Path -LiteralPath $targetFile)) {
        Backup-ExistingFile -SourcePath $targetFile -BackupRoot $RunContext.BackupDir
        Write-Log -Message ("Backed up: {0}" -f $targetFile) -LogFile $RunContext.LogFile
    } elseif ($Config.lua.overwriteMode -eq "skip" -and (Test-Path -LiteralPath $targetFile)) {
        Write-Log -Message ("Skipped existing Lua file: {0}" -f $targetFile) -Level "WARN" -LogFile $RunContext.LogFile
        return
    }

    $headers = @{}
    if ($Config.lua.headers) {
        foreach ($property in $Config.lua.headers.PSObject.Properties) {
            $headers[$property.Name] = [string]$property.Value
        }
    }

    $invokeParams = @{
        Uri         = $downloadUrl
        OutFile     = $targetFile
        TimeoutSec  = [int]$Config.network.timeoutSeconds
        ErrorAction = "Stop"
    }

    if ($headers.Count -gt 0) {
        $invokeParams.Headers = $headers
    }

    Invoke-WebRequest @invokeParams | Out-Null
    Write-Log -Message ("Downloaded: {0} -> {1}" -f $downloadUrl, $targetFile) -LogFile $RunContext.LogFile

    if ($Config.lua.validateFileExtension -and ([System.IO.Path]::GetExtension($targetFile) -ne ".lua")) {
        throw "Downloaded file does not end with .lua: $targetFile"
    }
}

function Resolve-ManifestHubDownloadUrl {
    param(
        [string]$InputValue,
        [string]$ResolvedApiKey,
        [string]$ResolvedDepotId,
        [string]$ResolvedManifestId
    )

    if (-not [string]::IsNullOrWhiteSpace($InputValue)) {
        $trimmed = $InputValue.Trim()
        if ($trimmed -match '^https?://') {
            return $trimmed
        }

        if ([string]::IsNullOrWhiteSpace($ResolvedApiKey)) {
            $ResolvedApiKey = $trimmed
        }
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedApiKey)) {
        throw "ManifestHub API key is required."
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedDepotId)) {
        throw "DepotId is required."
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedManifestId)) {
        throw "ManifestId is required."
    }

    $encodedApiKey = [System.Uri]::EscapeDataString($ResolvedApiKey.Trim())
    $encodedDepotId = [System.Uri]::EscapeDataString($ResolvedDepotId.Trim())
    $encodedManifestId = [System.Uri]::EscapeDataString($ResolvedManifestId.Trim())

    return "https://api.manifesthub1.filegear-sg.me/manifest?apikey=$encodedApiKey&depotid=$encodedDepotId&manifestid=$encodedManifestId"
}

function Get-ManifestHubFileName {
    param(
        [string]$DirectUrl,
        [string]$ResolvedDepotId,
        [string]$ResolvedManifestId
    )

    if (-not [string]::IsNullOrWhiteSpace($DirectUrl) -and $DirectUrl -match '^https?://') {
        try {
            $uri = [Uri]$DirectUrl
            $queryDepotMatch = [System.Text.RegularExpressions.Regex]::Match($uri.Query, '(?i)(?:\?|&)depotid=([^&]+)')
            $queryManifestMatch = [System.Text.RegularExpressions.Regex]::Match($uri.Query, '(?i)(?:\?|&)manifestid=([^&]+)')
            $queryDepotId = if ($queryDepotMatch.Success) { [System.Uri]::UnescapeDataString($queryDepotMatch.Groups[1].Value) } else { "" }
            $queryManifestId = if ($queryManifestMatch.Success) { [System.Uri]::UnescapeDataString($queryManifestMatch.Groups[1].Value) } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($queryDepotId) -and -not [string]::IsNullOrWhiteSpace($queryManifestId)) {
                return "{0}_{1}.manifest" -f $queryDepotId, $queryManifestId
            }

            $leaf = Split-Path -Leaf $uri.AbsolutePath
            if (-not [string]::IsNullOrWhiteSpace($leaf) -and $leaf -match '\.manifest$') {
                return $leaf
            }
        } catch {
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedDepotId) -and -not [string]::IsNullOrWhiteSpace($ResolvedManifestId)) {
        return "{0}_{1}.manifest" -f $ResolvedDepotId.Trim(), $ResolvedManifestId.Trim()
    }

    return "manifesthub.manifest"
}

function Invoke-DownloadManifestHub {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$InputValue,
        [string]$ManifestHubApiKey,
        [string]$ManifestHubDepotId,
        [string]$ManifestHubManifestId
    )

    $steamPath = Get-SteamPath -Config $Config
    $luaPath = Get-LuaPath -Config $Config -SteamPath $steamPath
    Ensure-Directory -PathValue $luaPath

    $resolvedApiKey = $ManifestHubApiKey
    if ([string]::IsNullOrWhiteSpace($resolvedApiKey)) {
        $manifestHubConfig = Get-ConfigValue -Object $Config -Name "manifestHub" -DefaultValue $null
        if ($null -ne $manifestHubConfig) {
            $resolvedApiKey = [string](Get-ConfigValue -Object $manifestHubConfig -Name "apiKey" -DefaultValue "")
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedApiKey) -and -not [string]::IsNullOrWhiteSpace($env:MANIFESTHUB_API_KEY)) {
        $resolvedApiKey = $env:MANIFESTHUB_API_KEY
    }

    $downloadUrl = Resolve-ManifestHubDownloadUrl `
        -InputValue $InputValue `
        -ResolvedApiKey $resolvedApiKey `
        -ResolvedDepotId $ManifestHubDepotId `
        -ResolvedManifestId $ManifestHubManifestId

    $fileName = Get-ManifestHubFileName `
        -DirectUrl $downloadUrl `
        -ResolvedDepotId $ManifestHubDepotId `
        -ResolvedManifestId $ManifestHubManifestId

    $targetFile = Join-Path $luaPath $fileName
    $invokeParams = @{
        Uri         = $downloadUrl
        OutFile     = $targetFile
        TimeoutSec  = [int]$Config.network.timeoutSeconds
        Headers     = @{ "User-Agent" = "STEAMX" }
        ErrorAction = "Stop"
    }

    Invoke-WebRequest @invokeParams | Out-Null
    Write-Log -Message ("Downloaded ManifestHub manifest: {0} -> {1}" -f $downloadUrl, $targetFile) -LogFile $RunContext.LogFile
    Write-Host ("Manifest downloaded to: {0}" -f $targetFile) -ForegroundColor Green
}

function Invoke-DownloadGameManifestByAppId {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [string]$GameId
    )

    if ([string]::IsNullOrWhiteSpace($Config.lua.urlTemplate)) {
        throw (New-Text @(0x5F53, 0x524D, 0x672A, 0x914D, 0x7F6E, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x4E0B, 0x8F7D, 0x6E90, 0x3002, 0x004D, 0x0061, 0x006E, 0x0069, 0x0066, 0x0065, 0x0073, 0x0074, 0x0048, 0x0075, 0x0062, 0x0020, 0x516C, 0x5F00, 0x0020, 0x0041, 0x0050, 0x0049, 0x0020, 0x9700, 0x8981, 0x0020, 0x0064, 0x0065, 0x0070, 0x006F, 0x0074, 0x0069, 0x0064, 0x0020, 0x002B, 0x0020, 0x006D, 0x0061, 0x006E, 0x0069, 0x0066, 0x0065, 0x0073, 0x0074, 0x0069, 0x0064, 0xFF0C, 0x4E0D, 0x80FD, 0x53EA, 0x9760, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x4E0B, 0x8F7D, 0x5B8C, 0x6574, 0x6E38, 0x620F, 0x6E05, 0x5355, 0x3002, 0x8BF7, 0x5148, 0x5728, 0x0020, 0x0073, 0x0074, 0x0065, 0x0061, 0x006D, 0x0078, 0x002E, 0x0063, 0x006F, 0x006E, 0x0066, 0x0069, 0x0067, 0x002E, 0x006A, 0x0073, 0x006F, 0x006E, 0x0020, 0x7684, 0x0020, 0x006C, 0x0075, 0x0061, 0x002E, 0x0075, 0x0072, 0x006C, 0x0054, 0x0065, 0x006D, 0x0070, 0x006C, 0x0061, 0x0074, 0x0065, 0x0020, 0x914D, 0x7F6E, 0x4E00, 0x4E2A, 0x652F, 0x6301, 0x0020, 0x007B, 0x0061, 0x0070, 0x0070, 0x0069, 0x0064, 0x007D, 0x0020, 0x7684, 0x0020, 0x004C, 0x0075, 0x0061, 0x0020, 0x4E0B, 0x8F7D, 0x63A5, 0x53E3, 0x3002))
    }

    Invoke-DownloadLua -Config $Config -RunContext $RunContext -AppId $GameId -DirectUrl ""
}

function Confirm-DestructiveAction {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ExpectedInput = "YES"
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    $answer = Read-Host ("Type {0} to continue" -f $ExpectedInput)
    return ($answer -ceq $ExpectedInput)
}

function Invoke-UninstallOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [switch]$RemoveLua
    )

    if (-not (Test-IsAdministrator)) {
        $elevatedCommand = if ($RemoveLua) { "UninstallOstAndLua" } else { "UninstallOst" }
        Invoke-ElevatedSteamxCommand `
            -Config $Config `
            -ElevatedCommand $elevatedCommand `
            -Prompt "Uninstall requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $files = @($Config.ost.files) + @("opensteamtool.toml")

    if ($RemoveLua) {
        $luaPath = Get-LuaPath -Config $Config -SteamPath $steamPath
        $expectedLuaPath = Join-Path $steamPath "config\lua"
        $fullLuaPath = [System.IO.Path]::GetFullPath($luaPath)
        $fullExpectedLuaPath = [System.IO.Path]::GetFullPath($expectedLuaPath)

        if ($fullLuaPath -ne $fullExpectedLuaPath) {
            throw "Refusing to clear Lua path because it is not the default Steam config lua path: $luaPath"
        }

        if (-not (Confirm-DestructiveAction -Message ("This will remove OST files and clear all Lua manifests in: {0}" -f $luaPath))) {
            Write-Log -Message "Uninstall cancelled by user." -Level "WARN" -LogFile $RunContext.LogFile
            return
        }
    } else {
        if (-not (Confirm-DestructiveAction -Message ("This will remove OST kernel files from: {0}" -f $steamPath))) {
            Write-Log -Message "Uninstall cancelled by user." -Level "WARN" -LogFile $RunContext.LogFile
            return
        }
    }

    foreach ($fileName in $files) {
        $targetFile = Join-Path $steamPath $fileName
        if (Test-Path -LiteralPath $targetFile) {
            Remove-Item -LiteralPath $targetFile -Force
            Write-Log -Message ("Removed: {0}" -f $targetFile) -LogFile $RunContext.LogFile
        }
    }

    if ($RemoveLua) {
        $luaPath = Get-LuaPath -Config $Config -SteamPath $steamPath
        if (Test-Path -LiteralPath $luaPath) {
            Get-ChildItem -LiteralPath $luaPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force
            Write-Log -Message ("Cleared Lua manifests: {0}" -f $luaPath) -LogFile $RunContext.LogFile
        }
    }

    Write-Host ""
    Write-Host "Uninstall completed." -ForegroundColor Green
}

function New-Text {
    param([Parameter(Mandatory = $true)][int[]]$CodePoints)

    return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Get-MenuItems {
    param([Parameter(Mandatory = $true)][string]$MenuName)

    switch ($MenuName) {
        "Main" {
            return @(
                [pscustomobject]@{ Label = New-Text @(0x4E00, 0x952E, 0x0020, 0x5F00, 0x542F, 0x002F, 0x66F4, 0x65B0, 0x0020, 0x89E3, 0x9501, 0x6A21, 0x5F0F); Command = "EnableUnlockMode" },
                [pscustomobject]@{ Label = New-Text @(0x6DFB, 0x52A0, 0x6E38, 0x620F); Command = "AddGameMenu" },
                [pscustomobject]@{ Label = New-Text @(0x8BBE, 0x7F6E); Command = "SettingsMenu" },
                [pscustomobject]@{ Label = New-Text @(0x9000, 0x51FA); Command = "Exit" }
            )
        }
        "AddGame" {
            return @(
                [pscustomobject]@{ Label = New-Text @(0x6309, 0x6E38, 0x620F, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x4E0B, 0x8F7D, 0x6E05, 0x5355); Command = "DownloadGameByAppId" },
                [pscustomobject]@{ Label = New-Text @(0x624B, 0x52A8, 0x6DFB, 0x52A0); Command = "ManualAdd" },
                [pscustomobject]@{ Label = New-Text @(0x0053, 0x0054, 0x0045, 0x0041, 0x004D, 0x0058, 0x0020, 0x5E02, 0x573A, 0xFF08, 0x5F00, 0x53D1, 0x4E2D, 0xFF0C, 0x656C, 0x8BF7, 0x671F, 0x5F85, 0xFF09); Command = "SteamxMarket" },
                [pscustomobject]@{ Label = New-Text @(0x8FD4, 0x56DE); Command = "Back" }
            )
        }
        "ManualAdd" {
            return @(
                [pscustomobject]@{ Label = New-Text @(0x6309, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x4E0B, 0x8F7D, 0x0020, 0x004C, 0x0075, 0x0061); Command = "DownloadLuaByAppId" },
                [pscustomobject]@{ Label = New-Text @(0x6309, 0x0020, 0x0055, 0x0052, 0x004C, 0x0020, 0x4E0B, 0x8F7D, 0x0020, 0x004C, 0x0075, 0x0061); Command = "DownloadLuaByUrl" },
                [pscustomobject]@{ Label = New-Text @(0x8FD4, 0x56DE); Command = "Back" }
            )
        }
        "Settings" {
            return @(
                [pscustomobject]@{ Label = New-Text @(0x6E05, 0x5355, 0x6E90, 0x8BBE, 0x7F6E); Command = "SetManifestSource" },
                [pscustomobject]@{ Label = New-Text @(0x4E91, 0x5B58, 0x6863, 0x8BBE, 0x7F6E, 0xFF08, 0x5F00, 0x53D1, 0x4E2D, 0xFF09); Command = "CloudSaveSettings" },
                [pscustomobject]@{ Label = New-Text @(0x5378, 0x8F7D); Command = "UninstallMenu" },
                [pscustomobject]@{ Label = New-Text @(0x8FD4, 0x56DE); Command = "Back" }
            )
        }
        "Uninstall" {
            return @(
                [pscustomobject]@{ Label = New-Text @(0x5378, 0x8F7D, 0x0020, 0x004F, 0x0053, 0x0054, 0x0020, 0x5185, 0x6838); Command = "UninstallOst" },
                [pscustomobject]@{ Label = New-Text @(0x5378, 0x8F7D, 0x0020, 0x004F, 0x0053, 0x0054, 0x0020, 0x5185, 0x6838, 0x0020, 0x002B, 0x0020, 0x6240, 0x6709, 0x6E38, 0x620F, 0x6E05, 0x5355); Command = "UninstallOstAndLua" },
                [pscustomobject]@{ Label = New-Text @(0x8FD4, 0x56DE); Command = "Back" }
            )
        }
        default {
            throw "Unknown menu: $MenuName"
        }
    }
}

function Get-ConsoleTextWidth {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    $width = 0
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($enumerator.MoveNext()) {
        $element = [string]$enumerator.Current
        if ([string]::IsNullOrEmpty($element)) {
            continue
        }

        $codePoint = if ($element.Length -ge 2 -and [char]::IsHighSurrogate($element[0])) {
            [char]::ConvertToUtf32($element[0], $element[1])
        } else {
            [int][char]$element[0]
        }

        if ($codePoint -lt 0x20) {
            continue
        }

        $isWide = (
            ($codePoint -ge 0x1100 -and $codePoint -le 0x115F) -or
            ($codePoint -ge 0x2E80 -and $codePoint -le 0xA4CF) -or
            ($codePoint -ge 0xAC00 -and $codePoint -le 0xD7A3) -or
            ($codePoint -ge 0xF900 -and $codePoint -le 0xFAFF) -or
            ($codePoint -ge 0xFE10 -and $codePoint -le 0xFE19) -or
            ($codePoint -ge 0xFE30 -and $codePoint -le 0xFE6F) -or
            ($codePoint -ge 0xFF00 -and $codePoint -le 0xFF60) -or
            ($codePoint -ge 0xFFE0 -and $codePoint -le 0xFFE6) -or
            ($codePoint -ge 0x1F300 -and $codePoint -le 0x1FAFF)
        )

        $width += if ($isWide) { 2 } else { 1 }
    }

    return $width
}

function Format-ConsoleLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $safeWidth = [Math]::Max(1, $Width)
    $textWidth = Get-ConsoleTextWidth -Text $Text
    if ($textWidth -ge $safeWidth) {
        return $Text
    }

    return $Text + (" " * ($safeWidth - $textWidth))
}

function Set-ConsoleCursorPositionSafe {
    param(
        [Parameter(Mandatory = $true)][int]$Left,
        [Parameter(Mandatory = $true)][int]$Top
    )

    $safeLeft = [Math]::Max(0, [Math]::Min($Left, [Console]::BufferWidth - 1))
    if ($Top -lt 0 -or $Top -ge [Console]::BufferHeight) {
        return $false
    }

    [Console]::SetCursorPosition($safeLeft, $Top)
    return $true
}

function Render-MenuItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][int]$SelectedIndex,
        [Parameter(Mandatory = $true)][int]$Top
    )

    $width = [Math]::Max(80, [Console]::WindowWidth - 1)
    for ($index = 0; $index -lt $Items.Count; $index++) {
        if (-not (Set-ConsoleCursorPositionSafe -Left 0 -Top ($Top + $index))) {
            continue
        }

        $prefix = if ($index -eq $SelectedIndex) { ">" } else { " " }
        $line = Format-ConsoleLine -Text ("  {0} {1}. {2}" -f $prefix, ($index + 1), $Items[$index].Label) -Width $width

        if ($index -eq $SelectedIndex) {
            if ($env:NO_COLOR) {
                $oldForeground = [Console]::ForegroundColor
                $oldBackground = [Console]::BackgroundColor
                try {
                    [Console]::ForegroundColor = [ConsoleColor]::Black
                    [Console]::BackgroundColor = [ConsoleColor]::Green
                    [Console]::Write($line)
                } finally {
                    [Console]::ForegroundColor = $oldForeground
                    [Console]::BackgroundColor = $oldBackground
                }
            } else {
                [Console]::Write("$([char]27)[30;48;2;34;197;94m$line$([char]27)[0m")
            }
        } else {
            $oldForeground = [Console]::ForegroundColor
            try {
                [Console]::ForegroundColor = [ConsoleColor]::Gray
                [Console]::Write($line)
            } finally {
                [Console]::ForegroundColor = $oldForeground
            }
        }
    }

    for ($offset = 0; $offset -lt 3; $offset++) {
        if (-not (Set-ConsoleCursorPositionSafe -Left 0 -Top ($Top + $Items.Count + $offset))) {
            continue
        }

        [Console]::Write(" " * $width)
    }
}

function Read-MenuSelection {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [string]$Subtitle = ""
    )

    Write-SteampXLogo
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host ("  {0}" -f $Subtitle) -ForegroundColor Gray
        Write-Host ""
    }

    Write-Host ("  {0}" -f (New-Text @(0x4F7F, 0x7528, 0x0020, 0x2191, 0x002F, 0x2193, 0x0020, 0x9009, 0x62E9, 0xFF0C, 0x0045, 0x006E, 0x0074, 0x0065, 0x0072, 0x0020, 0x6267, 0x884C, 0xFF0C, 0x0045, 0x0073, 0x0063, 0x0020, 0x8FD4, 0x56DE, 0x3002))) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host ""

    $selectedIndex = 0
    $menuTop = [Console]::CursorTop
    if (($menuTop + $Items.Count + 2) -ge [Console]::BufferHeight) {
        Clear-Host
        $menuTop = 0
    }

    $cursorVisible = [Console]::CursorVisible
    $lastWindowWidth = [Console]::WindowWidth
    $lastWindowHeight = [Console]::WindowHeight

    try {
        [Console]::CursorVisible = $false
        Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop

        while ($true) {
            [void](Set-ConsoleCursorPositionSafe -Left 0 -Top ([Math]::Min([Console]::BufferHeight - 1, $menuTop + $Items.Count + 2)))
            $key = [Console]::ReadKey($true)

            if ($lastWindowWidth -ne [Console]::WindowWidth -or $lastWindowHeight -ne [Console]::WindowHeight) {
                $lastWindowWidth = [Console]::WindowWidth
                $lastWindowHeight = [Console]::WindowHeight
                Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop
                continue
            }

            switch ($key.Key) {
                "UpArrow" {
                    $selectedIndex = if ($selectedIndex -le 0) { $Items.Count - 1 } else { $selectedIndex - 1 }
                    Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop
                }
                "DownArrow" {
                    $selectedIndex = if ($selectedIndex -ge ($Items.Count - 1)) { 0 } else { $selectedIndex + 1 }
                    Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop
                }
                "Home" {
                    $selectedIndex = 0
                    Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop
                }
                "End" {
                    $selectedIndex = $Items.Count - 1
                    Render-MenuItems -Items $Items -SelectedIndex $selectedIndex -Top $menuTop
                }
                "Enter" {
                    Write-Host ""
                    return $Items[$selectedIndex].Command
                }
                "Escape" {
                    Write-Host ""
                    $backItem = $Items | Where-Object { $_.Command -eq "Back" } | Select-Object -First 1
                    if ($backItem) {
                        return $backItem.Command
                    }
                    return "Exit"
                }
                default {
                    $number = 0
                    if ([int]::TryParse([string]$key.KeyChar, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
                        Write-Host ""
                        return $Items[$number - 1].Command
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}

function Invoke-Menu {
    param([pscustomobject]$Config)

    $menuStack = @("Main")

    while ($true) {
        $currentMenu = $menuStack[$menuStack.Count - 1]
        $items = Get-MenuItems -MenuName $currentMenu
        $subtitle = switch ($currentMenu) {
            "Main" { "" }
            "AddGame" { New-Text @(0x6DFB, 0x52A0, 0x6E38, 0x620F) }
            "ManualAdd" { New-Text @(0x624B, 0x52A8, 0x6DFB, 0x52A0) }
            "Settings" { New-Text @(0x8BBE, 0x7F6E) }
            "Uninstall" { New-Text @(0x5378, 0x8F7D) }
            default { "" }
        }

        $choice = Read-MenuSelection -Items $items -Subtitle $subtitle
        $runContext = New-RunContext -Config $Config

        try {
            switch ($choice) {
                "EnableUnlockMode" { Invoke-EnableOrUpdateUnlockMode -Config $Config -RunContext $runContext }
                "AddGameMenu" { $menuStack += "AddGame"; continue }
                "ManualAdd" { $menuStack += "ManualAdd"; continue }
                "SettingsMenu" { $menuStack += "Settings"; continue }
                "UninstallMenu" { $menuStack += "Uninstall"; continue }
                "Back" {
                    if ($menuStack.Count -gt 1) {
                        $menuStack = @($menuStack[0..($menuStack.Count - 2)])
                    }
                    continue
                }
                "DownloadGameByAppId" {
                    $gameId = Read-Host (New-Text @(0x8BF7, 0x8F93, 0x5165, 0x6E38, 0x620F, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x6216, 0x0020, 0x0053, 0x0074, 0x0065, 0x0061, 0x006D, 0x0020, 0x5546, 0x5E97, 0x94FE, 0x63A5))
                    Invoke-DownloadGameManifestByAppId -Config $Config -RunContext $runContext -GameId $gameId
                }
                "ManifestHubMarket" {
                    $manifestHubInput = Read-Host "ManifestHub API Key or full URL"
                    $manifestHubDepotId = ""
                    $manifestHubManifestId = ""
                    if ([string]::IsNullOrWhiteSpace($manifestHubInput) -or $manifestHubInput.Trim() -notmatch '^https?://') {
                        $manifestHubDepotId = Read-Host "DepotId"
                        $manifestHubManifestId = Read-Host "ManifestId"
                    }
                    Invoke-DownloadManifestHub `
                        -Config $Config `
                        -RunContext $runContext `
                        -InputValue $manifestHubInput `
                        -ManifestHubApiKey "" `
                        -ManifestHubDepotId $manifestHubDepotId `
                        -ManifestHubManifestId $manifestHubManifestId
                }
                "SteamxMarket" {
                    Write-Host (New-Text @(0x0053, 0x0054, 0x0045, 0x0041, 0x004D, 0x0058, 0x0020, 0x5E02, 0x573A, 0x5F00, 0x53D1, 0x4E2D, 0xFF0C, 0x656C, 0x8BF7, 0x671F, 0x5F85, 0x3002)) -ForegroundColor Yellow
                }
                "SetManifestSource" {
                    $source = Read-Host (New-Text @(0x9009, 0x62E9, 0x6E05, 0x5355, 0x6E90, 0xFF1A, 0x006F, 0x0070, 0x0065, 0x006E, 0x0073, 0x0074, 0x0065, 0x0061, 0x006D, 0x0074, 0x006F, 0x006F, 0x006C, 0x0020, 0x002F, 0x0020, 0x0077, 0x0075, 0x0064, 0x0072, 0x006D, 0x0020, 0x002F, 0x0020, 0x0073, 0x0074, 0x0065, 0x0061, 0x006D, 0x0072, 0x0075, 0x006E))
                    Invoke-SetManifestSource -Config $Config -RunContext $runContext -Source $source
                }
                "CloudSaveSettings" {
                    Write-Host (New-Text @(0x4E91, 0x5B58, 0x6863, 0x8BBE, 0x7F6E, 0x5F00, 0x53D1, 0x4E2D, 0x3002)) -ForegroundColor Yellow
                }
                "DeployOst" { Invoke-DeployOst -Config $Config -RunContext $runContext }
                "DownloadLuaByAppId" {
                    $menuAppId = Read-Host (New-Text @(0x8BF7, 0x8F93, 0x5165, 0x0020, 0x0041, 0x0070, 0x0070, 0x0049, 0x0064, 0x0020, 0x6216, 0x0020, 0x0053, 0x0074, 0x0065, 0x0061, 0x006D, 0x0020, 0x5546, 0x5E97, 0x94FE, 0x63A5))
                    Invoke-DownloadLua -Config $Config -RunContext $runContext -AppId $menuAppId -DirectUrl ""
                }
                "DownloadLuaByUrl" {
                    $menuUrl = Read-Host (New-Text @(0x8BF7, 0x8F93, 0x5165, 0x0020, 0x004C, 0x0075, 0x0061, 0x0020, 0x0055, 0x0052, 0x004C))
                    Invoke-DownloadLua -Config $Config -RunContext $runContext -AppId "" -DirectUrl $menuUrl
                }
                "UninstallOst" { Invoke-UninstallOst -Config $Config -RunContext $runContext }
                "UninstallOstAndLua" { Invoke-UninstallOst -Config $Config -RunContext $runContext -RemoveLua }
                "Exit" { return }
                default { Write-Host "Invalid choice." }
            }
        } catch {
            Write-Log -Message $_.Exception.Message -Level "ERROR" -LogFile $runContext.LogFile
        }
    }
}
try {
    $config = Get-Config -ConfigOverride $ConfigPath

    switch ($Command) {
        "Menu" {
            Invoke-Menu -Config $config
        }
        "Check" {
            $runContext = New-RunContext -Config $config
            Invoke-Check -Config $config -RunContext $runContext
        }
        "DeployOst" {
            $runContext = New-RunContext -Config $config
            Invoke-DeployOst -Config $config -RunContext $runContext
        }
        "EnableUnlockMode" {
            $runContext = New-RunContext -Config $config
            Invoke-EnableOrUpdateUnlockMode -Config $config -RunContext $runContext
        }
        "SetManifestSource" {
            $runContext = New-RunContext -Config $config
            Invoke-SetManifestSource -Config $config -RunContext $runContext -Source $ManifestSource
        }
        "UninstallOst" {
            $runContext = New-RunContext -Config $config
            Invoke-UninstallOst -Config $config -RunContext $runContext
        }
        "UninstallOstAndLua" {
            $runContext = New-RunContext -Config $config
            Invoke-UninstallOst -Config $config -RunContext $runContext -RemoveLua
        }
        "DownloadLua" {
            $runContext = New-RunContext -Config $config
            Invoke-DownloadLua -Config $config -RunContext $runContext -AppId $AppId -DirectUrl $Url
        }
        "DownloadManifestHub" {
            $runContext = New-RunContext -Config $config
            Invoke-DownloadManifestHub `
                -Config $config `
                -RunContext $runContext `
                -InputValue $Url `
                -ManifestHubApiKey $ApiKey `
                -ManifestHubDepotId $DepotId `
                -ManifestHubManifestId $ManifestId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [pscustomobject]@{
            success = $true
            error   = ""
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
} catch {
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        try {
            Ensure-Directory -PathValue (Split-Path -Parent $ResultPath)
            [pscustomobject]@{
                success = $false
                error   = $_.Exception.Message
            } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
        } catch {
        }
    }
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    exit 1
}

