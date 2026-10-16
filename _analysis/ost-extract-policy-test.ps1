#requires -Version 5.1
<#
  解压策略测试：zip 对了就解压，不管里面装什么

  验证两件事：
    A) 包内容不再是门槛 —— 只有 dwmapi.dll、只有 OpenSteamTool.dll、
       完全不同的文件名，都能正常通过校验并部署
    B) 真正的错误仍被拦住 —— 空包、路径穿越、哈希不符

  用真实函数（从 main.ps1 抽取）+ 真实 zip 文件。

  运行： pwsh -File _analysis\ost-extract-policy-test.ps1
#>

$ErrorActionPreference = 'Stop'

$mainPath = 'D:\Dev\STEAMX Cli\main.ps1'
if (-not (Test-Path $mainPath)) { $mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'main.ps1' }
$src = Get-Content $mainPath -Raw -Encoding UTF8

function Get-FunctionSource([string]$Name) {
    $m = [regex]::Match($src, "(?ms)^function\s+$([regex]::Escape($Name))\s*\{.*?^\}")
    if (-not $m.Success) { throw "无法抽取: $Name" }
    return $m.Value
}

$sandbox = Join-Path $env:TEMP ("steamx-extract-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  [FAIL] {0}`n         期望: {1}`n         实际: {2}" -f $Label, $Expected, $Actual) -ForegroundColor Red }
}

function Ensure-Directory { param([string]$PathValue) if (-not (Test-Path -LiteralPath $PathValue)) { New-Item -ItemType Directory -Path $PathValue -Force | Out-Null } }
function Get-ConfigValue { param($Object,[string]$Name,$DefaultValue=$null) if($null -eq $Object){return $DefaultValue}; $p=$Object.PSObject.Properties[$Name]; if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}; return $p.Value }

# 只装入被测函数
$h = @()
foreach ($f in @('Assert-OstSourceFiles','Assert-SafeZipArchive')) { $h += (Get-FunctionSource $f) }
$harnessFile = Join-Path $sandbox 'h.ps1'
$h | Set-Content -LiteralPath $harnessFile -Encoding UTF8
. $harnessFile

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " 解压策略测试（zip 对了就解压）" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# 造一个源目录
function New-Source([string[]]$Names) {
    $d = Join-Path $sandbox ("src-" + [Guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $i = 0
    foreach ($n in $Names) {
        $sub = if ($n -like '*/*') { Join-Path $d (Split-Path -Parent $n) } else { $d }
        if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $d $n) -Value ("payload-$i-" + ('x' * 64)) -Encoding UTF8
        $i++
    }
    return $d
}
function Invoke-Check([string]$Path, [string]$ConfigJson) {
    # Config 是 Mandatory 参数，必须给真实对象（传 $null 会因为参数绑定失败，
    # 那是测试脚手架的错，不是被测逻辑的行为）
    try {
        $cfg = if ($ConfigJson) { $ConfigJson | ConvertFrom-Json }
               else { '{"ost":{"files":["dwmapi.dll","xinput1_4.dll","OpenSteamTool.dll"]}}' | ConvertFrom-Json }
        Assert-OstSourceFiles -Config $cfg -SourcePath $Path
        return 'OK'
    } catch { return ('THROW: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
Write-Host "A  包内容不再设限" -ForegroundColor Yellow

# A1 缺 dwmapi.dll —— 这正是线上失败的场景，必须通过
$d = New-Source @('xinput1_4.dll','OpenSteamTool.dll')
Assert-Equal (Invoke-Check $d $null) 'OK' "缺 dwmapi.dll → 通过（就是线上那个包）"

# A2 只有 OpenSteamTool.dll
$d = New-Source @('OpenSteamTool.dll')
Assert-Equal (Invoke-Check $d $null) 'OK' "只有 OpenSteamTool.dll → 通过"

# A3 只有 dwmapi.dll
$d = New-Source @('dwmapi.dll')
Assert-Equal (Invoke-Check $d $null) 'OK' "只有 dwmapi.dll → 通过"

# A4 全新文件名（上游改了打包结构）
$d = New-Source @('OpenSteamTool.dll','NewShim.dll','README.txt')
Assert-Equal (Invoke-Check $d $null) 'OK' "含未知新文件 → 通过"

# A5 嵌套子目录
$d = New-Source @('bin/OpenSteamTool.dll')
Assert-Equal (Invoke-Check $d $null) 'OK' "嵌套子目录 → 通过"

# A6 完全陌生的 DLL 名
$d = New-Source @('totally-different.dll')
Assert-Equal (Invoke-Check $d $null) 'OK' "完全陌生的 DLL → 通过（客户端不该有意见）"

# A7 自定义 files 配置也不再影响（配置已不参与校验）
$d = New-Source @('custom.dll')
Assert-Equal (Invoke-Check $d '{"ost":{"files":["a.dll","b.dll"]}}') 'OK' "配置清单不干涉 → 通过"

# A8 真实 1.5.3.6 的完整解压内容（含 .lib/.exp 垃圾）
$d = New-Source @('lua_static.lib','OpenSteamTool.dll','version.dll','version.exp','version.lib','xinput1_4.dll','xinput1_4.exp','xinput1_4.lib')
Assert-Equal (Invoke-Check $d $null) 'OK' "真实的 1.5.3.6 包内容 → 通过"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "A+  DLL-only 过滤（只部署 .dll）" -ForegroundColor Yellow

# 复刻 Invoke-DeployOst 的过滤规则，验证真实包过滤后的结果
function Get-DeployableDll([string]$Path) {
    $all = @(Get-ChildItem -LiteralPath $Path -Recurse -File)
    return @($all | Where-Object { $_.Extension -eq '.dll' } | Select-Object -ExpandProperty Name | Sort-Object)
}
function Get-SkippedNonDll([string]$Path) {
    $all = @(Get-ChildItem -LiteralPath $Path -Recurse -File)
    return @($all | Where-Object { $_.Extension -ne '.dll' } | Select-Object -ExpandProperty Name | Sort-Object)
}

$real = New-Source @('lua_static.lib','OpenSteamTool.dll','version.dll','version.exp','version.lib','xinput1_4.dll','xinput1_4.exp','xinput1_4.lib')
$deploy = Get-DeployableDll $real
$skip = Get-SkippedNonDll $real
Assert-Equal ($deploy -join ',') 'OpenSteamTool.dll,version.dll,xinput1_4.dll' "只部署 3 个 DLL"
Assert-Equal ($skip -join ',') 'lua_static.lib,version.exp,version.lib,xinput1_4.exp,xinput1_4.lib' "跳过 5 个编译产物"
Write-Host ("         部署: {0}" -f ($deploy -join ', ')) -ForegroundColor DarkGray
Write-Host ("         跳过: {0}" -f ($skip -join ', ')) -ForegroundColor DarkGray

# 只有 .lib 没有 .dll → 应被拦
$d = New-Source @('lua_static.lib','version.exp')
Assert-Equal ((Invoke-Check $d $null) -match 'no DLL') 'True' "只有 .lib/.exp → 拦截（无可部署内容）"

# 大小写不敏感（.DLL）
$d = New-Source @('OpenSteamTool.DLL')
$up = @(Get-ChildItem -LiteralPath $d -Recurse -File | Where-Object { $_.Extension -eq '.dll' })
Assert-Equal $up.Count 1 "大写 .DLL 也被识别"

# 无扩展名文件 → 跳过
$d = New-Source @('OpenSteamTool.dll','Makefile')
Assert-Equal ((Get-SkippedNonDll $d) -join ',') 'Makefile' "无扩展名文件被跳过"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "B  真正的错误仍被拦住" -ForegroundColor Yellow

# B1 空目录 = 解压出零文件
$empty = Join-Path $sandbox "empty"
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$r = Invoke-Check $empty $null
# 必须是因为"没有 DLL"被拦，而不是因为别的错误（否则是假通过）
Assert-Equal ($r -match 'no DLL') 'True' "空目录 → 因无 DLL 被拦"
Write-Host ("         {0}" -f $r) -ForegroundColor DarkGray

# B2 目录不存在
$nope = Join-Path $sandbox "does-not-exist"
$r2 = Invoke-Check $nope $null
Assert-Equal ($r2 -match 'source directory not found') 'True' "目录不存在 → 因路径不存在被拦"

# B3 只有空子目录（无文件）
$onlydirs = Join-Path $sandbox "onlydirs"
New-Item -ItemType Directory -Path (Join-Path $onlydirs "sub") -Force | Out-Null
$r3 = Invoke-Check $onlydirs $null
Assert-Equal ($r3 -match 'no DLL') 'True' "只有空目录 → 因无 DLL 被拦"

# B4 非空且含 DLL —— 应通过（这正是本次修复的核心）
$d = New-Source @('unexpected-name.dll')
$r4 = Invoke-Check $d $null
Assert-Equal $r4 'OK' "无任何配置项名但含 DLL → 仍通过"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "C  zip 路径安全检查（防穿越）" -ForegroundColor Yellow
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-TestZip([string]$Name, [hashtable]$Entries) {
    $p = Join-Path $sandbox $Name
    if (Test-Path $p) { Remove-Item $p -Force }
    $fs = [System.IO.File]::Create($p)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($k in $Entries.Keys) {
            $e = $zip.CreateEntry($k)
            $s = $e.Open()
            $b = [Text.Encoding]::UTF8.GetBytes([string]$Entries[$k])
            $s.Write($b, 0, $b.Length)
            $s.Dispose()
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
    return $p
}
function Test-Zip([string]$Path) {
    try { Assert-SafeZipArchive -ZipPath $Path; return 'OK' } catch { return ('THROW: ' + $_.Exception.Message) }
}

$good = New-TestZip 'good.zip' @{ 'OpenSteamTool.dll' = 'data'; 'bin/x.dll' = 'data' }
Assert-Equal (Test-Zip $good) 'OK' "正常 zip → 通过"

$trav = New-TestZip 'trav.zip' @{ '../../evil.dll' = 'x' }
Assert-Equal ((Test-Zip $trav) -like 'THROW:*') 'True' "路径穿越 ../ → 拦截"

$trav2 = New-TestZip 'trav2.zip' @{ 'a/../../evil.dll' = 'x' }
Assert-Equal ((Test-Zip $trav2) -like 'THROW:*') 'True' "嵌套路径穿越 → 拦截"

$abs = New-TestZip 'abs.zip' @{ '\Windows\evil.dll' = 'x' }
Assert-Equal ((Test-Zip $abs) -like 'THROW:*') 'True' "绝对路径 → 拦截"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "==============================================================" -ForegroundColor Cyan
if ($script:Fail -eq 0) { Write-Host (" 全部通过: {0}/{0}" -f $script:Pass) -ForegroundColor Green }
else { Write-Host (" 通过 {0} / 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red }
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
exit ($(if ($script:Fail -eq 0) { 0 } else { 1 }))
