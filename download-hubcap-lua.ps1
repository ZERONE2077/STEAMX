[CmdletBinding()]
param(
    [string]$AppId = "",

    [ValidateSet("full", "basegame", "dlc")]
    [string]$Variant = "full",

    [string]$ApiKey = "",
    [string]$SteamPath = "",
    [string]$LuaPath = "",
    [string]$ConfigPath = "",
    [string]$OutputName = "",
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$DefaultHubcapApiKey = "smm_c26cc9d7de4b4dc96dab8a1081a99fedf59099637bbeac3c00d502c6a7286b1530144ea5af466c893f9eb28392e974a8"

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

function Resolve-AppId {
    param([string]$InputValue)

    if (-not [string]::IsNullOrWhiteSpace($InputValue)) {
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
    }

    $promptValue = Read-Host "AppId or Steam Store URL"
    if (-not [string]::IsNullOrWhiteSpace($promptValue)) {
        return Resolve-AppId -InputValue $promptValue
    }

    throw "AppId is required. Pass a numeric AppId or a Steam store URL."
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
        return $null
    }

    return (Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-SteamPath {
    param([string]$ConfiguredSteamPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredSteamPath) -and (Test-Path -LiteralPath $ConfiguredSteamPath)) {
        return $ConfiguredSteamPath
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
            return $candidate
        }
    }

    throw "Steam path not found. Pass -SteamPath explicitly."
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Get-LuaDirectory {
    param(
        [string]$ConfiguredLuaPath,
        [string]$ResolvedSteamPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredLuaPath)) {
        return $ConfiguredLuaPath
    }

    return (Join-Path $ResolvedSteamPath "config\lua")
}

function Get-ApiKey {
    param(
        [string]$ConfiguredApiKey,
        $Config
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredApiKey)) {
        return $ConfiguredApiKey
    }

    if ($null -ne $Config) {
        $hubcapNode = Get-ObjectPropertyValue -Object $Config -Name "hubcap"
        if ($null -ne $hubcapNode) {
            $hubcapApiKey = Get-ObjectPropertyValue -Object $hubcapNode -Name "apiKey"
            if (-not [string]::IsNullOrWhiteSpace($hubcapApiKey)) {
                return [string]$hubcapApiKey
            }
        }

        $rootApiKey = Get-ObjectPropertyValue -Object $Config -Name "hubcapApiKey"
        if (-not [string]::IsNullOrWhiteSpace($rootApiKey)) {
            return [string]$rootApiKey
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HUBCAP_API_KEY)) {
        return $env:HUBCAP_API_KEY
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultHubcapApiKey)) {
        return $DefaultHubcapApiKey
    }

    $promptedApiKey = Read-Host "Hubcap API Key"
    if (-not [string]::IsNullOrWhiteSpace($promptedApiKey)) {
        return $promptedApiKey
    }

    throw "API key is required. Pass -ApiKey, set HUBCAP_API_KEY, or put hubcap.apiKey in steamx.config.json."
}

function Get-EndpointUrl {
    param(
        [string]$ResolvedVariant,
        [string]$ResolvedAppId
    )

    switch ($ResolvedVariant) {
        "full" {
            return "https://hubcapmanifest.com/api/v1/lua/$ResolvedAppId"
        }
        "basegame" {
            return "https://hubcapmanifest.com/api/v1/lua/basegame/$ResolvedAppId"
        }
        "dlc" {
            return "https://hubcapmanifest.com/api/v1/lua/dlc/$ResolvedAppId"
        }
        default {
            throw "Unsupported variant: $ResolvedVariant"
        }
    }
}

function Get-DefaultOutputName {
    param(
        [string]$ResolvedVariant,
        [string]$ResolvedAppId
    )

    switch ($ResolvedVariant) {
        "full" { return "$ResolvedAppId.lua" }
        default { return "$ResolvedAppId.$ResolvedVariant.lua" }
    }
}

function Test-ZipFile {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $stream = [System.IO.File]::OpenRead($PathValue)
    try {
        if ($stream.Length -lt 4) {
            return $false
        }

        $buffer = New-Object byte[] 4
        [void]$stream.Read($buffer, 0, 4)
        return (
            $buffer[0] -eq 0x50 -and
            $buffer[1] -eq 0x4B -and
            $buffer[2] -eq 0x03 -and
            $buffer[3] -eq 0x04
        )
    } finally {
        $stream.Dispose()
    }
}

function Copy-LuaFilesFromDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    $luaFiles = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Filter *.lua)
    if ($luaFiles.Count -eq 0) {
        throw "No .lua files found after extracting archive."
    }

    foreach ($file in $luaFiles) {
        $targetFile = Join-Path $TargetDirectory $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force
        Write-Host ("Copied: {0}" -f $targetFile)
    }
}

$resolvedAppId = Resolve-AppId -InputValue $AppId
$config = Get-Config -ConfigOverride $ConfigPath
$resolvedSteamPath = Get-SteamPath -ConfiguredSteamPath $SteamPath
$resolvedLuaPath = Get-LuaDirectory -ConfiguredLuaPath $LuaPath -ResolvedSteamPath $resolvedSteamPath
$resolvedApiKey = Get-ApiKey -ConfiguredApiKey $ApiKey -Config $config
$downloadUrl = Get-EndpointUrl -ResolvedVariant $Variant -ResolvedAppId $resolvedAppId
$finalOutputName = if ([string]::IsNullOrWhiteSpace($OutputName)) {
    Get-DefaultOutputName -ResolvedVariant $Variant -ResolvedAppId $resolvedAppId
} else {
    $OutputName
}

Ensure-Directory -PathValue $resolvedLuaPath

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("steamx-lua-" + [Guid]::NewGuid().ToString("N"))
$tempDownload = Join-Path $tempRoot "download.bin"
$tempExtract = Join-Path $tempRoot "extract"

try {
    Ensure-Directory -PathValue $tempRoot

    $headers = @{
        "Authorization" = "Bearer $resolvedApiKey"
        "User-Agent"    = "STEAMX"
        "Accept"        = "*/*"
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempDownload -Headers $headers -TimeoutSec $TimeoutSeconds | Out-Null

    if (Test-ZipFile -PathValue $tempDownload) {
        Ensure-Directory -PathValue $tempExtract
        Expand-Archive -LiteralPath $tempDownload -DestinationPath $tempExtract -Force
        Copy-LuaFilesFromDirectory -SourceDirectory $tempExtract -TargetDirectory $resolvedLuaPath
        Write-Host ("Downloaded and extracted Lua archive to: {0}" -f $resolvedLuaPath)
    } else {
        $targetFile = Join-Path $resolvedLuaPath $finalOutputName
        Copy-Item -LiteralPath $tempDownload -Destination $targetFile -Force
        Write-Host ("Downloaded Lua file to: {0}" -f $targetFile)
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
