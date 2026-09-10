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
    [switch]$IncludeLua
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:LogFile = ""

# ---------------------------------------------------------------- 基础工具

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERR")][string]$Level = "INFO"
    )

    $prefix = @{ INFO = "[i]"; OK = "[+]"; WARN = "[!]"; ERR = "[x]" }[$Level]
    $color = @{ INFO = "Cyan"; OK = "Green"; WARN = "Yellow"; ERR = "Red" }[$Level]
    Write-Host ("  {0} {1}" -f $prefix, $Message) -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Write-Rule {
    param([string]$Title = "")
    $width = 78
    if ([string]::IsNullOrWhiteSpace($Title)) {
        Write-Host ("-" * $width) -ForegroundColor DarkGray
        return
    }
    $prefix = "-- {0} " -f $Title
    Write-Host ($prefix + ("-" * [Math]::Max(0, $width - $prefix.Length))) -ForegroundColor DarkGray
}

function Write-Field {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowEmptyString()][string]$Value = "",
        [string]$Color = "Gray"
    )
    Write-Host ("  {0,-14}" -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0} B" -f $Bytes
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

    try { $windowHeight = [int]$host.UI.RawUI.WindowSize.Height } catch { $windowHeight = 40 }
    $pageSize = [Math]::Max(5, [Math]::Min(20, $windowHeight - 12))
    $index = 0
    $hasRendered = $false
    try { $menuTop = [Console]::CursorTop } catch { $menuTop = 0 }

    while ($true) {
        if ($hasRendered) {
            try { [Console]::SetCursorPosition(0, $menuTop) } catch { }
        }

        $page = [Math]::Floor($index / $pageSize)
        $start = $page * $pageSize
        $end = [Math]::Min($start + $pageSize, $Items.Count) - 1
        $lineCount = 0

        Write-Rule -Title $Title
        $lineCount++
        for ($i = $start; $i -le $end; $i++) {
            $isSelected = ($i -eq $index)
            $marker = if ($isSelected) { ">" } else { " " }
            $line = "  {0} {1}" -f $marker, $Items[$i].Label
            $color = if ($isSelected) { "Cyan" } else { "White" }
            Write-Host $line -ForegroundColor $color
            $lineCount++
        }
        Write-Host ("  第 {0}/{1} 项  共 {2} 个" -f ($index + 1), $Items.Count, $Items.Count) -ForegroundColor DarkGray
        $lineCount++
        Write-Host "  Up/Down 选择   PgUp/PgDn 翻页   Home/End 首尾   Enter 确认   Esc 返回" -ForegroundColor DarkGray
        $lineCount++

        if (-not $hasRendered) {
            try { $menuTop = [Math]::Max(0, [Console]::CursorTop - $lineCount) } catch { }
            $hasRendered = $true
        }

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

    foreach ($dir in $RemoteDir) {
        $dirTrimmed = $dir.Trim("/")
        $api = "https://api.github.com/repos/{0}/contents/{1}?ref={2}" -f $Repo, ([Uri]::EscapeDataString($dirTrimmed)), ([Uri]::EscapeDataString($Branch))
        try {
            $entries = @(Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec $TimeoutSeconds)
            $zips = @($entries | Where-Object { $_.type -eq "file" -and $_.name -like "*.zip" })
            if ($zips.Count -gt 0) {
                $items = @(
                    foreach ($zip in $zips) {
                        [pscustomobject]@{
                            Name         = [string]$zip.name
                            Size         = [long]$zip.size
                            DownloadUrls = @(
                                [string]$zip.download_url,
                                ("https://cdn.jsdelivr.net/gh/{0}@{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, [Uri]::EscapeDataString([string]$zip.name)),
                                ("https://ghfast.top/https://raw.githubusercontent.com/{0}/{1}/{2}/{3}" -f $Repo, $Branch, $dirTrimmed, [Uri]::EscapeDataString([string]$zip.name))
                            )
                            Source       = "github:{0}" -f $dirTrimmed
                        }
                    }
                )
                return [pscustomobject]@{ Items = $items; Source = "github:{0}" -f $dirTrimmed; Error = "" }
            }
            $errors += ("{0}: 目录为空" -f $dirTrimmed)
        } catch {
            $errors += ("{0}: {1}" -f $dirTrimmed, $_.Exception.Message)
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
            return [pscustomobject]@{ Items = $items; Source = "jsdelivr"; Error = "" }
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
    param([Parameter(Mandatory = $true)]$Item)

    $size = Format-Size -Bytes ([long]$Item.Size)
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.AppId)) {
        return ("{0}  [{1}]  ({2})" -f $Item.DisplayName, $Item.AppId, $size)
    }
    return ("{0}  ({1})" -f $Item.DisplayName, $size)
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

function Get-SteamAppName {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $url = "https://store.steampowered.com/api/appdetails?appids={0}&cc=cn&l=schinese" -f $AppId
    $request = [System.Net.HttpWebRequest]::Create($url)
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
        $body = $reader.ReadToEnd()
        $json = $body | ConvertFrom-Json
        $node = $json.PSObject.Properties[$AppId]
        if ($null -ne $node -and $node.Value.success) {
            return [string]$node.Value.data.name
        }
        return ""
    } catch {
        return ""
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Add-GameDisplayNames {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][int]$Timeout,
        [switch]$SkipNetwork
    )

    $cache = Read-AppNameCache -PathValue $CachePath
    $changed = $false
    $total = [Math]::Max(1, $Items.Count)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $appId = Get-AppIdFromZipName -Name ([string]$item.Name)
        $item | Add-Member -NotePropertyName AppId -NotePropertyValue $appId -Force

        $display = ""
        if (-not [string]::IsNullOrWhiteSpace($appId) -and $cache.ContainsKey($appId)) { $display = $cache[$appId] }
        if ([string]::IsNullOrWhiteSpace($display) -and -not [string]::IsNullOrWhiteSpace($appId) -and -not $SkipNetwork) {
            Write-Progress -Id 4 -Activity "获取游戏中文名" -Status $appId -PercentComplete ([int]((($i + 1) * 100) / $total))
            $display = Get-SteamAppName -AppId $appId -Timeout $Timeout
            if (-not [string]::IsNullOrWhiteSpace($display)) {
                $cache[$appId] = $display
                $changed = $true
            }
            Start-Sleep -Milliseconds 120
        }
        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = [System.IO.Path]::GetFileNameWithoutExtension([string]$item.Name)
        }
        $item | Add-Member -NotePropertyName DisplayName -NotePropertyValue $display -Force
    }
    Write-Progress -Id 4 -Activity "获取游戏中文名" -Completed
    if ($changed) { Save-AppNameCache -Cache $cache -PathValue $CachePath }
    return @($Items)
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
            Write-Log -Message ("使用本地文件: {0}" -f $url) -Level OK
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
            Write-Log -Message ("下载: {0}" -f $url) -Level INFO
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
            Write-Log -Message ("下载源失败: {0}" -f $_.Exception.Message) -Level WARN
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
    $logDir = Join-Path $dataRoot "logs"
    Ensure-Dir -PathValue $logDir
    $script:LogFile = Join-Path $logDir ("repair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    Write-Host ""
    Write-Host "  STEAMX 清单修复" -ForegroundColor Cyan
    Write-Host "  识别 Steam -> 选择游戏 -> 下载 zip -> 解压覆盖" -ForegroundColor DarkGray
    Write-Host ""

    $steam = Format-PathCase -PathValue (Resolve-SteamPath)
    $luaDir = if ([string]::IsNullOrWhiteSpace($LuaTarget)) { Join-Path $steam "config\lua" } else { $LuaTarget }
    $manifestDir = if ([string]::IsNullOrWhiteSpace($ManifestTarget)) { Join-Path $steam "depotcache" } else { $ManifestTarget }
    $localZipDir = if (-not [string]::IsNullOrWhiteSpace($LocalDir)) { $LocalDir }
                   elseif (-not [string]::IsNullOrWhiteSpace($env:STEAMX_MANIFEST_DIR)) { $env:STEAMX_MANIFEST_DIR }
                   else { Join-Path $projectRoot "manifest" }

    if ($ShowEnv) {
        Write-Rule -Title "环境"
        Write-Field -Label "Steam 路径" -Value $steam -Color "White"
        if ($IncludeLua) { Write-Field -Label "Lua 目录" -Value $luaDir -Color "White" }
        Write-Field -Label "清单目录" -Value $manifestDir -Color "White"
        Write-Field -Label "本地缓存" -Value $localZipDir
        Write-Field -Label "仓库" -Value ("{0}@{1}" -f $Repo, $Branch)
        Write-Field -Label "日志" -Value $script:LogFile
    }

    if (@(Get-Process -Name "steam" -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log -Message "Steam 正在运行,写入可能被占用。建议退出 Steam 后再执行。" -Level WARN
    }

    # 1. 索引
    Write-Rule -Title "游戏列表"
    $index = $null
    if (-not $Offline) {
        Write-Host "  正在获取远端列表..." -ForegroundColor DarkGray
        $index = Get-RemoteZipIndex -AllowFailure
    }
    $items = @()
    $remoteCount = 0
    if ($null -ne $index -and @($index.Items).Count -gt 0) {
        $items = @($index.Items)
        $remoteCount = $items.Count
        Write-Log -Message ("远端列表: {0} 个 zip ({1})" -f $remoteCount, $index.Source) -Level OK
    } elseif ($null -ne $index -and -not [string]::IsNullOrWhiteSpace($index.Error)) {
        Write-Log -Message ("远端不可用: {0}" -f $index.Error) -Level WARN
    }

    # 本地 manifest/ 作为补充:远端没有的包(尚未推送)也能装
    $localItems = @(Get-LocalZipIndex -Directory $localZipDir)
    if ($localItems.Count -gt 0) {
        $remoteNames = @($items | ForEach-Object { $_.Name })
        $extra = @($localItems | Where-Object { $remoteNames -notcontains $_.Name })
        if ($extra.Count -gt 0) {
            $items = @($items) + @($extra)
            Write-Log -Message ("本地补充: {0} 个 zip (未推送到远端)" -f $extra.Count) -Level INFO
        }
    }

    # 远端列表为空时,完全回退本地
    if ($items.Count -eq 0 -and $localItems.Count -gt 0) {
        $items = $localItems
        Write-Log -Message ("回退本地目录: {0} 个 zip" -f $items.Count) -Level WARN
    }
    if ($items.Count -eq 0) {
        throw "没有可用的 zip 包(远端与本地均为空)。"
    }

    # 1.5 游戏中文名(本地缓存 manifest\appnames.json,缺失时查 Steam 商店)
    $cachePath = Join-Path $localZipDir "appnames.json"
    $items = Add-GameDisplayNames -Items $items -CachePath $cachePath -Timeout $TimeoutSeconds -SkipNetwork:$Offline

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
            Write-Log -Message ("关键词命中 {0} 个,请从列表中选择。" -f $matched.Count) -Level INFO
            $menuItems = @(
                foreach ($item in ($matched | Sort-Object DisplayName)) {
                    [pscustomobject]@{ Label = (New-GameLabel -Item $item); Value = $item }
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
                [pscustomobject]@{ Label = (New-GameLabel -Item $item); Value = $item }
            }
        )
        $picked = Read-MenuSelection -Items $menuItems -Title "选择游戏"
        if ($null -eq $picked) { throw "已取消。" }
        $selected = $picked
    }

    Write-Host ""
    Write-Rule -Title "安装"
    Write-Field -Label "游戏" -Value $selected.DisplayName -Color "White"
    Write-Field -Label "目标" -Value $manifestDir -Color "White"
    Write-Field -Label "大小" -Value (Format-Size $selected.Size)
    Write-Field -Label "来源" -Value $selected.Source

    # 3. 下载
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("STEAMX\repair\{0}" -f [Guid]::NewGuid().ToString("N"))
    Ensure-Dir -PathValue $tempRoot
    $zipPath = Join-Path $tempRoot $selected.Name
    try {
        # 本地已有同名包则直接复用
        $localCandidate = Join-Path $localZipDir $selected.Name
        if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
            Write-Log -Message ("本地缓存命中,直接使用: {0}" -f $localCandidate) -Level OK
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
        Write-Log -Message ("已就绪: {0}" -f (Format-Size (Get-Item -LiteralPath $zipPath).Length)) -Level OK

        # 4. 解压覆盖
        $backupDir = ""
        if (-not $NoBackup) {
            $backupDir = Join-Path (Join-Path $dataRoot "backups") ("repair-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        }
        $result = Expand-GameZip -ZipPath $zipPath -LuaDir $luaDir -ManifestDir $manifestDir -BackupDir $backupDir -IncludeLua:$IncludeLua

        Write-Host ""
        Write-Rule -Title "结果"
        Write-Field -Label "新增清单" -Value $result.Added -Color "Green"
        Write-Field -Label "覆盖清单" -Value $result.Overwritten -Color "Yellow"
        if ($result.Skipped -gt 0) {
            Write-Field -Label "跳过" -Value ("{0} 个 .lua(默认不装,用 -IncludeLua 开启)" -f $result.Skipped)
        }
        if (-not [string]::IsNullOrWhiteSpace($backupDir) -and $result.Overwritten -gt 0) {
            Write-Field -Label "备份位置" -Value $backupDir
        }
        Write-Log -Message ("完成: {0}" -f $selected.DisplayName) -Level OK
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Invoke-Repair
} catch {
    Write-Log -Message $_.Exception.Message -Level ERR
    exit 1
}
