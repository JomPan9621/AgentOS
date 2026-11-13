# 数据模型与能力映射

> **原则：AgentOS 只定义"契约形状"，绝不持有业务数据。**
>
> - 能力必须落在**契约**上——每个命令要么读某个契约、要么写某个契约，不空转。
> - 契约的**实例**由业务仓自己提供（`.agentos/` 目录），AgentOS 只按形状校验和读写。
> - **AgentOS 仓库内零业务数据**：没有项目名、没有仓名、没有 issue 号、没有设备型号。
>
> 一句话：**我们提供的是 AI-native 生态的 OS，不是某个项目的工具。**

---

## 一、四类数据结构

| # | 结构 | 落点 | 形态 | 生命周期 |
|---|---|---|---|---|
| 1 | **PLAN** | `<repo>/.agentos/plans/PLAN-<issue>.md` | Markdown 任务表 | 创建 → 全部 done/abandoned → `gc` 归档 |
| 2 | **STATE** | `<repo>/.agentos/plans/PLAN-<issue>.state.json` | JSON（id → status/owner/updated） | 随节点流转，随 PLAN 归档 |
| 3 | **LEDGER** | `<homebase>\devops\agentos\ledger.jsonl` | JSONL 追加 | 永续；`gc` 按龄压缩，未关闭任务不丢 |
| 4 | **WORKTREE** | `<projectRoot>/<repo>-<issue>-<slug>` | 磁盘目录 | `wt new` 创建 → `wt prune` 回收 |

### 字段定义

**PLAN 任务行**（8 列固定）

| 字段 | 类型 | 语义 | 谁用 |
|---|---|---|---|
| `id` | T1/M3… | 节点标识 | graph / next / state |
| `title` | string | 一句话描述 | 人读 |
| `kind` | `write` \| `read` | 是否改文件 | 并发判定 / 槽位分配 |
| `deps` | id 列表 | 前置依赖 | DAG 拓扑 |
| `touches` | 路径前缀列表 | 要碰的文件面 | 冲突判定 |
| `resource` | string | 独占资源标识（`none` 或自定义标签） | 资源互斥 |
| `worktree` | string | 槽位名（写型必填） | 资源分配 |
| `accept` | string | 验收命令或标准 | 人工/agent 验收 |

**STATE 节点**

```json
{ "T3": { "status": "running", "owner": "codex", "prev": "planned", "updated": "2026-11-06T11:18:39" } }
```

**LEDGER 事件**（每行一条）

```json
{ "ts": "...", "event": "claim|start|review|close|block|abandon|release|handoff|state",
  "issue": "<id>", "task": "<T1>", "owner": "<harness>", "subagent": "<worker-label>",
  "wave": "<wave>", "plan": "<plan-path>", "repo": "<repo-name>", "forced": false }
```

`start` 必须带 `subagent`；`close` 记录 `subagentMissing`。执行证据缺少带 `-Subagent` 的 `start` 时，`audit` 报 `subagent-missing`。

---

## 二、能力 × 数据结构矩阵

`R` = 读，`W` = 写，`-` = 不碰

| 能力 | PLAN | STATE | LEDGER | WORKTREE | 产出 |
|---|:--:|:--:|:--:|:--:|---|
| `plan new` | **W** | - | - | - | 新 PLAN 文件 |
| `plan validate` | **R** | - | - | - | 校验结论（errors/warnings） |
| `plan graph` | **R** | - | - | - | waves + forcedSerial |
| `plan next` | **R** | **R** | - | - | 当前可派发批次 |
| `plan state` | **R** | **W** | - | - | 节点状态 |
| `track start/review/close` | **R**\* | **W**\* | **W** | - | 生命周期事件 |
| `track claim/release/handoff` | **R**\* | **W**\* | **W** | - | 归属变更事件 |
| `track who` | - | - | **R** | - | 当前持有者与可接管性 |
| `snapshot` | **R** | **R** | **R** | **R** | 单仓全量快照 |
| `projects` | **R** | **R** | - | **R** | 跨仓总览 |
| `wt new` | **R** | - | - | **W** | 新槽位 |
| `wt status/list` | - | - | - | **R** | 槽位分类 |
| `wt prune` | - | - | - | **W** | 回收 + 审计日志 |
| `issue detect/new` | - | - | - | - | issue 源（外部） |
| `gc` | **W**（归档） | **W**（归档） | **W**（压缩） | - | 回收报告 |
| `doctor` | - | - | - | - | 挂载一致性 |

\* `track` 只在传 `-Plan` 时读写 PLAN/STATE；只传 `-Ledger` 时仅写 LEDGER。

### 读矩阵的两个用途

- **能力不能空转**：任何命令必须至少触及一个数据结构
- **影响面可预测**：改一条能力前，先看它会动哪几份数据

---

## 三、不变量（写代码必须守）

| # | 不变量 | 违反后果 |
|---|---|---|
| 1 | PLAN 是计划的**唯一源**；STATE 不存计划内容 | 两份计划打架 |
| 2 | STATE 只由 `plan state` / `track` 写 | 状态被旁路篡改 |
| 3 | LEDGER **只追加**；只有 `gc` 可压缩，且**未关闭任务的事件永不清** | 审计链断裂 |
| 4 | `worktree` 目录只由 `wt new` 创建、`wt prune` 删除 | 槽位失控 |
| 5 | 写型节点的 `worktree` 必须非空且唯一 | 两人共写同一目录 |
| 6 | 接管必须落一条 LEDGER 事件（带 `from`） | 归属不可追溯 |

---

## 四、解耦边界

**AgentOS 只认形状，不认业务语义：**

| 数据 | AgentOS 怎么理解 | AgentOS 不做什么 |
|---|---|---|
| `id` | 唯一标识符 | 不解释 T1 是什么意思 |
| `touches` | 路径前缀，做重叠判定 | 不读那些文件的内容 |
| `resource` | 字符串，做相等互斥 | 不知道 <device> 是什么卡 |
| `accept` | 字符串，原样展示 | 不执行验收命令 |
| 业务仓 | 通过 `.agentos/` 目录**自带**契约实例 | **不进入业务代码目录、不内置任何仓名/issue 号** |

**挂载方式**：业务仓只要在根目录有 `.agentos/plans/`，就接入 AgentOS；没有就完全不受影响。

---

## 五、一次任务的数据流（谁写谁读）

```
plan new ──写──▶ PLAN.md
                    │
plan graph ──读──────┘
                    │
派发 ──▶ track start ──写──▶ STATE + LEDGER
                                      │
                    wt new ──写──▶ WORKTREE
                                      │
track review/close ──写──▶ STATE + LEDGER
                                      │
snapshot ──读──▶ PLAN + STATE + LEDGER + WORKTREE（一次拿全）
                                      │
wt prune ──写──▶ WORKTREE（回收）
gc ──写──▶ LEDGER（压缩）+ PLAN/STATE（归档）
```

## subagent policy（append-only，PFX 签名）

Policy lives in the ledger as `{"event":"policy","since":"<ts>","source":"track-start|audit-init|audit-override|env-override","authorizedBy":"<who>","sig":{"alg":"RS256","thumbprint":"<sha1>","cert":"<base64 der>","value":"<base64 sig>"}}`. The signature covers `policy|ts|since|source|authorizedBy|note`. `subagent-policy.json` is only a cache; the ledger event is authoritative.

- `track start -Plan -Subagent` auto-initializes a policy only when a PFX signing key is available (`-PfxPath/-PfxPassword` or `AGENTOS_POLICY_PFX` / `AGENTOS_POLICY_PFX_PASSWORD`); it never writes an unsigned policy.
- `audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who> [-SubagentSince <ts>]` is the explicit initialization/waiver interface; future timestamps and missing keys are rejected.
- `audit -SubagentSince` / `AGENTOS_SUBAGENT_SINCE` require authorization and a signing key; they append a signed override event.
- Every policy event must be signed and chain to the first event's certificate thumbprint. Unsigned / tampered / different-key events => `policy-invalid` (error), and cannot waive `subagent-missing`.
- No policy => `policy-missing` error and no waiver. Pre-cutoff gaps are visible `subagent-legacy` warnings (`subagentWaived`); post-cutoff gaps are `subagent-missing` errors. `-SkipReclaim` is test/batch-only; destructive `-Apply`/`-Reap` is never automatic.
- **TOFU（信任锚）**：首个 policy 事件的证书 thumbprint 即整条链的信任锚。生产 / 共享 ledger 必须由 Master 先用生产 PFX 执行 `audit -InitPolicy -PfxPath <生产pfx> -PfxPassword <pwd> -AuthorizedBy <master>`，不要让普通 `track start` 自动签名产生首个 key。

## session events（append-only，统一 ledger）

`aos session register|heartbeat|close` appends:

```json
{"event":"session-register|session-heartbeat|session-close","session":"s-...","role":"master|sub-master|worker","issue":"<id>","task":"<T1>","host":"<machine>","ts":"..."}
```

Register requires the issue/task to be an open (`running`/`review`) tracked task. Sessions have no separate state file; `bin/ledger.ps1` excludes `session-*` from task parsing and `gc` never compacts them. `snapshot` exposes open sessions.
