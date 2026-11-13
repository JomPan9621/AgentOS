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

## 二、六条 MUST（MUST 0–5）

### MUST 0 · 主会话只派发，不执行任务
- Master 只做：用户交互、`aos snapshot`、PLAN、`plan graph`、派发、`track review/close`、只读验收、单步只读问答。
- 禁止 Master 自己写代码/改文件/跑长命令/占 GPU/做远端操作。
- 所有执行型工作必须派发给 subagent；每个 PLAN 节点一个 subagent；同一 wave 必须并行派发，串行执行可并行任务 = 违规。
- 派发时 `aos track start -Plan <file> -Subagent <label>` 必须带 `-Subagent`；没有 issue + PLAN 不得派发（见 MUST 4）。

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

- **一个 wave = 一批 subagent；每个节点派发一个 subagent，必须并行派发**
- 串行执行可并行任务 = 违规；被判定串行的，**不许强行并行**；理由已在 `ForcedSerial` 里
- 你"觉得可以并行"不算数

### MUST 3 · 写型任务独占 worktree
```powershell
aos wt new -Issue <n> -Slug <slug> -Repo <repo>
```

- **只有 Master 能开 worktree**
- Worker 只在分配给它的那棵树里写
- **Worker 严禁 `git worktree add`**
- 禁止两个写任务共用一个 worktree

### MUST 4 · Issue 先行
- git 仓库：必须走 GitHub/GitLab issue（`gh` / GitLab API）；不得用本地 issue 代替。
- 非 git 仓库：必须先在 `.agentos/issues/` 写 `ISSUE-<id>.md`，再建 PLAN；DAG 能力与 git 任务一致。
- 没有 issue + PLAN 不得派发。

### MUST 5 · 浏览器只用 Chrome
需要浏览器的任务（网页操作、UI 验证、浏览器 MCP / Playwright / Selenium 等）**只能使用 Google Chrome（含 headless Chrome）**。禁止 Edge、Firefox、Safari、Brave、Chromium 及其他浏览器。Chrome 不可用（未安装、启动失败、版本不兼容）时**停止并报告**，不得用替代浏览器继续。

## 派发协议（Master → subagent）

每个 subagent 的 prompt 必须包含：

- **目标**：一句话
- **边界**：只改 PLAN 的 `touches` 路径，不得越界
- **输入**：依赖节点的产物路径
- **验收**：PLAN 的 `accept`
- **回传**：task id、status、实际命令/输出、文件/测试证据

一个 subagent 只做一个节点；Worker 不得自建 worktree；不得在 subagent 内发起长任务/后台任务；Sub-Master 必须同步等待。

---

## 三、任务进行中（强制）

```powershell
aos track start  -Issue <n> -Task T1 -Owner <codex|claude|dsh> -Plan <file> -Subagent <label>
aos track review -Issue <n> -Task T1
aos track close  -Issue <n> -Task T1 -Plan <file>   # 自动对账 state/ledger + 只读 audit / wt prune / hygiene
aos track block  -Issue <n> -Task T1 -Reason "..."
aos track abandon -Issue <n> -Task T1 -Reason "..."
```

- 每个节点必须走 start → review → close
- **状态写文件，不写对话**：对话里说"做完了"不算完成
- **subagent 归属必须真实**：`start -Plan` 必须带 `-Subagent`，且不能与 `-Owner` 同名；`audit` 对没有 subagent start 的执行证据报 `subagent-missing`（含用 `plan state` 绕过）
- 阻塞就 `track block`，不要静默卡住；放弃就 `track abandon` 并写理由
- `track start -Plan` 会校验 DAG：依赖未 done、任务已完成/正在跑都会拒绝；只有 `-Force` + 理由才能越过
- `track close -Plan` 会自动对账 state/ledger 并清理 stale DAG，不需要手工 `-Force`
- 直接改 `*.state.json` 而不写 ledger = 丢账；`plan state` 已内置 ledger，但优先走 `track`
- **policy 必须签名**：`track start -Plan -Subagent` 首次自动建立 policy 时只用 PFX 签名；没有钥匙就不写 unsigned policy（audit 报 `policy-missing`）。显式初始化/豁免只用 `audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>`；未签名、钥匙不匹配、签名被篡改一律 `policy-invalid`
- **会话在场**：`aos session register -Issue <n> -Task T1 -Role worker -Host <machine>` 必须绑定已 start 的任务；`aos session heartbeat -Id <sid>` / `aos session close -Id <sid>` / `aos session list`；事件只写统一 ledger

---

## 四、每次任务结束（强制）

0. `aos track close -Plan <file>` —— 自动对账 state/ledger，并只读执行 `audit`、`wt prune` 盘点、`hygiene`

1. 读 close 返回的 `reclaim`：audit errors>0 先清账；`wt prune` 只是盘点，安全候选才可手动 `-Apply`；dirty worktree 一律保留
2. hygiene 有泄漏组先报告，`-Reap` 需确认；不自动杀进程
3. 在 PLAN 的 `## Notes` 写验收结论

**收工不跑 `track close -Plan`、不处理 reclaim = 违规。** 破坏性 `-Apply`/`-Reap` 永不自动执行。

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

## 并行：AgentOS 强制派发，harness 决定机制

**AgentOS 规定必须派发 subagent、同 wave 必须并行；harness 只决定用什么机制。**

| 层 | 谁负责 | 内容 |
|---|---|---|
| **边界 + 派发** | AgentOS（我们） | 从 PLAN 的 `deps` / `touches` / `resource` 算出 wave；每个节点一个 subagent；同 wave 必须并行 |
| **机制** | 各 harness（自己） | 用什么机制（Task/Agent、Agent Teams、子代理池）把同一 wave 的 subagent 真正并行跑起来 |

### 各 harness 用自己的方式做到极致

- **Claude Code**：Task / Agent 并行派发
- **Codex**：codex 插件 / 本地并行执行
- **DSH**：Agent Teams / 子代理池
- 未来新 harness：它有什么就用什么

**AgentOS 规定必须派发与并行，机制由 harness 决定**：`aos plan graph` 报出 N 个 PARALLEL wave，就必须真的把 N 批节点分别派发给 subagent 并并行跑，不允许串行假装并行，也不允许 Master 自己执行。

### 一条硬要求

**凡是被判定可并行的任务，必须由 harness 用自己的并行能力同时推进。**

- 串行执行本可并行的任务 = 违规
- 并行度受 harness 自身能力限制（比如某 harness 只能同时 3 个），要在任务记录里写明
- 但**不能因为"习惯串行"就放弃并行**

换句话说：**AgentOS 负责算清楚能并行到什么程度并强制派发，harness 负责把它跑到那个程度。**

## 资源：本地槽位 + 远端 GPU 子租约

两类资源，两个命令，互不混用：

| 资源 | 命令 | 数据落点 |
|---|---|---|
| 本地写型槽位 | `aos wt new/status/prune` | `<repo>-<issue>-<slug>` |
| 远端 GPU 子租约 | `aos room list/show/check/acquire/release` | `data/agentos/hosts.json` + `devops/agentos/leases/` |

**规矩**：
- 派发写型任务前先 `aos wt new` 拿槽位
- PLAN 可选第 9 列 `needs` 声明资源：`gpus=<n|all>` 是硬约束；`env.os=...;env.runtime=...` 是软感知
- 需要远端 GPU 时：先 `aos plan resources -Plan <file>` 预检（GPU 不足 exit 2），再 `aos room acquire <host> -Task <task> -Issue <n> -Gpus <n|all>`；收工 `aos room release <host> -Task <task> -Issue <n>`（v2 身份 = task+issue，issue 作用域不能省略）
- GPU 是硬约束：不同 task 不得重叠占用同一张卡；`track start -Plan` 必须找到匹配 allocation，缺失或卡数不足直接拒绝，**不会自动 acquire**
- env mismatch / unknown 只 warning，由用户决定，不阻断执行
- 同一 host 可挂多个不重叠 allocation；v1 整机租约仍兼容
- 冲突时只报告，不自动接管；替代 host / 减少卡数 / 等待释放的建议见命令输出

## 五、开工前自检（六项，缺一不可）

- [ ] 我跑过 `aos snapshot` 且 `attention` 为空
- [ ] 主会话没有直接执行任务（只做规划/派发/验收）
- [ ] issue 已建立（git 用 issue tracker；非 git 用本地 issue）
- [ ] 我的 PLAN 通过 `aos plan validate`
- [ ] 每个 PLAN 节点已派发 subagent；同一 wave 并行；`track start` 已带 `-Subagent`
- [ ] 每个 write 节点都有独立 worktree
- [ ] 同一 wave 的节点 `touches` 不重叠
- [ ] `aos audit` 的 `errors` 为 0（含 `subagent-missing`、签名 `policy`、`crossLayerErrors`；在飞任务只报告）
- [ ] `track close -Plan` 的 `reclaim` 已读；未自动删除 dirty worktree
- [ ] 浏览器任务只用 Chrome，未使用替代浏览器

## 六、禁止清单

| 禁止 | 原因 |
|---|---|
| 不跑 snapshot 直接开工 | 会踩已在告警的坑 |
| Master 自己执行任务 | 派发模型被绕过 |
| 同一 wave 串行执行 | 可并行任务被拖慢 |
| git 仓库不走 issue | 任务失去唯一状态源 |
| 无 issue/PLAN 直接派发 | 不可跟踪 |
| 自己判断能不能并行 | 并发必须由脚本算 |
| Worker 自建 worktree | 槽位失控的根源 |
| 多个写任务共享 worktree | 必然互相覆盖 |
| 做完不 `wt prune` | worktree 无限堆积 |
| 只在对话里报告完成 | 换会话就丢 |
| 跳过 ledger 直接改 state | 计划丢账，audit 会报 state-only |
| 用 `plan state` 或手工执行绕过 `track start -Subagent` | audit 报 `subagent-missing`，无法静默 |
| 自动执行 `wt prune -Apply` / `hygiene -Reap` | 破坏性操作必须人工确认 |
| 写入未签名 policy 或用不同 PFX 追加 policy | policy 链固定 thumbprint，audit 报 `policy-invalid` / key mismatch |
| 浏览器任务使用 Chrome 以外的浏览器 | 用户要求浏览器只用 Chrome |
| 用 `git stash`/`reset` 掩盖脏现场 | 破坏证据 |

---

## 七、系统提示的三种含义

| 返回 | 含义 | 你该做什么 |
|---|---|---|
| `exit 0` | 正常 | 继续 |
| `exit 1` | 错误 | 读 `error`，修正后重做 |
| `exit 2` | 需治理 | **停下**，先清 `attention`，再继续 |

## 派发边界：派发是强制的，机制由 harness 决定

**AgentOS 规定每个 PLAN 节点必须由 subagent 执行、同 wave 必须并行；不规定 harness 用什么机制创建/调度 subagent。**

| 属于 AgentOS（harness 层） | 不属于 AgentOS（harness 内部 / 业务层） |
|---|---|
| 派发要求：每个节点一个 subagent、同 wave 并行 | harness 用什么机制：Task/Agent、Agent Teams、子代理池 |
| 任务归属：哪个 harness 认领了哪个 task | subagent 的创建、回收、上下文隔离细节 |
| 生命周期：start / review / close / claim / handoff | 用户交互：会话、UI、任务板、审批流 |
| 资源槽位：worktree 的分配与回收 | harness 自己的日志、trace、内存 |

### 规矩

harness 内部怎么干，AgentOS 不管；但**派发必须发生，干了什么必须落回 AgentOS**：

- 开工：`aos track start -Plan <file> -Subagent <label>`
- 收工：`aos track close -Plan <file>` —— 自动对账 state/ledger，并只读 audit / wt prune / hygiene；破坏性 `-Apply`/`-Reap` 人工确认
- 写型任务：`aos wt new` 拿槽位
- 交接：`aos track handoff -Owner <harness>`

换句话说：**AgentOS 管"必须派发、同 wave 并行、谁认领哪个任务、何时销账"；不管 subagent 的创建/回收细节。派发本身不是可选的：不派发 = 违规。**

子代理的任务板、UI 会话状态、团队协作视图——这些是 harness 自己的事，不写进 PLAN、不写进台账。

## 八、边界

- 本规程只管**怎么干**，不管**干什么**
- 涉及 push / deploy / 破坏性清理，仍按仓库根 `AGENTS.md` 的最高优先级规则执行
- 规程自身在本机位于 `<homebase>\agentos`，更新以仓库为准
