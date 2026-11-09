# STEAMX 使用指南

不用下载任何文件，联网复制一行命令就能用。开发者请看 [README-开发者.md](README-开发者.md)。

## 1. 启动

1. 按 Win 键，输入 `powershell`，右键「Windows PowerShell」→ **以管理员身份运行**。
2. 粘贴下面这一行，回车：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://gh-proxy.com/https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/boot-main.ps1')"
```

卡住时把命令里的 `gh-proxy.com` 换成 `hk.gh-proxy.com`、`ghfast.top` 或 `ghproxy.net` 再试。

## 2. 使用

第一次运行会自动安装内核，期间会自动关闭再重开 Steam。之后进入主菜单：

| 输入 | 作用 |
|---|---|
| 游戏 AppID 或 Steam 商店链接 | 入库游戏，不用重启 Steam |
| `1` | 部署 / 修复内核（游戏打不开时先试这个） |
| `0` | 卸载，还原官方 Steam |
| `?` | 帮助 |

第一次入库会要求输入密钥，只需输入一次。用完直接关窗口即可。

## 3. 常见问题

- **提示「未对文件进行数字签名」**：命令没复制完整，少了 `-ExecutionPolicy Bypass`。
- **提示「拒绝访问」**：没用管理员身份打开，窗口标题应显示「管理员：Windows PowerShell」。
- **提示「密钥已到期」**：联系 GM 获取最新密钥，按提示粘贴即可。
- **提示「清单库里没有」**：试玩版、未发售、已下架的游戏不收录，换正式版的商店链接。
- **下载卡住**：换上面另一个加速地址，或换代理节点。
