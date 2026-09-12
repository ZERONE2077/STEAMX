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

## 0. 三个双击入口

| 文件 | 跑什么 | 日志 | 适用 |
|---|---|---|---|
| `修复下载-本地测试版.lnk` | 直接跑本机的 `DownloadRepair.ps1`（`-File`），带 `-Log -Pause` | **写** `logs\repair-<时间戳>.log` | 自己调试用。本机脚本永远是最新的那一份，跑完留窗能看结果和日志路径 |
| `修复下载-线上正式版.cmd` | `curl` 取 `boot.ps1` → `powershell -File` 运行 → boot 再取最新脚本 → 跑 | 不写 | 对外分发用，**首选**。整条链路里每个进程的命令行都很平淡（`curl.exe ... -o` / `powershell ... -File`），不会撞安全软件 |
| `修复下载-线上正式版.lnk` | `iex` 一条 `irm` 拉 `boot.ps1` 再跑 | 不写 | 同上，图标和悬停文字更好看；代价是命令行里带一条下载 URL —— 这正是 Defender 误判的那种形状（见 0.2），所以只作备用 |

三个都**不带**「以管理员身份运行」标记。之前带过，但那个标记在部分机器上会让快捷方式直接启动失败（双击报 Windows 的「无法访问指定设备、路径或文件」），已改为**脚本按需自动提权**：目标目录不可写且当前不是管理员时，脚本会自己弹 UAC、以管理员身份重开一个窗口接管，本窗口安静退出（`-NoElevate` 可禁用；普通权限能写的机器上不会触发）。

命名口径：**本地测试版** = 只在本机跑、跑的是工作区里正在改的脚本、带日志，改完代码立刻能验；**线上正式版** = 发给别人的那一份，每次启动自己去仓库取最新脚本，拿到什么就是线上发布的那一版。

### 0.1 线上版为什么要多一个 `boot.ps1`

`boot.ps1` 就是原来塞在快捷方式 `Arguments` 里的那段取源逻辑，现在独立成文件。三个入口都指向它：

- `.cmd` 用 `curl.exe -sSL -o "%TEMP%\STEAMX-boot.ps1" <url>` 取下来，再 `powershell -File` 跑它
- `.lnk` 用 `-Command "iex (irm '<url>')"` 取下来直接执行

它做两件事：问 `api.github.com/.../commits/main` 拿 `main` 的最新 sha → 用 `cdn.jsdelivr.net/gh/...@<sha>/...` 取真正的 `DownloadRepair.ps1` → 跑。取源顺序（全部失败才报错并留窗）：

| # | 源 | 备注 |
|---|---|---|
| 1 | `api.github.com/repos/ZERONE2077/STEAMX/commits/main` → jsDelivr `@<sha>` | 推送后 `Age: 0` 立刻可用，国内速度也好；sha 地址永久缓存 |
| 2 | 同一个 API 走 `gh-proxy.com` 转发 | 直连 GitHub 不通时用，实测 0.6 s 返回同一个 sha |
| 3 | `raw.githubusercontent.com/.../main/...` | ≤5 分钟缓存 |
| 4 | `ghfast.top/https://raw.githubusercontent.com/.../main/...` | 国内镜像 |
| 5 | jsDelivr `@latest` | 兜底 |

`boot.ps1` **必须保持纯 ASCII**、不写中文：`.lnk` 那条路径是用 `irm` 拉的，而 jsDelivr 把 `.ps1` 当 `application/octet-stream` 返回，`Invoke-RestMethod` 会按 ISO-8859-1 解码 —— 任何非 ASCII 字节都会变成乱码。中文提示交给它启动的 `DownloadRepair.ps1`。

`.cmd` 本身存成 **GBK**（头部 `chcp 936`），因为 cmd.exe 是按当前控制台代码页逐行解码批处理文件的。

### 0.2 为什么不能把「下载并执行」写在快捷方式的命令行里

**Microsoft Defender 会把这种快捷方式判成木马。** 实测记录（`Get-MpThreatDetection`，路径前缀都是 `CmdLine:`，也就是按命令行内容拦）：

| 时间 | 检测名 | 命令行 |
|---|---|---|
| 2026-09-12 18:20 / 23:42 | `Trojan:Win32/Commando.A!ml` | `powershell -Command irm '<raw.githubusercontent.com>/.../main.ps1' \| iex` |
| 2026-09-13 03:13 | `Trojan:Win32/Commando.A!ml` | 第一版线上快捷方式的长 payload |
| 2026-09-13 03:43 / 04:02 / 05:34 / 06:05 | `Trojan:Win32/ClickFix.DAC!MTB` | 现版线上快捷方式的 1665 字符内联 payload |

命中后 Defender 在**进程创建阶段就拒绝**，ShellExecute 拿不到进程，于是双击弹的是 Windows 的「无法访问指定设备、路径或文件。你可能没有适当的权限访问该项目。」—— 看着像权限问题，其实跟权限无关。

对照实验（同一台机器、同一时间窗，逐个跑一遍再看日志有没有新增检测）：

| 写法 | 结果 |
|---|---|
| `-File "本地脚本"` | ✅ 从不被拦（本地测试版就是这条） |
| `curl -o x.ps1` 然后 `-File x.ps1` | ✅ 不被拦 |
| `iwr ... -OutFile x.ps1; & x.ps1` | ✅ 不被拦 |
| `iex (irm '<cdn.jsdelivr.net>/...')` | ✅ 不被拦（`.lnk` 走的就是这条） |
| 长内联 payload + 真的下载并执行 | 🚫 拦 |
| `iex (irm '<raw.githubusercontent.com>/...')` | 🚫 拦（这个域名的启发式权重很高） |

结论：**逻辑放文件里（走 `-File`）就没事，塞进命令行就会被当成 ClickFix 那类「快捷方式投放器」**。所以线上版的取源逻辑一律留在 `boot.ps1`，`Arguments` 越短越好。

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

jsDelivr（国内最快）。`@latest` 是 jsDelivr 解析的 HEAD，刚推送后可能滞后十几分钟；要绝对最新就把 `@latest` 换成最新 commit 的 sha：

```powershell
$u='https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@latest/DownloadRepair/DownloadRepair.ps1';$r=Invoke-WebRequest -Uri $u -UseBasicParsing;$s=[Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF);& ([scriptblock]::Create($s)) -Game 1091500
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
| `-Pause` | 失败时**一定**停在窗口里等按键（即使输入被重定向） | 自动 |
| `-NoPause` | 失败时**不**停留，直接退出（自动化调用用） | 自动 |
| `-NoElevate` | 目标不可写时**不**自动弹 UAC 提权，直接报权限错误 | 关（默认自动提权） |

失败时是否留窗口是**自动**判断的：输入没被重定向（双击快捷方式、正常开 PowerShell 跑）就留，输入是管道 / 重定向（脚本调用、CI）就不留。两个开关用于强制覆盖。等价环境变量：`STEAMX_NO_PAUSE=1`。

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
- **报「无权写入 / 拒绝访问」**：目标在系统盘（如 `C:\Program Files (x86)\Steam`）且当前账户写不进去。三种常见原因：
    1. 账户是标准用户（非管理员）——没有任何写 `Program Files` 的令牌；
    2. 该机 Steam 目录的 ACL 被重置过（手工搬移过 Steam、从旧机器整目录拷贝、重装系统后直接放回 `Program Files`）。正常由 Steam 安装程序初始化过的机器上，`icacls "C:\Program Files (x86)\Steam\depotcache"` 能看到 `BUILTIN\Users:(I)(F)`，这种机器普通权限就能写；看不到这条就是被继承了 `Program Files` 的只读 ACL；
    3. 安全软件 / 系统策略（AppLocker、WDAC、受控文件夹访问）拦截对 `Program Files` 的写入。
  - 处理：现在**不需要手动右键提权**——脚本检测到目标不可写且当前不是管理员时，会自动弹 UAC、以管理员身份重开一个窗口接管（`-NoElevate` 禁用此行为）。若自动提权被拒（点了「否」），再手动用管理员 PowerShell 跑，或干脆放权一次（等效于 Steam 安装程序做的事）：
    ```powershell
    icacls "C:\Program Files (x86)\Steam" /grant "*S-1-5-32-545:(OI)(CI)M" /T
    ```
    `*S-1-5-32-545` 即 `BUILTIN\Users`（用 SID 可避免中文系统组名匹配问题），`/T` 递归子目录。
  - 脚本动手前会先试写一个探针文件做预检，不可写就直接报 `无权写入 <路径>` 并中止，不会留下半截文件。第 0 节那三个入口都**不带**「以管理员身份运行」标记——那个标记在提权不可用的机器上会让入口本身启动失败（报「无法访问指定设备、路径或文件」），改由脚本按需自动提权。
- 正常运行时日志只打控制台、不写文件；加 `-Log` 才写 `logs\repair-<时间戳>.log`。**失败时例外**：会自动写 `logs\repair-error-<时间戳>.log`（含失败前 200 行日志），见第 7 节。`WARN` / `ERROR` 行始终显示。
- 中文名来自 `manifest\appnames.json`：**默认只读本地名单，菜单立刻出现**，名字缺失的先显示 AppID，选中后会补一次。本地没有名单文件时，会从仓库拉一次 `manifest/appnames.json`。
- 名单条目格式为 `"AppID": "中文名"`，仓库里带的就是纯中文（`-Game` 用中文名或 AppID 都能命中）；如需保留英文搜索，可在本地写成 `"中文名 || 官方原名"`，此时显示只用前半段，关键词两段都能匹配。
- 只有数字命名的 `<AppID>.zip` 才能查到中文名，旧的游戏名 zip 直接显示文件名。
- 远程执行（`irm | iex`、快捷方式双击）时脚本目录不可用，项目根落到 `%LOCALAPPDATA%\STEAMX`（与 `main.ps1` 一致），名单缓存、`logs\`、`backups\` 都落在那；本地包源用 `-LocalDir` 或 `$env:STEAMX_MANIFEST_DIR` 指定。旧版落到 `%TEMP%\STEAMX`，被清理后名单要重新拉一遍。
- 建议先退出 Steam，避免文件占用导致覆盖失败。

## 7. 退出码与错误提示

失败时除了一行 `ERROR`，还会给出 `Reason` / `Try` 引导（加 `-Log` 时附技术细节）：

| 退出码 | 含义 | 典型场景 |
|---|---|---|
| 0 | 成功 | 清单已安装 |
| 1 | 其他失败 | 远端与本地都没有可用包 |
| 2 | 参数/选择无效 | `-Game` 没匹配到；环境无法接收键盘输入 |
| 3 | 环境不满足 | 找不到 Steam（用 `-SteamPath` 指定） |
| 4 | 用户取消 | 菜单按 Esc |
| 5 | 权限不足 | 目标目录不可写，见第 6 节 |
| 6 | 缺少依赖 | 系统组件缺失 |
| 7 | 网络失败 | 所有下载源均失败 |

### 失败不会闪退

双击快捷方式启动的窗口，会在进程退出的瞬间消失，错误信息根本来不及看。所以脚本在退出前会：

1. 打印错误 + `Reason` / `Try`；
2. 把**完整记录**写到 `logs\repair-error-<时间戳>.log`（错误类型、退出码、命令行、系统版本、异常详情，以及**失败前最后 200 行日志**），路径直接显示在屏幕上；
3. 停住等一句 `按 Enter 关闭窗口 ...`。

主动按 Esc 取消（退出码 4）不留窗口 —— 那是你自己要退的。

加过 `-Log` 时，成功结束也会把 `日志文件: <路径>` 打在一行里（成败都回显，否则窗口一关就找不到那个 txt）。

这几个文件会自动生成在项目根（远程双击时为 `%LOCALAPPDATA%\STEAMX`）：

| 路径 | 何时产生 |
|---|---|
| `logs\repair-error-<时间戳>.log` | 任何失败，无需加参数 |
| `logs\repair-<时间戳>.log` | 仅 `-Log` |
| `backups\repair-<时间戳>\` | 覆盖了已有文件时

交互性是增强而非前提：**没有控制台或输入被重定向时，菜单自动降级为「打印列表 + 输入序号」**，不会再抛「无法读取键」这类异常；完全无输入能力时请直接用 `-Game <AppID|关键词>`。
