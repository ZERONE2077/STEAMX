# STEAMX 开发者文档

Windows PowerShell 5.1 脚本：在本地 Steam 目录部署/更新 **OpenSteamTool (OST)** 内核，按 AppID 写入 Lua 清单，并能把 Steam 还原成官方原版。OST 运行时从上游下载并校验 SHA-256，本仓库不打包二进制（许可证见 `NOTICE`）。

**代码就是文档**：具体行为以 `main.ps1` 和其中的注释为准。本文只记录不常变的东西，改功能时不需要同步改这里。

## 运行

双击快捷方式：`STEAMX 本地测试版.lnk`（跑本地 `main.ps1`）、`STEAMX 国内用户版.lnk` / `STEAMX Global.lnk`（经 `boot-main.ps1` 拉取最新版）。

命令行必须带 `-ExecutionPolicy Bypass`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\main.ps1 -Command <命令> [参数]
```

命令：`Start`（默认，交互菜单）、`Check`（只读检查）、`DeployOst`、`EnableUnlockMode`、`AddGame -AppId <AppID 或商店链接>`、`SetManifestSource -ManifestSource <源>`、`UninstallOst`、`UninstallOstAndLua`。完整参数见 `main.ps1` 顶部的 `param()`。

`-ShowLog` 或 `STEAMX_SHOW_LOG=1` 把详细日志打到屏幕上。

## 测试

改完 `main.ps1` 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\parse-check.ps1
pwsh -NoProfile -File tests\ost-extract-policy-test.ps1
pwsh -NoProfile -File tests\ost-latch-test.ps1
pwsh -NoProfile -File tests\ost-loop-regression-test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\ost-residue-cleanup-test.ps1
```

- 测试按函数名从 `main.ps1` 里取出真实函数来跑，所以被测函数不要随便改名。
- `main.ps1` 必须保存为 **UTF-8 带 BOM**，否则 PowerShell 5.1 会把中文读成乱码。

## 设计约束（改代码前先看）

- 网络、下载或校验失败时，不能改动 Steam 目录。部署要么全部成功，要么用备份全部回滚。
- 已有的 `opensteamtool.toml` 只改 manifest `url` 这一个键，其他内容不动。
- 日志、备份、密钥都不能写进 Steam 目录，统一放在 `%TEMP%\STEAMX` 和 `%LOCALAPPDATA%\STEAMX` 下。日志里不能出现密钥。
- 更新判断以发布时间为准，不看版本号（上游的 DLL 不带版本号）。部署成功后会给这个版本打标记，避免每次启动都重复下载。
- 远端查询失败也必须能进主菜单，不能显示成「已是最新」。
- 卸载清理 Lua 时，目标只能是 `<Steam>\config\lua`，并且要先备份。Steam 自带的文件一个都不能动。

## 命名

- 品牌一律写 `STEAMX`。
- 函数用 `Verb-Noun` 格式。参数和属性用 PascalCase，局部变量和配置键用 camelCase。
- `-Command` 的取值直接拼接，比如 `DeployOst`，不加 `-` 或 `_`。
- 上游名字原样照用。

## 目录

```
main.ps1            主脚本
boot-main.ps1       引导：拉取最新 main.ps1 并运行
opensteamtool.toml  OST 配置模板
lua/  manifest/     随附资源
tests/              回归测试
docs/               只在本地：参考资料和归档，不进 git
```

本项目使用 MIT License（`LICENSE`）；OpenSteamTool 使用 GPL-3.0（`NOTICE`）。
