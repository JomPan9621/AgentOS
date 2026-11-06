# 角色模型

## 三层

| 角色 | 职责 | 能否派发 |
|---|---|---|
| **Master** | 规划、派发、验收；自己不动手 | ✅ |
| **Sub-Master** | 承接一个子目标，再拆一层 | ✅ |
| **Worker** | 执行单个 PLAN 节点 | ❌ |

**角色不是工具**：Claude Code、Codex、DSH 都可以是 Master，也都可以是 Worker。

## 硬约束

1. **只有 Master 能派发**，Worker 不再派生
2. **递归深度 ≤ 3**（Master → Sub-Master → Worker），超过则上下文损耗大于收益
3. **Sub-Master 必须同步等待**其子代理返回，禁止 fire-and-forget
   （子代理生命周期结束会连带回收进程树——2026-10-14 实际踩坑）
4. **只有 Master 能开 worktree**；Worker 在自己被分配的树里写

## 典型拓扑

```
人
└─ Master（Claude / Codex / DSH 任一）
   ├─ Worker×N   ← 同一 wave，并行
   └─ Sub-Master
      ├─ Worker
      └─ Worker
```

## 派发话术模板

给 Worker 的任务描述必须包含四要素，缺一不可：

```
目标 : <一句话>
边界 : 只改 <touches 列出的路径>，不得越界
输入 : <依赖节点的产物路径>
验收 : <accept 列出的命令>
```

## 边界：只管 harness 层

**AgentOS 建模的最小单位是 harness（Claude Code / Codex / DSH），不是 harness 内部的 agent 实例。**

| 属于 AgentOS（harness 层） | 不属于 AgentOS（harness 内部 / 业务层） |
|---|---|
| 任务归属：哪个 harness 认领了哪个 task | harness 内部怎么并行：Agent Teams、子代理池、并发调度器 |
| 生命周期：start / review / close / claim / handoff | 子代理的创建、回收、上下文隔离 |
| 资源槽位：worktree 的分配与回收 | 用户交互：会话、UI、任务板、审批流 |
| 感知：谁持有什么、多久了、可不可接管 | harness 自己的日志、trace、内存 |

### 规矩

harness 内部怎么干，AgentOS 不管；但**干了什么必须落回 AgentOS**：

- 开工：`aos track start -Owner <harness>`
- 收工：`aos track close -Owner <harness>`
- 写型任务：`aos wt new` 拿槽位
- 交接：`aos track handoff -Owner <harness>`

换句话说：**AgentOS 不管理 agent 怎么并行，只管理"谁认领了哪个任务、什么时候销账"。**

子代理的任务板、UI 会话状态、团队协作视图——这些是 harness 自己的事，不写进 PLAN、不写进台账。
