# DownloadRepair 使用文档

单游戏清单修复工具：识别 Steam 路径 → 选择游戏 → 下载 zip → 解压覆盖。

- 脚本：`DownloadRepair.ps1`（UTF-8 with BOM，Windows PowerShell 5.1 可直接运行）
- 默认只解压 `.manifest` → `<Steam>\depotcache`，`.lua` 跳过（加 `-IncludeLua` 才写 `<Steam>\config\lua`）
- 菜单显示 Steam 中文名，缓存文件 `manifest\appnames.json`，缺失时自动查 Steam 商店接口
- 本地包源：项目根 `manifest\`，文件名为 `<AppID>.zip`
- 远端包源：`ZERONE2077/STEAMX`，依次尝试 `manifest/`、`Lua/` 目录，GitHub API 不通时自动切 jsDelivr

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

## 2. 从 GitHub 一键运行

> 前提：`DownloadRepair\` 已提交到 `ZERONE2077/STEAMX` 的 `main` 分支。

下载后执行（中文不乱码，推荐）：

```powershell
irm -Uri 'https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/DownloadRepair.ps1' -OutFile "$env:TEMP\DownloadRepair.ps1"; & "$env:TEMP\DownloadRepair.ps1" -Game 1091500
```

不落盘、内存中执行：

```powershell
$s=((irm -Uri 'https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/DownloadRepair.ps1') -join "`n") -replace '^\uFEFF',''; & ([scriptblock]::Create($s)) -Game 1091500
```

---

## 3. 从 jsDelivr 一键运行（国内更快）

下载后执行：

```powershell
irm -Uri 'https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@main/DownloadRepair/DownloadRepair.ps1' -OutFile "$env:TEMP\DownloadRepair.ps1"; & "$env:TEMP\DownloadRepair.ps1" -Game 1091500
```

不落盘、内存中执行：

```powershell
$s=((irm -Uri 'https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@main/DownloadRepair/DownloadRepair.ps1') -join "`n") -replace '^\uFEFF',''; & ([scriptblock]::Create($s)) -Game 1091500
```

ghfast 镜像（raw 被墙时用）：

```powershell
irm -Uri 'https://ghfast.top/https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/DownloadRepair.ps1' -OutFile "$env:TEMP\DownloadRepair.ps1"; & "$env:TEMP\DownloadRepair.ps1" -Game 1091500
```

不带 `-Game` 就是菜单模式，把末尾的 ` -Game 1091500` 删掉即可。

---

## 4. 参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `-Game` | AppID / 中文名 / 关键词，唯一命中直接安装，多个命中仍出菜单 | 无（出菜单） |
| `-Offline` | 不联网，只用本地 `manifest\`（中文名取缓存） | 关 |
| `-NoBackup` | 覆盖已有文件时不备份 | 关（默认备份） |
| `-ShowEnv` | 显示 Steam 路径、目标目录、仓库等环境信息 | 关（默认不显示） |
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
- 运行日志写入 `logs\repair-<时间戳>.log`。
- 中文名来自 `manifest\appnames.json` 缓存；首次运行会联网查 Steam 商店（每个 AppID 一次，约 0.15 秒），之后直接读缓存。离线（`-Offline`）只显示缓存里有的名字，其余显示 AppID。
- 只有数字命名的 `<AppID>.zip` 才能查到中文名，旧的游戏名 zip 直接显示文件名。
- 通过 `irm | iex` 运行时找不到项目根，日志和备份会落到 `%TEMP%\STEAMX\`，本地包源用 `-LocalDir` 或 `$env:STEAMX_MANIFEST_DIR` 指定。
- 建议先退出 Steam，避免文件占用导致覆盖失败。
- `manifest\` 未推送到远端前，远端命令只能拉到 `Lua\` 下的 7 个旧名包。
