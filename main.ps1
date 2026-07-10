[CmdletBinding()]
param(
    [ValidateSet("Menu", "Check", "EnableUnlockMode", "DeployOst", "SetManifestSource", "UninstallOst", "UninstallOstAndLua")]
    [string]$Command = "Menu",
    [string]$ManifestSource,
    [string]$ConfigPath = "",
    [string]$ResultPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
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

    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

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
        logRoot    = ""
        backupRoot = ""
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
            cacheRoot                   = "./cache/opensteamtools"
            targetPath                  = ""
            files                       = @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll")
            overwrite                   = $true
            backup                      = $false
            requireSteamClosed          = $true
            autoCloseSteam              = $true
            steamShutdownTimeoutSeconds = 15
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
    $configuredLogRoot = Get-ConfigValue -Object $Config -Name "logRoot" -DefaultValue ""
    $logRoot = if ([string]::IsNullOrWhiteSpace($configuredLogRoot)) {
        Join-Path ([System.IO.Path]::GetTempPath()) "STEAMX\logs"
    } else {
        Resolve-LocalPath -PathValue $configuredLogRoot -BasePath $scriptRoot
    }
    Ensure-Directory -PathValue $logRoot

    $backupDir = ""
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    if ([bool](Get-ConfigValue -Object $ostConfig -Name "backup" -DefaultValue $false)) {
        $configuredBackupRoot = Get-ConfigValue -Object $Config -Name "backupRoot" -DefaultValue ""
        $backupRoot = if ([string]::IsNullOrWhiteSpace($configuredBackupRoot)) {
            Join-Path ([System.IO.Path]::GetTempPath()) "STEAMX\backup"
        } else {
            Resolve-LocalPath -PathValue $configuredBackupRoot -BasePath $scriptRoot
        }
        Ensure-Directory -PathValue $backupRoot
        $backupDir = Join-Path $backupRoot (Get-Timestamp)
        Ensure-Directory -PathValue $backupDir
    }

    return [pscustomobject]@{
        ScriptRoot = $scriptRoot
        LogFile    = Join-Path $logRoot ("steamx-{0}.log" -f (Get-Timestamp))
        BackupDir  = $backupDir
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO",
        [string]$LogFile = ""
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
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
    Write-Host "  OpenSteamTools deploy and Lua manifest helper" -ForegroundColor Gray
    Write-Host ""
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

    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
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
        "-ResultPath", ('"{0}"' -f $resultPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($Config.__configFile)) {
        $arguments += @("-ConfigPath", ('"{0}"' -f $Config.__configFile))
    }
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
            $detail = "No detail was returned. UAC may have been cancelled."
        }
        throw "Elevated $ElevatedCommand failed with exit code $($process.ExitCode). $detail"
    }
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

    throw "Steam path not found. Set steamPath in steamx.config.json."
}

function Get-SteamVersion {
    param([Parameter(Mandatory = $true)][string]$SteamPath)

    $steamExe = Join-Path $SteamPath "steam.exe"
    if (-not (Test-Path -LiteralPath $steamExe)) { return "not found" }

    $version = (Get-Item -LiteralPath $steamExe).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) { return "unknown" }
    return $version
}

function Get-SteamRelatedProcesses {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -in @("steam", "steamwebhelper", "GameOverlayUI", "steamservice") } |
            Sort-Object ProcessName, Id
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

    Write-Log -Message ("Stopping Steam related processes: {0}" -f (Get-SteamRunningSummary)) -Level "WARN" -LogFile $RunContext.LogFile
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Log -Message ("Failed to stop process {0}({1}): {2}" -f $process.ProcessName, $process.Id, $_.Exception.Message) -Level "WARN" -LogFile $RunContext.LogFile
        }
    }

    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $waitSeconds = [int](Get-ConfigValue -Object $ostConfig -Name "steamShutdownTimeoutSeconds" -DefaultValue 15)
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    do {
        Start-Sleep -Milliseconds 300
        $remaining = @(Get-SteamRelatedProcesses)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw ("Steam related processes are still running: {0}" -f (Get-SteamRunningSummary))
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

    return [pscustomobject]@{
        Present = $present
        Missing = $missing
        IsReady = ($missing.Count -eq 0)
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
    return $localPath
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
    $cacheRootValue = [string](Get-ConfigValue -Object $ostConfig -Name "cacheRoot" -DefaultValue "./cache/opensteamtools")
    $cacheRoot = Resolve-LocalPath -PathValue $cacheRootValue -BasePath $RunContext.ScriptRoot
    Ensure-Directory -PathValue $cacheRoot

    $apiUrl = "https://api.github.com/repos/{0}/releases/latest" -f $repo
    Write-Log -Message ("Fetching latest OST release: {0}" -f $apiUrl) -LogFile $RunContext.LogFile
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers (Get-GitHubHeaders) -TimeoutSec $timeoutSeconds
    } catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        $cachedSource = Get-CachedOstSourceDirectory -CacheRoot $cacheRoot
        if (-not [string]::IsNullOrWhiteSpace($cachedSource)) {
            Write-Log -Message ("GitHub request failed: {0}" -f $detail) -Level "WARN" -LogFile $RunContext.LogFile
            Write-Log -Message ("Using cached OST extraction: {0}" -f $cachedSource) -Level "WARN" -LogFile $RunContext.LogFile
            return $cachedSource
        }
        throw $detail
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
    $releaseRoot = Join-Path $cacheRoot $tagName
    $zipPath = Join-Path $releaseRoot $asset.name
    $extractRoot = Join-Path $releaseRoot "extracted"
    Ensure-Directory -PathValue $releaseRoot

    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Log -Message ("Downloading OST asset: {0}" -f $asset.browser_download_url) -LogFile $RunContext.LogFile
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers (Get-GitHubHeaders) -TimeoutSec $timeoutSeconds
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

    if (-not (Test-Path -LiteralPath $CacheRoot)) { return "" }
    $candidate = Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "extracted") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) { return "" }
    return (Join-Path $candidate.FullName "extracted")
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [AllowEmptyString()][string]$BackupDir
    )

    if ([string]::IsNullOrWhiteSpace($BackupDir)) { return }
    if (-not (Test-Path -LiteralPath $SourceFile)) { return }

    Ensure-Directory -PathValue $BackupDir
    Copy-Item -LiteralPath $SourceFile -Destination (Join-Path $BackupDir (Split-Path -Leaf $SourceFile)) -Force
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
        Set-Content -LiteralPath $TomlPath -Encoding UTF8 -Value (@("[manifest]", $line, "") + $lines)
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

    Set-Content -LiteralPath $TomlPath -Encoding UTF8 -Value $lines
}

function Invoke-Check {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    $steamPath = Get-SteamPath -Config $Config
    $kernelState = Get-OstKernelState -Config $Config -SteamPath $steamPath
    $tomlPath = Join-Path $steamPath "config\stplug-in\OpenSteamTool.toml"

    Write-Log -Message ("Steam path: {0}" -f $steamPath) -LogFile $RunContext.LogFile
    Write-Log -Message ("Steam version: {0}" -f (Get-SteamVersion -SteamPath $steamPath)) -LogFile $RunContext.LogFile
    Write-Log -Message ("Steam running: {0}" -f (Get-SteamRunningSummary)) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST files ready: {0}" -f $kernelState.IsReady) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST present files: {0}" -f (($kernelState.Present | ForEach-Object { $_ }) -join ", ")) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST missing files: {0}" -f (($kernelState.Missing | ForEach-Object { $_ }) -join ", ")) -LogFile $RunContext.LogFile
    Write-Log -Message ("OST config: {0}" -f $tomlPath) -LogFile $RunContext.LogFile
}

function Invoke-DeployOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedSteamxCommand -Config $Config -ElevatedCommand "DeployOst" -Prompt "Deploy OST requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $sourcePath = Get-OstSourceDirectory -Config $Config -RunContext $RunContext
    $files = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    $targetPathValue = [string](Get-ConfigValue -Object $ostConfig -Name "targetPath" -DefaultValue "")
    $targetPath = if ([string]::IsNullOrWhiteSpace($targetPathValue)) {
        $steamPath
    } else {
        Resolve-LocalPath -PathValue $targetPathValue -BasePath $steamPath
    }

    Ensure-Directory -PathValue $targetPath

    if ([bool](Get-ConfigValue -Object $ostConfig -Name "requireSteamClosed" -DefaultValue $true)) {
        if ([bool](Get-ConfigValue -Object $ostConfig -Name "autoCloseSteam" -DefaultValue $true)) {
            Stop-SteamProcesses -Config $Config -RunContext $RunContext
        } elseif (@(Get-SteamRelatedProcesses).Count -gt 0) {
            throw ("Steam related processes are still running: {0}" -f (Get-SteamRunningSummary))
        }
    }

    foreach ($fileName in $files) {
        $sourceFile = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $sourceFile) {
            throw "Required OST file not found in source: $fileName"
        }

        $targetFile = Join-Path $targetPath $fileName
        if ((Test-Path -LiteralPath $targetFile) -and -not [bool](Get-ConfigValue -Object $ostConfig -Name "overwrite" -DefaultValue $true)) {
            Write-Log -Message ("Skipped existing file: {0}" -f $targetFile) -Level "WARN" -LogFile $RunContext.LogFile
            continue
        }

        Backup-ExistingFile -SourceFile $targetFile -BackupDir $RunContext.BackupDir
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
        Write-Log -Message ("Deployed: {0} -> {1}" -f $sourceFile.FullName, $targetFile) -LogFile $RunContext.LogFile
    }

    if ([bool](Get-ConfigValue -Object $ostConfig -Name "restartSteamAfterDeploy" -DefaultValue $true)) {
        Start-Steam -RunContext $RunContext -SteamPath $steamPath
    }
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

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedSteamxCommand `
            -Config $Config `
            -ElevatedCommand "SetManifestSource" `
            -ExtraArguments @("-ManifestSource", $Source) `
            -Prompt "Changing OST manifest source requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $tomlPath = Join-Path $steamPath "config\stplug-in\OpenSteamTool.toml"
    Set-OstManifestSourceInToml -TomlPath $tomlPath -Source $Source
    Write-Log -Message ("Manifest source set to: {0}" -f $Source) -LogFile $RunContext.LogFile
}

function Invoke-EnableUnlockMode {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext
    )

    if (-not (Test-IsAdministrator)) {
        Invoke-ElevatedSteamxCommand -Config $Config -ElevatedCommand "EnableUnlockMode" -Prompt "Enable unlock mode requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    Invoke-DeployOst -Config $Config -RunContext $RunContext
    Invoke-SetManifestSource -Config $Config -RunContext $RunContext -Source $ManifestSource

    $steamPath = Get-SteamPath -Config $Config
    $kernelState = Get-OstKernelState -Config $Config -SteamPath $steamPath
    Write-Log -Message ("Unlock mode ready: {0}" -f $kernelState.IsReady) -LogFile $RunContext.LogFile
}

function Confirm-DestructiveAction {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    $answer = Read-Host "Type YES to continue"
    return ($answer -ceq "YES")
}

function Invoke-UninstallOst {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$RunContext,
        [switch]$RemoveLua
    )

    if (-not (Test-IsAdministrator)) {
        $commandName = if ($RemoveLua) { "UninstallOstAndLua" } else { "UninstallOst" }
        Invoke-ElevatedSteamxCommand -Config $Config -ElevatedCommand $commandName -Prompt "Uninstall requires administrator permission. Approve the UAC prompt to continue."
        return
    }

    $steamPath = Get-SteamPath -Config $Config
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $files = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))

    $message = if ($RemoveLua) {
        "This will remove OST files and clear all Lua manifests in: {0}" -f (Join-Path $steamPath "config\lua")
    } else {
        "This will remove OST files from: {0}" -f $steamPath
    }
    if (-not (Confirm-DestructiveAction -Message $message)) {
        Write-Log -Message "Uninstall cancelled by user." -Level "WARN" -LogFile $RunContext.LogFile
        return
    }

    foreach ($fileName in $files) {
        $targetFile = Join-Path $steamPath $fileName
        if (Test-Path -LiteralPath $targetFile) {
            Remove-Item -LiteralPath $targetFile -Force
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

        if (Test-Path -LiteralPath $luaPath) {
            Get-ChildItem -LiteralPath $luaPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
            Write-Log -Message ("Cleared Lua manifests: {0}" -f $luaPath) -LogFile $RunContext.LogFile
        }
    }

    Write-Log -Message "Uninstall completed." -LogFile $RunContext.LogFile
}

function Invoke-Menu {
    param([pscustomobject]$Config)

    while ($true) {
        Write-Host ""
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
        Write-SteampXLogo
        Write-Host ""
        Write-Host "1. 开启/更新解锁模式"
        Write-Host "2. 检查状态"
        Write-Host "3. 设置清单源"
        Write-Host "4. 卸载 OST 内核"
        Write-Host "5. 卸载 OST 内核 + 清空 Lua 清单"
        Write-Host "0. 退出"
        Write-Host ""

        $choice = Read-Host "请选择"
        $runContext = New-RunContext -Config $Config

        if ($choice -eq "1") {
            Invoke-EnableUnlockMode -Config $Config -RunContext $runContext
            Read-Host "按 Enter 返回菜单" | Out-Null
        } elseif ($choice -eq "2") {
            Invoke-Check -Config $Config -RunContext $runContext
            Read-Host "按 Enter 返回菜单" | Out-Null
        } elseif ($choice -eq "3") {
            $source = Read-Host "清单源 opensteamtool / wudrm / steamrun"
            Invoke-SetManifestSource -Config $Config -RunContext $runContext -Source $source
            Read-Host "按 Enter 返回菜单" | Out-Null
        } elseif ($choice -eq "4") {
            Invoke-UninstallOst -Config $Config -RunContext $runContext
            Read-Host "按 Enter 返回菜单" | Out-Null
        } elseif ($choice -eq "5") {
            Invoke-UninstallOst -Config $Config -RunContext $runContext -RemoveLua
            Read-Host "按 Enter 返回菜单" | Out-Null
        } elseif ($choice -eq "0") {
            return
        } else {
            Write-Host "无效选择。" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

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
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}




