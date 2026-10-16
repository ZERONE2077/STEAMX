#requires -Version 5.1
<#
  死循环回归测试：模拟"zip 对了但内容不符预期"的完整启动流程

  背景：线上 1.5.3.6 的 zip 通过了 GitHub 官方 SHA-256 校验，但包里没有
        dwmapi.dll。旧代码因此每次启动都重新下载、重新部署、再次失败。

  本测试证明修复后：
    1) 这样的包能正常部署（不再因内容被判为坏包）
    2) 部署后 IsReady = true（不会每次启动都当"未安装"重装一遍）
    3) 幂等：第二次启动不再触发部署

  用真实函数（Get-OstKernelState / Get-OstLocalVersion）+ 真实文件系统。

  运行： pwsh -File _analysis\ost-loop-regression-test.ps1
#>

$ErrorActionPreference = 'Stop'

$mainPath = 'D:\Dev\STEAMX Cli\main.ps1'
$src = Get-Content $mainPath -Raw -Encoding UTF8

function Get-FunctionSource([string]$Name) {
    $m = [regex]::Match($src, "(?ms)^function\s+$([regex]::Escape($Name))\s*\{.*?^\}")
    if (-not $m.Success) { throw "无法抽取: $Name" }
    return $m.Value
}

$sandbox = Join-Path $env:TEMP ("steamx-loop-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0,8)))
$steamPath = Join-Path $sandbox "Steam"
$sourcePath = Join-Path $sandbox "extracted"
New-Item -ItemType Directory -Path $steamPath -Force | Out-Null
New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null

# ---- 测试用桩 ----
function Ensure-Directory { param([string]$PathValue) if (-not (Test-Path -LiteralPath $PathValue)) { New-Item -ItemType Directory -Path $PathValue -Force | Out-Null } }
function Get-ConfigValue { param($Object,[string]$Name,$DefaultValue=$null) if($null -eq $Object){return $DefaultValue}; $p=$Object.PSObject.Properties[$Name]; if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}; return $p.Value }
function Write-Log { param($Message,$Level,$Scope,$LogFile) }

# ---- 装真实函数 ----
$h = @()
foreach ($f in @('Get-OstLocalVersion','Get-OstKernelState','Assert-OstSourceFiles')) { $h += (Get-FunctionSource $f) }
$hf = Join-Path $sandbox 'h.ps1'
$h | Set-Content -LiteralPath $hf -Encoding UTF8
. $hf

$config = '{"ost":{"files":["dwmapi.dll","xinput1_4.dll","OpenSteamTool.dll"]}}' | ConvertFrom-Json

$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ("  [FAIL] {0}`n         期望: {1}`n         实际: {2}" -f $Label, $Expected, $Actual) -ForegroundColor Red }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " 死循环回归测试" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host (" 模拟 Steam 目录: {0}" -f $steamPath) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "准备：造一个「zip 对但缺 dwmapi.dll」的解压结果" -ForegroundColor Yellow
# 线上 1.5.3.6 的真实情况：只有 xinput1_4.dll 和 OpenSteamTool.dll
Set-Content -LiteralPath (Join-Path $sourcePath "OpenSteamTool.dll") -Value ('MZ' + ('x' * 500)) -Encoding ASCII
Set-Content -LiteralPath (Join-Path $sourcePath "xinput1_4.dll") -Value ('MZ' + ('y' * 300)) -Encoding ASCII
Write-Host ("  源文件: {0}" -f ((Get-ChildItem $sourcePath -File).Name -join ', ')) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "1  包能通过校验（旧代码在这里 throw）" -ForegroundColor Yellow
$passed = $false
try {
    Assert-OstSourceFiles -Config $config -SourcePath $sourcePath
    $passed = $true
} catch { }
Assert-Equal $passed 'True' "缺 dwmapi.dll 的包 → 通过校验（不再判为坏包）"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "2  部署前：内核状态" -ForegroundColor Yellow
$before = Get-OstKernelState -Config $config -SteamPath $steamPath
Assert-Equal $before.IsReady 'False' "部署前 IsReady=false"
Assert-Equal $before.Status 'NotInstalled' "部署前状态 NotInstalled"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "3  模拟部署（把源文件复制过去）" -ForegroundColor Yellow
foreach ($f in (Get-ChildItem $sourcePath -File)) {
    Copy-Item $f.FullName (Join-Path $steamPath $f.Name) -Force
}
Write-Host ("  Steam 目录现在: {0}" -f ((Get-ChildItem $steamPath -File).Name -join ', ')) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "4  部署后：内核状态（关键）" -ForegroundColor Yellow
$after = Get-OstKernelState -Config $config -SteamPath $steamPath
Assert-Equal $after.IsReady 'True' ">>> 部署后 IsReady=true（不再每次启动重装）" 
Assert-Equal $after.Status 'Partial' "状态为 Partial（装了，但与配置清单不完全一致）"
Assert-Equal $after.IsComplete 'False' "IsComplete=false（如实反映清单不全）"
Assert-Equal ($after.Missing -join ',') 'dwmapi.dll' "Missing 如实记录缺失项（供显示/卸载用）"
Write-Host "         >>> 关键：IsReady 与 IsComplete 解耦了。" -ForegroundColor Magenta
Write-Host "             Partial 不再触发「未安装→自动部署」分支，循环被打破。" -ForegroundColor Magenta
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "5  幂等性：第二次启动不会再部署" -ForegroundColor Yellow
$secondLaunch = Get-OstKernelState -Config $config -SteamPath $steamPath
$wouldRedeploy = (-not $secondLaunch.IsReady)
Assert-Equal $wouldRedeploy 'False' ">>> 第二次启动不会重新部署（幂等）"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "6  对照：清单齐全时行为不变" -ForegroundColor Yellow
Set-Content -LiteralPath (Join-Path $steamPath "dwmapi.dll") -Value ('MZ' + ('z' * 200)) -Encoding ASCII
$full = Get-OstKernelState -Config $config -SteamPath $steamPath
Assert-Equal $full.IsReady 'True' "齐全 → IsReady=true"
Assert-Equal $full.IsComplete 'True' "齐全 → IsComplete=true"
Assert-Equal $full.Missing.Count 0 "齐全 → 无缺失"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "7  对照：真正的空安装仍判为未安装" -ForegroundColor Yellow
$clean = Join-Path $sandbox "SteamClean"
New-Item -ItemType Directory -Path $clean -Force | Out-Null
$cleanState = Get-OstKernelState -Config $config -SteamPath $clean
Assert-Equal $cleanState.IsReady 'False' "空目录 → IsReady=false（仍会安装）"
Assert-Equal $cleanState.Status 'NotInstalled' "空目录 → NotInstalled"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "8  对照：只有非载荷文件时" -ForegroundColor Yellow
$shimOnly = Join-Path $sandbox "SteamShimOnly"
New-Item -ItemType Directory -Path $shimOnly -Force | Out-Null
Set-Content -LiteralPath (Join-Path $shimOnly "dwmapi.dll") -Value 'x' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $shimOnly "xinput1_4.dll") -Value 'x' -Encoding ASCII
$shimState = Get-OstKernelState -Config $config -SteamPath $shimOnly
Assert-Equal $shimState.IsReady 'False' "无 OpenSteamTool.dll → IsReady=false（会继续部署）"
Assert-Equal $shimState.Missing.Count 1 "只缺载荷本体"
Write-Host ""

Write-Host "==============================================================" -ForegroundColor Cyan
if ($script:Fail -eq 0) { Write-Host (" 全部通过: {0}/{0}" -f $script:Pass) -ForegroundColor Green }
else { Write-Host (" 通过 {0} / 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red }
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
exit ($(if ($script:Fail -eq 0) { 0 } else { 1 }))
