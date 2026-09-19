# Keep this entry script ASCII-only, UTF-8 without BOM, LF endings.
# Run.Local.lnk starts it with `powershell.exe -File`, and PowerShell 5.1 decodes a
# BOM-less .ps1 with the system ANSI code page (936 here), so any non-ASCII byte in
# code or comments can break parsing. Chinese UI text must go through ConvertFrom-Utf8Base64.
[CmdletBinding()]
param(
    [ValidateSet("Start", "Check", "EnableUnlockMode", "AddGame", "DeployOst", "SetManifestSource", "UninstallOst", "UninstallOstAndLua")]
    [string]$Command = "Start",
    [string]$ManifestSource,
    [string]$ConfigPath = "",
    [string]$AppId = "",
    [ValidateSet("full", "basegame", "dlc")]
    [string]$Variant = "full",
    [string]$ApiKey = "",
    [string]$CredentialPath = "",
    [switch]$ResetApiKey,
    [string]$LuaPath = "",
    [string]$OutputName = "",
    [int]$TimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8Encoding = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8Encoding
[Console]::OutputEncoding = $utf8Encoding
$OutputEncoding = $utf8Encoding
$script:OstReleaseCache = @{}
$script:SteamPathCache = ""
$script:NetworkRegionCache = ""

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
    if ($PSBoundParameters.ContainsKey("ForegroundColor") -and -not $env:NO_COLOR) {
        Write-Host $Text -ForegroundColor $ForegroundColor
    } else {
        Write-Host $Text
    }
}

function Read-UiInput {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    return Read-Host $Prompt
}

function Test-LauncherSession {
    # True when the script was started as a file (shortcut / double click), where the
    # console window disappears the moment the script ends.
    try {
        foreach ($argument in [Environment]::GetCommandLineArgs()) {
            if ($argument -ieq "-File" -or $argument -ieq "/File") { return $true }
        }
    } catch {
    }
    return $false
}

function Wait-LauncherExit {
    if (-not (Test-LauncherSession)) { return }
    try {
        # Redirected stdin can never answer Read-Host, so do not block on it.
        if ([Console]::IsInputRedirected) {
            Start-Sleep -Seconds 5
            return
        }
    } catch {
    }
    try {
        Write-UiLine
        [void](Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "5oyJ5Zue6L2m6ZSu5YWz6Zet56qX5Y+j"))
    } catch {
        Start-Sleep -Seconds 5
    }
}

function Test-UiVirtualTerminal {
    if ($env:NO_COLOR) { return $false }

    try {
        $property = $host.UI.PSObject.Properties["SupportsVirtualTerminal"]
        if ($null -ne $property -and [bool]$property.Value) { return $true }
    } catch {
    }

    return (-not [string]::IsNullOrWhiteSpace([string]$env:WT_SESSION) -or
        -not [string]::IsNullOrWhiteSpace([string]$env:TERM_PROGRAM) -or
        -not [string]::IsNullOrWhiteSpace([string]$env:ANSICON))
}

function Get-UiWidth {
    try {
        $width = [int]$host.UI.RawUI.WindowSize.Width
    } catch {
        $width = 80
    }
    return [Math]::Max(24, [Math]::Min(96, $width - 1))
}

$script:UiLogLevelStyle = @{
    DEBUG   = @{ Tag = "DEBUG"; Ansi = "90" }
    INFO    = @{ Tag = "INFO";  Ansi = "36" }
    SUCCESS = @{ Tag = "OK";    Ansi = "32" }
    WARN    = @{ Tag = "WARN";  Ansi = "33" }
    ERROR   = @{ Tag = "ERROR"; Ansi = "31" }
}
$script:UiLogTagWidth = 5
$script:UiLogScopeWidth = 8

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARN", "ERROR")][string]$Level = "INFO",
        [string]$Scope = "steamx"
    )

    $style = $script:UiLogLevelStyle[$Level]
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $tag = $style.Tag.PadRight($script:UiLogTagWidth)
    $scopeText = $Scope.PadRight($script:UiLogScopeWidth)

    if (-not (Test-UiVirtualTerminal)) {
        Write-UiLine -Text ("{0} {1} {2} {3}" -f $timestamp, $tag, $scopeText, $Message)
        return
    }

    $esc = [string][char]27
    $line = "{0}[90m{1} {0}[{2}m{3}{0}[37m {4} {0}[0m" -f $esc, $timestamp, $style.Ansi, $tag, $scopeText
    if ($Level -in @("WARN", "ERROR")) {
        $line += "{0}[{1}m{2}{0}[0m" -f $esc, $style.Ansi, $Message
    } else {
        $line += $Message
    }
    Write-UiLine -Text $line
}

function Test-SteamxProjectRoot {
    # A directory only counts as the project root when it really looks like a checkout.
    param([AllowEmptyString()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) { return $false }
        foreach ($marker in @("main.ps1", "manifest", "Lua", "DownloadRepair")) {
            if (Test-Path -LiteralPath (Join-Path $PathValue $marker)) { return $true }
        }
    } catch {
    }
    return $false
}

function Get-ScriptRoot {
    # Launched as a file: the script folder is the project root.
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

    # Launched through irm | iex there is no script file, so the working directory is
    # the only hint. A shortcut shipped to another machine still carries this project's
    # path, which neither exists nor is writable there, so trust it only when it really
    # is a checkout. Otherwise relative paths (config, ost cache) would point at a
    # missing drive and the run would break before it starts.
    $current = (Get-Location).Path
    if (Test-SteamxProjectRoot -PathValue $current) { return $current }

    $fallbacks = @()
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $fallbacks += (Join-Path $localAppData "STEAMX")
    }
    $fallbacks += (Join-Path ([System.IO.Path]::GetTempPath()) "STEAMX")

    foreach ($candidate in $fallbacks) {
        try {
            [void][System.IO.Directory]::CreateDirectory($candidate)
            return $candidate
        } catch {
        }
    }
    return $current
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
            timeoutSeconds       = 30
            # Hubcap builds the lua on demand; response headers can take over a minute,
            # so this needs its own (much larger) budget.
            hubcapTimeoutSeconds = 180
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
            # Prefer the official asset and retain the mirror as a fallback.
            downloadUrlTemplates        = @(
                "{official}",
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
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARN", "ERROR")][string]$Level = "INFO",
        [string]$Scope = "steamx",
        [string]$LogFile = ""
    )

    Write-UiLog -Message $Message -Level $Level -Scope $Scope
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $line = "{0} [{1}] {2} {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Scope, $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Write-SteampXLogo {
    try {
        $host.UI.RawUI.WindowTitle = "STEAMX - OpenSteamTools Deploy"
    } catch {
    }
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

    $steamColumns = 49
    $blue = @(56, 189, 248)
    $green = @(34, 197, 94)
    $reset = "$([char]27)[0m"
    $useTrueColor = Test-UiVirtualTerminal

    if ((Get-UiWidth) -lt 70) {
        if ($useTrueColor) {
            Write-Host ("  $([char]27)[38;2;$($blue[0]);$($blue[1]);$($blue[2])mSTEAM$([char]27)[38;2;$($green[0]);$($green[1]);$($green[2])mX$reset")
        } else {
            Write-Host "  " -NoNewline
            Write-Host "STEAM" -NoNewline -ForegroundColor Cyan
            Write-Host "X" -ForegroundColor Green
        }
        Write-UiLine -Text "  OpenSteamTools deploy and Lua manifest helper" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    foreach ($line in $logo) {
        $rendered = $line.Replace("D", $lowerBlock).Replace("R", $fullBlock).Replace("T", $upperBlock)
        $steamPart = $rendered.Substring(0, [Math]::Min($steamColumns, $rendered.Length))
        $xStart = $steamPart.Length
        $xPart = if ($xStart -lt $rendered.Length) { $rendered.Substring($xStart) } else { "" }

        if ($env:NO_COLOR) {
            Write-Host ("{0}{1}{2}" -f $logoIndent, $steamPart, $xPart)
            continue
        }

        if ($useTrueColor) {
            Write-Host ("{0}{1}{2}{3}{4}{5}" -f
                $logoIndent,
                "$([char]27)[38;2;$($blue[0]);$($blue[1]);$($blue[2])m",
                $steamPart,
                "$([char]27)[38;2;$($green[0]);$($green[1]);$($green[2])m",
                $xPart,
                $reset)
        } else {
            Write-Host $logoIndent -NoNewline
            Write-Host $steamPart -NoNewline -ForegroundColor Cyan
            Write-Host $xPart -ForegroundColor Green
        }
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

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties["Response"]
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return 0
    }

    try {
        return [int]$responseProperty.Value.StatusCode
    } catch {
        return 0
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

function Test-SteamInstallPath {
    param([AllowNull()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    try {
        $steamExe = [System.IO.Path]::Combine($PathValue, "steam.exe")
        return [bool](Test-Path -LiteralPath $steamExe -PathType Leaf -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Get-SteamPath {
    param([pscustomobject]$Config)

    if (Test-SteamInstallPath -PathValue $script:SteamPathCache) {
        return $script:SteamPathCache
    }

    $candidates = @(
        [string](Get-ConfigValue -Object $Config -Name "steamPath" -DefaultValue ""),
        [string]$env:STEAM_PATH
    )

    foreach ($process in @(Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                $candidates += Split-Path -Parent ([string]$process.Path)
            }
        } catch {
            continue
        }
    }

    foreach ($registryPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\Software\WOW6432Node\Valve\Steam",
        "HKLM:\Software\Valve\Steam"
    )) {
        if (Test-Path $registryPath -ErrorAction SilentlyContinue) {
            $item = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
            $steamPathValue = Get-ObjectPropertyValue -Object $item -Name "SteamPath"
            $installPathValue = Get-ObjectPropertyValue -Object $item -Name "InstallPath"
            $steamExeValue = Get-ObjectPropertyValue -Object $item -Name "SteamExe"
            if (-not [string]::IsNullOrWhiteSpace($steamPathValue)) { $candidates += $steamPathValue }
            if (-not [string]::IsNullOrWhiteSpace($installPathValue)) { $candidates += $installPathValue }
            if (-not [string]::IsNullOrWhiteSpace($steamExeValue)) {
                $candidates += Split-Path -Parent ([string]$steamExeValue)
            }
        }
    }

    foreach ($registryPath in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\steam.exe",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\steam.exe",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\steam.exe"
    )) {
        if (-not (Test-Path $registryPath -ErrorAction SilentlyContinue)) { continue }
        try {
            $steamExe = [string](Get-Item -Path $registryPath -ErrorAction Stop).GetValue("")
            if (-not [string]::IsNullOrWhiteSpace($steamExe)) {
                $candidates += Split-Path -Parent $steamExe.Trim('"')
            }
        } catch {
            continue
        }
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = [string]$drive.Root
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidates += @(
            [System.IO.Path]::Combine($root, "Steam"),
            [System.IO.Path]::Combine($root, "Program Files (x86)", "Steam"),
            [System.IO.Path]::Combine($root, "Program Files", "Steam")
        )
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $candidatePath = ([string]$candidate).Trim().Trim('"')
        if (Test-SteamInstallPath -PathValue $candidatePath) {
            $script:SteamPathCache = [System.IO.Path]::GetFullPath($candidatePath)
            return $script:SteamPathCache
        }
    }

    $enteredPath = (Read-UiInput -Prompt "Steam path not found. Enter the folder containing steam.exe, or press Enter to cancel").Trim().Trim('"')
    if ($enteredPath.EndsWith("steam.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $enteredPath = Split-Path -Parent $enteredPath
    }
    if (Test-SteamInstallPath -PathValue $enteredPath) {
        $script:SteamPathCache = [System.IO.Path]::GetFullPath($enteredPath)
        return $script:SteamPathCache
    }

    throw "Steam path not found. Set `$env:STEAM_PATH to the folder containing steam.exe before running STEAMX."
}

function Resolve-SteamAppId {
    param([Parameter(Mandatory = $true)][string]$InputValue)

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

    throw "Invalid AppID or Steam store URL."
}

function Get-HubcapCredentialFile {
    param([string]$CredentialOverride)

    if (-not [string]::IsNullOrWhiteSpace($CredentialOverride)) {
        return Resolve-LocalPath -PathValue $CredentialOverride -BasePath (Get-ScriptRoot)
    }

    return Join-Path (Join-Path $env:LOCALAPPDATA "STEAMX") "hubcap-api-key.dat"
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Save-HubcapApiKey {
    param(
        [Parameter(Mandatory = $true)][Security.SecureString]$SecureApiKey,
        [Parameter(Mandatory = $true)][string]$CredentialFile
    )

    Ensure-Directory -PathValue (Split-Path -Parent $CredentialFile)
    $SecureApiKey |
        ConvertFrom-SecureString |
        Set-Content -LiteralPath $CredentialFile -Encoding ASCII -NoNewline
}

function Get-HubcapApiKey {
    param(
        [string]$ConfiguredApiKey,
        [Parameter(Mandatory = $true)][string]$CredentialFile,
        [switch]$ForcePrompt
    )

    if (-not $ForcePrompt) {
        if (-not [string]::IsNullOrWhiteSpace($ConfiguredApiKey)) {
            return $ConfiguredApiKey.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($env:HUBCAP_API_KEY)) {
            return $env:HUBCAP_API_KEY.Trim()
        }
        if (Test-Path -LiteralPath $CredentialFile -PathType Leaf) {
            try {
                $encryptedValue = (Get-Content -LiteralPath $CredentialFile -Raw -Encoding ASCII).Trim()
                if (-not [string]::IsNullOrWhiteSpace($encryptedValue)) {
                    $secureApiKey = $encryptedValue | ConvertTo-SecureString
                    return (ConvertTo-PlainText -SecureValue $secureApiKey).Trim()
                }
            } catch {
                Write-UiLog -Scope "hubcap" -Level WARN -Message "saved API Key could not be decrypted; a new key is required"
            }
        }
    }

    $promptedApiKey = Read-Host "Hubcap API Key (input is hidden)" -AsSecureString
    $plainApiKey = ConvertTo-PlainText -SecureValue $promptedApiKey
    if ([string]::IsNullOrWhiteSpace($plainApiKey)) {
        throw "Hubcap API Key is required."
    }

    Save-HubcapApiKey -SecureApiKey $promptedApiKey -CredentialFile $CredentialFile
    Write-UiLog -Scope "hubcap" -Level SUCCESS -Message ("API Key encrypted for the current Windows user -> {0}" -f (Get-DisplayPath -PathValue $CredentialFile))
    return $plainApiKey.Trim()
}

function Get-HubcapHeaders {
    param([Parameter(Mandatory = $true)][string]$ResolvedApiKey)

    return @{
        "Authorization" = "Bearer $ResolvedApiKey"
        "User-Agent"    = "STEAMX"
        "Accept"        = "*/*"
    }
}

function Show-HubcapApiStatus {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][int]$RequestTimeoutSeconds
    )

    try {
        $stats = Invoke-RestMethod `
            -Uri "https://hubcapmanifest.com/api/v1/user/stats" `
            -Headers $Headers `
            -TimeoutSec $RequestTimeoutSeconds
        $dailyUsage = [long](Get-ObjectPropertyValue -Object $stats -Name "daily_usage")
        $dailyLimit = [long](Get-ObjectPropertyValue -Object $stats -Name "daily_limit")
        $remaining = [Math]::Max(0, $dailyLimit - $dailyUsage)
        $expiresValue = [string](Get-ObjectPropertyValue -Object $stats -Name "api_key_expires_at")
        $expiresText = if ([string]::IsNullOrWhiteSpace($expiresValue)) {
            "not reported"
        } else {
            ([DateTimeOffset]::Parse($expiresValue)).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz")
        }

        $userName = [string](Get-ObjectPropertyValue -Object $stats -Name "username")
        Write-UiLog -Scope "hubcap" -Level INFO -Message ("{0,-10}{1}" -f "user", $userName)
        Write-UiLog -Scope "hubcap" -Level INFO -Message ("{0,-10}{1}" -f "expires", $expiresText)
        Write-UiLog -Scope "hubcap" -Level INFO -Message ("{0,-10}{1}" -f "quota", ("{0}/{1} used, {2} remaining" -f $dailyUsage, $dailyLimit, $remaining))
        return "Ready"
    } catch {
        if ((Get-HttpStatusCode -ErrorRecord $_) -eq 401) {
            Write-UiLog -Scope "hubcap" -Level WARN -Message "API Key is invalid or expired"
            return "Unauthorized"
        }
        Write-UiLog -Scope "hubcap" -Level WARN -Message ("status query failed: {0}" -f $_.Exception.Message)
        return "Unavailable"
    }
}

function Get-HubcapLuaUrl {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedVariant,
        [Parameter(Mandatory = $true)][string]$ResolvedAppId
    )

    # Every lua endpoint answers with plain text, so no depot manifest archive is needed:
    # OST fetches the manifests itself. "full" keeps the old /manifest zip as a fallback -
    # it carries the same lua, and the .manifest entries inside it are ignored.
    switch ($ResolvedVariant) {
        "full" {
            return @(
                "https://hubcapmanifest.com/api/v1/lua/$ResolvedAppId",
                "https://hubcapmanifest.com/api/v1/manifest/$ResolvedAppId"
            )
        }
        "basegame" { return @("https://hubcapmanifest.com/api/v1/lua/basegame/$ResolvedAppId") }
        "dlc" { return @("https://hubcapmanifest.com/api/v1/lua/dlc/$ResolvedAppId") }
        default { throw "Unsupported Hubcap variant: $ResolvedVariant" }
    }
}

function Test-ZipFile {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $stream = [System.IO.File]::OpenRead($PathValue)
    try {
        if ($stream.Length -lt 4) { return $false }
        $buffer = New-Object byte[] 4
        [void]$stream.Read($buffer, 0, 4)
        return ($buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and $buffer[2] -eq 0x03 -and $buffer[3] -eq 0x04)
    } finally {
        $stream.Dispose()
    }
}

function Test-HubcapTimeoutError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $inner = $ErrorRecord.Exception
    while ($null -ne $inner) {
        if ($inner -is [System.Net.WebException] -and $inner.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            return $true
        }
        $inner = $inner.InnerException
    }
    # WebException messages are localized, so the status chain above is the reliable
    # signal; keep this text match ASCII-only as a secondary check.
    return ([string]$ErrorRecord.Exception.Message -match '(?i)timed?\s*out|timeout')
}

function Invoke-HubcapDownloadWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][int]$RequestTimeoutSeconds
    )

    $maxAttempts = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.UserAgent = [string]$Headers["User-Agent"]
        $request.Accept = [string]$Headers["Accept"]
        $request.Headers["Authorization"] = [string]$Headers["Authorization"]
        $request.AllowAutoRedirect = $true
        $request.Timeout = $RequestTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $RequestTimeoutSeconds * 1000
        $response = $null
        $responseStream = $null
        $fileStream = $null
        try {
            $response = $request.GetResponse()
            $totalBytes = [long]$response.ContentLength
            $responseStream = $response.GetResponseStream()
            $fileStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $buffer = New-Object byte[] 131072
            $downloaded = 0L
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $downloaded += $read
                $speed = $downloaded / [Math]::Max(0.001, $stopwatch.Elapsed.TotalSeconds)
                if ($totalBytes -gt 0) {
                    $percent = [Math]::Min(100, [int](($downloaded * 100) / $totalBytes))
                    $status = "{0} / {1} | {2}/s" -f (Format-FileSize $downloaded), (Format-FileSize $totalBytes), (Format-FileSize $speed)
                    Write-Progress -Id 3 -Activity "Downloading Lua manifests" -Status $status -PercentComplete $percent
                } else {
                    Write-Progress -Id 3 -Activity "Downloading Lua manifests" -Status ("{0} downloaded" -f (Format-FileSize $downloaded))
                }
            }
            Write-UiLog -Scope "hubcap" -Level SUCCESS -Message ("downloaded {0} <- {1}" -f (Format-FileSize $downloaded), ($Url -replace '^https?://[^/]+', ''))
            return
        } catch {
            $statusCode = Get-HttpStatusCode -ErrorRecord $_
            if ($statusCode -eq 401) {
                throw "Hubcap rejected the API Key while downloading. Run the game import again to replace the saved key."
            }
            $retryable = ($statusCode -eq 0) -and (Test-HubcapTimeoutError -ErrorRecord $_)
            if ((-not $retryable) -or ($attempt -ge $maxAttempts)) {
                if ($retryable) {
                    throw "Hubcap did not answer within $RequestTimeoutSeconds s. The lua is built on demand; try again in a minute."
                }
                throw
            }
            Write-UiLog -Scope "hubcap" -Level WARN -Message ("no response in {0}s, retrying ({1}/{2})" -f $RequestTimeoutSeconds, ($attempt + 1), $maxAttempts)
            Start-Sleep -Seconds 3
        } finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
            if ($null -ne $responseStream) { $responseStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            Write-Progress -Id 3 -Activity "Downloading Lua manifests" -Completed
    }
    }
}

function Install-HubcapLuaDownload {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadPath,
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][string]$TargetFileName
    )

    Ensure-Directory -PathValue $TargetDirectory
    if (-not (Test-ZipFile -PathValue $DownloadPath)) {
        $targetFile = Join-Path $TargetDirectory ([System.IO.Path]::GetFileName($TargetFileName))
        Copy-Item -LiteralPath $DownloadPath -Destination $targetFile -Force
        Write-UiLog -Scope "install" -Level SUCCESS -Message ("lua -> {0}" -f (Get-DisplayPath -PathValue $targetFile))
        return
    }

    # Fallback path only: the Hubcap lua endpoints answer with plain text, but a zip
    # response is still tolerated. Depot manifests inside the archive are ignored on
    # purpose - OST fetches them on its own, so nothing is written to depotcache.
    $extractDirectory = Join-Path (Split-Path -Parent $DownloadPath) "extract"
    Ensure-Directory -PathValue $extractDirectory
    # ZipFile::ExtractToDirectory works regardless of the file extension (Expand-Archive does not).
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadPath, $extractDirectory)
    $luaFiles = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter *.lua)
    if ($luaFiles.Count -eq 0) {
        throw "The Hubcap archive did not contain any Lua files."
    }
    foreach ($luaFile in $luaFiles) {
        $targetFile = Join-Path $TargetDirectory $luaFile.Name
        Copy-Item -LiteralPath $luaFile.FullName -Destination $targetFile -Force
        Write-UiLog -Scope "install" -Level SUCCESS -Message ("lua -> {0}" -f (Get-DisplayPath -PathValue $targetFile))
    }
}

function Invoke-AddGame {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Config,
        [string]$InputAppId,
        [ValidateSet("full", "basegame", "dlc")][string]$InputVariant = "full",
        [string]$ConfiguredApiKey = "",
        [string]$CredentialOverride = "",
        [switch]$ForceApiKeyPrompt,
        [switch]$RetryInvalidCredential,
        [string]$LuaOverride = "",
        [string]$RequestedOutputName = "",
        [int]$RequestTimeoutSeconds = 0
    )

    if ([string]::IsNullOrWhiteSpace($InputAppId)) {
        $InputAppId = Read-UiInput -Prompt "Game AppID or Steam store URL"
    }
    $resolvedAppId = Resolve-SteamAppId -InputValue $InputAppId
    $steamPath = Get-SteamPath -Config $Config
    $targetLuaPath = if ([string]::IsNullOrWhiteSpace($LuaOverride)) {
        Join-Path $steamPath "config\lua"
    } else {
        Resolve-LocalPath -PathValue $LuaOverride -BasePath (Get-ScriptRoot)
    }
    # OST fetches the depot manifests on its own, but only while its toml points at a source
    # that still answers: the example shipped with OST defaults to "opensteamtool", and that
    # one is dead. Align the source before downloading, otherwise a lua-only install is useless.
    $ostConfig = Get-ConfigValue -Object $Config -Name "ost" -DefaultValue $null
    $ostFiles = @(Get-ConfigValue -Object $ostConfig -Name "files" -DefaultValue @("dwmapi.dll", "xinput1_4.dll", "OpenSteamTool.dll"))
    $ostInstalled = $false
    foreach ($ostFileName in $ostFiles) {
        if (Test-Path -LiteralPath (Join-Path $steamPath $ostFileName)) { $ostInstalled = $true; break }
    }
    if ($ostInstalled) {
        $manifestConfig = Get-ConfigValue -Object $Config -Name "manifest" -DefaultValue $null
        $manifestSource = [string](Get-ConfigValue -Object $manifestConfig -Name "source" -DefaultValue "wudrm")
        $tomlPath = Get-OstConfigPath -Config $Config -SteamPath $steamPath
        if (Set-OstManifestSourceInToml -TomlPath $tomlPath -Source $manifestSource) {
            Write-UiLog -Scope "addgame" -Level SUCCESS -Message ("manifest source -> {0} in {1}" -f $manifestSource, (Get-DisplayPath -PathValue $tomlPath))
        }
    }
    $networkConfig = Get-ConfigValue -Object $Config -Name "network" -DefaultValue $null
    if ($RequestTimeoutSeconds -le 0) {
        $RequestTimeoutSeconds = [int](Get-ConfigValue -Object $networkConfig -Name "hubcapTimeoutSeconds" -DefaultValue 180)
    }
    $credentialFile = Get-HubcapCredentialFile -CredentialOverride $CredentialOverride
    $resolvedApiKey = Get-HubcapApiKey `
        -ConfiguredApiKey $ConfiguredApiKey `
        -CredentialFile $credentialFile `
        -ForcePrompt:$ForceApiKeyPrompt
    $headers = Get-HubcapHeaders -ResolvedApiKey $resolvedApiKey
    $downloadUrls = @(Get-HubcapLuaUrl -ResolvedVariant $InputVariant -ResolvedAppId $resolvedAppId)
    $outputFileName = if ([string]::IsNullOrWhiteSpace($RequestedOutputName)) {
        if ($InputVariant -eq "full") { "$resolvedAppId.lua" } else { "$resolvedAppId.$InputVariant.lua" }
    } else {
        [System.IO.Path]::GetFileName($RequestedOutputName)
    }

    Write-UiLog -Scope "addgame" -Level INFO -Message ("{0,-10}{1}" -f "appid", ("{0} (variant={1})" -f $resolvedAppId, $InputVariant))
    Write-UiLog -Scope "addgame" -Level INFO -Message ("{0,-10}{1}" -f "lua", (Get-DisplayPath -PathValue $targetLuaPath))
    $apiStatus = Show-HubcapApiStatus -Headers $headers -RequestTimeoutSeconds $RequestTimeoutSeconds
    if ($apiStatus -eq "Unauthorized") {
        if (-not $RetryInvalidCredential) {
            throw "Hubcap API Key is invalid or expired. Run again with -ResetApiKey to replace it."
        }

        Write-UiLog -Scope "hubcap" -Level INFO -Message "entering a new API Key to replace the saved credential"
        $resolvedApiKey = Get-HubcapApiKey `
            -ConfiguredApiKey "" `
            -CredentialFile $credentialFile `
            -ForcePrompt
        $headers = Get-HubcapHeaders -ResolvedApiKey $resolvedApiKey
        $apiStatus = Show-HubcapApiStatus -Headers $headers -RequestTimeoutSeconds $RequestTimeoutSeconds
        if ($apiStatus -eq "Unauthorized") {
            throw "The new Hubcap API Key was also rejected. Check the key and try again."
        }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\hubcap\{0}" -f [Guid]::NewGuid().ToString("N"))
    # Must keep the .zip extension: Windows PowerShell 5.1 Expand-Archive rejects other suffixes.
    $tempDownload = Join-Path $tempRoot "download.zip"
    try {
        Ensure-Directory -PathValue $tempRoot
        $lastDownloadError = $null
        $downloaded = $false
        foreach ($downloadUrl in $downloadUrls) {
            try {
                Write-UiLog -Scope "hubcap" -Level INFO -Message ("requesting lua <- {0}" -f ($downloadUrl -replace '^https?://[^/]+/api/v1/', ''))
                Invoke-HubcapDownloadWithProgress `
                    -Url $downloadUrl `
                    -Destination $tempDownload `
                    -Headers $headers `
                    -RequestTimeoutSeconds $RequestTimeoutSeconds
                $downloaded = $true
                break
            } catch {
                $lastDownloadError = $_
                Write-UiLog -Scope "hubcap" -Level WARN -Message ("source failed ({0}): {1}" -f ($downloadUrl -replace '^https?://[^/]+/api/v1/', ''), $_.Exception.Message)
            }
        }
        if (-not $downloaded) {
            throw $lastDownloadError
        }
        Install-HubcapLuaDownload `
            -DownloadPath $tempDownload `
            -TargetDirectory $targetLuaPath `
            -TargetFileName $outputFileName
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-UiLog -Scope "steam" -Level INFO -Message "restart Steam to load the new lua"
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

    Write-Log -Message ("Steam is running; closing related processes before continuing: {0}" -f (Get-SteamRunningSummary)) -Level "INFO" -Scope "steam" -LogFile $RunContext.LogFile
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
            Write-Log -Message "Steam could not be terminated automatically. Waiting for the user to exit Steam." -Level "WARN" -Scope "steam" -LogFile $RunContext.LogFile
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
        Write-Log -Message "steam.exe not found; skip restart." -Level "WARN" -Scope "steam" -LogFile $RunContext.LogFile
        return
    }

    Start-Process -FilePath $steamExe -WorkingDirectory $SteamPath | Out-Null
    Write-Log -Message "Steam restarted." -Scope "steam" -LogFile $RunContext.LogFile
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

    $networkRegion = Get-NetworkRegion
    if ($networkRegion -eq "CN") {
        Write-UiLog -Scope "net" -Level INFO -Message "region CN, mirror download sources have priority"
        return @(
            @($urls | Where-Object { $_ -ne $OfficialUrl })
            $OfficialUrl
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($networkRegion)) {
        Write-UiLog -Scope "net" -Level INFO -Message ("region {0}, GitHub official source has priority" -f $networkRegion)
        return @(
            $OfficialUrl
            @($urls | Where-Object { $_ -ne $OfficialUrl })
        )
    }

    $probes = @(
        foreach ($url in $urls) {
            Test-DownloadEndpoint -Url $url -TimeoutMilliseconds 3000
        }
    )
    $reachableUrls = @($probes | Where-Object { $_.Reachable } | Sort-Object ElapsedMilliseconds | ForEach-Object { $_.Url })
    if ($reachableUrls.Count -gt 0) {
        Write-UiLog -Scope "net" -Level WARN -Message "region detection unavailable, sources ordered by connectivity"
        return @(
            $reachableUrls
            @($urls | Where-Object { $_ -notin $reachableUrls })
        )
    }

    Write-UiLog -Scope "net" -Level WARN -Message "region and endpoint probes unavailable, using configured source order"
    return $urls
}

function Get-NetworkRegion {
    $regionOverride = ([string]$env:STEAMX_NETWORK_REGION).Trim().ToUpperInvariant()
    if ($regionOverride -match '^[A-Z]{2}$') {
        return $regionOverride
    }

    if ($script:NetworkRegionCache -eq "__UNKNOWN__") {
        return ""
    }
    if (-not [string]::IsNullOrWhiteSpace($script:NetworkRegionCache)) {
        return $script:NetworkRegionCache
    }

    try {
        $trace = [string](Invoke-RestMethod `
            -Uri "https://www.cloudflare.com/cdn-cgi/trace" `
            -Headers @{ "User-Agent" = "STEAMX" } `
            -TimeoutSec 5)
        $locationMatch = [System.Text.RegularExpressions.Regex]::Match($trace, '(?m)^loc=([A-Za-z]{2})\s*$')
        if ($locationMatch.Success) {
            $script:NetworkRegionCache = $locationMatch.Groups[1].Value.ToUpperInvariant()
            return $script:NetworkRegionCache
        }
    } catch {
    }

    $script:NetworkRegionCache = "__UNKNOWN__"
    return ""
}

function Test-DownloadEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMilliseconds = 3000
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "HEAD"
    $request.UserAgent = "STEAMX"
    $request.AllowAutoRedirect = $true
    $request.Timeout = $TimeoutMilliseconds
    $request.ReadWriteTimeout = $TimeoutMilliseconds
    $response = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reachable = $false
    try {
        $response = $request.GetResponse()
        $reachable = $true
    } catch {
        $statusCode = Get-HttpStatusCode -ErrorRecord $_
        $reachable = ($statusCode -ge 200 -and $statusCode -lt 500)
    } finally {
        $stopwatch.Stop()
        if ($null -ne $response) { $response.Dispose() }
    }

    return [pscustomobject]@{
        Url                 = $Url
        Reachable           = $reachable
        ElapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds
    }
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
        Write-Log -Message ("OST SHA-256 verified against GitHub release metadata: {0}" -f $downloadedSha256) -Scope "ost" -LogFile $LogFile
        return
    }

    if ($DownloadUrl -eq $OfficialUrl) {
        Write-Log -Message ("GitHub release metadata has no SHA-256 digest; official asset SHA-256: {0}" -f $downloadedSha256) -Level "WARN" -Scope "ost" -LogFile $LogFile
        return
    }

    $officialVerificationPath = "$DownloadedPath.official"
    try {
        Write-Log -Message "Release metadata has no SHA-256 digest; downloading the official asset for comparison." -Level "WARN" -Scope "ost" -LogFile $LogFile
        Invoke-DownloadFileWithProgress -Url $OfficialUrl -Destination $officialVerificationPath -TimeoutSeconds $TimeoutSeconds
        $officialSha256 = Get-FileSha256 -PathValue $officialVerificationPath
        if ([string]::IsNullOrWhiteSpace($officialSha256)) {
            throw "Unable to calculate the official OST SHA-256."
        }
        if ($downloadedSha256 -ne $officialSha256) {
            throw ("Mirror OST SHA-256 does not match the official asset. Mirror {0}, official {1}." -f $downloadedSha256, $officialSha256)
        }
        Write-Log -Message ("OST SHA-256 verified against the official asset: {0}" -f $downloadedSha256) -Scope "ost" -LogFile $LogFile
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
    Write-Log -Message ("Resolving latest OST release: {0}" -f $repo) -Scope "ost" -LogFile $RunContext.LogFile
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
                    Write-Log -Message ("Downloading OST asset from: {0}" -f $downloadUrl) -Scope "ost" -LogFile $RunContext.LogFile
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
                    Write-Log -Message ("Download candidate failed: {0}" -f $_.Exception.Message) -Level "WARN" -Scope "ost" -LogFile $RunContext.LogFile
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

    # Sources understood by the OST builds in the wild: the 1.5.x line knows the first three,
    # the 1.4.8.x line adds "manifestdex". "wudrm" is the one that keeps working from CN.
    $validSources = @("opensteamtool", "wudrm", "steamrun", "manifestdex")
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
        return $true
    }

    # An existing toml belongs to the user (everyone copies the example that ships with OST),
    # so only the [manifest] url line is ours to touch: rewrite that single line and keep the
    # comments, key order, BOM state and line endings exactly as they were. OST hot-reloads
    # the file, so nothing has to be restarted for this to take effect.
    $bytes = [System.IO.File]::ReadAllBytes($TomlPath)
    $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
    $encoding = New-Object System.Text.UTF8Encoding $hasBom
    $text = $encoding.GetString($bytes)
    $eol = ""
    if ($text.Contains("`r`n")) { $eol = "`r" }
    $lines = @($text -split "`n")

    $sectionSeen = $false
    $handled = $false
    $changed = $false
    $result = New-Object System.Collections.Generic.List[string]

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $current = [string]$lines[$index]
        $trimmed = $current.Trim()

        if (-not $sectionSeen) {
            if ($trimmed -eq "[manifest]") { $sectionSeen = $true }
            $result.Add($current)
            continue
        }

        if ($handled) {
            $result.Add($current)
            continue
        }

        if ($trimmed.StartsWith("[")) {
            # Section ended without a url key: ours goes in directly above this header.
            $result.Add($line + $eol)
            $handled = $true
            $changed = $true
            $result.Add($current)
            continue
        }

        if ($trimmed -match '^url[ \t]*=') {
            $handled = $true
            if ($trimmed -eq $line) {
                $result.Add($current)
            } else {
                $result.Add($line + $eol)
                $changed = $true
            }
            continue
        }

        $result.Add($current)
    }

    if (-not $sectionSeen) {
        $result.Add("")
        $result.Add("[manifest]")
        $result.Add($line + $eol)
        $changed = $true
    } elseif (-not $handled) {
        # Section runs to the end of the file; step back over the trailing blank lines.
        $insertAt = $result.Count
        while ($insertAt -gt 0 -and ([string]$result[$insertAt - 1]).Trim() -eq "") { $insertAt-- }
        $result.Insert($insertAt, $line + $eol)
        $changed = $true
    }

    if (-not $changed) { return $false }

    [System.IO.File]::WriteAllText($TomlPath, ($result -join "`n"), $encoding)
    return $true
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

    $steamVersion = Get-SteamVersionInfo -SteamPath $steamPath
    $steamBuildDisplay = Format-DateStamp -DateValue $steamVersion.BuildDate
    if ([string]::IsNullOrWhiteSpace($steamBuildDisplay)) { $steamBuildDisplay = "unknown" }
    Write-UiLog -Scope "check" -Level INFO -Message ("{0,-12}{1}" -f "steam.path", (Get-DisplayPath -PathValue $steamPath))
    Write-UiLog -Scope "check" -Level INFO -Message ("{0,-12}{1}" -f "steam.build", $steamBuildDisplay)
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
    $localOstLevel = if ($kernelState.Status -in @("Ready", "ReadyByDate")) {
        "SUCCESS"
    } elseif ($kernelState.Status -eq "UpdateAvailable") {
        "WARN"
    } else {
        "INFO"
    }
    Write-UiLog -Scope "check" -Level $localOstLevel -Message ("{0,-12}{1}" -f "ost.local", ("{0} ({1})" -f $localOstDisplay, $kernelState.Status))
    Write-UiLog -Scope "check" -Level INFO -Message ("{0,-12}{1}" -f "ost.latest", $latestOstDisplay)
    Write-UiLog -Scope "check" -Level INFO -Message ("{0,-12}{1}" -f "ost.legacy", $(if ($kernelState.LegacyPaths.Count -gt 0) { @($kernelState.LegacyPaths | ForEach-Object { Get-DisplayPath -PathValue $_ }) -join ", " } else { "none" }))
    if ($cfgState -ne "None") {
        Write-UiLog -Scope "check" -Level WARN -Message ("{0,-12}{1}" -f "steam.cfg", $cfgState)
    }
    Write-UiLog -Scope "check" -Level INFO -Message ("{0,-12}{1}" -f "ost.config", (Get-DisplayPath -PathValue (Get-OstConfigPath -Config $Config -SteamPath $steamPath)))

    if (-not $remote.Available) {
        Write-Log -Message ("Remote OST status unavailable: {0}" -f $remote.Error) -Level "WARN" -Scope "ost" -LogFile $RunContext.LogFile
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
            Write-Log -Message "Renamed steam.cfg to steam.cfg.bak." -Scope "ost" -LogFile $RunContext.LogFile
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
            Write-Log -Message ("Deployed: {0}" -f $item.TargetPath) -Scope "ost" -LogFile $RunContext.LogFile
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
        Write-Log -Message ("Deployment failed; rolling back: {0}" -f $_.Exception.Message) -Level "ERROR" -Scope "ost" -LogFile $RunContext.LogFile
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
    Write-Log -Message $successMessage -Level "SUCCESS" -Scope "ost" -LogFile $RunContext.LogFile
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
        Write-Log -Message ("Manifest source set to: {0}" -f $Source) -Scope "ost" -LogFile $RunContext.LogFile
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

    Write-UiLog -Scope "steamx" -Level WARN -Message $Message
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
        Write-Log -Message "Uninstall cancelled by user." -Level "WARN" -Scope "uninstall" -LogFile $RunContext.LogFile
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
            Write-Log -Message $warnings[-1] -Level "WARN" -Scope "uninstall" -LogFile $RunContext.LogFile
            continue
        }

        [void](Backup-ExistingFile -SourceFile $targetFile -BackupDir $RunContext.BackupDir)
        Remove-Item -LiteralPath $targetFile -Force
        if ([bool]$fileRecord.existed) {
            $originalBackup = [string]$fileRecord.backupPath
            if ([string]::IsNullOrWhiteSpace($originalBackup) -or -not (Test-Path -LiteralPath $originalBackup -PathType Leaf)) {
                $warnings += "Original backup is missing; cannot restore: $targetFile"
                Write-Log -Message $warnings[-1] -Level "WARN" -Scope "uninstall" -LogFile $RunContext.LogFile
            } else {
                Copy-Item -LiteralPath $originalBackup -Destination $targetFile -Force
                Write-Log -Message ("Restored original file: {0}" -f $targetFile) -Scope "uninstall" -LogFile $RunContext.LogFile
            }
        } else {
            Write-Log -Message ("Removed: {0}" -f $targetFile) -Scope "uninstall" -LogFile $RunContext.LogFile
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
            Write-Log -Message ("Cleared Lua manifests: {0}" -f $luaPath) -Scope "uninstall" -LogFile $RunContext.LogFile
        }
    }

    if ($warnings.Count -eq 0) {
        if ($RemoveLua) {
            Write-Log -Message ("Lua backup retained at: {0}" -f (Join-Path $RunContext.BackupDir "lua")) -Level "WARN" -Scope "uninstall" -LogFile $RunContext.LogFile
        } elseif (Test-Path -LiteralPath $RunContext.TransactionDir) {
            Remove-Item -LiteralPath $RunContext.TransactionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log -Message "Uninstall completed." -Scope "uninstall" -LogFile $RunContext.LogFile
    } else {
        Write-Log -Message ("Uninstall completed with warnings. {0}" -f ($warnings -join " | ")) -Level "WARN" -Scope "uninstall" -LogFile $RunContext.LogFile
    }
}

function Invoke-QuickStart {
    param([pscustomobject]$Config)

    Clear-Host
    Write-SteampXLogo

    $steamPath = Get-SteamPath -Config $Config
    $kernelState = Get-OstKernelState -Config $Config -SteamPath $steamPath
    if (-not $kernelState.IsReady) {
        Write-UiLine
        Write-UiLog -Scope "ost" -Message (ConvertFrom-Utf8Base64 "5pyq5qOA5rWL5Yiw6Kej6ZSB5YaF5qC477yM5q2j5Zyo6Ieq5Yqo6YOo572yIE9TVOKApg==") -Level WARN
        $runContext = New-RunContext -Config $Config
        Invoke-DeployOst -Config $Config -RunContext $runContext
        Write-UiLog -Scope "ost" -Message (ConvertFrom-Utf8Base64 "T1NUIOmDqOe9suWujOaIkO+8jOaOpeS4i+adpei+k+WFpea4uOaIjyBBcHBJRCDljbPlj6/lhaXlupPjgII=") -Level SUCCESS
    }

    while ($true) {
        Write-UiLine
        $rawInput = [string](Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "6K+36L6T5YWl5ri45oiPIEFwcElEIOaIliBTdGVhbSDllYblupfpk77mjqXvvIgxIOmDqOe9su+8jDAg5Y246L2977yMaCDluK7liqnvvIzlm57ovabpgIDlh7rvvIk="))
        $value = $rawInput.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        if ($value -match '^(?i)(q|quit|exit)$') { return }

        if ($value -match '^(?i)(h|help|\?)$') {
            Write-UiLine
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "5Y+v55So5ZG95Luk")
            Write-UiLine
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "PEFwcElEIOaIliBTdGVhbSDpk77mjqU+ICAg5ri45oiP5YWl5bqT")
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "MSAgICDpg6jnvbIgLyDph43mlrDpg6jnvbIgT1NU")
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "MCAgICDljbjovb0gT1NU77yIMSDku4UgT1NUIC8gMiDov57muIXljZXvvIk=")
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "aCAgICDmmL7npLrmnKzluK7liqk=")
            Write-UiLine -Text (ConvertFrom-Utf8Base64 "cSAvIOWbnui9piAgICDpgIDlh7o=")
            continue
        }

        if ($value -eq "1") {
            $runContext = New-RunContext -Config $Config
            Write-UiLog -Scope "ost" -Level INFO -Message (ConvertFrom-Utf8Base64 "5q2j5Zyo6YOo572yIE9TVCDnjq/looPigKY=")
            try {
                Invoke-DeployOst -Config $Config -RunContext $runContext
            } catch {
                Write-UiLog -Scope "steamx" -Level ERROR -Message $_.Exception.Message
            }
            continue
        }

        if ($value -match '^(?i)(0|u|uninstall)$') {
            $uninstallChoice = [string](Read-UiInput -Prompt (ConvertFrom-Utf8Base64 "6L6T5YWlIDEg5LuF5Y246L29IE9TVO+8m+i+k+WFpSAyIOWNuOi9vSBPU1Qg5bm25riF55CG5ri45oiP5riF5Y2V77yb5Zue6L2m5Y+W5raI"))
            $runContext = New-RunContext -Config $Config
            if ($uninstallChoice.Trim() -eq "1") {
                Invoke-UninstallOst -Config $Config -RunContext $runContext
            } elseif ($uninstallChoice.Trim() -eq "2") {
                Invoke-UninstallOst -Config $Config -RunContext $runContext -RemoveLua
            } else {
                Write-UiLog -Scope "steamx" -Message (ConvertFrom-Utf8Base64 "5bey5Y+W5raI44CC") -Level WARN
            }
            continue
        }

        # Single digits other than 0/1 are reserved command slots, not AppIDs.
        if ($value -match '^\d$') {
            Write-UiLog -Scope "steamx" -Level WARN -Message (ConvertFrom-Utf8Base64 "5peg5pWI6L6T5YWl44CC5Y+v6L6T5YWlIEFwcElEIC8gU3RlYW0g6ZO+5o6l77yM5oiWIDHjgIEw44CBaOOAgXE=")
            continue
        }

        try {
            Invoke-AddGame `
                -Config $Config `
                -InputAppId $value `
                -InputVariant "full" `
                -ConfiguredApiKey $ApiKey `
                -CredentialOverride $CredentialPath `
                -ForceApiKeyPrompt:$ResetApiKey `
                -RetryInvalidCredential `
                -LuaOverride $LuaPath `
                -RequestTimeoutSeconds $TimeoutSeconds
        } catch {
            Write-UiLog -Scope "steamx" -Message $_.Exception.Message -Level ERROR
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $config = Get-Config -ConfigOverride $ConfigPath
        $runContext = New-RunContext -Config $config

        switch ($Command) {
            "Start" { Invoke-QuickStart -Config $config }
            "Check" { Invoke-Check -Config $config -RunContext $runContext }
            "DeployOst" { Invoke-DeployOst -Config $config -RunContext $runContext }
            "EnableUnlockMode" { Invoke-EnableUnlockMode -Config $config -RunContext $runContext }
            "AddGame" {
                Invoke-AddGame `
                    -Config $config `
                    -InputAppId $AppId `
                    -InputVariant $Variant `
                    -ConfiguredApiKey $ApiKey `
                    -CredentialOverride $CredentialPath `
                    -ForceApiKeyPrompt:$ResetApiKey `
                    -LuaOverride $LuaPath `
                    -RequestedOutputName $OutputName `
                    -RequestTimeoutSeconds $TimeoutSeconds
            }
            "SetManifestSource" { Invoke-SetManifestSource -Config $config -RunContext $runContext -Source $ManifestSource }
            "UninstallOst" { Invoke-UninstallOst -Config $config -RunContext $runContext }
            "UninstallOstAndLua" { Invoke-UninstallOst -Config $config -RunContext $runContext -RemoveLua }
        }

    } catch {
        Write-UiLog -Scope "steamx" -Level ERROR -Message $_.Exception.Message
        Wait-LauncherExit
        exit 1
    }
}
