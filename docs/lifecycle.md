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
| `running` | 已派发给某个 worker | `aos track start -Task T1 -Owner codex` |
| `review` | worker 交付，等待验收 | `aos track review -Task T1` |
| `done` | 验收通过 | `aos track close -Task T1` |
| `blocked` | 外部阻塞 | `aos plan state -Task T1 -Status blocked` |
| `abandoned` | 放弃 | `aos plan state -Task T1 -Status abandoned` |

## 两处记录

1. **PLAN 节点状态**：`<repo>/.agentos/plans/PLAN-<issue>.state.json` —— 单一事实源，供 `plan next` 计算
2. **全局台账**：`<homebase>\devops\agentos\ledger.jsonl` —— 追加式审计流水，`aos track list` 可查

## 与 tasktrack 的分工

| 工具 | 管什么 | 用于 |
|---|---|---|
| `aos track` | **任务节点**的生命周期 | PLAN 里的 T1/T2 派发与验收 |
| `repo/devops/tasktrack` | **进程级长任务**防丢失 | Codex 后台任务、长命令、跨会话作业 |

两个都要用：`track` 记"这个节点在谁手上"，`tasktrack` 记"这个后台进程别被回收后失联"。

## 回收闭环

`done` 之后必须做两件事，否则生命周期没走完：

1. `aos wt prune` —— 回收该节点的 worktree 槽位
2. 在 PLAN 的 `## Notes` 里记一句验收结论

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

**事件类型**：`start` / `review` / `close` / `claim` / `release` / `handoff`。
每条事件都带 `repo` 字段，所以跨仓也能定位。
