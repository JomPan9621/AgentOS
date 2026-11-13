# 角色模型

## 三层

| 角色 | 职责 | 能否派发 | 谁 |
|---|---|---|---|
| **Master** | 只与用户交互、规划、派发、验收；**不执行任务** | ✅ | 主会话 |
| **Sub-Master** | 承接一个子目标，再拆一层；同步等待子代理 | ✅ | subagent |
| **Worker** | 执行单个 PLAN 节点 | ❌ | subagent |

**角色不是工具**：Claude Code、Codex、DSH 都可以是 Master，也都可以是 Worker；但 **Worker 必须是 subagent**。

## 硬约束

1. **主会话只派发，不执行任务**：Master 不写代码、不改文件、不跑长命令、不占 GPU、不做远端操作；只做 snapshot/plan/graph/派发/track review/close、只读验收和单步只读问答。
2. **每个 PLAN 节点 = 一个 subagent**；同一 wave 的所有节点必须并行派发；串行执行可并行任务 = 违规。
3. **只有 Master 能派发**，Worker 不再派生；Sub-Master 递归深度 ≤ 3。
4. **Sub-Master 必须同步等待**其子代理返回，禁止 fire-and-forget（子代理生命周期结束会连带回收进程树——实战踩坑）。
5. **只有 Master 能开 worktree**；Worker 在自己被分配的树里写，严禁 `git worktree add`。
6. **Issue 先行**：git 仓库必须走 GitHub/GitLab issue；非 git 仓库必须先建本地 `.agentos/issues/ISSUE-<id>.md`，再建 PLAN；没有 issue/PLAN 不得派发。

## 典型拓扑

```
人
└─ Master（主会话：只交互/规划/派发/验收）
   ├─ Worker×N   ← 同一 wave，并行 subagent
   └─ Sub-Master（subagent 编排者）
      ├─ Worker
      └─ Worker
```

## 派发话术模板

给 Worker 的任务描述必须包含五要素，缺一不可：

```
目标 : <一句话>
边界 : 只改 touches 列出的路径，不得越界
输入 : <依赖节点的产物路径>
验收 : <accept 列出的命令>
回传 : task id/status/实际命令输出/文件与测试证据
```

Master 收到回传后：`aos track review` → 验收 → `aos track close -Plan <file>`；close 自动对账 state/ledger 并返回只读 `reclaim`（audit / wt prune / hygiene），安全候选才手动 `-Apply`。结论写入 PLAN 的 `## Notes`。

需要说明"谁在哪个 host 上执行"时，用 `aos session register -Issue <n> -Task <T> -Role <master|sub-master|worker> -Host <machine>` 绑定已 start 的任务；session 只是在场证明，不替代 track 生命周期。session 事件只写统一 ledger。

## 边界

AgentOS 规定必须派发、同 wave 并行；harness 只决定用什么机制（Claude Code Task/Agent、Codex、DSH Agent Teams）。AgentOS 不管理 subagent 的创建/回收/上下文隔离细节，但**派发本身不是可选的：不派发 = 违规**。
