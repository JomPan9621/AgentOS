---
name: agentos
description: HIGHEST-PRIORITY operating procedure for ALL multi-step engineering work in this environment. Every agent (Claude Code, Codex, DSH) MUST follow it before touching code; also handles task handover between them — snapshot first, plan before acting, let the DAG decide parallelism, take an exclusive worktree slot for any write, and close the lifecycle when done. Load this before starting any task that is more than one step.
---

# AgentOS — Agent 操作规程（最高优先级）

> 这不是一个真实的操作系统进程，也**没有内核强制**。
> 它是通过 skill 注入给你的**操作规程**，有效性来自：你被要求遵守它。
> 与用户直接指令冲突时以用户指令为准；**其余一切情况，本规程优先于你的默认习惯。**

---

## 一、每次任务开始（强制）

```powershell
$s = & <homebase>\agentos\bin\aos.ps1 snapshot -Repo <repo路径> | ConvertFrom-Json
```

读 `$s.attention`：

- **非空 → 先处理，不要开始新任务**
- `exit 2` 表示系统需要治理

不确定当前状态就派发 = 违规。

---

## 二、三条 MUST

### MUST 1 · 计划先行
非单步任务，**必须先产出 PLAN**，不得边想边干：

```powershell
aos plan new -Issue <n> -Title "<一句话>" -Repo <repo>
```

然后填写任务表（`<repo>/.agentos/plans/PLAN-<n>.md`）。
单步任务（改一行、查一个文件）可以跳过。

### MUST 2 · 并发由 DAG 决定，不由你决定
```powershell
aos plan validate -Plan <file>    # 不通过不许开工
aos plan graph    -Plan <file>    # 读 Waves
```

- **一个 wave = 一批 subagent，必须并行派发**
- 被判定串行的，**不许强行并行**；理由已在 `ForcedSerial` 里
- 你"觉得可以并行"不算数

### MUST 3 · 写型任务独占 worktree
```powershell
aos wt new -Issue <n> -Slug <slug> -Repo <repo>
```

- **只有 Master 能开 worktree**
- Worker 只在分配给它的那棵树里写
- **Worker 严禁 `git worktree add`**
- 禁止两个写任务共用一个 worktree

---

## 三、任务进行中（强制）

```powershell
aos track start  -Issue <n> -Task T1 -Owner <codex|claude|dsh>
aos track review -Issue <n> -Task T1
aos track close  -Issue <n> -Task T1
```

- 每个节点必须走 start → review → close
- **状态写文件，不写对话**：对话里说"做完了"不算完成
- 阻塞就标 `blocked`，不要静默卡住

---

## 四、每次任务结束（强制）

0. `aos hygiene` —— 检查是否有 harness helper 进程泄漏（退出码 2 表示有泄漏组）；有则 `-Reap` 回收

1. `aos wt prune` —— 先只读盘点
2. 安全候选才可 `-Apply`；有脏改动的一律保留并说明原因
3. 在 PLAN 的 `## Notes` 写验收结论

**不回收 worktree 就收工 = 违规。** 历史欠账 45 个就是这么来的。

---


## 隔离铁律（最高优先）

**harness 内部正在执行的任务是各自私域，绝不可互相干扰。**

| 禁止（默认） | 允许（仅在用户明确要求时） |
|---|---|
| 改另一个 harness 正在用的 worktree / 文件 | 用户说"把 X 的任务接过来"后 `track claim -AuthorizedBy user` |
| 抢另一个 harness 持有的任务 | 用户说"交接一下"后 `track handoff -AuthorizedBy user` |
| 停/杀另一个 harness 的进程 | 用户明确授权后 `track release -AuthorizedBy user` |
| 因超时自动接管 | — **超时也只报告，不自动接管** |

**脚本已强制**：`claim` / `handoff` / `release 他人任务` 若不带 `-AuthorizedBy`，直接报错拒绝。

`track who` 只用于**观察**（谁在跑什么、跑多久了）。看到别人超时，正确动作是**报告给用户**，不是接管。

## 跨 harness 接管（仅在用户明确要求时）

任务归属写在 ledger 里，不写在对话里。**你可以接手另一个 agent 的任务**：

```powershell
aos track who                                            # 谁在做什么、哪些可接管
aos track claim -Issue 308 -Task T4 -Owner codex          # 接手（对方已 release 或已超时）
aos track claim -Issue 308 -Task T4 -Owner codex -Force -Reason "claude 卡住 40 分钟"
aos track release -Issue 308 -Task T4 -Owner codex -Note "交回主线"
aos track handoff -Issue 308 -Task T4 -From codex -Owner claude   # 一步交接
```

### 规则

| 场景 | 行为 |
|---|---|
| 任务无主（release 过 / 从未被领） | `claim` 直接成功 |
| 他人持有但**已超时**（默认 120 分钟） | `claim` 直接成功，记录 `from` |
| 他人持有且未超时 | `claim` **被拒绝**，须 `-Force` 并写明 `-Reason` |
| 你想主动让出 | `release`，任务变 available |
| 一对一交接 | `handoff`，一步完成，记录 `from`/to |

### 不许做的事

- 看到他人在跑就直接改他的 worktree —— 先 `claim`
- 接管后不写 `-Reason` —— 审计会缺环
- 抢非超时任务却不说明理由 —— 会被拒绝

## 并行：方法论给边界，harness 给实现

**AgentOS 不说"怎么并行"，只说"什么可以并行"。**

| 层 | 谁负责 | 内容 |
|---|---|---|
| **边界** | AgentOS（我们） | 从 PLAN 的 `deps` / `touches` / `resource` 算出哪些节点可并行（`aos plan graph` 的 wave） |
| **实现** | 各 harness（自己） | 用什么机制把同一 wave 的任务真正并行跑起来 |

### 各 harness 用自己的方式做到极致

- **Claude Code**：subagent / Task 并行派发
- **Codex**：codex 插件 / 本地并行执行
- **DSH**：Agent Teams / 子代理池
- 未来新 harness：它有什么就用什么

**AgentOS 不规定机制，只验收结果**：`aos plan graph` 报出 N 个 PARALLEL wave，就必须真的并行跑 N 批，不允许串行假装并行。

### 一条硬要求

**凡是被判定可并行的任务，必须由 harness 用自己的并行能力同时推进。**

- 串行执行本可并行的任务 = 违规
- 并行度受 harness 自身能力限制（比如某 harness 只能同时 3 个），要在任务记录里写明
- 但**不能因为"习惯串行"就放弃并行**

换句话说：**AgentOS 负责算清楚能并行到什么程度，harness 负责把它跑到那个程度。**

## 资源：本地槽位 + 远端租约

两类资源，两个命令，互不混用：

| 资源 | 命令 | 数据落点 |
|---|---|---|
| 本地写型槽位 | `aos wt new/status/prune` | `<repo>-<issue>-<slug>` |
| 远端机器租约 | `aos room list/check/acquire/release` | `data/agentos/hosts.json` + `devops/agentos/leases/` |

**规矩**：
- 派发写型任务前先 `aos wt new` 拿槽位
- 需要远端机器时先 `aos room acquire <host> -Task <issue>`，收工 `aos room release <host> -Task <issue>`
- PLAN 的 `resource` 字段写机器别名；`aos plan validate` 会检查它是否已被别人租用
- 一次只能租一台机给一个任务，冲突时只报告，不自动接管

## 五、开工前自检（四项，缺一不可）

- [ ] 我跑过 `aos snapshot` 且 `attention` 为空
- [ ] 我的 PLAN 通过 `aos plan validate`
- [ ] 每个 write 节点都有独立 worktree
- [ ] 同一 wave 的节点 `touches` 不重叠

## 六、禁止清单

| 禁止 | 原因 |
|---|---|
| 不跑 snapshot 直接开工 | 会踩已在告警的坑 |
| 自己判断能不能并行 | 并发必须由脚本算 |
| Worker 自建 worktree | 槽位失控的根源 |
| 多个写任务共享 worktree | 必然互相覆盖 |
| 做完不 `wt prune` | worktree 无限堆积 |
| 只在对话里报告完成 | 换会话就丢 |
| 用 `git stash`/`reset` 掩盖脏现场 | 破坏证据 |

---

## 七、系统提示的三种含义

| 返回 | 含义 | 你该做什么 |
|---|---|---|
| `exit 0` | 正常 | 继续 |
| `exit 1` | 错误 | 读 `error`，修正后重做 |
| `exit 2` | 需治理 | **停下**，先清 `attention`，再继续 |

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

## 八、边界

- 本规程只管**怎么干**，不管**干什么**
- 涉及 push / deploy / 破坏性清理，仍按根据地 `AGENTS.md` 的最高优先级规则执行
- 规程自身在本机位于 `<homebase>\agentos`，更新以仓库为准
