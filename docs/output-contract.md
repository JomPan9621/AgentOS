# 输出契约速查

**默认即 JSON。** 人类可读渲染走 `-Human`，是可选能力。

| 命令 | 默认输出 | 退出码 |
|---|---|---|
| `aos snapshot` | 单个 JSON | 0 / 2 需治理 |
| `aos plan new` | JSON | 0 / 1 已存在 |
| `aos plan validate` | JSON | 0 / 1 非法 |
| `aos plan graph` | JSON | 0 / 1 有环 |
| `aos plan next` | JSON | 0 |
| `aos plan show` | JSON | 0 |
| `aos plan state` | JSON | 0 / 1 无此任务 |
| `aos wt list` | JSON | 0 |
| `aos wt status` | JSON | 0 / 2 超限 |
| `aos wt new` | JSON | 0 / 1 冲突或超限 |
| `aos wt prune` | JSON（dryRun=true） | 0 |
| `aos issue detect` | JSON | 0 |
| `aos issue new/show/list` | JSON | 0 / 1 |
| `aos track start/review/close` | JSON | 0 |
| `aos track claim` | JSON | 0 / 1 被拒（他人持有且未超时） |
| `aos track release` | JSON | 0 / 1 非本人持有 |
| `aos track handoff` | JSON | 0 / 1 当前 owner 不匹配 |
| `aos track who` | JSON（谁在做什么、可接管性） | 0 |
| `aos track list/lost` | JSON | 0 |

## 通用形状

成功：```json
{ "ok": true, "...": "..." }
```

失败：```json
{ "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
```

## 人类模式

```powershell
aos plan graph -Plan x.md -Human     # 出 mermaid + 表格
aos wt status  -Repo <path> -Human   # 出表格
```

## agent 推荐用法

```powershell
# 1. 先拿全量上下文
$s = aos snapshot -Repo <path> | ConvertFrom-Json

# 2. 有阻塞先处理
if ($s.attention.Count -gt 0) { $s.attention }

# 3. 按 schedule.Waves 派发，一个 wave 一批 subagent
# 4. 每个 write 节点：wt new -> track start -> track close
# 5. wt prune 回收槽位
```
