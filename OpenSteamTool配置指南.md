# OpenSteamTool 配置指南

## 概述

本文档详细说明 OpenSteamTool 的配置文件 `opensteamtool.toml` 的各项设置。配置文件需要放置在 Steam 根目录下，系统启动时会自动加载，文件修改后会热重载。

---

## 目录
1. [日志配置](#日志配置)
2. [清单配置](#清单配置)
3. [统计配置](#统计配置)
4. [Lua 脚本配置](#lua-脚本配置)
5. [游戏注入配置](#游戏注入配置)
6. [云存档配置](#云存档配置)
7. [远程元数据配置](#远程元数据配置)

---

## 日志配置

### [log] 部分

```toml
[log]
level = "debug"
```

**说明：**
- 设置日志级别（仅 Debug 构建版本有效）
- **可选值：** `trace`、`debug`、`info`、`warn`、`error`
- **推荐设置：**
  - `trace` - 最详细，用于深度调试
  - `debug` - 调试信息，开发环境推荐
  - `info` - 一般信息，生产环境推荐
  - `warn` - 仅警告信息
  - `error` - 仅错误信息

---

## 清单配置

### [manifest] 部分

```toml
[manifest]
url = "opensteamtool"
timeout_resolve_ms = 5000
timeout_connect_ms = 5000
timeout_send_ms    = 10000
timeout_recv_ms    = 10000
```

### URL 源选择

**url 参数的选项：**

| 选项 | API 地址 | 说明 |
|------|---------|------|
| `"opensteamtool"` | https://manifest.opensteamtool.com/{gid} | 默认源 |
| `"wudrm"` | http://gmrc.wudrm.com/manifest/{gid} | **推荐中国用户使用** |
| `"steamrun"` | https://manifest.steam.run/api/manifest/{gid} | 官方 Steam 源 |

### 超时设置

| 参数 | 含义 | 默认值 | 说明 |
|------|------|--------|------|
| `timeout_resolve_ms` | DNS 解析超时 | 5000ms | 域名转换为 IP 地址的时间 |
| `timeout_connect_ms` | TCP 连接超时 | 5000ms | 建立网络连接的时间 |
| `timeout_send_ms` | 请求发送超时 | 10000ms | 发送请求数据的时间 |
| `timeout_recv_ms` | 响应接收超时 | 10000ms | 接收响应数据的时间 |

### Lua 脚本自定义

如果 `<Steam>/config/lua/manifest.lua` 中定义了以下函数，这些 Lua 函数将优先于上述 URL 设置：

**函数原型：**

```lua
-- 基础版本
function fetch_manifest_code(gid)
    -- 返回清单代码字符串
end

-- 扩展版本（推荐）
function fetch_manifest_code_ex(app_id, depot_id, gid)
    -- 使用 app_id 和 depot_id 获取更精准的清单代码
end
```

**可用的 Lua 网络函数：**

```lua
-- HTTP GET 请求
local body, status_code = http_get(url [, headers])

-- HTTP POST 请求
local body, status_code = http_post(url, body [, headers])
```

**示例 - 多源备选：**

```lua
function fetch_manifest_code(gid)
    -- 首先尝试 wudrm（返回纯文本数字）
    local body, st = http_get("http://gmrc.wudrm.com/manifest/" .. gid)
    if st == 200 and body then 
        return body 
    end
    
    -- 备选方案：使用 steamrun（返回 JSON）
    body, st = http_get("https://manifest.steam.run/api/manifest/" .. gid)
    if st == 200 and body then
        local code = body:match('"content":"(%d+)"')
        if code then 
            return code 
        end
    end
    
    return nil
end
```

**注意：** 返回值必须是字符串格式的数字，以避免双精度浮点数损失（> 2^53）。

---

## 统计配置

### [stats] 部分

```toml
[stats]
enable_api = true
```

**说明：**
- 当未通过 Lua 脚本设置 SteamID 时，自动查询 https://stats.opensteamtool.com/{appid} 获取推荐的 SteamID
- `enable_api = true` - 启用统计 API
- `enable_api = false` - 禁用统计 API

**优先级：**
1. **最高** - Lua 脚本中的 `setStat(appid, "steamid")` 设置
2. **中等** - 统计 API（当启用且返回有效值时）
3. **最低** - 内置预设的 SteamID

---

## Lua 脚本配置

### [lua] 部分

```toml
[lua]
paths = []
```

**说明：**
- 指定额外的 Lua 配置目录
- 文件会在默认的 `<Steam>/config/lua` 文件夹之后加载
- 默认文件夹总是最后加载，确保用户文件具有最高优先级

**示例 - 加载其他驱动器上的自定义目录：**

```toml
[lua]
paths = ["D:/my-steam-config/lua"]
```

**多个目录：**

```toml
[lua]
paths = [
    "D:/my-steam-config/lua",
    "E:/backup-configs/lua"
]
```

---

## 游戏注入配置

### [inject] 部分

```toml
[inject]
enabled = false
# library_x64 = "OpenSteamTool.GameHook.x64.dll"
# library_x86 = "OpenSteamTool.GameHook.x86.dll"
```

**说明：**
- 可选功能，用于向游戏进程注入库
- 注入的库必须与目标进程的架构匹配（x64 或 x86）

**配置步骤：**

1. 设置 `enabled = true` 启用注入功能
2. 指定对应架构的 DLL 文件路径：
   - `library_x64` - 64 位游戏使用
   - `library_x86` - 32 位游戏使用

**示例：**

```toml
[inject]
enabled = true
library_x64 = "OpenSteamTool.GameHook.x64.dll"
library_x86 = "OpenSteamTool.GameHook.x86.dll"
```

---

## 云存档配置

### [cloud] 部分

```toml
[cloud]
enabled = false
# library = "cloud_redirect.dll"
```

**功能说明：**
- 为解锁的游戏（通过 Lua 脚本加载的游戏）提供 Steam 云存档重定向
- 由 CloudRedirect 提供支持：https://github.com/Selectively11/CloudRedirect

**工作原理：**
1. OpenSteamTool 在 Steam 内部加载 `cloud_redirect.dll`
2. 将每个通过 `addappid()` 添加的游戏注册为重定向应用
3. 将这些游戏的 Steam Cloud RPC 路由到 CloudRedirect 的云存档引擎

**配置步骤：**

1. 启用功能：`enabled = true`
2. 指定 DLL 路径（可选）：
   - 绝对路径：`library = "C:/full/path/cloud_redirect.dll"`
   - 相对路径（相对于 Steam 根目录）：`library = "cloud_redirect.dll"`
   - 默认位置：`<Steam>/cloud_redirect.dll`（未指定时使用）

**示例：**

```toml
[cloud]
enabled = true
library = "cloud_redirect.dll"
```

**提供商登录：**
- 用户仍需通过 CloudRedirect 的伴随应用进行登录
- 支持的云存储服务：Google Drive、OneDrive、本地文件夹
- OpenSteamTool 仅负责在 Steam 内部托管 DLL

---

## 远程元数据配置

### [remote] 部分

```toml
[remote]
# url_template = "https://your.server/{channel}/{component}/{sha256}.toml"
# url_template = "https://fast.jsdelivr.net/gh/OpenSteam001/steam-monitor@{channel}/{component}/{sha256}.toml"
```

**说明：**
- 可选功能，用于配置自定义元数据镜像源
- 不设置此项时，使用 GitHub 源，备选方案为 jsDelivr CDN

**URL 模板占位符：**

| 占位符 | 说明 |
|-------|------|
| `{channel}` | 更新通道（如 stable、beta 等） |
| `{component}` | 组件名称 |
| `{sha256}` | 文件的 SHA256 校验和 |

**示例 - 使用国内 CDN 加速：**

```toml
[remote]
url_template = "https://fast.jsdelivr.net/gh/OpenSteam001/steam-monitor@{channel}/{component}/{sha256}.toml"
```

**示例 - 使用自己的服务器：**

```toml
[remote]
url_template = "https://mirrors.example.com/{channel}/{component}/{sha256}.toml"
```

---

## 快速参考

### 中国用户推荐配置

```toml
[log]
level = "info"

[manifest]
url = "wudrm"
timeout_resolve_ms = 5000
timeout_connect_ms = 5000
timeout_send_ms    = 10000
timeout_recv_ms    = 10000

[stats]
enable_api = true

[lua]
paths = []

[inject]
enabled = false

[cloud]
enabled = false

[remote]
# 使用 jsDelivr CDN 加速
url_template = "https://fast.jsdelivr.net/gh/OpenSteam001/steam-monitor@{channel}/{component}/{sha256}.toml"
```

### 高级用户配置（支持云存档）

```toml
[inject]
enabled = true
library_x64 = "OpenSteamTool.GameHook.x64.dll"
library_x86 = "OpenSteamTool.GameHook.x86.dll"

[cloud]
enabled = true
library = "cloud_redirect.dll"
```

---

## 常见问题

**Q: 修改配置后需要重启 Steam 吗？**
A: 不需要。配置文件支持热重载，修改后自动生效。

**Q: 中国用户应该选择哪个清单源？**
A: 推荐使用 `"wudrm"` 源，它针对中国用户网络环境优化。

**Q: 如何自定义清单代码获取逻辑？**
A: 在 `<Steam>/config/lua/manifest.lua` 中编写 `fetch_manifest_code()` 或 `fetch_manifest_code_ex()` 函数。

**Q: 云存档功能是否必需？**
A: 不是必需的。仅当需要为解锁的游戏同步云存档时才启用。

**Q: 注入库会影响游戏运行吗？**
A: 注入库可能影响某些反作弊系统。如遇问题，请禁用此功能。

---

## 文件位置汇总

| 文件/文件夹 | 位置 | 用途 |
|-----------|------|------|
| opensteamtool.toml | `<Steam>` 根目录 | 主配置文件 |
| manifest.lua | `<Steam>/config/lua` | 自定义清单获取逻辑 |
| cloud_redirect.dll | `<Steam>` 根目录 | 云存档重定向库 |
| GameHook DLL | 任意位置 | 游戏注入库 |

---

*文档最后更新：2026年7月*
