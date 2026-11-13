# 任务生命周期

## 状态机

```
planned ──派发──▸ running ──交付──▸ review ──验收──▸ done
   │                  │                 │
   │                  └───卡住──▸ blocked
   └──放弃──────────────────────────────▸ abandoned
```

| 状态 | 含义 | 迁移命令 |
|---|---|---|
| `planned` | 已进 PLAN，尚未派发 | 初始态 |
| `ready` | 依赖已满足，可派发 | `aos plan next` 算出来 |
| `running` | 已派发给某个 worker | `aos track start -Task T1 -Owner codex -Plan <file> -Subagent <label>` |
| `review` | worker 交付，等待验收 | `aos track review -Task T1` |
| `done` | 验收通过 | `aos track close -Task T1 -Plan <file>`（自动对账） |
| `blocked` | 外部阻塞 | `aos track block -Task T1 -Reason "..."` |
| `abandoned` | 放弃 | `aos track abandon -Task T1 -Reason "..."` |

## 派发

Master 只派发不执行：每个 PLAN 节点由一个 subagent 执行；同一 wave 的节点并行派发。派发前必须有 issue + PLAN；`track start -Plan` 必须带 `-Subagent`，且不能与 owner 同名。subagent 返回证据后 Master `review`/`close`，结论写入 PLAN 的 `## Notes`。

`audit` 会检查 subagent 归属：有执行证据（start/review/close，或 `plan state` 写成 running/done）但 ledger 没有带 `-Subagent` 的 start，报 `subagent-missing`。`plan state` 是状态修正通道，不是执行通道。

## 两处记录

1. **PLAN 节点状态**：`<repo>/.agentos/plans/PLAN-<issue>.state.json` —— 供 `plan next` 计算
2. **全局台账**：`<homebase>\devops\agentos\ledger.jsonl` —— 追加式审计流水，`track` / `audit` 的权威来源

`track close -Plan` 自动对账两者：ledger 终态回写 state；没有 ledger 证据的 stale `running`/`review` 清回 `planned`，不再需要手工 `-Force`。依赖判定也以 ledger 终态优先，旧 state 不会卡住 DAG。

## 与进程级长任务的分工

`aos track` 只负责 PLAN 里的**任务节点**生命周期。若 harness 另有进程级长任务登记工具，应由该工具自行管理；本仓不随附、也不假设其存在。

## 回收闭环

`track close -Plan` 自带只读收工检查（`reclaim`）：

| 检查 | 内容 | 边界 |
|---|---|---|
| `audit` | PLAN / state / ledger、subagent 归属 | 有 error 先清账 |
| `worktrees` | `wt prune` 盘点 safe candidates / dirty | 只读，不自动 `-Apply` |
| `hygiene` | harness helper 进程泄漏 | 只读，不自动 `-Reap` |

收工后：

1. 读 `reclaim`；audit `errors>0` 先清账，`-Backfill` 只修可证明的缺口
2. `worktrees.paths` 里的安全候选才可手动 `aos wt prune -Apply`；dirty worktree 一律保留
3. `hygiene.attention` 非空先报告；`-Reap` 需确认
4. 在 PLAN 的 `## Notes` 里记验收结论

---

## 回收：不让任务数据无限堆叠

三处会无限增长，`aos gc` 负责压掉它们：

| 数据 | 位置 | 增长原因 | gc 动作 |
|---|---|---|---|
| 台账 | `devops/agentos/ledger.jsonl` | 每次 start/review/close 追加一行 | 只保留「最近 N 天」或「仍未关闭」的事件 |
| 计划 | `<repo>/.agentos/plans/PLAN-*.md` | 每个 issue 一份 | 全部节点 done/abandoned 且超龄 → 移到 `devops/agentos/archive/<repo>/` |
| 状态 | `PLAN-*.state.json` | 随计划同行 | 随计划一起归档 |

### 用法

```powershell
aos gc                    # dry-run，exit 2 表示有可回收项
aos gc -Human             # 表格
aos gc -Apply             # 实际执行
aos gc -KeepDays 14 -Apply
```

### 安全边界

- 默认 **dry-run**，只有 `-Apply` 才动手
- 未关闭的任务事件**永不丢弃**（无论多老）
- 计划只有在「所有节点都已 done/abandoned」且「超过 KeepDays」时才归档
- 压缩采用「写临时文件 → 原子替换」，中途失败不会留下半个台账

## 感知：谁正在做什么

`aos snapshot` 返回的 `active` 字段列出所有 `running` / `review` 状态的节点：

```json
{
  "active": [
    { "plan": "PLAN-271", "task": "T3", "status": "running", "owner": "codex", "updated": "2026-11-06T09:12:00" }
  ],
  "attention": ["1 task(s) in flight: T3@codex"]
}
```

三个 agent 都读同一个 `snapshot`，所以**任何一个 agent 都能看到另外两个正在干什么**。

## 隔离铁律

harness 内部任务互不干扰。`claim` / `handoff` / `release 他人任务` 必须带 `-AuthorizedBy <来源>`，
否则脚本直接拒绝。超时任务**只报告不接管**。

## 接管：跨 harness 交接任务（需用户授权）

三个 agent 共享同一份 ledger。任务归属显式记录，**可以被另一个 harness 接手**。

```powershell
aos track who                                      # 当前谁持有什么、是否可接管
aos track claim   -Issue 308 -Task T4 -Owner codex  # 接手
aos track release -Issue 308 -Task T4 -Owner codex  # 交出
aos track handoff -Issue 308 -Task T4 -From codex -Owner claude
```

| 判定 | 结果 |
|---|---|
| 任务无主 | claim 成功 |
| 持有者超时（> `-StaleMinutes`，默认 120） | claim 成功，记 `from` |
| 持有者未超时 | claim 被拒，须 `-Force` + `-Reason` |
| 本人持有 | 幂等，no-op |

**事件类型**：任务 `start` / `review` / `close` / `block` / `abandon` / `claim` / `release` / `handoff` / `state`；policy `policy`（PFX 签名）；会话 `session-register` / `session-heartbeat` / `session-close`。
每条任务事件都带 `repo` 字段，所以跨仓也能定位。session 事件通过 `issue+task` 绑定任务，但不参与任务状态机。

## session（在场证明）

`aos session register -Issue <n> -Task <T> -Role worker -Host <machine>` 要求该任务已在 ledger 中 `running`/`review`；`heartbeat` / `close` 按 session id 操作。session 只是"谁在哪个 host 上执行这个任务"，不替代 `track`，也不自动销账任务。session 事件只写统一 ledger，`gc` 永不压缩。

## subagent policy

见 [data-model.md](data-model.md) 的 subagent policy（append-only）权威段。
