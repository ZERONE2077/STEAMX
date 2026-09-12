# DownloadRepair.ps1 - STEAMX 单游戏清单修复工具
# 识别 Steam 路径 -> 选择游戏 -> 从仓库/本地取 zip -> 解压覆盖
#   .lua      -> <Steam>\config\lua
#   .manifest -> <Steam>\depotcache
#
# 目标环境: Windows 10 / 11 + Windows PowerShell 5.1, 零外部依赖
# 文件编码: UTF-8 with BOM —— BOM 是 -File 与 irm|iex 两条路径都能正确解出中文的前提
#
# 退出码:
#   0 成功        1 其他失败        2 参数/选择无效    3 环境不满足(未找到 Steam)
#   4 用户取消    5 权限不足        6 缺少依赖         7 网络失败
#
# 分层:
#   业务逻辑 -> 只发语义日志(Write-Log*), 不直接写屏幕
#   渲染层   -> Show-* / Read-* 负责一切终端输出与输入
#   能力探测 -> $script:Caps 一次性判定(交互能力 / ANSI / JSON)
[CmdletBinding()]
param(
    [string]$Repo = "ZERONE2077/STEAMX",
    [string]$Branch = "main",
    [string[]]$RemoteDir = @("manifest", "Lua"),
    [string]$LocalDir = "",
    [string]$SteamPath = "",
    [string]$LuaTarget = "",
    [string]$ManifestTarget = "",
    [int]$TimeoutSeconds = 30,
    [string]$Game = "",
    [switch]$NoBackup,
    [switch]$Offline,
    [switch]$ShowEnv,
    [switch]$IncludeLua,
    [switch]$Log,
    [switch]$RefreshNames,
    [switch]$Pause,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OutputEncoding = [System.Text.Encoding]::UTF8
# 只在交互式控制台改输出编码; 重定向/管道时不碰, 免得破坏下游消费方
if (-not [Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}
# PS 5.1 默认不一定启用 TLS 1.2, GitHub API / jsDelivr 需要
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ================================================================ 运行时状态

$script:LogFile = ""
$script:LogEnabled = [bool]$Log
$script:ErrorKind = "Operation"
$script:ExitCode = 0
# 出错时窗口要不要留住(解决了"双击启动 -> 报错 -> 窗口秒关")
$script:Failed = $false
$script:CrashLogFile = ""
# 最近 200 行日志的环形缓冲: 失败时连同异常一起落盘, 关窗后也能复盘
$script:LogRing = New-Object System.Collections.ArrayList

# 退出码基线(不要随意增删, 见文件头注释)
$script:Codes = @{
    Success     = 0
    Failure     = 1
    BadInput    = 2
    Environment = 3
    Cancelled   = 4
    Permission  = 5
    Dependency  = 6
    Network     = 7
}

# ---------------------------------------------------------------- 文案表
# UI 文本集中在这里, 业务逻辑只引用键, 改文案不动逻辑

$script:Strings = @{
    Title              = "STEAMX 清单修复"
    MenuTitle          = "选择游戏"
    MenuMatchTitle     = "匹配 [{0}]"
    MenuKeys           = "  Up/Down 选择   PgUp/PgDn 翻页   Home/End 首尾   Enter 确认   Esc 返回"
    MenuPosition       = "  第 {0}/{1} 项"
    MenuByNumberPrompt = "  请输入序号 [1-{0}] (回车取消)"
    MenuBadChoice      = "  序号无效, 请输入 1-{0} 之间的数字。"
    MenuFallback       = "当前终端不支持方向键, 已切换为序号选择"
    MenuNoInput        = "当前环境无法接收键盘输入, 请改用 -Game <AppID|关键词> 指定游戏"
    SteamAskPath       = "  未自动识别到 Steam, 请输入 steam.exe 所在文件夹 (回车取消)"
    SteamNotFound      = "未找到 Steam 安装路径。用 -SteamPath 指定, 或设置环境变量 STEAM_PATH。"
    Cancelled          = "已取消。"
    NoPackages         = "没有可用的 zip 包 (远端与本地均为空)。"
    NoMatch            = "没有匹配 [{0}] 的游戏包。"
    MatchMultiple      = "关键词命中 {0} 个, 请从列表选择"
    DownloadFailedAll  = "所有下载源均失败, 请检查网络或用 -LocalDir 指定本地包目录。"
    ZipEmpty           = "下载到的 zip 为空。"
    ZipNotValid        = "下载到的文件不是有效的 zip (可能是 HTML 错误页)。"
    TargetBlocked      = "写入目标不可用, 已中止 (未改动任何文件)。"
    NoPermission       = "无权写入 {0}"
    NotWritable        = "目标不可写 {0} (可能被安全软件或系统策略拦截)"
    RunAsAdmin         = "请右键本快捷方式 -> 以管理员身份运行, 或用管理员 PowerShell 重跑"
    RemoteUnavailable  = "远端不可用: {0}"
    RemoteListed       = "远端列表 {0} 个包 ({1})"
    RemoteDegraded     = "GitHub API 不可用, 已降级: {0}"
    LocalExtra         = "本地补充 {0} 个包 (未推送)"
    LocalCount         = "本地目录 {0} 个包"
    LocalFallback      = "回退本地目录 {0} 个包"
    NamesSynced        = "本地名单为空, 已同步仓库缓存 {0} 条"
    NamesFilling       = "补全游戏名 {0} 个 (Steam 商店)"
    SteamRunning       = "Steam 正在运行, 写入可能被占用, 建议先退出"
    TargetDirLabel     = "目标 {0}"
    SteamDirLabel      = "Steam {0}"
    GameSelected       = "游戏 {0}"
    SourceUsed         = "来源 {0}"
    LocalHit           = "本地命中 {0}"
    Downloading        = "下载 {0}"
    DownloadFailed     = "下载失败 ({0}): {1}"
    Installed          = "清单已安装 新增 {0} / 覆盖 {1}"
    SkippedLua         = "跳过 {0} 个 .lua (默认不装, 用 -IncludeLua 开启)"
    BackupDirLabel     = "备份 {0}"
    LocalSourceDir     = "本地包源 {0}"
    RepoLabel          = "仓库 {0}@{1}"
    LogPathLabel       = "日志 {0}"
    LuaDirLabel        = "Lua 目录 {0}"
    EnvUnknown         = "环境检查未通过。"
}

function T {
    param([Parameter(Mandatory = $true)][string]$Key)
    if (-not $script:Strings.ContainsKey($Key)) { return $Key }
    return [string]$script:Strings[$Key]
}

function Format-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object[]]$Values
    )
    return ([string]$script:Strings[$Key] -f $Values)
}

# ---------------------------------------------------------------- 错误分类

function Set-ErrorKind {
    param([Parameter(Mandatory = $true)][string]$Kind)
    $script:ErrorKind = $Kind
}

function Get-ErrorKind {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    # 显式标记优先(抛错前 Set-ErrorKind)
    if ($script:ErrorKind -ne "Operation") { return $script:ErrorKind }

    $exception = $ErrorRecord.Exception
    if ($null -eq $exception) { return "Operation" }
    if ($exception -is [System.UnauthorizedAccessException]) { return "Permission" }
    if ($exception -is [System.Security.SecurityException]) { return "Permission" }
    if ($exception -is [System.Net.WebException]) { return "Network" }
    if ($exception -is [System.TimeoutException]) { return "Network" }
    if ($exception -is [System.IO.IOException]) { return "FileSystem" }
    if ($exception -is [System.IO.DirectoryNotFoundException]) { return "FileSystem" }
    $typeName = $exception.GetType().FullName
    if ($null -ne $typeName -and $typeName -like "*Unauthorized*") { return "Permission" }
    return "Operation"
}

function Get-ExitCodeForKind {
    param([Parameter(Mandatory = $true)][string]$Kind)

    switch ($Kind) {
        "Permission" { return $script:Codes.Permission }
        "Environment" { return $script:Codes.Environment }
        "Network" { return $script:Codes.Network }
        "Dependency" { return $script:Codes.Dependency }
        "UserInput" { return $script:Codes.BadInput }
        "Cancelled" { return $script:Codes.Cancelled }
        default { return $script:Codes.Failure }
    }
}

# ================================================================ 能力探测

function Get-TerminalCapabilities {
    $interactive = $true
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { $interactive = $false }
    } catch {
        $interactive = $false
    }

    $ansi = $false
    if ($interactive -and [string]::IsNullOrEmpty($env:NO_COLOR)) {
        if (-not [string]::IsNullOrEmpty($env:WT_SESSION)) {
            $ansi = $true
        } else {
            try {
                $property = $Host.UI.PSObject.Properties["SupportsVirtualTerminal"]
                if ($null -ne $property) { $ansi = [bool]$property.Value }
            } catch {
                $ansi = $false
            }
        }
    }

    return [pscustomobject]@{
        Interactive = $interactive
        Ansi        = $ansi
        Color       = $interactive
    }
}

$script:Caps = Get-TerminalCapabilities

function Get-ConsoleWidth {
    try {
        $width = [int]$host.UI.RawUI.WindowSize.Width
        if ($width -ge 30) { return $width }
    } catch { }
    return 80
}

function Get-ConsoleHeight {
    try {
        $height = [int]$host.UI.RawUI.WindowSize.Height
        if ($height -ge 8) { return $height }
    } catch { }
    return 40
}

# ================================================================ 日志层
# tail 风格: HH:mm:ss TAG scope message
#   TAG 宽 5 (INFO/OK/WARN/ERROR/DBUG), scope 宽 8
#   整行拼成单个 Write-Host(ANSI SGR), 避免重定向时被拆行
#   非 VT 终端 / 输出被重定向 / 设了 NO_COLOR -> 退化为纯文本
# 业务逻辑只调这一层, 不直接 Write-Host

$script:LogTags = @{ DEBUG = "DBUG"; INFO = "INFO"; SUCCESS = "OK"; WARN = "WARN"; ERROR = "ERROR" }
$script:LogAnsi = @{ DEBUG = "90"; INFO = "36"; SUCCESS = "32"; WARN = "33"; ERROR = "31" }

function Write-LogLine {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("DEBUG", "INFO", "SUCCESS", "WARN", "ERROR")][string]$Level,
        [Parameter(Mandatory = $true)][string]$Scope,
        [AllowEmptyString()][string]$Message = ""
    )

    # DEBUG 只在 -Log(写文件)时输出, 正常使用不打扰
    if ($Level -eq "DEBUG" -and -not $script:LogEnabled) { return }

    $tag = ([string]$script:LogTags[$Level]).PadRight(5)
    $scopeKey = $Scope.ToLowerInvariant()
    if ($scopeKey.Length -gt 8) { $scopeKey = $scopeKey.Substring(0, 8) }
    $scopePad = $scopeKey.PadRight(8)
    $stamp = Get-Date -Format "HH:mm:ss"

    if ($script:Caps.Ansi) {
        $esc = [char]27
        $messageIn = ""
        $messageOut = ""
        if ($Level -eq "WARN" -or $Level -eq "ERROR") {
            $messageIn = "${esc}[$($script:LogAnsi[$Level])m"
            $messageOut = "${esc}[0m"
        }
        Write-Host ("${esc}[90m{0}${esc}[0m ${esc}[{1}m{2}${esc}[0m ${esc}[90m{3}${esc}[0m {4}{5}{6}" -f $stamp, $script:LogAnsi[$Level], $tag, $scopePad, $messageIn, $Message, $messageOut)
    } else {
        Write-Host ("{0} {1} {2} {3}" -f $stamp, $tag, $scopePad, $Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        $line = "{0} [{1}] {2} {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $scopeKey, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }

    # 环形缓冲(只驻内存): 失败时把这几十行一起写进崩溃日志
    if ($null -ne $script:LogRing) {
        [void]$script:LogRing.Add(("{0} {1} {2} {3}" -f $stamp, $tag.TrimEnd(), $scopeKey, $Message))
        if ($script:LogRing.Count -gt 200) { $script:LogRing.RemoveAt(0) }
    }
}

function Write-LogDebug {
    param([string]$Scope, [string]$Message)
    Write-LogLine -Level "DEBUG" -Scope $Scope -Message $Message
}
function Write-LogInfo {
    param([string]$Scope, [string]$Message)
    Write-LogLine -Level "INFO" -Scope $Scope -Message $Message
}
function Write-LogSuccess {
    param([string]$Scope, [string]$Message)
    Write-LogLine -Level "SUCCESS" -Scope $Scope -Message $Message
}
function Write-LogWarning {
    param([string]$Scope, [string]$Message)
    Write-LogLine -Level "WARN" -Scope $Scope -Message $Message
}
function Write-LogError {
    param([string]$Scope, [string]$Message)
    Write-LogLine -Level "ERROR" -Scope $Scope -Message $Message
}

# ================================================================ 渲染层
# 一切终端输出与输入都收在这里, 换主题/换渲染方式不用动业务逻辑

# 显示宽度: CJK 全角算 2 列
# 菜单重绘靠这个算真实宽度, 用 .Length 会让中文行错位 / 折行
function Get-CharWidth {
    param([char]$Ch)

    $code = [int]$Ch
    if ($code -lt 0x1100) { return 1 }
    if (($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2E80 -and $code -le 0x303E) -or
        ($code -ge 0x3041 -and $code -le 0x33FF) -or
        ($code -ge 0x3400 -and $code -le 0x4DBF) -or
        ($code -ge 0x4E00 -and $code -le 0x9FFF) -or
        ($code -ge 0xA000 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { return 2 }
    return 1
}

# 2 列宽的码点区间(与 Get-CharWidth 一一对应):
# 单个正则扫描比逐字符调 PowerShell 函数快两个数量级, 菜单每帧要量几十行的宽度
$script:WideCharPattern = "[\u1100-\u115F\u2E80-\u303E\u3041-\u33FF\u3400-\u4DBF\u4E00-\u9FFF\uA000-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]"

function Get-DisplayWidth {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return ($Text.Length + [regex]::Matches($Text, $script:WideCharPattern).Count)
}

# 按显示宽度右侧补空格(直接 PadRight 会把中文行算短, 表格立刻歪)
function Add-DisplayPadding {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $pad = $Width - (Get-DisplayWidth -Text $Text)
    if ($pad -le 0) { return $Text }
    return ($Text + (" " * $pad))
}

# 按显示宽度截断, 超出部分用 … 收尾
function Limit-DisplayWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$MaxWidth
    )

    if ($MaxWidth -le 0) { return "" }
    if ((Get-DisplayWidth -Text $Text) -le $MaxWidth) { return $Text }

    $builder = New-Object System.Text.StringBuilder
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $charWidth = Get-CharWidth -Ch $ch
        if (($width + $charWidth) -gt ($MaxWidth - 2)) { break }
        [void]$builder.Append($ch)
        $width += $charWidth
    }
    return ($builder.ToString() + [char]0x2026)
}

# 菜单专用分隔标题(不属于日志流)
function Format-RuleText {
    param([string]$Title = "")

    $width = [Math]::Min(62, (Get-ConsoleWidth) - 1)
    if ($width -lt 12) { $width = 62 }
    if ([string]::IsNullOrWhiteSpace($Title)) { return ("-" * $width) }

    $prefix = "- {0} " -f $Title
    return ($prefix + ("-" * [Math]::Max(0, $width - (Get-DisplayWidth -Text $prefix))))
}

function Show-Rule {
    param([string]$Title = "")
    Write-Host (Format-RuleText -Title $Title) -ForegroundColor DarkGray
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0} B" -f $Bytes
}

function Format-UrlShort {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $uri = [Uri]$Url
        $leaf = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($leaf)) { return $uri.Host }
        return ("{0}/{1}" -f $uri.Host, $leaf)
    } catch {
        return $Url
    }
}

# 按磁盘上的真实大小写还原路径(Windows 路径大小写不敏感, 显示一致性靠它)
function Format-PathCase {
    param([AllowEmptyString()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
    $full = [System.IO.Path]::GetFullPath($PathValue)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { return $full }
    $result = $root.Substring(0, 1).ToUpperInvariant() + $root.Substring(1)
    $current = $root
    try {
        foreach ($segment in @($full.Substring($root.Length).Split("\", [System.StringSplitOptions]::RemoveEmptyEntries))) {
            $name = $segment
            if (Test-Path -LiteralPath $current -PathType Container) {
                $match = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $segment } | Select-Object -First 1
                if ($null -ne $match) { $name = $match.Name }
            }
            $result = Join-Path $result $name
            $current = Join-Path $current $segment
        }
    } catch {
        $result = $full
        if ($result -match '^[a-z]:\\') { $result = $result.Substring(0, 1).ToUpperInvariant() + $result.Substring(1) }
    }
    return $result
}

# 游戏行: "<名字>  [AppID]  (体积)"
# 菜单里限宽时先砍名字, [AppID] 与体积一定留在同一行
function New-GameLabel {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [int]$MaxWidth = 0
    )

    $size = Format-Size -Bytes ([long]$Item.Size)
    $display = [string]$Item.DisplayName
    $appId = [string]$Item.AppId
    # 名字还没补上时 DisplayName 就是 AppID, 不重复显示两次
    $suffix = if ([string]::IsNullOrWhiteSpace($appId) -or $appId -eq $display) {
        ("  ({0})" -f $size)
    } else {
        ("  [{0}]  ({1})" -f $appId, $size)
    }

    if ($MaxWidth -gt 0) {
        $room = $MaxWidth - (Get-DisplayWidth -Text $suffix)
        $display = Limit-DisplayWidth -Text $display -MaxWidth ([Math]::Max(8, $room - 1))
    }
    return ($display + $suffix)
}

# 拆列: 名字 / [AppID] / 体积数字 / 体积单位 分开返回, 菜单靠它对齐成表格
function Get-GameLabelParts {
    param([Parameter(Mandatory = $true)]$Item)

    $name = [string]$Item.DisplayName
    $appId = [string]$Item.AppId
    $size = Format-Size -Bytes ([long]$Item.Size)

    $num = $size
    $unit = ""
    $split = $size.LastIndexOf(" ")
    if ($split -gt 0) {
        $num = $size.Substring(0, $split)
        $unit = $size.Substring($split + 1)
    }

    # 名字还没补上时 DisplayName 就是 AppID, 不重复显示两次
    $id = ""
    if (-not [string]::IsNullOrWhiteSpace($appId) -and $appId -ne $name) { $id = "[{0}]" -f $appId }

    return [pscustomobject]@{ Name = $name; AppId = $id; SizeNum = $num; SizeUnit = $unit }
}


# ================================================================ 交互: 菜单 / 确认

# 序号模式: 有交互能力时的兜底, 也是非交互终端(重定向/无控制台)的唯一可用模式
function Read-MenuByNumber {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$Title
    )

    Show-Rule -Title $Title
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (New-GameLabel -Item $Items[$i].Item)) -ForegroundColor Gray
    }
    Write-Host ""

    while ($true) {
        $raw = $null
        try {
            $raw = Read-Host (Format-Text -Key "MenuByNumberPrompt" -Values @($Items.Count))
        } catch {
            Set-ErrorKind -Kind "UserInput"
            throw (T -Key "MenuNoInput")
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $choice = 0
        if ([int]::TryParse($raw.Trim(), [ref]$choice) -and $choice -ge 1 -and $choice -le $Items.Count) {
            return $Items[$choice - 1].Value
        }
        Write-Host (Format-Text -Key "MenuBadChoice" -Values @($Items.Count)) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 菜单渲染
# 一帧一次写: 定位到帧顶 -> 整帧(含 ANSI)单次写出。
# 旧实现逐行 Write-Host = 每行一次刷新, 方向键连按时整屏逐行撕裂, 也就是"闪屏"。
# 同时把每项的列内容预先算好, 每帧只做拼接(逐帧逐字符量宽度会拖慢手感)。

$script:MenuStyles = @{
    Rule    = "90"     # 亮黑: 分隔线 / 次要信息
    Head    = "1"      # 加粗: 标题行
    Item    = ""       # 跟随终端默认前景色(亮底/暗底都不会看不清)
    ItemSel = "7"      # 反显: 选中项整行高亮条
    Foot    = "90"     # 亮黑: 快捷键
}

# 往帧缓冲里追加一行: 按样式包 ANSI + 补齐到 Cols 列。
# 补位放在 SGR 内部, 选中条才能铺满整行; 补到 Cols(<=控制台宽-1) 而不是宽,
# 是为了不让光标停进最后一列(待换行态, 下一个字符就换行 -> 整屏上滚)
# -Exact 表示调用方已保证文本正好 Cols 宽(表格行), 跳过量宽/截断/补位
function Add-MenuRowText {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [AllowEmptyString()][string]$Text = "",
        [string]$Style = "Item",
        [Parameter(Mandatory = $true)][int]$Cols,
        [switch]$Exact
    )

    if ($Builder.Length -gt 0) { [void]$Builder.Append("`n") }

    $code = ""
    if ($script:Caps.Ansi) { $code = [string]$script:MenuStyles[$Style] }
    $close = $false
    if (-not [string]::IsNullOrEmpty($code)) {
        $esc = [char]27
        [void]$Builder.Append("${esc}[${code}m")
        $close = $true
    }

    if ($Exact) {
        [void]$Builder.Append($Text)
    } else {
        if ((Get-DisplayWidth -Text $Text) -gt $Cols) {
            $Text = Limit-DisplayWidth -Text $Text -MaxWidth $Cols
        }
        [void]$Builder.Append($Text)
        $pad = $Cols - (Get-DisplayWidth -Text $Text)
        if ($pad -gt 0) { [void]$Builder.Append(" " * $pad) }
    }

    if ($close) { [void]$Builder.Append("${esc}[0m") }
}

# 拼一整帧(不含换行结尾)
function New-MenuFrame {
    param(
        [Parameter(Mandatory = $true)][array]$Rows,
        [Parameter(Mandatory = $true)][int]$Cols
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($row in $Rows) {
        Add-MenuRowText -Builder $builder -Text ([string]$row.Text) -Style ([string]$row.Style) -Cols $Cols
    }
    return $builder.ToString()
}

# 定位 + 整帧单次写出: 一次 SetCursorPosition + 一次 Write, 中间没有任何刷新
function Write-MenuFrameText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Top
    )

    # 定位一次 + 整帧一次写出: 中间不发生任何刷新, 所以看不到逐行撕裂
    try {
        [Console]::SetCursorPosition(0, $Top)
    } catch {
        # 拿不到定位能力(无控制台/重定向): 退化为顺序输出, 至少让人看得到菜单
        [Console]::Out.WriteLine($Text)
        return
    }

    # 2026 = 同步输出(Windows Terminal 1.18+): 前后包住整帧做成原子刷新;
    # 拼在同一个字符串里是为了让"每帧一次写"真正成立(不支持的终端会忽略这两个序列)
    if ($script:Caps.Ansi) {
        $esc = [char]27
        [Console]::Out.Write("${esc}[?2026h" + $Text + "${esc}[?2026l")
    } else {
        [Console]::Out.Write($Text)
    }
}

# 行数组 -> 上屏(给外部/测试用的组合入口)
function Write-MenuFrame {
    param(
        [Parameter(Mandatory = $true)][array]$Rows,
        [Parameter(Mandatory = $true)][int]$Top,
        [Parameter(Mandatory = $true)][int]$Cols
    )

    Write-MenuFrameText -Text (New-MenuFrame -Rows $Rows -Cols $Cols) -Top $Top
}

# 标题行: 左标题 + 右页码, 中间空格撑开
function New-MenuHeaderText {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][int]$Position,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $left = "  " + $Title
    $right = "  " + (Format-Text -Key "MenuPosition" -Values @($Position, $Total))
    $leftWidth = Get-DisplayWidth -Text $left
    $pad = $Width - $leftWidth - (Get-DisplayWidth -Text $right)
    if ($pad -lt 2) { $pad = 2 }
    return ((Add-DisplayPadding -Text $left -Width ($leftWidth + $pad)) + $right)
}

# 方向键模式: 原地整帧覆盖, 不整屏清屏 -> 不闪
function Read-MenuByArrow {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$Title
    )

    # 行布局: 前缀 4 列(含选中标记) + 名字列(弹性) + [AppID] 10 + 体积 10
    # 帧宽由快捷键行的宽度定(宽屏上不拉成一条长线), 名字列再吃掉剩下的宽度:
    # 这样表格右端、分隔线、选中条三者严格对齐, 整块是个矩形
    $layoutWidth = Get-ConsoleWidth
    $windowHeight = Get-ConsoleHeight
    $chromeRows = 4
    $footerText = T -Key "MenuKeys"
    $baseFrame = [Math]::Max((Get-DisplayWidth -Text $footerText) + 2, 62)
    if ($baseFrame -gt ($layoutWidth - 1)) { $baseFrame = $layoutWidth - 1 }
    $nameWidth = [Math]::Max(16, $baseFrame - 24)

    # 列内容一次算好(名字列要按显示宽度补位, 中文占 2 列), 每帧只做拼接
    $entries = New-Object System.Collections.ArrayList
    foreach ($entry in $Items) {
        $part = Get-GameLabelParts -Item $entry.Item
        [void]$entries.Add(@{
                Name = (Add-DisplayPadding -Text (Limit-DisplayWidth -Text $part.Name -MaxWidth $nameWidth) -Width $nameWidth)
                Id   = ([string]$part.AppId).PadLeft(10)
                Size = $part.SizeNum.PadLeft(7) + " " + $part.SizeUnit.PadRight(2)
            })
    }

    $menuTop = 0
    try { $menuTop = [Console]::CursorTop } catch { $menuTop = 0 }

    # 腾地方: 先用换行把日志顶上去(保留上下文), 实在没地方才清屏
    $minPage = 5
    $avail = ($windowHeight - 1) - $menuTop
    if ($avail -lt ($minPage + $chromeRows)) {
        $need = ($minPage + $chromeRows) - $avail
        if ($menuTop -ge $need) {
            for ($k = 0; $k -lt $need; $k++) { [Console]::Out.Write("`n") }
            try { $menuTop = [Console]::CursorTop } catch { $menuTop = 0 }
        } else {
            try { [Console]::Clear() } catch { }
            $menuTop = 0
        }
        $avail = ($windowHeight - 1) - $menuTop
    }
    $basePage = [Math]::Min(20, $avail - $chromeRows)
    if ($basePage -lt $minPage) { $basePage = $minPage }

    $index = 0
    $lastLineCount = 0
    $cursorHidden = $false
    try { [Console]::CursorVisible = $false; $cursorHidden = $true } catch { }

    try {
        while ($true) {
            # 窗口宽度变了就按新宽度收缩, 免得行超宽触发折行(折行 = 帧高算错 = 残影)
            $windowWidth = [Math]::Min((Get-ConsoleWidth), $layoutWidth)
            $windowHeight = Get-ConsoleHeight
            $frameWidth = [Math]::Min($baseFrame, ($windowWidth - 1))
            $footer = Limit-DisplayWidth -Text $footerText -MaxWidth $frameWidth
            $rules = "-" * $frameWidth

            # 窗口变矮时收缩页大小, 帧高始终不超过可视区, 避免滚屏
            $maxPage = ($windowHeight - 1) - $menuTop - $chromeRows
            $pageSize = [Math]::Min($basePage, [Math]::Max($minPage, $maxPage))

            $page = [Math]::Floor($index / $pageSize)
            $start = $page * $pageSize
            $end = [Math]::Min($start + $pageSize, $Items.Count) - 1

            # 整帧拼成一个字符串再一次写出(逐行写出 = 逐行刷新 = 闪屏)
            $exact = ($frameWidth -eq $baseFrame)
            $builder = New-Object System.Text.StringBuilder
            Add-MenuRowText -Builder $builder -Text $rules -Style "Rule" -Cols $frameWidth -Exact
            Add-MenuRowText -Builder $builder -Text (New-MenuHeaderText -Title $Title -Position ($index + 1) -Total $Items.Count -Width $frameWidth) -Style "Head" -Cols $frameWidth -Exact:$exact
            Add-MenuRowText -Builder $builder -Text $rules -Style "Rule" -Cols $frameWidth -Exact
            for ($i = $start; $i -le $end; $i++) {
                $isSelected = ($i -eq $index)
                $data = $entries[$i]
                $text = $(if ($isSelected) { "  > " } else { "    " }) + $data.Name + $data.Id + $data.Size
                Add-MenuRowText -Builder $builder -Text $text -Style $(if ($isSelected) { "ItemSel" } else { "Item" }) -Cols $frameWidth -Exact:$exact
            }
            Add-MenuRowText -Builder $builder -Text $rules -Style "Rule" -Cols $frameWidth -Exact
            Add-MenuRowText -Builder $builder -Text $footer -Style "Foot" -Cols $frameWidth

            # 本帧比上一帧短(翻到最后页/窗口变矮)时补空行, 否则会留下残影
            $lineCount = 4 + ($end - $start + 1)
            for ($k = $lineCount; $k -lt $lastLineCount; $k++) {
                Add-MenuRowText -Builder $builder -Text "" -Style "Item" -Cols $frameWidth
            }
            $lastLineCount = $lineCount

            Write-MenuFrameText -Text $builder.ToString() -Top $menuTop

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow) { $index = ($index - 1 + $Items.Count) % $Items.Count; continue }
                ([ConsoleKey]::DownArrow) { $index = ($index + 1) % $Items.Count; continue }
                ([ConsoleKey]::PageUp) { $index = [Math]::Max(0, $start - $pageSize); continue }
                ([ConsoleKey]::PageDown) { $index = [Math]::Min($Items.Count - 1, $start + $pageSize); continue }
                ([ConsoleKey]::Home) { $index = 0; continue }
                ([ConsoleKey]::End) { $index = $Items.Count - 1; continue }
                ([ConsoleKey]::Enter) { return $Items[$index].Value }
                ([ConsoleKey]::Escape) { return $null }
            }

            $typed = [string]$key.KeyChar
            if ($typed -match '^[0-9]$') {
                $target = $start + ([int]$typed - 1)
                if ($target -lt $Items.Count) { $index = $target }
            }
        }
    } finally {
        if ($cursorHidden) { try { [Console]::CursorVisible = $true } catch { } }
        # 光标落到帧下方: 后续日志往下写, 菜单继续留在屏幕上
        $line = [Math]::Min($menuTop + $lastLineCount, (Get-ConsoleHeight) - 1)
        try { [Console]::SetCursorPosition(0, $line) } catch { }
    }
}

# 方向键是增强, 序号是保底: 拿不到控制台输入时自动降级, 而不是崩掉
function Show-GameMenu {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$Title
    )

    if ($script:Caps.Interactive) {
        try {
            return (Read-MenuByArrow -Items $Items -Title $Title)
        } catch [System.InvalidOperationException] {
            Write-LogWarning -Scope "repair" -Message (T -Key "MenuFallback")
        }
    }
    return (Read-MenuByNumber -Items $Items -Title $Title)
}

# ================================================================ 路径与环境

function Get-ScriptRoot {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $parent = Split-Path -Parent $PSCommandPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) { return $parent }
    }
    return ""
}

# 项目根判定: 含 manifest / Lua / DownloadRepair / main.ps1 任一
function Test-SteamxProjectRoot {
    param([AllowNull()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) { return $false }
    foreach ($marker in @("manifest", "Lua", "DownloadRepair", "main.ps1")) {
        if (Test-Path -LiteralPath (Join-Path $PathValue $marker)) { return $true }
    }
    return $false
}

# 项目根依次尝试: 脚本所在目录 -> 其父目录(脚本在 DownloadRepair\ 下) -> 当前目录 -> %LOCALAPPDATA%\STEAMX
# 不把当前目录当默认值: 快捷方式启动时 CWD 是 C:\Windows\System32
function Get-ProjectRoot {
    $candidates = New-Object System.Collections.ArrayList
    $scriptRoot = Get-ScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($scriptRoot)) {
        [void]$candidates.Add($scriptRoot)
        try {
            $parent = Split-Path -Parent $scriptRoot
            if (-not [string]::IsNullOrWhiteSpace($parent)) { [void]$candidates.Add($parent) }
        } catch { }
    }
    try { [void]$candidates.Add((Get-Location).Path) } catch { }

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-SteamxProjectRoot -PathValue $candidate) { return [System.IO.Path]::GetFullPath($candidate) }
    }

    # 远程执行(irm|iex / 快捷方式)时的稳定落点, 与 main.ps1 保持一致
    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) { $local = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($local)) { $local = [System.IO.Path]::GetTempPath() }
    $fallback = Join-Path $local "STEAMX"
    return [System.IO.Path]::GetFullPath($fallback)
}

function Ensure-Dir {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

# ---------------------------------------------------------------- 权限

function Test-IsAdministrator {
    try {
        $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# 直接试写探针文件判断可写(比读 ACL 可靠); 目录不存在时沿父链向上找最近的已存在目录
function Test-DirWritable {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }

    $target = $PathValue
    try {
        while (-not (Test-Path -LiteralPath $target)) {
            $parent = Split-Path -Parent $target
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $target) { return $false }
            $target = $parent
        }
    } catch {
        return $false
    }

    $probe = Join-Path $target ("steamx-probe-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        $stream = [System.IO.File]::Open($probe, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- Steam 定位

function Test-SteamDir {
    param([AllowNull()][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    try {
        return [bool](Test-Path -LiteralPath (Join-Path $PathValue "steam.exe") -PathType Leaf)
    } catch {
        return $false
    }
}

# 顺序: 显式参数 -> 环境变量 -> 运行中的 steam 进程 -> 注册表 -> 各盘符常见位置 -> 询问
function Resolve-SteamPath {
    $candidates = New-Object System.Collections.ArrayList

    if (-not [string]::IsNullOrWhiteSpace($SteamPath)) { [void]$candidates.Add($SteamPath) }
    if (-not [string]::IsNullOrWhiteSpace($env:STEAM_PATH)) { [void]$candidates.Add($env:STEAM_PATH) }

    foreach ($process in @(Get-Process -Name "steam" -ErrorAction SilentlyContinue)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                [void]$candidates.Add((Split-Path -Parent ([string]$process.Path)))
            }
        } catch { }
    }

    foreach ($key in @(
            "HKCU:\Software\Valve\Steam",
            "HKLM:\Software\WOW6432Node\Valve\Steam",
            "HKLM:\Software\Valve\Steam"
        )) {
        if (-not (Test-Path $key -ErrorAction SilentlyContinue)) { continue }
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($name in @("SteamPath", "InstallPath", "SteamExe")) {
            $property = $item.PSObject.Properties[$name]
            if ($null -eq $property) { continue }
            $value = [string]$property.Value
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ($name -eq "SteamExe") { $value = Split-Path -Parent $value }
            [void]$candidates.Add($value)
        }
    }

    foreach ($key in @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\steam.exe",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\steam.exe",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\steam.exe"
        )) {
        if (-not (Test-Path $key -ErrorAction SilentlyContinue)) { continue }
        try {
            $value = [string](Get-Item -Path $key -ErrorAction Stop).GetValue("")
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [void]$candidates.Add((Split-Path -Parent $value.Trim('"')))
            }
        } catch { }
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = [string]$drive.Root
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        [void]$candidates.Add((Join-Path $root "Steam"))
        [void]$candidates.Add((Join-Path $root "Program Files (x86)\Steam"))
        [void]$candidates.Add((Join-Path $root "Program Files\Steam"))
    }

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $clean = ([string]$candidate).Trim().Trim('"')
        if (Test-SteamDir -PathValue $clean) {
            return [System.IO.Path]::GetFullPath($clean)
        }
    }

    if (-not $script:Caps.Interactive) {
        Set-ErrorKind -Kind "Environment"
        throw (T -Key "SteamNotFound")
    }

    $entered = $null
    try {
        $entered = (Read-Host (T -Key "SteamAskPath")).Trim().Trim('"')
    } catch {
        Set-ErrorKind -Kind "Environment"
        throw (T -Key "SteamNotFound")
    }
    if ($entered.EndsWith("steam.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $entered = Split-Path -Parent $entered
    }
    if (Test-SteamDir -PathValue $entered) {
        return [System.IO.Path]::GetFullPath($entered)
    }

    Set-ErrorKind -Kind "Environment"
    throw (T -Key "SteamNotFound")
}

# ================================================================ 数据层: zip 索引

function New-ZipItem {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][long]$Size,
        [Parameter(Mandatory = $true)][string[]]$DownloadUrls,
        [Parameter(Mandatory = $true)][string]$Source
    )
    return [pscustomobject]@{
        Name         = $Name
        Size         = $Size
        DownloadUrls = $DownloadUrls
        Source       = $Source
    }
}

# 远端索引: GitHub contents API 优先, gh-proxy 镜像次之, 最后退到 jsDelivr 文件索引
function Get-RemoteZipIndex {
    param([switch]$AllowFailure)

    $errors = @()
    $headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "STEAMX" }
    # 直连 api.github.com 在部分网络下常被墙/超时, 再试 gh-proxy 镜像转发同一 API
    $apiPrefixes = @("", "https://gh-proxy.com/")

    foreach ($dir in $RemoteDir) {
        $dirTrimmed = $dir.Trim("/")
        $apiPath = "repos/{0}/contents/{1}?ref={2}" -f $Repo, ([Uri]::EscapeDataString($dirTrimmed)), ([Uri]::EscapeDataString($Branch))
        foreach ($prefix in $apiPrefixes) {
            $api = "{0}https://api.github.com/{1}" -f $prefix, $apiPath
            try {
                # 注意: @(Invoke-RestMethod ...) 会把 JSON 数组当成单个元素, 必须先赋值再包
                $response = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec $TimeoutSeconds
                $entries = @($response)
                $zips = @($entries | Where-Object { $_.type -eq "file" -and $_.name -like "*.zip" })
                if ($zips.Count -gt 0) {
                    $items = @(
                        foreach ($zip in $zips) {
                            $name = [string]$zip.name
                            $escaped = [Uri]::EscapeDataString($name)
                            # jsDelivr 文件级缓存刷新快, 优先; 镜像 raw 次之; 直连 download_url 最后
                            New-ZipItem -Name $name -Size ([long]$zip.size) -Source ("github:{0}" -f $dirTrimmed) -DownloadUrls @(
                                ("https://cdn.jsdelivr.net/gh/{0}@{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                ("https://gh-proxy.com/https://raw.githubusercontent.com/{0}/{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                [string]$zip.download_url
                            )
                        }
                    )
                    return [pscustomobject]@{ Items = $items; Source = "github:{0}" -f $dirTrimmed; Error = "" }
                }
                # API 可达但目录里没有 zip, 换下一个 RemoteDir
                $errors += ("{0}: 目录为空" -f $dirTrimmed)
                break
            } catch {
                $errors += ("{0}{1}: {2}" -f $prefix, $dirTrimmed, $_.Exception.Message)
            }
        }
    }

    # jsDelivr 兜底(GitHub API 被限流时)
    $jsdelivrApi = "https://data.jsdelivr.com/v1/packages/gh/{0}@{1}?structure=flat" -f $Repo, $Branch
    try {
        $payload = Invoke-RestMethod -Uri $jsdelivrApi -Headers @{ "User-Agent" = "STEAMX" } -TimeoutSec $TimeoutSeconds
        $files = @($payload.files)
        $zips = @($files | Where-Object { $_.name -like "*.zip" })
        if ($zips.Count -gt 0) {
            $items = @(
                foreach ($zip in $zips) {
                    $relative = ([string]$zip.name).TrimStart("/")
                    New-ZipItem -Name (Split-Path -Leaf $relative) -Size ([long]$zip.size) -Source "jsdelivr" -DownloadUrls @(
                        ("https://cdn.jsdelivr.net/gh/{0}@{1}/{2}" -f $Repo, $Branch, $relative),
                        ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/{2}" -f $Repo, $Branch, $relative)
                    )
                }
            )
            return [pscustomobject]@{ Items = $items; Source = "jsdelivr"; Error = ($errors -join " | ") }
        }
    } catch {
        $errors += ("jsdelivr: {0}" -f $_.Exception.Message)
    }

    if ($AllowFailure) {
        return [pscustomobject]@{ Items = @(); Source = ""; Error = ($errors -join " | ") }
    }
    Set-ErrorKind -Kind "Network"
    throw (Format-Text -Key "RemoteUnavailable" -Values @(($errors -join " | ")))
}

function Get-LocalZipIndex {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $Directory -File -Filter *.zip -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                New-ZipItem -Name $_.Name -Size ([long]$_.Length) -Source "local" -DownloadUrls @($_.FullName)
            }
    )
}

# ================================================================ 数据层: 游戏中文名

# 名单条目支持 "中文名 || 官方原名": 前半段用于显示, 后半段只用于关键词搜索
function Split-NameEntry {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @("", "") }
    $parts = @($Value -split '\s*\|\|\s*', 2)
    $name = $parts[0].Trim()
    $alias = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" }
    return @($name, $alias)
}

function Get-AppIdFromZipName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($base -match '^\d+$') { return $base }
    return ""
}

function Read-AppNameCache {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $cache = @{}
    if (Test-Path -LiteralPath $PathValue -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $PathValue -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $json) {
                foreach ($property in $json.PSObject.Properties) {
                    $cache[[string]$property.Name] = [string]$property.Value
                }
            }
        } catch { }
    }
    return $cache
}

function Save-AppNameCache {
    param(
        [Parameter(Mandatory = $true)]$Cache,
        [Parameter(Mandatory = $true)][string]$PathValue
    )

    # 缓存写不进去不是致命问题(只影响下次要重新拉名单), 所以只记 DEBUG
    try {
        Ensure-Dir -PathValue (Split-Path -Parent $PathValue)
        $ordered = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($key in @($Cache.Keys | Sort-Object)) { $ordered[[string]$key] = [string]$Cache[$key] }
        ($ordered | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $PathValue -Encoding UTF8
    } catch {
        Write-LogDebug -Scope "names" -Message ("名单缓存写入失败: {0}" -f $_.Exception.Message)
    }
}

# 统一走 HttpWebRequest: PS 5.1 下能显式控制超时与 gzip/deflate
function Invoke-RemoteText {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = "STEAMX"
    $request.Accept = "application/json"
    $request.AllowAutoRedirect = $true
    try {
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    } catch { }
    $request.Timeout = $Timeout * 1000
    $request.ReadWriteTimeout = $Timeout * 1000
    $response = $null
    $stream = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader $stream
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

# 仓库里的名单: jsDelivr -> raw -> ghfast, 逐个试
function Read-RemoteAppNameCache {
    param([Parameter(Mandatory = $true)][int]$Timeout)

    $urls = @(
        ("https://cdn.jsdelivr.net/gh/{0}@{1}/manifest/appnames.json" -f $Repo, $Branch),
        ("https://raw.githubusercontent.com/{0}/{1}/manifest/appnames.json" -f $Repo, $Branch),
        ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/manifest/appnames.json" -f $Repo, $Branch)
    )
    foreach ($url in $urls) {
        try {
            $body = Invoke-RemoteText -Url $url -Timeout $Timeout
            if ([string]::IsNullOrWhiteSpace($body)) { continue }
            if ($body.TrimStart().StartsWith("<")) { continue }
            $json = $body | ConvertFrom-Json
            $cache = @{}
            foreach ($property in $json.PSObject.Properties) {
                $cache[[string]$property.Name] = [string]$property.Value
            }
            if ($cache.Count -gt 0) { return $cache }
        } catch { }
    }
    return @{}
}

# 单个 AppID 的 Steam 商店简中名
function Get-SteamAppName {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $url = "https://store.steampowered.com/api/appdetails?appids={0}&cc=cn&l=schinese" -f $AppId
    try {
        $body = Invoke-RemoteText -Url $url -Timeout $Timeout
        if ([string]::IsNullOrWhiteSpace($body)) { return "" }
        $json = $body | ConvertFrom-Json
        $node = $json.PSObject.Properties[$AppId]
        if ($null -ne $node -and $node.Value.success) {
            return [string]$node.Value.data.name
        }
    } catch { }
    return ""
}

# 名单只走本地缓存(缺失时同步仓库里的 appnames.json), 不做逐个联网:
# 这样菜单立刻可见; 名字缺的先显示 AppID, 安装时或 -RefreshNames 再补
function Add-GameDisplayNames {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][int]$Timeout,
        [switch]$SkipNetwork,
        [switch]$Refresh
    )

    $cache = Read-AppNameCache -PathValue $CachePath

    if ($cache.Count -eq 0 -and -not $SkipNetwork) {
        $remoteCache = Read-RemoteAppNameCache -Timeout $Timeout
        if ($remoteCache.Count -gt 0) {
            $cache = $remoteCache
            Save-AppNameCache -Cache $cache -PathValue $CachePath
            Write-LogSuccess -Scope "names" -Message (Format-Text -Key "NamesSynced" -Values @($cache.Count))
        }
    }

    $pending = @()
    foreach ($item in $Items) {
        $appId = Get-AppIdFromZipName -Name ([string]$item.Name)
        $item | Add-Member -NotePropertyName AppId -NotePropertyValue $appId -Force

        $display = ""
        $alias = ""
        if (-not [string]::IsNullOrWhiteSpace($appId) -and $cache.ContainsKey($appId)) {
            $parts = Split-NameEntry -Value ([string]$cache[$appId])
            $display = $parts[0]
            $alias = $parts[1]
        }

        $isPending = [string]::IsNullOrWhiteSpace($display)
        if ($isPending) {
            $display = if ([string]::IsNullOrWhiteSpace($appId)) {
                [System.IO.Path]::GetFileNameWithoutExtension([string]$item.Name)
            } else {
                $appId
            }
            if (-not [string]::IsNullOrWhiteSpace($appId) -and -not $SkipNetwork) { $pending += $appId }
        }

        $item | Add-Member -NotePropertyName NamePending -NotePropertyValue $isPending -Force
        $item | Add-Member -NotePropertyName DisplayName -NotePropertyValue $display -Force
        $item | Add-Member -NotePropertyName Alias -NotePropertyValue $alias -Force
    }

    if ($Refresh -and $pending.Count -gt 0) {
        Write-LogInfo -Scope "names" -Message (Format-Text -Key "NamesFilling" -Values @($pending.Count))
        $changed = $false
        foreach ($appId in $pending) {
            $name = Get-SteamAppName -AppId $appId -Timeout $Timeout
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $cache[$appId] = $name
                $changed = $true
                Write-LogDebug -Scope "names" -Message ("{0} = {1}" -f $appId, $name)
            }
            Start-Sleep -Milliseconds 120
        }
        if ($changed) { Save-AppNameCache -Cache $cache -PathValue $CachePath }
        foreach ($item in $Items) {
            if (-not $item.NamePending) { continue }
            $id = [string]$item.AppId
            if (-not [string]::IsNullOrWhiteSpace($id) -and $cache.ContainsKey($id)) {
                $parts = Split-NameEntry -Value ([string]$cache[$id])
                $item.DisplayName = $parts[0]
                $item.Alias = $parts[1]
                $item.NamePending = $false
            }
        }
    }

    return @($Items)
}

# 选中的包没有中文名时补一次(单次请求, 顺带写回缓存)
function Update-PendingGameName {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    if (-not $Item.NamePending) { return $Item }
    $appId = [string]$Item.AppId
    if ([string]::IsNullOrWhiteSpace($appId)) { return $Item }

    $name = Get-SteamAppName -AppId $appId -Timeout $Timeout
    if ([string]::IsNullOrWhiteSpace($name)) { return $Item }

    $cache = Read-AppNameCache -PathValue $CachePath
    $cache[$appId] = $name
    Save-AppNameCache -Cache $cache -PathValue $CachePath

    $parts = Split-NameEntry -Value $name
    $Item.DisplayName = $parts[0]
    $Item.Alias = $parts[1]
    $Item.NamePending = $false
    return $Item
}

# ================================================================ 下载 / 解压

# 按给定顺序逐个源尝试, 全失败才抛错; 本地路径直接复制
function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    foreach ($url in $Urls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        if ($url -match '^[a-zA-Z]:\\' -or $url.StartsWith("\\\\")) {
            Copy-Item -LiteralPath $url -Destination $Destination -Force
            Write-LogDebug -Scope "net" -Message ("使用本地文件 {0}" -f $url)
            return $url
        }

        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.UserAgent = "STEAMX"
        $request.Accept = "application/octet-stream"
        $request.AllowAutoRedirect = $true
        $request.Timeout = $Timeout * 1000
        $request.ReadWriteTimeout = $Timeout * 1000
        $response = $null
        $responseStream = $null
        $fileStream = $null
        try {
            Write-LogInfo -Scope "net" -Message (Format-Text -Key "Downloading" -Values @((Format-UrlShort -Url $url)))
            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()
            $fileStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $buffer = New-Object byte[] 131072
            $total = [long]$response.ContentLength
            $done = 0L
            while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) {
                    Write-Progress -Id 1 -Activity "下载清单包" -Status ("{0} / {1}" -f (Format-Size $done), (Format-Size $total)) -PercentComplete ([Math]::Min(100, [int](($done * 100) / $total)))
                } else {
                    Write-Progress -Id 1 -Activity "下载清单包" -Status ("{0}" -f (Format-Size $done))
                }
            }
            return $url
        } catch {
            Write-LogWarning -Scope "net" -Message (Format-Text -Key "DownloadFailed" -Values @((Format-UrlShort -Url $url), $_.Exception.Message))
        } finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
            if ($null -ne $responseStream) { $responseStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            Write-Progress -Id 1 -Activity "下载清单包" -Completed
        }
    }

    Set-ErrorKind -Kind "Network"
    throw (T -Key "DownloadFailedAll")
}

# zip 魔数: PK\x03\x04, 用来挡掉"下载到 HTML 错误页"这类情况
function Test-ZipMagic {
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

# 覆盖前先备份同名文件, 默认只装 .manifest(-IncludeLua 才装 .lua)
function Expand-GameZip {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$LuaDir,
        [Parameter(Mandatory = $true)][string]$ManifestDir,
        [AllowEmptyString()][string]$BackupDir = "",
        [switch]$IncludeLua
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $added = 0
    $overwritten = 0
    $skipped = 0
    try {
        $entries = @($archive.Entries)
        $total = [Math]::Max(1, $entries.Count)
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $name = [string]$entry.Name
            if ([string]::IsNullOrEmpty($name)) { continue }

            $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
            if ($extension -eq ".lua" -and -not $IncludeLua) {
                $skipped++
                continue
            }
            switch ($extension) {
                ".lua" { $targetDir = $LuaDir }
                default { $targetDir = $ManifestDir }
            }
            Ensure-Dir -PathValue $targetDir
            $targetPath = Join-Path $targetDir $name

            Write-Progress -Id 2 -Activity "解压覆盖" -Status $name -PercentComplete ([int]((($i + 1) * 100) / $total))

            $existed = Test-Path -LiteralPath $targetPath -PathType Leaf
            if ($existed -and -not [string]::IsNullOrWhiteSpace($BackupDir)) {
                Ensure-Dir -PathValue $BackupDir
                Copy-Item -LiteralPath $targetPath -Destination (Join-Path $BackupDir $name) -Force
            }

            $entryStream = $null
            $outputStream = $null
            try {
                $entryStream = $entry.Open()
                $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $entryStream.CopyTo($outputStream)
            } catch [System.UnauthorizedAccessException] {
                Set-ErrorKind -Kind "Permission"
                Write-LogError -Scope "install" -Message (Format-Text -Key "NoPermission" -Values @($targetPath))
                throw
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }

            if ($existed) { $overwritten++ } else { $added++ }
        }
    } finally {
        $archive.Dispose()
        Write-Progress -Id 2 -Activity "解压覆盖" -Completed
    }

    return [pscustomobject]@{ Added = $added; Overwritten = $overwritten; Skipped = $skipped }
}

# ================================================================ 错误呈现

# ERROR 行之外的补充说明(Reason / Try), 只在出错时出现, 不参与正常输出
function Show-ErrorGuidance {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Detail = ""
    )

    $guide = $null
    switch ($Kind) {
        "Permission" {
            $guide = @{
                Reason = "当前账户没有写入目标目录的权限。"
                Try    = "右键快捷方式 -> 以管理员身份运行; 或在管理员 PowerShell 里放权一次: icacls `"<Steam 目录>`" /grant `"*S-1-5-32-545:(OI)(CI)M`" /T"
            }
        }
        "Environment" {
            $guide = @{
                Reason = "没有找到可用的 Steam 安装目录。"
                Try    = "用 -SteamPath <steam.exe 所在目录> 指定, 或设置环境变量 STEAM_PATH 后重跑。"
            }
        }
        "Network" {
            $guide = @{
                Reason = "远端仓库或 Steam 商店不可达(超时 / 被拦截 / 无网络)。"
                Try    = "检查网络或代理后重试; 已有本地包时用 -Offline -LocalDir <目录> 走本地。"
            }
        }
        "FileSystem" {
            $guide = @{
                Reason = "文件被占用或路径不可用。"
                Try    = "先完全退出 Steam 再重跑; 确认目标目录存在、磁盘未只读。"
            }
        }
        "UserInput" {
            $guide = @{
                Reason = "选择结果不合法, 或当前环境无法接收键盘输入。"
                Try    = "用 -Game <AppID|关键词> 直接指定游戏后重跑。"
            }
        }
        "Dependency" {
            $guide = @{
                Reason = "缺少运行所需的组件。"
                Try    = "确认系统为 Windows 10/11 且使用 Windows PowerShell 5.1。"
            }
        }
        default { $guide = $null }
    }

    if ($null -eq $guide) { return }

    Write-Host ""
    Write-Host "  Reason:" -ForegroundColor DarkGray
    Write-Host ("    " + $guide.Reason) -ForegroundColor Gray
    Write-Host "  Try:" -ForegroundColor DarkGray
    Write-Host ("    " + $guide.Try) -ForegroundColor Gray
    if ($script:LogEnabled -and -not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host "  Details:" -ForegroundColor DarkGray
        Write-Host ("    " + $Detail) -ForegroundColor DarkGray
    }
}

# 退出前恢复终端状态(光标等), 别把用户终端留在坏状态
function Restore-Terminal {
    try { [Console]::CursorVisible = $true } catch { }
}

# 失败时该不该把窗口留住:
#   双击 / 快捷方式启动 -> 进程一退窗口就没了, 必须留, 否则用户什么都看不到
#   管道 / 自动化调用   -> 没人按键, 等了就是挂死, 不留
# 显式开关: -Pause 强制留, -NoPause 或环境变量 STEAMX_NO_PAUSE=1 强制不留
function Test-ShouldPause {
    if ($NoPause) { return $false }
    if ($Pause) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($env:STEAMX_NO_PAUSE)) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch {
        return $false
    }
    return $true
}

# 把错误 + 最近 200 行日志落盘, 窗口关了也能事后查(甚至直接发给作者)
function Save-CrashLog {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowEmptyString()][string]$Detail = "",
        [int]$ExitCodeValue = 0
    )

    try {
        $dir = Join-Path (Get-ProjectRoot) "logs"
        Ensure-Dir -PathValue $dir
        $path = Join-Path $dir ("repair-error-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add("===== STEAMX 修复下载 / 失败记录 =====")
        [void]$lines.Add(("时间    : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
        [void]$lines.Add(("退出码  : {0} ({1})" -f $ExitCodeValue, $Kind))
        [void]$lines.Add(("错误    : {0}" -f $Message))
        [void]$lines.Add(("命令行  : {0}" -f ([Environment]::CommandLine)))
        [void]$lines.Add(("环境    : PowerShell {0} / OS {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.Version))
        if (-not [string]::IsNullOrWhiteSpace($Detail)) {
            [void]$lines.Add("")
            [void]$lines.Add("--- 异常详情 ---")
            foreach ($detailLine in ($Detail -split "`r?`n")) { [void]$lines.Add($detailLine) }
        }
        [void]$lines.Add("")
        [void]$lines.Add(("--- 失败前日志 (末 {0} 行) ---" -f $script:LogRing.Count))
        foreach ($entry in $script:LogRing) { [void]$lines.Add([string]$entry) }

        Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
        return $path
    } catch {
        return ""
    }
}

# 停在窗口里等人按 Enter, 而不是 exit 之后窗口消失
function Wait-WindowBeforeExit {
    Write-Host ""
    Write-Host "  按 Enter 关闭窗口 ..." -ForegroundColor DarkGray
    try {
        $line = [Console]::ReadLine()
        # stdin 已经到 EOF(无人值守) -> 至少留几秒给人看, 不无限挂住
        if ($null -eq $line) { Start-Sleep -Seconds 10 }
    } catch {
        Start-Sleep -Seconds 10
    }
}

# ================================================================ 主流程

function Invoke-Repair {
    $projectRoot = Get-ProjectRoot

    if ($Log) {
        try {
            $logDir = Join-Path $projectRoot "logs"
            Ensure-Dir -PathValue $logDir
            $script:LogFile = Join-Path $logDir ("repair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
            $script:LogEnabled = $true
        } catch {
            $script:LogFile = ""
            Write-LogWarning -Scope "repair" -Message ("日志文件不可写, 已跳过: {0}" -f $_.Exception.Message)
        }
    }

    Write-LogInfo -Scope "repair" -Message (T -Key "Title")

    # --- 环境: Steam 与目标目录
    $steam = Format-PathCase -PathValue (Resolve-SteamPath)
    $luaDir = if ([string]::IsNullOrWhiteSpace($LuaTarget)) { Join-Path $steam "config\lua" } else { $LuaTarget }
    $manifestDir = if ([string]::IsNullOrWhiteSpace($ManifestTarget)) { Join-Path $steam "depotcache" } else { $ManifestTarget }
    $localZipDir = if (-not [string]::IsNullOrWhiteSpace($LocalDir)) { $LocalDir }
    elseif (-not [string]::IsNullOrWhiteSpace($env:STEAMX_MANIFEST_DIR)) { $env:STEAMX_MANIFEST_DIR }
    else { Join-Path $projectRoot "manifest" }

    Write-LogSuccess -Scope "steam" -Message (Format-Text -Key "SteamDirLabel" -Values @($steam))
    Write-LogInfo -Scope "install" -Message (Format-Text -Key "TargetDirLabel" -Values @($manifestDir))

    if ($ShowEnv) {
        if ($IncludeLua) { Write-LogInfo -Scope "install" -Message (Format-Text -Key "LuaDirLabel" -Values @($luaDir)) }
        Write-LogInfo -Scope "repair" -Message (Format-Text -Key "LocalSourceDir" -Values @($localZipDir))
        Write-LogInfo -Scope "repair" -Message (Format-Text -Key "RepoLabel" -Values @($Repo, $Branch))
        if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
            Write-LogInfo -Scope "repair" -Message (Format-Text -Key "LogPathLabel" -Values @($script:LogFile))
        }
    }

    if (@(Get-Process -Name "steam" -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-LogWarning -Scope "steam" -Message (T -Key "SteamRunning")
    }

    # --- 权限预检: 系统盘下的 Steam(如 C:\Program Files (x86)\Steam) 默认只让管理员写
    #     提前失败并给可操作的提示, 而不是抛原始的 UnauthorizedAccessException
    $writeTargets = @($manifestDir)
    if ($IncludeLua) { $writeTargets += $luaDir }
    $blockedTargets = @($writeTargets | Where-Object { -not (Test-DirWritable -PathValue $_) })
    if ($blockedTargets.Count -gt 0) {
        $isAdmin = Test-IsAdministrator
        foreach ($blockedPath in $blockedTargets) {
            if ($isAdmin) {
                Write-LogError -Scope "install" -Message (Format-Text -Key "NotWritable" -Values @($blockedPath))
            } else {
                Write-LogError -Scope "install" -Message (Format-Text -Key "NoPermission" -Values @($blockedPath))
            }
        }
        if (-not $isAdmin) {
            Write-LogWarning -Scope "install" -Message (T -Key "RunAsAdmin")
        }
        Set-ErrorKind -Kind "Permission"
        throw (T -Key "TargetBlocked")
    }

    # --- 索引: 远端列表 + 本地补充
    $index = $null
    if (-not $Offline) {
        $index = Get-RemoteZipIndex -AllowFailure
    }
    $items = @()
    if ($null -ne $index -and @($index.Items).Count -gt 0) {
        $items = @($index.Items)
        Write-LogSuccess -Scope "net" -Message (Format-Text -Key "RemoteListed" -Values @($items.Count, $index.Source))
        if (-not [string]::IsNullOrWhiteSpace($index.Error)) {
            Write-LogWarning -Scope "net" -Message (Format-Text -Key "RemoteDegraded" -Values @($index.Error))
        }
    } elseif ($null -ne $index -and -not [string]::IsNullOrWhiteSpace($index.Error)) {
        Write-LogWarning -Scope "net" -Message (Format-Text -Key "RemoteUnavailable" -Values @($index.Error))
    }

    $localItems = @(Get-LocalZipIndex -Directory $localZipDir)
    if ($Offline) {
        $items = $localItems
        Write-LogInfo -Scope "net" -Message (Format-Text -Key "LocalCount" -Values @($items.Count))
    } elseif ($localItems.Count -gt 0) {
        $remoteNames = @($items | ForEach-Object { $_.Name })
        $extra = @($localItems | Where-Object { $remoteNames -notcontains $_.Name })
        if ($extra.Count -gt 0) {
            $items = @($items) + @($extra)
            Write-LogInfo -Scope "net" -Message (Format-Text -Key "LocalExtra" -Values @($extra.Count))
        }
    }

    # 远端列表为空时完全回退本地
    if ($items.Count -eq 0 -and $localItems.Count -gt 0) {
        $items = $localItems
        Write-LogWarning -Scope "net" -Message (Format-Text -Key "LocalFallback" -Values @($items.Count))
    }
    if ($items.Count -eq 0) {
        throw (T -Key "NoPackages")
    }

    # --- 游戏名: 默认只读本地名单, 缺失先用 AppID 顶上; -RefreshNames 才逐个联网补全
    $cachePath = Join-Path $localZipDir "appnames.json"
    $items = Add-GameDisplayNames -Items $items -CachePath $cachePath -Timeout $TimeoutSeconds -SkipNetwork:$Offline -Refresh:$RefreshNames

    # --- 选择
    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($Game)) {
        $matched = @($items | Where-Object {
                $_.Name -like ("*{0}*" -f $Game) -or
                $_.DisplayName -like ("*{0}*" -f $Game) -or
                $_.Alias -like ("*{0}*" -f $Game) -or
                $_.AppId -eq $Game
            })
        if ($matched.Count -eq 1) {
            $selected = $matched[0]
        } elseif ($matched.Count -gt 1) {
            Write-LogInfo -Scope "repair" -Message (Format-Text -Key "MatchMultiple" -Values @($matched.Count))
            $menuItems = @(
                foreach ($item in ($matched | Sort-Object DisplayName)) {
                    [pscustomobject]@{ Item = $item; Value = $item }
                }
            )
            $picked = Show-GameMenu -Items $menuItems -Title (Format-Text -Key "MenuMatchTitle" -Values @($Game))
            if ($null -eq $picked) {
                Set-ErrorKind -Kind "Cancelled"
                throw (T -Key "Cancelled")
            }
            $selected = $picked
        } else {
            Set-ErrorKind -Kind "UserInput"
            throw (Format-Text -Key "NoMatch" -Values @($Game))
        }
    } else {
        $menuItems = @(
            foreach ($item in ($items | Sort-Object DisplayName)) {
                [pscustomobject]@{ Item = $item; Value = $item }
            }
        )
        $picked = Show-GameMenu -Items $menuItems -Title (T -Key "MenuTitle")
        if ($null -eq $picked) {
            Set-ErrorKind -Kind "Cancelled"
            throw (T -Key "Cancelled")
        }
        $selected = $picked
    }

    # 选中的包名字缺失时补一次(单次请求, 不阻塞菜单)
    if (-not $Offline) {
        $selected = Update-PendingGameName -Item $selected -CachePath $cachePath -Timeout $TimeoutSeconds
    }

    Write-LogInfo -Scope "install" -Message (Format-Text -Key "GameSelected" -Values @((New-GameLabel -Item $selected)))
    Write-LogInfo -Scope "install" -Message (Format-Text -Key "SourceUsed" -Values @($selected.Source))

    # --- 取包 + 解压覆盖
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\repair\{0}" -f [Guid]::NewGuid().ToString("N"))
    Ensure-Dir -PathValue $tempRoot
    $zipPath = Join-Path $tempRoot $selected.Name
    try {
        # 本地已有同名包则直接复用, 省一次下载
        $localCandidate = Join-Path $localZipDir $selected.Name
        if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
            Write-LogSuccess -Scope "net" -Message (Format-Text -Key "LocalHit" -Values @($localCandidate))
            Copy-Item -LiteralPath $localCandidate -Destination $zipPath -Force
        } else {
            [void](Invoke-FileDownload -Urls $selected.DownloadUrls -Destination $zipPath -Timeout $TimeoutSeconds)
        }

        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
            Set-ErrorKind -Kind "Network"
            throw (T -Key "ZipEmpty")
        }
        if (-not (Test-ZipMagic -PathValue $zipPath)) {
            Set-ErrorKind -Kind "Network"
            throw (T -Key "ZipNotValid")
        }

        $backupDir = ""
        if (-not $NoBackup) {
            $backupDir = Join-Path (Join-Path $projectRoot "backups") ("repair-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        }
        $result = Expand-GameZip -ZipPath $zipPath -LuaDir $luaDir -ManifestDir $manifestDir -BackupDir $backupDir -IncludeLua:$IncludeLua

        Write-LogSuccess -Scope "install" -Message (Format-Text -Key "Installed" -Values @($result.Added, $result.Overwritten))
        if ($result.Skipped -gt 0) {
            Write-LogWarning -Scope "install" -Message (Format-Text -Key "SkippedLua" -Values @($result.Skipped))
        }
        if (-not [string]::IsNullOrWhiteSpace($backupDir) -and $result.Overwritten -gt 0) {
            Write-LogInfo -Scope "install" -Message (Format-Text -Key "BackupDirLabel" -Values @($backupDir))
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ================================================================ 入口

try {
    Invoke-Repair
} catch {
    $kind = Get-ErrorKind -ErrorRecord $_
    $message = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = (T -Key "EnvUnknown") }
    $detail = $_.Exception.ToString()

    if ($kind -eq "Cancelled") {
        Write-LogWarning -Scope "repair" -Message $message
    } else {
        Write-LogError -Scope "repair" -Message $message
        Show-ErrorGuidance -Kind $kind -Detail $detail
    }
    $script:ExitCode = Get-ExitCodeForKind -Kind $kind

    # 主动取消(Esc)不留窗口, 其他失败都留: 见 Test-ShouldPause 注释
    if ($script:ExitCode -ne 0 -and $kind -ne "Cancelled") {
        $script:Failed = $true
        $script:CrashLogFile = Save-CrashLog -Kind $kind -Message $message -Detail $detail -ExitCodeValue $script:ExitCode
    }
} finally {
    Restore-Terminal
}

# 双击启动的场景: exit 一执行窗口就关, 所以留窗口这件事必须发生在 exit 之前
if ($script:Failed) {
    if (-not [string]::IsNullOrWhiteSpace($script:CrashLogFile)) {
        Write-Host ""
        Write-Host ("  详细日志: " + $script:CrashLogFile) -ForegroundColor DarkGray
    }
    if (Test-ShouldPause) { Wait-WindowBeforeExit }
}

exit $script:ExitCode
