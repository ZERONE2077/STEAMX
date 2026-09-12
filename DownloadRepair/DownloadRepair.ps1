# repair.ps1 - STEAMX 单游戏清单修复工具
# 识别 Steam 路径 -> 手动选择游戏 -> 从仓库下载 zip -> 解压覆盖到 Steam 目录
# .lua -> <Steam>\config\lua      .manifest -> <Steam>\depotcache
#
# 编码: UTF-8 with BOM,可直接右键 / powershell -File 运行(PS 5.1 安全)
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
    [switch]$RefreshNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# PS 5.1 默认不一定启用 TLS 1.2,GitHub API / jsDelivr 需要
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# 日志文件默认不写, -Log 才落到 logs\repair-<时间戳>.log
$script:LogFile = ""
$script:LogEnabled = $false

# ---------------------------------------------------------------- 输出

# tail 风格日志: HH:mm:ss TAG scope message
# TAG 宽 5 (INFO/OK/WARN/ERROR/DBUG), scope 宽 8
# 整行拼成单个 Write-Host(ANSI SGR), 避免重定向时被拆行;
# 非 VT 终端 / 输出被重定向 / 设了 NO_COLOR 时退化为纯文本

function Test-VirtualTerminal {
    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) { return $false }
    if ([Console]::IsOutputRedirected) { return $false }
    if (-not [string]::IsNullOrEmpty($env:WT_SESSION)) { return $true }
    try {
        $property = $Host.UI.PSObject.Properties["SupportsVirtualTerminal"]
        if ($null -ne $property) { return [bool]$property.Value }
    } catch { }
    return $false
}

function Initialize-Ui {
    $script:UseAnsi = Test-VirtualTerminal
}

$script:UseAnsi = $false

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARN", "ERROR")][string]$Level = "INFO",
        [AllowEmptyString()][string]$Message = ""
    )

    if ($Level -eq "DEBUG" -and -not $script:LogEnabled) { return }

    $tagMap = @{ DEBUG = "DBUG"; INFO = "INFO"; SUCCESS = "OK"; WARN = "WARN"; ERROR = "ERROR" }
    $colorMap = @{ DEBUG = "90"; INFO = "36"; SUCCESS = "32"; WARN = "33"; ERROR = "31" }
    $tag = $tagMap[$Level].PadRight(5)

    $scopeKey = $Scope.ToLowerInvariant()
    if ($scopeKey.Length -gt 8) { $scopeKey = $scopeKey.Substring(0, 8) }
    $scopePad = $scopeKey.PadRight(8)

    $stamp = Get-Date -Format "HH:mm:ss"

    if ($script:UseAnsi) {
        $esc = [char]27
        $msgIn = ""
        $msgOut = ""
        if ($Level -eq "WARN" -or $Level -eq "ERROR") {
            $msgIn = "${esc}[$($colorMap[$Level])m"
            $msgOut = "${esc}[0m"
        }
        Write-Host ("${esc}[90m{0}${esc}[0m ${esc}[{1}m{2}${esc}[0m ${esc}[90m{3}${esc}[0m {4}{5}{6}" -f $stamp, $colorMap[$Level], $tag, $scopePad, $msgIn, $Message, $msgOut)
    } else {
        Write-Host ("{0} {1} {2} {3}" -f $stamp, $tag, $scopePad, $Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        $line = "{0} [{1}] {2} {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $scopeKey, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

# ---------------------------------------------------------------- 显示宽度

# 单个字符占几列: 中日韩全角 2 列, 其余 1 列
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

function Get-TextWidth {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) { $width += (Get-CharWidth -Ch $ch) }
    return $width
}

# 按显示宽度截断, 超出部分用 … 收尾
function Limit-TextWidth {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$MaxWidth
    )

    if ($MaxWidth -le 0) { return "" }
    if ((Get-TextWidth -Text $Text) -le $MaxWidth) { return $Text }

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

# 菜单专用分隔标题(不属于日志流)
function Format-RuleText {
    param([string]$Title = "")

    $width = [Math]::Min(62, (Get-ConsoleWidth) - 1)
    if ($width -lt 12) { $width = 62 }
    if ([string]::IsNullOrWhiteSpace($Title)) { return ("-" * $width) }

    $prefix = "- {0} " -f $Title
    return ($prefix + ("-" * [Math]::Max(0, $width - (Get-TextWidth -Text $prefix))))
}

function Write-Rule {
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

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}

# 脚本位于 <项目根>\DownloadRepair,manifest/backups/logs 都在项目根
# irm | iex 运行时 $PSScriptRoot 为空,需要按 manifest 目录反查项目根
function Get-ProjectRoot {
    $root = Get-ScriptRoot
    $candidates = @($root)
    try {
        $parent = Split-Path -Parent $root
        if (-not [string]::IsNullOrWhiteSpace($parent)) { $candidates += $parent }
    } catch { }
    $candidates += (Get-Location).Path

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $candidate "manifest") -PathType Container) { return $candidate }
    }
    return $root
}

# 日志/备份落盘位置:找到项目根就用它,否则退到 %TEMP%\STEAMX(irm|iex 场景)
function Get-DataRoot {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    if (Test-Path -LiteralPath (Join-Path $ProjectRoot "manifest") -PathType Container) { return $ProjectRoot }
    $temp = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    return (Join-Path $temp "STEAMX")
}

function Ensure-Dir {
    param([Parameter(Mandatory = $true)][string]$PathValue)
    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
}

# ---------------------------------------------------------------- Steam 路径

function Test-SteamDir {
    param([AllowNull()][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    try {
        return [bool](Test-Path -LiteralPath (Join-Path $PathValue "steam.exe") -PathType Leaf)
    } catch {
        return $false
    }
}

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

    $entered = (Read-Host "  未自动识别到 Steam,请输入 steam.exe 所在文件夹(回车取消)").Trim().Trim('"')
    if ($entered.EndsWith("steam.exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $entered = Split-Path -Parent $entered
    }
    if (Test-SteamDir -PathValue $entered) {
        return [System.IO.Path]::GetFullPath($entered)
    }

    throw "未找到 Steam 安装路径。用 -SteamPath 指定,或设置环境变量 STEAM_PATH。"
}

# ---------------------------------------------------------------- 菜单

function Read-MenuSelection {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $index = 0
    $hasRendered = $false
    $lastLineCount = 0

    # 页面大小按"光标到窗口底部还剩多少行"定, 尽量不把上面的日志滚掉
    $windowHeight = Get-ConsoleHeight
    $menuTop = 0
    try { $menuTop = [Console]::CursorTop } catch { $menuTop = 0 }
    $avail = ($windowHeight - 1) - $menuTop
    $pageSize = [Math]::Min(20, [Math]::Min($windowHeight - 12, $avail - 3))
    if ($pageSize -lt 5) { $pageSize = 5 }
    if (($menuTop + $pageSize + 3) -gt ($windowHeight - 1)) {
        try { [Console]::Clear() } catch { }
        $menuTop = 0
        $pageSize = [Math]::Max(5, [Math]::Min(20, $windowHeight - 12))
    }

    while ($true) {
        $windowHeight = Get-ConsoleHeight
        $consoleWidth = Get-ConsoleWidth

        $page = [Math]::Floor($index / $pageSize)
        $start = $page * $pageSize
        $end = [Math]::Min($start + $pageSize, $Items.Count) - 1

        # 前缀 "  > " 占 4 列, 右侧留 1 列; 每项严格一行, 否则重绘会错位
        $rowLimit = $consoleWidth - 1
        $labelWidth = [Math]::Max(12, $consoleWidth - 5)
        $rows = New-Object System.Collections.ArrayList
        [void]$rows.Add(@{ Text = (Format-RuleText -Title $Title); Color = "DarkGray" })
        for ($i = $start; $i -le $end; $i++) {
            $isSelected = ($i -eq $index)
            $marker = if ($isSelected) { ">" } else { " " }
            $label = New-GameLabel -Item $Items[$i].Item -MaxWidth $labelWidth
            $color = if ($isSelected) { "Cyan" } else { "Gray" }
            [void]$rows.Add(@{ Text = ("  {0} {1}" -f $marker, $label); Color = $color })
        }
        [void]$rows.Add(@{ Text = ("  第 {0}/{1} 项" -f ($index + 1), $Items.Count); Color = "DarkGray" })
        [void]$rows.Add(@{
                Text  = (Limit-TextWidth -MaxWidth $rowLimit -Text "  Up/Down 选择   PgUp/PgDn 翻页   Home/End 首尾   Enter 确认   Esc 返回")
                Color = "DarkGray"
            })

        $lineCount = $rows.Count

        if ($hasRendered) {
            if (($menuTop + $lineCount) -gt ($windowHeight - 1)) {
                # 窗口被缩小 / 本帧比上帧长, 整屏重绘避免残影
                try { [Console]::Clear() } catch { }
                $menuTop = 0
                $pageSize = [Math]::Max(5, [Math]::Min(20, $windowHeight - 12))
                continue
            }
        } else {
            $hasRendered = $true
        }

        try {
            [Console]::SetCursorPosition(0, $menuTop)
        } catch {
            try { [Console]::Clear() } catch { }
            $menuTop = 0
        }

        foreach ($row in $rows) {
            $pad = $consoleWidth - 1 - (Get-TextWidth -Text $row.Text)
            if ($pad -lt 0) { $pad = 0 }
            Write-Host ($row.Text + (" " * $pad)) -ForegroundColor $row.Color
        }
        for ($k = $lineCount; $k -lt $lastLineCount; $k++) {
            Write-Host (" " * ($consoleWidth - 1))
        }
        $lastLineCount = $lineCount

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
}

# ---------------------------------------------------------------- 远端索引

function Get-RemoteZipIndex {
    param([switch]$AllowFailure)

    $errors = @()
    $headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "STEAMX" }

    # 直连 api.github.com 在国内常被墙/超时,再试 gh-proxy 镜像转发同一 API
    $apiPrefixes = @("", "https://gh-proxy.com/")

    foreach ($dir in $RemoteDir) {
        $dirTrimmed = $dir.Trim("/")
        $apiPath = "repos/{0}/contents/{1}?ref={2}" -f $Repo, ([Uri]::EscapeDataString($dirTrimmed)), ([Uri]::EscapeDataString($Branch))
        foreach ($prefix in $apiPrefixes) {
            $api = "{0}https://api.github.com/{1}" -f $prefix, $apiPath
            try {
                # 注意: @(Invoke-RestMethod ...) 会把 JSON 数组当成单个元素,必须先赋值再包
                $response = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec $TimeoutSeconds
                $entries = @($response)
                $zips = @($entries | Where-Object { $_.type -eq "file" -and $_.name -like "*.zip" })
                if ($zips.Count -gt 0) {
                    $items = @(
                        foreach ($zip in $zips) {
                            $name = [string]$zip.name
                            $escaped = [Uri]::EscapeDataString($name)
                            [pscustomobject]@{
                                Name         = $name
                                Size         = [long]$zip.size
                                # jsDelivr 文件级缓存刷新快,优先;镜像 raw 次之;直连 download_url 最后
                                DownloadUrls = @(
                                    ("https://cdn.jsdelivr.net/gh/{0}@{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                    ("https://gh-proxy.com/https://raw.githubusercontent.com/{0}/{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                    ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, $escaped),
                                    [string]$zip.download_url
                                )
                                Source       = "github:{0}" -f $dirTrimmed
                            }
                        }
                    )
                    return [pscustomobject]@{ Items = $items; Source = "github:{0}" -f $dirTrimmed; Error = "" }
                }
                # API 可达但目录里没有 zip,换下一个 RemoteDir
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
                    [pscustomobject]@{
                        Name         = Split-Path -Leaf $relative
                        Size         = [long]$zip.size
                        DownloadUrls = @(
                            ("https://cdn.jsdelivr.net/gh/{0}@{1}/{2}" -f $Repo, $Branch, $relative),
                            ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/{2}" -f $Repo, $Branch, $relative)
                        )
                        Source       = "jsdelivr"
                    }
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
    throw ("无法获取远端 zip 列表。{0}" -f ($errors -join " | "))
}

function Get-LocalZipIndex {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $Directory -File -Filter *.zip -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Name         = $_.Name
                    Size         = $_.Length
                    DownloadUrls = @($_.FullName)
                    Source       = "local"
                }
            }
    )
}

# ---------------------------------------------------------------- 游戏中文名

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

    # 菜单里限宽: 先砍名字, [AppID] 和体积一定留在同一行
    if ($MaxWidth -gt 0) {
        $room = $MaxWidth - (Get-TextWidth -Text $suffix)
        $display = Limit-TextWidth -Text $display -MaxWidth ([Math]::Max(8, $room - 1))
    }
    return ($display + $suffix)
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

    try {
        $ordered = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($key in @($Cache.Keys | Sort-Object)) { $ordered[[string]$key] = [string]$Cache[$key] }
        ($ordered | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $PathValue -Encoding UTF8
    } catch { }
}

function Invoke-RemoteText {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = "STEAMX"
    $request.Accept = "application/json"
    $request.AllowAutoRedirect = $true
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

# 名单只走本地缓存(缺失时同步仓库里的 appnames.json), 不做逐个联网
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
            Write-UiLog -Scope "names" -Level "SUCCESS" -Message ("本地名单为空, 已同步仓库缓存 {0} 条" -f $cache.Count)
        }
    }

    $pending = @()
    foreach ($item in $Items) {
        $appId = Get-AppIdFromZipName -Name ([string]$item.Name)
        $item | Add-Member -NotePropertyName AppId -NotePropertyValue $appId -Force

        $display = ""
        if (-not [string]::IsNullOrWhiteSpace($appId) -and $cache.ContainsKey($appId)) {
            $display = [string]$cache[$appId]
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
    }

    if ($Refresh -and $pending.Count -gt 0) {
        Write-UiLog -Scope "names" -Level "INFO" -Message ("补全游戏名 {0} 个 (Steam 商店)" -f $pending.Count)
        $changed = $false
        foreach ($appId in $pending) {
            $name = Get-SteamAppName -AppId $appId -Timeout $Timeout
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $cache[$appId] = $name
                $changed = $true
                Write-UiLog -Scope "names" -Level "DEBUG" -Message ("{0} = {1}" -f $appId, $name)
            }
            Start-Sleep -Milliseconds 120
        }
        if ($changed) { Save-AppNameCache -Cache $cache -PathValue $CachePath }
        foreach ($item in $Items) {
            if (-not $item.NamePending) { continue }
            $id = [string]$item.AppId
            if (-not [string]::IsNullOrWhiteSpace($id) -and $cache.ContainsKey($id)) {
                $item.DisplayName = [string]$cache[$id]
                $item.NamePending = $false
            }
        }
    }

    return @($Items)
}

# 选中的包没有中文名时补一次(单次请求, 顺带写回缓存)
function Update-PendingDisplayName {
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

    $Item.DisplayName = $name
    $Item.NamePending = $false
    return $Item
}

# ---------------------------------------------------------------- 下载 / 解压

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
            Write-UiLog -Scope "net" -Level "DEBUG" -Message ("使用本地文件 {0}" -f $url)
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
            Write-UiLog -Scope "net" -Level "INFO" -Message ("下载 {0}" -f (Format-UrlShort -Url $url))
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
            Write-UiLog -Scope "net" -Level "WARN" -Message ("下载失败 ({0}): {1}" -f (Format-UrlShort -Url $url), $_.Exception.Message)
        } finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
            if ($null -ne $responseStream) { $responseStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            Write-Progress -Id 1 -Activity "下载清单包" -Completed
        }
    }

    throw "所有下载源均失败。"
}

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
                ".manifest" { $targetDir = $ManifestDir }
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

# ---------------------------------------------------------------- 主流程

function Invoke-Repair {
    $projectRoot = Get-ProjectRoot
    $dataRoot = Get-DataRoot -ProjectRoot $projectRoot
    $script:LogEnabled = [bool]$Log
    if ($Log) {
        $logDir = Join-Path $dataRoot "logs"
        Ensure-Dir -PathValue $logDir
        $script:LogFile = Join-Path $logDir ("repair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    } else {
        $script:LogFile = ""
    }

    Initialize-Ui

    Write-UiLog -Scope "repair" -Level "INFO" -Message "STEAMX 清单修复"

    $steam = Format-PathCase -PathValue (Resolve-SteamPath)
    $luaDir = if ([string]::IsNullOrWhiteSpace($LuaTarget)) { Join-Path $steam "config\lua" } else { $LuaTarget }
    $manifestDir = if ([string]::IsNullOrWhiteSpace($ManifestTarget)) { Join-Path $steam "depotcache" } else { $ManifestTarget }
    $localZipDir = if (-not [string]::IsNullOrWhiteSpace($LocalDir)) { $LocalDir }
                   elseif (-not [string]::IsNullOrWhiteSpace($env:STEAMX_MANIFEST_DIR)) { $env:STEAMX_MANIFEST_DIR }
                   else { Join-Path $projectRoot "manifest" }

    Write-UiLog -Scope "steam" -Level "SUCCESS" -Message ("Steam {0}" -f $steam)
    Write-UiLog -Scope "install" -Level "INFO" -Message ("目标 {0}" -f $manifestDir)

    if ($ShowEnv) {
        if ($IncludeLua) { Write-UiLog -Scope "install" -Level "INFO" -Message ("Lua 目录 {0}" -f $luaDir) }
        Write-UiLog -Scope "repair" -Level "INFO" -Message ("本地包源 {0}" -f $localZipDir)
        Write-UiLog -Scope "repair" -Level "INFO" -Message ("仓库 {0}@{1}" -f $Repo, $Branch)
        if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
            Write-UiLog -Scope "repair" -Level "INFO" -Message ("日志 {0}" -f $script:LogFile)
        }
    }

    if (@(Get-Process -Name "steam" -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-UiLog -Scope "steam" -Level "WARN" -Message "Steam 正在运行, 写入可能被占用, 建议先退出"
    }

    # 1. 索引
    $index = $null
    if (-not $Offline) {
        $index = Get-RemoteZipIndex -AllowFailure
    }
    $items = @()
    $remoteCount = 0
    if ($null -ne $index -and @($index.Items).Count -gt 0) {
        $items = @($index.Items)
        $remoteCount = $items.Count
        Write-UiLog -Scope "net" -Level "SUCCESS" -Message ("远端列表 {0} 个包 ({1})" -f $remoteCount, $index.Source)
        if (-not [string]::IsNullOrWhiteSpace($index.Error)) {
            Write-UiLog -Scope "net" -Level "WARN" -Message ("GitHub API 不可用, 已降级: {0}" -f $index.Error)
        }
    } elseif ($null -ne $index -and -not [string]::IsNullOrWhiteSpace($index.Error)) {
        Write-UiLog -Scope "net" -Level "WARN" -Message ("远端不可用: {0}" -f $index.Error)
    }

    # 本地 manifest/ 作为补充:远端没有的包(尚未推送)也能装
    $localItems = @(Get-LocalZipIndex -Directory $localZipDir)
    if ($Offline) {
        $items = $localItems
        Write-UiLog -Scope "net" -Level "INFO" -Message ("本地目录 {0} 个包" -f $items.Count)
    } elseif ($localItems.Count -gt 0) {
        $remoteNames = @($items | ForEach-Object { $_.Name })
        $extra = @($localItems | Where-Object { $remoteNames -notcontains $_.Name })
        if ($extra.Count -gt 0) {
            $items = @($items) + @($extra)
            Write-UiLog -Scope "net" -Level "INFO" -Message ("本地补充 {0} 个包 (未推送)" -f $extra.Count)
        }
    }

    # 远端列表为空时,完全回退本地
    if ($items.Count -eq 0 -and $localItems.Count -gt 0) {
        $items = $localItems
        Write-UiLog -Scope "net" -Level "WARN" -Message ("回退本地目录 {0} 个包" -f $items.Count)
    }
    if ($items.Count -eq 0) {
        throw "没有可用的 zip 包(远端与本地均为空)。"
    }

    # 1.5 游戏中文名: 默认只读本地名单 manifest\appnames.json, 缺失先用 AppID 顶上
    #      -RefreshNames 才逐个联网补全(带进度日志)
    $cachePath = Join-Path $localZipDir "appnames.json"
    $items = Add-GameDisplayNames -Items $items -CachePath $cachePath -Timeout $TimeoutSeconds -SkipNetwork:$Offline -Refresh:$RefreshNames

    # 2. 选择
    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($Game)) {
        $matched = @($items | Where-Object {
            $_.Name -like ("*{0}*" -f $Game) -or
            $_.DisplayName -like ("*{0}*" -f $Game) -or
            $_.AppId -eq $Game
        })
        if ($matched.Count -eq 1) {
            $selected = $matched[0]
        } elseif ($matched.Count -gt 1) {
            Write-UiLog -Scope "repair" -Level "INFO" -Message ("关键词命中 {0} 个, 请从列表选择" -f $matched.Count)
            $menuItems = @(
                foreach ($item in ($matched | Sort-Object DisplayName)) {
                    [pscustomobject]@{ Item = $item; Value = $item }
                }
            )
            $picked = Read-MenuSelection -Items $menuItems -Title ("匹配 [{0}]" -f $Game)
            if ($null -eq $picked) { throw "已取消。" }
            $selected = $picked
        } else {
            throw ("没有匹配 [{0}] 的游戏包。" -f $Game)
        }
    } else {
        $menuItems = @(
            foreach ($item in ($items | Sort-Object DisplayName)) {
                [pscustomobject]@{ Item = $item; Value = $item }
            }
        )
        $picked = Read-MenuSelection -Items $menuItems -Title "选择游戏"
        if ($null -eq $picked) { throw "已取消。" }
        $selected = $picked
    }

    # 选中的包名字缺失时补一次(单次请求, 不阻塞菜单)
    if (-not $Offline) {
        $selected = Update-PendingDisplayName -Item $selected -CachePath $cachePath -Timeout $TimeoutSeconds
    }

    Write-UiLog -Scope "install" -Level "INFO" -Message ("游戏 {0}" -f (New-GameLabel -Item $selected))
    Write-UiLog -Scope "install" -Level "INFO" -Message ("来源 {0}" -f $selected.Source)

    # 3. 下载
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\repair\{0}" -f [Guid]::NewGuid().ToString("N"))
    Ensure-Dir -PathValue $tempRoot
    $zipPath = Join-Path $tempRoot $selected.Name
    try {
        # 本地已有同名包则直接复用
        $localCandidate = Join-Path $localZipDir $selected.Name
        if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
            Write-UiLog -Scope "net" -Level "SUCCESS" -Message ("本地命中 {0}" -f $localCandidate)
            Copy-Item -LiteralPath $localCandidate -Destination $zipPath -Force
        } else {
            [void](Invoke-FileDownload -Urls $selected.DownloadUrls -Destination $zipPath -Timeout $TimeoutSeconds)
        }

        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
            throw "下载到的 zip 为空。"
        }
        if (-not (Test-ZipMagic -PathValue $zipPath)) {
            throw "下载到的文件不是有效的 zip(可能是 HTML 错误页)。"
        }

        # 4. 解压覆盖
        $backupDir = ""
        if (-not $NoBackup) {
            $backupDir = Join-Path (Join-Path $dataRoot "backups") ("repair-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        }
        $result = Expand-GameZip -ZipPath $zipPath -LuaDir $luaDir -ManifestDir $manifestDir -BackupDir $backupDir -IncludeLua:$IncludeLua

        Write-UiLog -Scope "install" -Level "SUCCESS" -Message ("清单已安装 新增 {0} / 覆盖 {1}" -f $result.Added, $result.Overwritten)
        if ($result.Skipped -gt 0) {
            Write-UiLog -Scope "install" -Level "WARN" -Message ("跳过 {0} 个 .lua (默认不装, 用 -IncludeLua 开启)" -f $result.Skipped)
        }
        if (-not [string]::IsNullOrWhiteSpace($backupDir) -and $result.Overwritten -gt 0) {
            Write-UiLog -Scope "install" -Level "INFO" -Message ("备份 {0}" -f $backupDir)
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Invoke-Repair
} catch {
    Write-UiLog -Scope "repair" -Level "ERROR" -Message $_.Exception.Message
    exit 1
}
