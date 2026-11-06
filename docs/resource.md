# 资源管理

AgentOS 管两类资源，都遵循「先占后用、用完即还」。

## 本地：worktree 槽位

写型任务必须独占一个 worktree，避免并发写同一份代码。

```powershell
aos wt new -Issue <issue> -Slug <slug> -Repo <repo>   # 拿槽位
aos wt status -Repo <repo>                            # 看占用
aos wt prune -Repo <repo>                             # 收工盘点
```

- 槽位上限：`-Limit`（默认 5）
- 只统计 AgentOS 管理的 `task/*` 分支；历史遗留单独报告，不阻塞调度
- 回收前提：路径在 project 根下、非主工作区、全部干净、已合入目标 ref

## 远端：机器租约

一台机器同一时刻只租给一个任务（单机单任务互斥）。

```powershell
aos room list                          # 清单 + 租约
aos room check <host>                    # SSH 连通性
aos room acquire <host> -Task <issue>    # 占用
aos room release <host> -Task <issue>    # 释放
```

- 清单：`data/agentos/hosts.json`（真实值，永不入 git）
- 租约：`devops/agentos/leases/*.json`（生成物，永不入 git）
- 冲突：已有他人租约时 acquire 被拒，只报告不接管
- 释放不匹配：租约持有者与 `-Task` 不一致时拒绝

## 与 PLAN 的关系

PLAN 的 `resource` 字段写机器别名：

| id | title | kind | deps | touches | resource | worktree | accept |
|---|---|---|---|---|---|---|---|
| T2 | 构建 sweep | write | T1 | remote/ | <host> | demo-84 | 通过 |

- `aos plan validate` 检查：别名是否在清单内、是否已被他人租用（只警告不阻断）
- `aos plan graph` 用 `resource` 判并行：同资源的任务自动串行
- `aos snapshot` 输出 `resources` 段，agent 一次拿到全部资源状态

## 与 harness 的边界

harness 内部怎么并行（Agent Teams / subagent / 自研）AgentOS 不管；
AgentOS 只管「哪个 harness 占了哪个槽位/机器、什么时候还」。
