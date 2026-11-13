# 派发协议

Master 是主会话，只负责用户交互、规划、派发、验收；所有执行型工作由 subagent 完成。每个 PLAN 节点 = 一个 subagent；同一 wave 的节点必须并行派发。

## 派发前置

1. 任务已有 issue（git 用 GitHub/GitLab issue；非 git 用 `.agentos/issues/ISSUE-<id>.md`）。
2. 已有 PLAN，且 `aos plan validate` 通过。
3. `aos plan graph` 已算出 wave；同一 wave 的 `touches` 不重叠、`resource` 不相交。
4. 写型节点已有独占 worktree（Master 用 `aos wt new` 创建）。
5. Master 已 `aos track start -Task <id> -Owner <harness> -Plan <file> -Subagent <label>`；`-Subagent` 必须真实、且不能与 owner 同名。
6. 需要会话在场时，subagent / Master 用 `aos session register -Issue <n> -Task <id> -Role worker -Host <machine>` 绑定该任务；heartbeat / close 按 session id 操作。

## 派发 prompt（五要素）

```
目标 : <一句话>
边界 : 只改 PLAN 的 touches 路径，不得越界
输入 : <依赖节点的产物路径>
验收 : PLAN 的 accept
回传 : task id/status/实际命令输出/文件与测试证据
```

## Subagent 约束

- 只做一个节点；不得派生（除非它是 Sub-Master）。
- 不得自建 worktree；不得改别人的 worktree。
- 不得发起长任务/后台任务（全局规则：子代理生命周期结束会回收进程树）。
- 必须回传证据；不得只在对话里说完成。

## Master 验收

1. 收集回传证据，确认 `accept` 满足。
2. `aos track review` → `aos track close -Plan <file>`；close 自动对账 state/ledger，并返回只读 `reclaim`（audit / wt prune / hygiene）。
3. 读 `reclaim`：audit `errors>0` 先清账；dirty worktree 保留；破坏性 `-Apply`/`-Reap` 人工确认后再执行。
4. 在 PLAN 的 `## Notes` 写验收结论。

## Subagent 归属审计

`track start -Plan` 缺 `-Subagent`、或 subagent 与 owner 同名会被拒绝。执行证据（start/review/close，或 `plan state` 写成 running/done）如果没有带 `-Subagent` 的 start，`audit` 报 `subagent-missing`（error）。Master 直接执行无法静默：它只能留下可审计的缺环。

## subagent policy（PFX 签名）

见 [data-model.md](data-model.md) 的 subagent policy（append-only，PFX 签名）权威段。摘要：`track start -Plan -Subagent` 只在有签名钥匙时自动初始化；`audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>` 是显式入口；未签名 / 改签名 / 换钥匙都拒绝。

## cross-layer（租约对账）

`aos audit` 会把 `room` 租约与 `track` 未关闭节点关联：租约没有对应的在飞任务 → `lease-stale` warning；在飞任务超过宽限期却没有租约 → `agent-task-no-lease` warning。`track close` 的 `reclaim` 会消费 `crossLayerErrors`。

租约文件只来自本机数据层的 `devops/agentos/leases/`；仓库代码不含任何机器名、主机清单或真实资源值。
