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
| `aos track close -Plan` | JSON（含 `reconciled` / `reclaim`） | 0 |
| `aos session register/heartbeat/close` | JSON | 0 / 1 未绑定任务或 session 不存在 |
| `aos session list` | JSON（`items`: id/role/issue/task/host/ageMin/stale） | 0 |
| `aos audit` | JSON（`summary.subagentMissing` / `policyErrors` / `crossLayerWarnings` / `subagentPolicy`） | 0 / 2 有错账或 policy 无效 |
| `aos room list/show/check/acquire/release` | JSON | 0 / 1 参数或冲突；2 hosts 数据缺失 |
| `aos plan resources` | JSON（每任务 host / gpus / gpu_ids / free / env / status） | 0 / 2 GPU 不足或 host 容量未知 |
| `aos artifact path/list` | JSON（固定根 / 目录 / 文件计数） | 0 / 1 非法名称或参数 |
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

## close 的 reclaim

`track close -Plan` 返回：

```json
{
  "reconciled": [ { "task": "T2", "from": "running", "to": "done", "source": "ledger" } ],
  "reclaim": {
    "mode": "read-only",
    "destructiveApplied": false,
    "audit": { "ok": true, "errors": 0, "subagentMissing": 0, "inFlight": 0 },
    "worktrees": { "dryRun": true, "candidates": 0, "dirty": 0, "paths": [] },
    "hygiene": { "dryRun": true, "leaked": 0, "attention": [] }
  },
  "attention": []
}
```

`reclaim` 永远是只读：不会自动 `wt prune -Apply`，也不会自动 `hygiene -Reap`。

## agent 推荐用法

```powershell
# 1. 先拿全量上下文
$s = aos snapshot -Repo <path> | ConvertFrom-Json

# 2. 有阻塞先处理
if ($s.attention.Count -gt 0) { $s.attention }

# 3. 按 schedule.Waves 派发，一个 wave 一批 subagent
# 4. 每个 write 节点：wt new -> track start -Plan -Subagent -> track close -Plan
# 5. 读 close 返回的 reclaim；安全候选才手动 wt prune -Apply
```

## subagent policy

见 [data-model.md](data-model.md) 的 subagent policy（append-only）权威段。

## policy / reclaim fields

- `subagentPolicy`: mode, since, source, authorizedBy, fileStatus, fileSince, error
- `summary.subagentWaived`, `summary.policyErrors`, `summary.subagentMissing`
- `reclaim.audit.invoked`, `reclaim.worktrees.invoked/dryRun/candidates/dirty`, `reclaim.hygiene.invoked/dryRun/leaked`
- `attention`: audit.ok=false, staleInFlight, dirty, safe candidates, wt/hygiene failure, crossLayerErrors
- `-SkipReclaim`: test/batch only; destructive -Apply/-Reap never automatic.
