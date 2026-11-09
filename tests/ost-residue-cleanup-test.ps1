#requires -Version 5.1
<#
  OST stale residue cleanup test.

  Extracts the real cleanup functions from main.ps1 and runs them against a
  temporary fake Steam directory. The test verifies:
    - every configured residue target is removed
    - unrelated files and directories remain
    - cleanup creates no backup
    - a no-op install produces no log output
    - traversal, rooted paths and reparse points are rejected
    - the first-run cleanup marker is one-shot and isolated to the test sandbox

  Run:
    powershell.exe -NoProfile -File tests\ost-residue-cleanup-test.ps1
#>

$ErrorActionPreference = 'Stop'

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'main.ps1'
$src = Get-Content -LiteralPath $mainPath -Raw -Encoding UTF8

function Get-FunctionSource([string]$Name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($Name))\s*\{.*?^\}"
    $match = [regex]::Match($src, $pattern)
    if (-not $match.Success) { throw ("Function not found: {0}" -f $Name) }
    return $match.Value
}

$sandbox = Join-Path $env:TEMP ("steamx-residue-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
$steamPath = Join-Path $sandbox 'Steam'
$outsidePath = Join-Path $sandbox 'Outside'
$harnessPath = Join-Path $sandbox 'harness.ps1'
New-Item -ItemType Directory -Path $steamPath -Force | Out-Null
New-Item -ItemType Directory -Path $outsidePath -Force | Out-Null

$script:LogMessages = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param($Message, $Level, $Scope, $LogFile)
    $script:LogMessages.Add([string]$Message)
}

$script:TestLocalAppData = Join-Path $sandbox 'LocalAppData'
New-Item -ItemType Directory -Path $script:TestLocalAppData -Force | Out-Null
$markerPathFunction = (Get-FunctionSource 'Get-OstStartupCleanupMarkerPath').Replace(
    '    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")',
    '    $localAppData = $script:TestLocalAppData'
).Replace(
    '    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [System.IO.Path]::GetTempPath() }',
    ''
)

$harness = @(
    (Get-FunctionSource 'Get-OstStaleResiduePaths'),
    (Get-FunctionSource 'Remove-OstStaleResidue'),
    $markerPathFunction,
    (Get-FunctionSource 'Test-OstStartupCleanupCompleted'),
    (Get-FunctionSource 'Set-OstStartupCleanupCompleted')
) -join "`n`n"
[System.IO.File]::WriteAllText($harnessPath, $harness, (New-Object System.Text.UTF8Encoding $false))
. $harnessPath

function Ensure-Directory {
    param([string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

$script:Pass = 0
$script:Fail = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ("$Actual" -eq "$Expected") {
        $script:Pass++
        Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}`n         expected: {1}`n         actual:   {2}" -f $Label, $Expected, $Actual) -ForegroundColor Red
    }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    try {
        & $Action
        $script:Fail++
        Write-Host ("  [FAIL] {0} (did not throw)" -f $Label) -ForegroundColor Red
    } catch {
        if ($_.Exception.Message -match $Pattern) {
            $script:Pass++
            Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
        } else {
            $script:Fail++
            Write-Host ("  [FAIL] {0}`n         expected match: {1}`n         actual:         {2}" -f $Label, $Pattern, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function New-File {
    param([string]$RelativePath, [string]$Content = 'stale')
    $path = Join-Path $steamPath $RelativePath
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function New-Directory {
    param([string]$RelativePath)
    $path = Join-Path $steamPath $RelativePath
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

function Reset-FakeSteam {
    Get-ChildItem -LiteralPath $steamPath -Force | Remove-Item -Recurse -Force
    [System.IO.File]::WriteAllText((Join-Path $steamPath 'steam.exe'), 'stub', (New-Object System.Text.UTF8Encoding $false))
}

try {
    Write-Host ''
    Write-Host '1  Every target is removed; unrelated content remains' -ForegroundColor Yellow
    Reset-FakeSteam
    $targets = @(Get-OstStaleResiduePaths)
    foreach ($target in $targets) {
        if ([System.IO.Path]::GetExtension($target) -eq '.dll' -or [System.IO.Path]::GetExtension($target) -eq '.exe' -or
            [System.IO.Path]::GetExtension($target) -eq '.cfg' -or [System.IO.Path]::GetExtension($target) -eq '.ini' -or
            [System.IO.Path]::GetExtension($target) -eq '.bak') {
            New-File $target
        } else {
            New-Directory $target
            New-File (Join-Path $target 'nested.bin')
        }
    }
    New-File 'bin\unrelated.dll'
    New-File 'package\keep.txt'
    New-File 'steam.cfg.bak'
    New-File 'unrelated.txt'
    New-Directory 'unrelated-folder'
    New-File 'unrelated-folder\keep.bin'

    $script:LogMessages.Clear()
    Remove-OstStaleResidue -SteamPath $steamPath -LogFile '' | Out-Null

    $remainingTargets = @($targets | Where-Object { Test-Path -LiteralPath (Join-Path $steamPath $_) })
    Assert-Equal $targets.Count 32 'configured target count is 32'
    Assert-Equal ($targets -contains 'package\beta') 'True' 'package\beta is configured'
    Assert-Equal ($targets -contains 'package\bin') 'False' 'package\bin is not configured'
    Assert-Equal $remainingTargets.Count 0 'all 32 residue targets removed'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $steamPath 'bin\unrelated.dll')) 'True' 'unrelated file under bin remains'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $steamPath 'package\keep.txt')) 'True' 'unrelated file under package remains'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $steamPath 'steam.cfg.bak')) 'True' 'steam.cfg.bak remains'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $steamPath 'unrelated-folder\keep.bin')) 'True' 'unrelated directory remains'
    Assert-Equal (@($script:LogMessages | Where-Object { $_ -like 'Removed stale residue:*' }).Count) $targets.Count 'each removed target is logged'
    Assert-Equal (@(Get-ChildItem -LiteralPath $steamPath -Directory -Force | Where-Object Name -like '*backup*').Count) 0 'cleanup creates no backup directory'
    Write-Host ''

    Write-Host '2  A clean install is silent' -ForegroundColor Yellow
    Reset-FakeSteam
    $script:LogMessages.Clear()
    Remove-OstStaleResidue -SteamPath $steamPath -LogFile '' | Out-Null
    Assert-Equal $script:LogMessages.Count 0 'no residue and no logs'
    Write-Host ''

    Write-Host '3  Path validation rejects escapes' -ForegroundColor Yellow
    $pathCheckSource = (Get-FunctionSource 'Remove-OstStaleResidue').Replace(
        'foreach ($relativePath in @(Get-OstStaleResiduePaths)) {',
        'foreach ($relativePath in @($RelativePaths)) {'
    )
    $pathCheckSource = $pathCheckSource.Replace(
        'function Remove-OstStaleResidue {',
        'function Test-ResiduePathValidation {'
    )
    $pathCheckSource = $pathCheckSource.Replace(
        "        [AllowEmptyString()][string]`$LogFile = `"`"",
        "        [AllowEmptyString()][string]`$LogFile = `"`",`n        [string[]]`$RelativePaths = @(Get-OstStaleResiduePaths)"
    )
    $pathCheckPath = Join-Path $sandbox 'path-check.ps1'
    [System.IO.File]::WriteAllText($pathCheckPath, $pathCheckSource, (New-Object System.Text.UTF8Encoding $false))
    . $pathCheckPath

    Assert-Throws { Test-ResiduePathValidation -SteamPath $steamPath -RelativePaths @('../outside.txt') } 'Unsafe residue path' 'parent traversal is rejected'
    Assert-Throws { Test-ResiduePathValidation -SteamPath $steamPath -RelativePaths @((Join-Path $outsidePath 'rooted.txt')) } 'Unsafe residue path' 'rooted path is rejected'
    Write-Host ''

    Write-Host '4  Reparse points are rejected' -ForegroundColor Yellow
    Reset-FakeSteam
    $junctionPath = Join-Path $steamPath 'diversion'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $outsidePath -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Host '  [SKIP] junction creation unavailable in this environment' -ForegroundColor DarkYellow
    }
    if ($junctionCreated) {
        Assert-Throws { Remove-OstStaleResidue -SteamPath $steamPath -LogFile '' } 'reparse point' 'junction target is rejected'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $outsidePath 'keep.txt')) 'False' 'outside path was not touched'
        Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''

    Write-Host '5  First-run cleanup marker is one-shot' -ForegroundColor Yellow
    $markerPath = Get-OstStartupCleanupMarkerPath
    Assert-Equal $markerPath (Join-Path $script:TestLocalAppData 'STEAMX\ost-startup-cleanup-v1.done') 'marker lives under LOCALAPPDATA'
    Assert-Equal (Test-OstStartupCleanupCompleted) 'False' 'marker starts absent'
    Set-OstStartupCleanupCompleted
    Assert-Equal (Test-OstStartupCleanupCompleted) 'True' 'marker appears after success'
    Assert-Equal (Test-Path -LiteralPath $markerPath -PathType Leaf) 'True' 'marker is a file'
    $script:LogMessages.Clear()
    Set-OstStartupCleanupCompleted
    Assert-Equal $script:LogMessages.Count 0 'writing the marker is silent'
    Write-Host ''
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '==============================================================' -ForegroundColor Cyan
if ($script:Fail -eq 0) {
    Write-Host (" ALL PASS: {0}/{0}" -f $script:Pass) -ForegroundColor Green
} else {
    Write-Host (" PASS {0} / FAIL {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red
}
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ''
exit ($(if ($script:Fail -eq 0) { 0 } else { 1 }))
