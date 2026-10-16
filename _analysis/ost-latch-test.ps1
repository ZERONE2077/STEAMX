#requires -Version 5.1
<#
  STEAMX / OST 自动更新 latch 行为测试

  范围：
    1) 原有 latch 语义（读写/去重/上限/容错）——防回归
    2) 新增：失败分类、失败记录、跳过已知缺陷版本、手动重试清除记录

  只用真实代码路径：
    - 被测函数从 main.ps1 原文抽取，不改写
    - 状态文件重定向到隔离临时目录（不碰真实 %LOCALAPPDATA%）

  运行： pwsh -File _analysis\ost-latch-test.ps1
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 测试床
# ---------------------------------------------------------------------------
$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'main.ps1'
if (-not (Test-Path $mainPath)) { $mainPath = 'D:\Dev\STEAMX Cli\main.ps1' }
$src = Get-Content $mainPath -Raw -Encoding UTF8

function Get-FunctionSource([string]$Name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($Name))\s*\{.*?^\}"
    $m = [regex]::Match($src, $pattern)
    if (-not $m.Success) { throw "无法从 main.ps1 抽取函数: $Name" }
    return $m.Value
}

# 抽取用非贪婪匹配到行首的 '}'，相邻函数的定义可能被一并带出来。
# Get-OstUpdateStatePath 若被带入并定义在沙箱覆盖之后，就会把覆盖顶掉，
# 测试转而写用户的真实 %LOCALAPPDATA%。所有抽取结果都过一遍这里。
function Remove-ForeignDefinitions([string]$Text) {
    return [regex]::Replace($Text, '(?ms)^function\s+Get-OstUpdateStatePath\s*\{.*?^\}\s*', '')
}

$sandbox = Join-Path $env:TEMP ("steamx-latch-test-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

function Ensure-Directory {
    param([string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue)) { New-Item -ItemType Directory -Path $PathValue -Force | Out-Null }
}
function Get-ObjectPropertyValue {
    param($Object, [string]$Name, $DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $DefaultValue }
    return $p.Value
}

$overridden = 'function Get-OstUpdateStatePath { return (Join-Path $env:STEAMX_TEST_SANDBOX "ost-update-state.json") }'
$harness = @($overridden)
foreach ($fn in @('Get-OstUpdateState','Save-OstUpdateState','Get-OstHandledTags','Get-OstFailedTag',
                  'Get-OstFailureKind','Test-OstFailureRetryable','Add-OstHandledTag',
                  'Add-OstFailedTag','Clear-OstFailedTag')) {
    $harness += (Remove-ForeignDefinitions (Get-FunctionSource $fn))
}
# 抽取的函数里若含真实的 Get-OstUpdateStatePath，会覆盖上面的沙箱版本，
# 于是测试直接写进用户的真实 %LOCALAPPDATA%。这里断言覆盖确实生效，
# 一旦失效立刻中止，绝不在真实环境上跑测试。
$harnessFile = Join-Path $sandbox 'harness.ps1'
$harness | Set-Content -LiteralPath $harnessFile -Encoding UTF8
$env:STEAMX_TEST_SANDBOX = $sandbox
. $harnessFile

$resolved = Get-OstUpdateStatePath
if (-not $resolved.StartsWith($sandbox, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "沙箱隔离失败：状态文件会写到 $resolved。已中止，避免污染真实环境。"
}
Write-Host (" 隔离确认: {0}" -f $resolved) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 断言
# ---------------------------------------------------------------------------
$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ("$Actual" -eq "$Expected") {
        $script:Pass++; Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}`n         期望: {1}`n         实际: {2}" -f $Label, $Expected, $Actual) -ForegroundColor Red
    }
}
function Reset-Latch { Remove-Item -LiteralPath (Get-OstUpdateStatePath) -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " STEAMX / OST 自动更新 latch 测试" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host (" 沙箱: {0}" -f $sandbox) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# T1  latch 基本语义（回归）
# ---------------------------------------------------------------------------
Write-Host "T1  latch 基本语义（回归）" -ForegroundColor Yellow
Reset-Latch
Assert-Equal (Get-OstHandledTags).Count 0 "初始为空"

Add-OstHandledTag -Tag '1.5.3.5'
Assert-Equal ((Get-OstHandledTags) -join ',') '1.5.3.5' "写入后可读回"

Add-OstHandledTag -Tag '1.5.3.5'
Assert-Equal (Get-OstHandledTags).Count 1 "重复写入不重复"

Add-OstHandledTag -Tag '1.5.3.6'
Assert-Equal ((Get-OstHandledTags) -join ',') '1.5.3.5,1.5.3.6' "可追加"
Write-Host ""

# ---------------------------------------------------------------------------
# T2  向后兼容：旧格式状态文件（只有 handledTags）
# ---------------------------------------------------------------------------
Write-Host "T2  向后兼容（旧格式状态文件）" -ForegroundColor Yellow
Reset-Latch
Set-Content -LiteralPath (Get-OstUpdateStatePath) -Value '{"handledTags":["1.5.3.5"]}' -Encoding UTF8
$st = Get-OstUpdateState
Assert-Equal ($st.handledTags -join ',') '1.5.3.5' "旧文件 handledTags 可读"
Assert-Equal $st.failedTags.Count 0 "旧文件无 failedTags → 空数组（不崩）"

Add-OstFailedTag -Tag '1.5.3.6' -Reason 'test' -Kind 'ContentDefect'
$st2 = Get-OstUpdateState
Assert-Equal ($st2.handledTags -join ',') '1.5.3.5' "升级写入后 handledTags 保留"
Assert-Equal $st2.failedTags.Count 1 "failedTags 已写入"
Write-Host ""

# ---------------------------------------------------------------------------
# T3  失败分类
# ---------------------------------------------------------------------------
Write-Host "T3  失败分类（决定是否重试）" -ForegroundColor Yellow
$cases = @(
    @{ m = 'OST package is incomplete. Missing: dwmapi.dll'; e = 'ContentDefect' },
    @{ m = 'OST validation failed. Missing: OpenSteamTool.dll'; e = 'ContentDefect' },
    @{ m = 'Mirror OST SHA-256 does not match the official asset.'; e = 'IntegrityMismatch' },
    @{ m = 'OST archive is invalid or cannot be extracted: bad end of central directory'; e = 'ArchiveDefect' },
    @{ m = 'Unable to download OST asset from any configured source. x: timed out'; e = 'Transient' },
    @{ m = 'Unable to fetch the latest OST release: The SSL connection could not be established'; e = 'Transient' },
    # DNS 抖动是瞬时故障，必须保持可重试——曾经被误判为 Unknown 而永久跳过版本
    @{ m = 'Unable to fetch the latest OST release: No such host is known'; e = 'Transient' },
    @{ m = 'Unable to download OST asset from any configured source. remote name could not be resolved'; e = 'Transient' },
    # 空/无信息归为保守分支
    @{ m = ''; e = 'Unknown' },
    @{ m = 'some brand new error text nobody anticipated'; e = 'Unknown' }
)
foreach ($c in $cases) {
    Assert-Equal (Get-OstFailureKind -Message $c.m) $c.e ("分类: " + $c.m.Substring(0, [Math]::Min(45, $c.m.Length)) + "...")
}
Write-Host ""

# ---------------------------------------------------------------------------
# T4  关键：缺文件这类确定性失败不重试，网络失败仍重试
# ---------------------------------------------------------------------------
Write-Host "T4  重试策略" -ForegroundColor Yellow
Assert-Equal (Test-OstFailureRetryable -Kind 'ContentDefect') 'False' "内容缺陷 → 不重试"
Assert-Equal (Test-OstFailureRetryable -Kind 'IntegrityMismatch') 'False' "哈希不符 → 不重试"
Assert-Equal (Test-OstFailureRetryable -Kind 'ArchiveDefect') 'False' "解包失败 → 不重试"
Assert-Equal (Test-OstFailureRetryable -Kind 'Transient') 'True' "网络故障 → 重试"
Assert-Equal (Test-OstFailureRetryable -Kind 'Unknown') 'False' "未知 → 不重试（保守）"
Write-Host ""

# ---------------------------------------------------------------------------
# T5  复现线上场景：1.5.3.6 缺 dwmapi.dll
# ---------------------------------------------------------------------------
Write-Host "T5  复现线上场景（1.5.3.6 缺 dwmapi.dll）" -ForegroundColor Yellow
Reset-Latch
Add-OstHandledTag -Tag '1.5.3.5'   # 真实文件内容

# 模拟 deploy 失败后的 catch 分支（新逻辑）
$msg = 'OST package is incomplete. Missing: dwmapi.dll'
$kind = Get-OstFailureKind -Message $msg
if (-not (Test-OstFailureRetryable -Kind $kind)) {
    Add-OstFailedTag -Tag '1.5.3.6' -Reason $msg -Kind $kind
}
$fr = Get-OstFailedTag -Tag '1.5.3.6'
Assert-Equal ($null -ne $fr) 'True' "1.5.3.6 已记为失败"
Assert-Equal $fr.kind 'ContentDefect' "失败类型正确"
Assert-Equal $fr.reason $msg "失败原因已保存（可用于提示用户）"
Assert-Equal ($null -ne (Get-OstFailedTag -Tag '1.5.3.5')) 'False' "未失败的其他 tag 不受影响"

# 第二轮启动：应命中记录 → 跳过下载
$secondLaunchSkips = ($null -ne (Get-OstFailedTag -Tag '1.5.3.6'))
Assert-Equal $secondLaunchSkips 'True' ">>> 第二次启动跳过下载（循环已打破）" -ForegroundColor Magenta
Write-Host ""

# ---------------------------------------------------------------------------
# T6  手动重试（按 1）应清除失败记录
# ---------------------------------------------------------------------------
Write-Host "T6  手动重试清除记录" -ForegroundColor Yellow
Clear-OstFailedTag -Tag '1.5.3.6'
Assert-Equal ($null -ne (Get-OstFailedTag -Tag '1.5.3.6')) 'False' "清除后不再被跳过"
Assert-Equal ((Get-OstHandledTags) -join ',') '1.5.3.5' "清除失败记录不影响 handledTags"

# 手动重试成功 → 记 handled
Add-OstHandledTag -Tag '1.5.3.6'
Assert-Equal ((Get-OstHandledTags) -contains '1.5.3.6') 'True' "手动成功后记为已处理"

# 成功安装应顺带清掉该 tag 的失败记录
Reset-Latch
Add-OstFailedTag -Tag '1.5.3.6' -Reason 'x' -Kind 'ContentDefect'
Add-OstHandledTag -Tag '1.5.3.6'
Assert-Equal ((Get-OstUpdateState).failedTags.Count) 0 "成功 latch 会清除同名失败记录"
Write-Host ""

# ---------------------------------------------------------------------------
# T7  网络失败不写记录（保持可重试）
# ---------------------------------------------------------------------------
Write-Host "T7  网络失败保持可重试" -ForegroundColor Yellow
Reset-Latch
$netMsg = 'Unable to download OST asset from any configured source. https://x: timed out'
$netKind = Get-OstFailureKind -Message $netMsg
if (-not (Test-OstFailureRetryable -Kind $netKind)) {
    Add-OstFailedTag -Tag '1.5.3.6' -Reason $netMsg -Kind $netKind
}
Assert-Equal ((Get-OstUpdateState).failedTags.Count) 0 "网络失败不写记录 → 下次仍会重试"
Write-Host ""

# ---------------------------------------------------------------------------
# T8  容错与边界
# ---------------------------------------------------------------------------
Write-Host "T8  容错与边界" -ForegroundColor Yellow
Set-Content -LiteralPath (Get-OstUpdateStatePath) -Value '{ broken json' -Encoding UTF8
Assert-Equal (Get-OstHandledTags).Count 0 "损坏 JSON → 空（不崩）"
Assert-Equal (Get-OstUpdateState).failedTags.Count 0 "损坏 JSON → failedTags 空"

Set-Content -LiteralPath (Get-OstUpdateStatePath) -Value '{"handledTags":null,"failedTags":null}' -Encoding UTF8
Assert-Equal (Get-OstHandledTags).Count 0 "null 字段 → 空数组"

Set-Content -LiteralPath (Get-OstUpdateStatePath) -Value '{"failedTags":[null,{"tag":""},{"tag":"1.5.3.6","reason":"r","kind":"ContentDefect","at":"t"}]}' -Encoding UTF8
Assert-Equal ((Get-OstUpdateState).failedTags.Count) 1 "无效 failedTags 条目被过滤"

Reset-Latch
for ($i = 1; $i -le 30; $i++) { Add-OstHandledTag -Tag ("9.9.9.{0}" -f $i) }
Assert-Equal (Get-OstHandledTags).Count 20 "handledTags 上限 20"
Reset-Latch
for ($i = 1; $i -le 30; $i++) { Add-OstFailedTag -Tag ("9.9.9.{0}" -f $i) -Reason 'r' -Kind 'ContentDefect' }
Assert-Equal ((Get-OstUpdateState).failedTags.Count) 20 "failedTags 上限 20"
Assert-Equal (Get-OstFailedTag -Tag '9.9.9.30').tag '9.9.9.30' "保留最近条目"

Assert-Equal ($null -ne (Get-OstFailedTag -Tag '')) 'False' "空 tag 不匹配"
Write-Host ""

# ---------------------------------------------------------------------------
# T9  尺寸稳定性（状态文件不应无限增长）
# ---------------------------------------------------------------------------
Write-Host "T9  状态文件尺寸" -ForegroundColor Yellow
Reset-Latch
Add-OstHandledTag -Tag '1.5.3.5'
Add-OstFailedTag -Tag '1.5.3.6' -Reason 'OST package is incomplete. Missing: dwmapi.dll' -Kind 'ContentDefect'
$size = (Get-Item (Get-OstUpdateStatePath)).Length
Write-Host ("  当前状态文件: {0} 字节" -f $size) -ForegroundColor DarkGray
Write-Host "  内容:" -ForegroundColor DarkGray
Get-Content (Get-OstUpdateStatePath) -Raw | ForEach-Object { Write-Host ("    " + ($_ -replace "`r?`n", " ")) -ForegroundColor DarkGray }
Assert-Equal ($size -lt 4096) 'True' "状态文件体积可控"
Write-Host ""

# ---------------------------------------------------------------------------
Write-Host "==============================================================" -ForegroundColor Cyan
if ($script:Fail -eq 0) {
    Write-Host (" 全部通过: {0}/{0}" -f $script:Pass) -ForegroundColor Green
} else {
    Write-Host (" 通过 {0} / 失败 {1}" -f $script:Pass, $script:Fail) -ForegroundColor Red
}
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\STEAMX_TEST_SANDBOX -ErrorAction SilentlyContinue
exit ($(if ($script:Fail -eq 0) { 0 } else { 1 }))
