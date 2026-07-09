# HubcapTools Wiki 中文文档

> 这份文档是基于你提供的 HubcapTools Wiki 入口整理的中文说明。由于当前站点在未登录状态下会返回 401/登录要求，因此本文档以“Wiki 主题 + 常见使用方式 + API 入口说明”为主，便于你直接阅读和后续二次扩展。

## 1. HubcapTools 是什么

HubcapTools 是一套围绕 Steam 游戏清单、Manifest、Lua 文件和相关资源的获取与管理工具。它的核心用途包括：

- 查询 Steam 游戏的资源状态
- 下载游戏的 Manifest 文件
- 下载 Lua 格式的清单文件
- 查看 API 使用情况和账号状态
- 处理游戏内容更新和资源同步流程

它适合用于：

- Steam 游戏入库
- 游戏资源整理
- 自动化清单生成
- 维护本地游戏资源库

## 2. Wiki 页面要表达的核心内容

你给到的 Wiki 入口，重点并不是单纯的“介绍一个工具”，而是更接近下面这些主题：

1. Hubcap 的使用入口与登录要求
2. 通过 API 获取 Manifest / Lua / 状态信息
3. 使用 API Key 进行授权访问
4. 开发者和自动化脚本如何接入 Hubcap
5. 资源下载、查询、更新与统计的工作流

因此，这份中文文档把它整理成了“面向使用者和开发者”的说明版本。

## 3. 访问前需要注意的事项

如果你直接访问 Wiki 页面，当前环境下会出现登录要求。通常这意味着：

- 需要先在主站完成登录
- 访问 Wiki 需要先通过站点身份验证
- 未登录状态下部分页面内容可能不可见

所以在实际使用时，建议先完成站点登录，再继续阅读 Wiki 或调用接口。

## 4. 常见使用方式

### 4.1 先检查服务状态

```bash
curl https://hubcapmanifest.com/api/v1/health
```

用途：确认 Hubcap 服务是否正常。

### 4.2 查看当前账号使用情况

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" https://hubcapmanifest.com/api/v1/user/stats
```

用途：查看 API 配额、使用量和账户信息。

### 4.3 搜索游戏

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" "https://hubcapmanifest.com/api/v1/search?q=Portal&limit=20"
```

用途：按名称或 App ID 查找目标游戏。

### 4.4 下载 Manifest

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o manifest.zip "https://hubcapmanifest.com/api/v1/manifest/400"
```

用途：下载指定游戏的 Manifest 压缩包。

### 4.5 下载 Lua 文件

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o game.lua "https://hubcapmanifest.com/api/v1/lua/400"
```

用途：下载指定游戏的 Lua 清单文件。

## 5. 常用接口总结

### 健康检查

- 接口：GET /api/v1/health
- 作用：检测服务是否健康

### 用户统计

- 接口：GET /api/v1/user/stats
- 作用：查看 API Key 使用情况

### 搜索游戏

- 接口：GET /api/v1/search
- 作用：按名称或 App ID 查找游戏

### 获取状态

- 接口：GET /api/v1/status/{app_id}
- 作用：查看某个游戏的资源状态

### 下载 Manifest

- 接口：GET /api/v1/manifest/{app_id}
- 作用：下载 Manifest 文件

### 下载 Lua

- 接口：GET /api/v1/lua/{app_id}
- 作用：下载 Lua 清单文件

## 6. 你在 STEAMX 场景下可以怎么理解它

如果你是把它和 STEAMX 一起使用，可以把 Hubcap 看成：

- 一个“资源清单获取器”
- 一个“Steam 游戏内容查询入口”
- 一个“供脚本调用的 Manifest/Lua 数据源”

这对你当前的工作流很有价值，因为你现在正在处理：

- 游戏入库
- 清单生成
- 资源管理
- 自动化脚本流程

## 7. 使用建议

- 先用搜索和状态接口确认资源是否存在，再进行下载。
- 批量请求时要控制频率，避免触发限制。
- 对敏感或大规模抓取任务，尽量遵守站点的使用规则。
- 如果你是做脚本化接入，建议把 API Key 放在环境变量中，而不是直接写死在脚本里。

## 8. 备注

如果你希望，我下一步可以继续把这份文档整理成下面任意一种更实用的版本：

- 更像官方 Wiki 的中文版本
- 更像 API 手册的中文版本
- 更像 STEAMX 集成说明的中文版本
- 直接附带 PowerShell 示例的版本
