# Hubcap API 中文文档

基于官方网页文档整理，来源页面：

- `https://hubcapmanifest.com/api-keys/stats`
- 文档页签：`Documentation`

整理时间：`2026-07-03`

## 说明

- 认证方式：大多数接口需要请求头 `Authorization: Bearer YOUR_API_KEY`
- 官方警告：不要抓取整站数据，否则可能被永久封禁
- 免费接口通常不计入下载配额；下载 Lua、Manifest、生成类接口会消耗额度

## 通用请求头

```bash
Authorization: Bearer YOUR_API_KEY
```

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" "https://hubcapmanifest.com/api/v1/..."
```

## General

### `GET /api/v1/health`

用途：

- 检查 API 系统健康状态
- 返回 Redis、数据库、Manifest 存储等组件状态
- 状态可能为 `healthy` 或 `degraded`

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl https://hubcapmanifest.com/api/v1/health
```

### `GET /api/v1/user/stats`

用途：

- 查询当前 API key 的使用情况
- 查看每日限制和账户相关信息

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" https://hubcapmanifest.com/api/v1/user/stats
```

## Library

### `GET /api/v1/library`

用途：

- 浏览游戏库
- 支持分页、搜索、排序

查询参数：

- `limit`：整数，默认 `100`
- `offset`：整数，默认 `0`
- `search`：字符串，匹配 `game_name` 或 `game_id`
- `sort_by`：`updated` 或 `name`，默认 `updated`

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" "https://hubcapmanifest.com/api/v1/library?limit=50&offset=0&search=portal"
```

### `GET /api/v1/status/{app_id}`

用途：

- 检查某个游戏的 manifest 是否存在
- 不下载文件，只返回状态和文件信息
- 可用于判断文件大小、修改时间、是否正在更新、是否需要更新

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" https://hubcapmanifest.com/api/v1/status/400
```

### `GET /api/v1/search`

用途：

- 按游戏名或 App ID 搜索游戏

查询参数：

- `q`：必填，最少 3 个字符
- `limit`：整数，范围 `1-100`，默认 `50`
- `appid`：布尔值，默认 `false`
  - `true` 时按精确 `game_id` 匹配
  - `false` 时按名称匹配

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" "https://hubcapmanifest.com/api/v1/search?q=Portal&limit=20"
```

## Manifest

### `GET /api/v1/manifest/{app_id}`

用途：

- 下载游戏的 Manifest ZIP 文件
- 官方说明这是 V1 接口

查询参数：

- `force_update`：布尔值，默认 `false`
  - 为 `true` 时，先触发刷新再返回结果
- `content`：可选字符串
  - 用于指定替代内容选择器

返回：

- `zip` 压缩包

是否计费：

- 计入每日使用额度

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o manifest.zip "https://hubcapmanifest.com/api/v1/manifest/400"
```

## Lua Files

### `GET /api/v1/lua/{app_id}`

用途：

- 下载完整 Lua manifest
- 包含全部分段

返回：

- `.lua` 文件

是否计费：

- 计入每日使用额度

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o game.lua "https://hubcapmanifest.com/api/v1/lua/400"
```

### `GET /api/v1/lua/basegame/{app_id}`

用途：

- 仅下载本体部分的 Lua manifest
- 不包含 DLC

返回：

- `.lua` 文件

是否计费：

- 计入每日使用额度

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o basegame.lua "https://hubcapmanifest.com/api/v1/lua/basegame/400"
```

### `GET /api/v1/lua/dlc/{app_id}`

用途：

- 仅下载 DLC 部分的 Lua manifest

返回：

- `.lua` 文件

是否计费：

- 计入每日使用额度

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o dlc.lua "https://hubcapmanifest.com/api/v1/lua/dlc/400"
```

## Depot Keys

### `GET /api/v1/depot-keys`

用途：

- 返回可用 depot ID 列表
- 包含已有 keys 文件中的 ID
- 也包含尚未合并的待上传 ID
- 只返回 ID，不返回真实 key

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" https://hubcapmanifest.com/api/v1/depot-keys
```

## Generation

### `GET /api/v1/generate/manifest`

用途：

- 直接从 Steam 生成单个 depot 的 manifest

查询参数：

- `depot_id`：整数，必填
- `manifest_id`：整数，必填
  - 即 Steam manifest GID

返回：

- 二进制 `.manifest` 文件

是否计费：

- 计入 generation 配额

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o out.manifest "https://hubcapmanifest.com/api/v1/generate/manifest?depot_id=401&manifest_id=1234567890123456789"
```

### `GET /api/v1/generate/appmanifest/{app_id}`

用途：

- 为某个游戏生成完整 app manifest bundle
- 包含该游戏全部 depots

查询参数：

- `branch`：字符串，默认 `public`

返回：

- `bundle.zip`

是否计费：

- 计入 generation 配额

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o bundle.zip "https://hubcapmanifest.com/api/v1/generate/appmanifest/400?branch=public"
```

### `GET /api/v1/generate/workshopmanifest/{workshop_id}`

用途：

- 生成 workshop item manifest

返回：

- 二进制 `.manifest` 文件

是否计费：

- 计入 generation 配额

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" -o out.manifest "https://hubcapmanifest.com/api/v1/generate/workshopmanifest/123456"
```

### `GET /api/v1/generate/usage`

用途：

- 查看 generation 使用情况
- 查看 single、bundle、workshop 剩余额度
- 也会返回 Steam 侧生成服务是否可用

是否计费：

- 免费
- 不计入使用次数

示例：

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" https://hubcapmanifest.com/api/v1/generate/usage
```

## 快速索引

### 免费接口

- `/api/v1/health`
- `/api/v1/user/stats`
- `/api/v1/library`
- `/api/v1/status/{app_id}`
- `/api/v1/search`
- `/api/v1/depot-keys`
- `/api/v1/generate/usage`

### 会消耗下载额度的接口

- `/api/v1/manifest/{app_id}`
- `/api/v1/lua/{app_id}`
- `/api/v1/lua/basegame/{app_id}`
- `/api/v1/lua/dlc/{app_id}`

### 会消耗 generation 配额的接口

- `/api/v1/generate/manifest`
- `/api/v1/generate/appmanifest/{app_id}`
- `/api/v1/generate/workshopmanifest/{workshop_id}`

## 备注

- 这份文档是根据官方网页文档整理成中文的本地版
- 如果官网后续增删接口，这份本地文档需要重新同步
