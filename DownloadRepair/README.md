# DownloadRepair 使用文档

单游戏清单修复工具：识别 Steam 路径 → 选择游戏 → 下载 zip → 解压覆盖。

- 脚本：`DownloadRepair.ps1`（UTF-8 with BOM，Windows PowerShell 5.1 可直接运行）
- 默认只解压 `.manifest` → `<Steam>\depotcache`，`.lua` 跳过（加 `-IncludeLua` 才写 `<Steam>\config\lua`）
- 菜单显示 Steam 中文名，名单缓存 `manifest\appnames.json`；**默认只读缓存，不联网加载**，缺失的先显示 AppID（`-RefreshNames` 才联网补全）
- 本地包源：项目根 `manifest\`，文件名为 `<AppID>.zip`
- 远端包源：`ZERONE2077/STEAMX`，依次尝试 `manifest/`、`Lua/` 目录；GitHub API 直连失败时自动走 `gh-proxy.com` 镜像，再退 jsDelivr 索引
- 输出为 CLI 日志风格：`HH:mm:ss INFO  scope  message`（scope: `repair` / `steam` / `net` / `names` / `install`）
- 默认不写日志文件；加 `-Log` 才落 `logs\repair-<时间戳>.log`（DEBUG 行也只在这时出现）

---

## 1. 本地运行（复制整行 → 粘贴到 PowerShell → 回车）

打开菜单：

```powershell
& "D:\Dev\STEAMX\DownloadRepair\DownloadRepair.ps1"
```

带 AppID（跳过菜单，1091500 = Cyberpunk 2077）：

```powershell
& "D:\Dev\STEAMX\DownloadRepair\DownloadRepair.ps1" -Game 1091500
```

---

## 2. 一键运行（复制整行 → 粘贴到 PowerShell → 回车）

> 推荐用**内存执行**版本：不落盘、不写临时文件，因此**不受 ExecutionPolicy 限制**（默认 Restricted 的机器也能直接跑）。
>
> 必须显式按 UTF-8 解码：jsDelivr / raw 返回 `application/octet-stream`，PS 5.1 的 `irm` 会按 ISO-8859-1 解码，脚本里的中文会变成乱码（`æ«æ`），进而导致中文比较、菜单文案错乱。

jsDelivr（国内最快）：

```powershell
$u='https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@main/DownloadRepair/DownloadRepair.ps1';$r=Invoke-WebRequest -Uri $u -UseBasicParsing;$s=[Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF);& ([scriptblock]::Create($s)) -Game 1091500
```

GitHub raw：

```powershell
$u='https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/DownloadRepair.ps1';$r=Invoke-WebRequest -Uri $u -UseBasicParsing;$s=[Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF);& ([scriptblock]::Create($s)) -Game 1091500
```

ghfast 镜像（raw / jsDelivr 都不通时用）：

```powershell
$u='https://ghfast.top/https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/DownloadRepair.ps1';$r=Invoke-WebRequest -Uri $u -UseBasicParsing;$s=[Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF);& ([scriptblock]::Create($s)) -Game 1091500
```

不带 `-Game` 就是菜单模式，把末尾的 ` -Game 1091500` 删掉即可。

### 2.1 落盘执行（执行策略会拦）

下面这种写法会先存成文件再运行，在默认策略下会报
`无法加载文件 ... 因为在此系统上禁止运行脚本`（`UnauthorizedAccess`）：

```powershell
irm -Uri 'https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@main/DownloadRepair/DownloadRepair.ps1' -OutFile "$env:TEMP\DownloadRepair.ps1"; & "$env:TEMP\DownloadRepair.ps1" -Game 1091500
```

要用这种写法，把当前会话的策略放开即可（只影响当前窗口，关掉就恢复，不写注册表）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; irm -Uri 'https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@main/DownloadRepair/DownloadRepair.ps1' -OutFile "$env:TEMP\DownloadRepair.ps1"; & "$env:TEMP\DownloadRepair.ps1" -Game 1091500
```

> 不想改策略就用第 2 节的内存执行版本，效果完全一样。


## 4. 参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-Game` | AppID / 中文名 / 关键词，唯一命中直接安装，多个命中仍出菜单 | 无（出菜单） |
| `-Offline` | 不联网，只用本地 `manifest\`（中文名取缓存） | 关 |
| `-NoBackup` | 覆盖已有文件时不备份 | 关（默认备份） |
| `-RefreshNames` | 逐个联网补全缺失的中文名并写回 `appnames.json` | 关（默认只读缓存，菜单秒开） |
| `-Log` | 写 `logs\repair-<时间戳>.log`，并显示 DEBUG 行（`names` 的逐条结果） | 关（不写文件） |
| `-ShowEnv` | 显示本地包源、仓库、日志路径 | 关（默认不显示） |
| `-IncludeLua` | 连同 `.lua` 一起解压到 `<Steam>\config\lua` | 关（只装 manifest） |
| `-LuaTarget` | `.lua` 解压目录（配合 `-IncludeLua`） | `<Steam>\config\lua` |
| `-LocalDir` | 本地 zip 目录 | `<项目根>\manifest` 或 `$env:STEAMX_MANIFEST_DIR` |
| `-Repo` | 远端仓库 | `ZERONE2077/STEAMX` |
| `-Branch` | 分支 | `main` |
| `-RemoteDir` | 远端目录，按顺序尝试 | `manifest`, `Lua` |
| `-SteamPath` | Steam 安装目录（含 steam.exe） | 自动识别 |
| `-LuaTarget` | `.lua` 解压目录 | `<Steam>\config\lua` |
| `-ManifestTarget` | `.manifest` 解压目录 | `<Steam>\depotcache` |
| `-TimeoutSeconds` | 单次网络超时 | `30` |

Steam 路径识别顺序：参数 → `$env:STEAM_PATH` → steam 进程 → 注册表 → 各盘常见路径 → 手动输入。

---

## 5. 常用组合

每条都是完整命令，直接粘贴执行（`$dr` 只是缩短长度的别名）：

```powershell
$dr="D:\Dev\STEAMX\DownloadRepair\DownloadRepair.ps1"

# 只从本地 manifest\ 安装（不联网，最快）
& $dr -Game 1091500 -Offline

# 菜单模式，手动挑游戏（显示中文名）
& $dr

# 用中文名直接安装
& $dr -Game 黑神话

# 覆盖时不留备份
& $dr -Game 1091500 -NoBackup

# 连同 .lua 一起装
& $dr -Game 1091500 -IncludeLua

# 想看 Steam 路径和目标目录时
& $dr -Game 1091500 -ShowEnv

# 需要排查问题时输出日志文件（控制台 + logs\repair-<时间戳>.log）
& $dr -Game 1091500 -Log

# 新加了包、菜单里显示的还是 AppID 时：联网补全中文名
& $dr -RefreshNames

# 指定别的 zip 目录
& $dr -Game 1091500 -LocalDir D:\Packs

# 指定 Steam 位置和两个目标目录
& $dr -SteamPath D:\Steam -LuaTarget D:\Steam\config\lua -ManifestTarget D:\Steam\depotcache

# 换仓库 / 分支 / 远端目录
& $dr -Repo user/repo -Branch dev -RemoteDir manifest
```

---

## 6. 注意

- 覆盖已有文件时，原文件会备份到 `backups\repair-<时间戳>\`（`-NoBackup` 关闭）。
- `无法加载文件 ... 因为在此系统上禁止运行脚本`：这是 ExecutionPolicy 拦的，用第 2 节的**内存执行**版本即可绕过，或 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`。
- Steam 装在 `C:\Program Files (x86)\Steam` 时写入 `depotcache` 需要管理员权限；右键「以管理员身份运行」打开 PowerShell 再执行。
- 日志默认只在控制台输出，不写文件；加 `-Log` 才写 `logs\repair-<时间戳>.log`。`WARN` / `ERROR` 行始终显示。
- 中文名来自 `manifest\appnames.json`：**默认只读本地名单，菜单立刻出现**，名字缺失的先显示 AppID，选中后会补一次。本地没有名单文件时，会从仓库拉一次 `manifest/appnames.json`。
- 名单条目格式为 `"AppID": "中文名"`，仓库里带的就是纯中文（`-Game` 用中文名或 AppID 都能命中）；如需保留英文搜索，可在本地写成 `"中文名 || 官方原名"`，此时显示只用前半段，关键词两段都能匹配。
- 只有数字命名的 `<AppID>.zip` 才能查到中文名，旧的游戏名 zip 直接显示文件名。
- 通过 `irm | iex` 运行时找不到项目根，日志和备份会落到 `%TEMP%\STEAMX\`，本地包源用 `-LocalDir` 或 `$env:STEAMX_MANIFEST_DIR` 指定。
- 建议先退出 Steam，避免文件占用导致覆盖失败。
