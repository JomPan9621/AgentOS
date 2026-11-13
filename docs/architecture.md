# AgentOS 架构

> 一句话：**让本机的三个 AI agent 像同一支团队一样协同** —— 看得见彼此、接得了对方的活、不会互相踩工作区，任务数据不会无限堆积。

---

## 一、全景图

```
┌──────────────────────────────────────────────────────────────────────┐
│                          人（唯一决策者）                              │
└──────────────────────────────────────────────────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        ▼                         ▼                         ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│  Claude Code  │         │    Codex      │         │      DSH      │
│  规划 / 派活   │         │  本地执行      │         │   Web GUI     │
└───────┬───────┘         └───────┬───────┘         └───────┬───────┘
        │                         │                         │
        └─────────────┬───────────┴─────────────┬───────────┘
                      │   ①同一份规则（skill 注入）│
                      ▼                         ▼
        ┌──────────────────────────────────────────────────┐
        │              AgentOS  规程层（aos）               │
        │  snapshot  plan  wt  track  issue  projects  gc   │
        └───────────────────────┬──────────────────────────┘
                                │ ②所有状态落文件
        ┌───────────────────────┴──────────────────────────┐
        ▼                    ▼                ▼            ▼
  ┌──────────┐      ┌──────────────┐  ┌──────────┐  ┌──────────┐
  │ PLAN.md  │      │ state.json   │  │ ledger   │  │ worktree │
  │ 计划与DAG│      │ 节点状态/归属 │  │ 审计流水 │  │ 资源槽位 │
  └──────────┘      └──────────────┘  └──────────┘  └──────────┘
        │                    │                │            │
        └────────────────────┴────────────────┴────────────┘
                                │
                      ┌─────────┴─────────┐
                      ▼                   ▼
              ┌──────────────┐    ┌──────────────┐
              │ 业务仓（自带 │    │ 本机生成物    │
              │ .agentos）   │    │ （不入 git）  │
              └──────────────┘    └──────────────┘
```

---

## 二、三层职责

| 层 | 是什么 | 谁是消费者 |
|---|---|---|
| **接入层** | Claude Code / Codex / DSH 三个 harness | 人 |
| **规程层** | `aos` 命令集 + skill 规程 | agent |
| **状态层** | PLAN / state.json / ledger / worktree | 机器与 agent 共读 |

**关键设计**：接入层可以换（未来接第 4 个 harness），规程层和状态层不变。

规程层内部再分两层：`bin/` + `skills/agentos` 是命令与规则；`drivercore/` 是驱动职责层（bootstrap / harness 模板 / session / tasktrack / worktree）。drivercore 公开版只含架构与实现，不随包内部/第三方 skill，不含任何运行数据。详见 [drivercore.md](drivercore.md)。

---

## 三、四条核心数据流

### 3.1 任务生命周期（谁在干什么）

```
issue ──▶ plan new ──▶ plan graph ──▶ 派发 ──▶ track start ──▶ review ──▶ close
          (PLAN.md)     (wave 并发)            (state+ledger)
```

```powershell
aos issue detect -Repo <repo>          # GitHub 必走 issue / GitLab / 本地兜底
aos plan new -Issue 308 -Title "..." -Repo <repo>
aos plan validate -Plan PLAN-308.md    # 不通过不许开工
aos plan graph    -Plan PLAN-308.md    # 输出 wave：哪些能并行由 DAG 算
aos track start   -Issue 308 -Task T3 -Owner codex -Plan <file> -Subagent <label>
aos track review  -Issue 308 -Task T3 -Plan <file>
aos track close   -Issue 308 -Task T3 -Plan <file>   # auto reconcile + read-only reclaim
```

### 3.2 互相感知（看得见彼此）

```powershell
aos snapshot -Repo <repo>    # 单仓全景：plan / schedule / worktrees / active / ledger / attention
aos projects                 # 跨仓全景：计划数、在飞任务、worktree、issue 源
aos track who                # 谁持有什么任务、跑了多久、可不可接管
```

`snapshot.active` 实测输出：

```json
{ "active": [
    { "plan":"PLAN-900","task":"T1","status":"running","owner":"claude" },
    { "plan":"PLAN-900","task":"T2","status":"running","owner":"codex"  },
    { "plan":"PLAN-900","task":"T3","status":"running","owner":"dsh"    } ],
  "attention": ["3 task(s) in flight: T1@claude,T2@codex,T3@dsh"] }
```

### 3.3 任务交接（接得了对方的活）

```powershell
aos track handoff -Issue 900 -Task T1 -From claude -Owner dsh
aos track claim   -Issue 900 -Task T1 -Owner codex -Force -Reason "claude 卡住"
aos track release -Issue 900 -Task T1 -Owner codex -Note "交回主线"
```

```
判定表
├─ 任务无主            → claim 成功
├─ 持有者超时 (>120min) → claim 成功，记 from
├─ 持有者未超时         → 拒绝，须 -Force + -Reason
└─ 本人持有            → 幂等 no-op
```

实测流水（3 个 harness 真实协作）：

```
11:21:29 start    owner=claude   from=         repo=agentos
11:21:29 claim    owner=codex    from=claude   repo=agentos
11:21:29 handoff  owner=dsh      from=codex    repo=agentos
11:21:29 close    owner=dsh      from=         repo=agentos
```

### 3.4 资源隔离（不互相踩）

```
写型任务 ──▶ 独占 worktree 槽位 ──▶ 验收 ──▶ prune 回收
读型任务 ──▶ 共享工作区（不占槽位）
```

| 规则 | 值 |
|---|---|
| 单机并发写者上限 | 5 个 worktree |
| 命名 | `<repo>-<issue>-<slug>`，分支 `task/<issue>-<slug>` |
| 谁能开 | **只有 Master**；Worker 严禁 `git worktree add` |
| 回收条件 | 路径在 project 下 + 非主工作区 + 三种脏状态全零 + HEAD 已进目标 ref |

---

## 四、命令集

| 命令 | 作用 | 默认输出 |
|---|---|---|
| `aos snapshot` | 单仓全景快照 | JSON |
| `aos projects` | 跨仓总览 | JSON |
| `aos plan` | new / validate / graph / next / state / show / resources | JSON |
| `aos wt` | list / new / status / prune | JSON |
| `aos issue` | detect / new / show / list | JSON |
| `aos track` | start / review / close / block / abandon / claim / release / handoff / who / list / lost | JSON |
| `aos session` | register / heartbeat / close / list | JSON |
| `aos room` | list / show / check / acquire / release | JSON |
| `aos hygiene` | 检测泄漏 helper 进程与机器压力 | JSON |
| `aos artifact` | path / list —— 生成物固定根 | JSON |
| `aos audit` | PLAN / state / ledger / lease 对账，可 -Backfill | JSON |
| `aos gc` | 台账压缩 + 已完结计划归档 | JSON |
| `aos doctor` | 三 harness 安装面自检 | JSON |

**共同契约**：默认 JSON、`-Human` 才出表格、退出码 `0 成功 / 1 错误 / 2 需治理`。

---

## 五、可验证性（这不是 PPT）

| 判据 | 命令 | 当前值 |
|---|---|---|
| 三 harness 是否统一 | `aos doctor` | `ok` 需安装；scripts 必须全过，skill hash 允许因未安装失败 |
| 工具自身是否正确 | `tests/selftest.ps1` | **209/209 PASS**（2026-11-12，隔离沙箱，不碰生产数据） |
| drivercore 是否正确 | `drivercore/tasktrack/tests/tasktrack.tests.ps1` | **55/55 PASS**（2026-11-12，`%TEMP%` 隔离） |
| 跨仓是否可感知 | `aos projects` | 计划 / 在飞 / worktree 汇总 |
| 任务是否可追踪 | `aos track who` | 实时持有者 + 年龄 + 可接管性 |
| 数据是否堆积 | `aos gc` | dry-run 报告可压缩量与可归档量 |

---

## 六、目录与落地位置

```
<homebase>\agentos\          本仓（功能仓库，可放在任意路径）
├─ bin/        14 个脚本（aos 是统一入口；ledger 是唯一台账模型）
├─ drivercore/ 驱动职责层（bootstrap / harness / session / tasktrack / worktree；仅架构，无数据）
├─ docs/       文档（本文件在列）
├─ schema/     任务节点 schema
├─ templates/  PLAN 模板
├─ skills/     skill 包（装进三个 harness）
└─ tests/      selftest 与 artifact 测试

运行时状态
├─ <repo>/.agentos/plans/PLAN-*.md           计划
├─ <repo>/.agentos/plans/*.state.json        节点状态
├─ <homebase>\devops\agentos\ledger.jsonl   审计流水（task/policy/session）
├─ <homebase>\devops\agentos\leases\        机器租约（issue/agent_task）
├─ <homebase>\devops\agentos\artifacts\     生成物固定根
└─ <homebase>\devops\agentos\archive\      归档计划
```

---

## 七、对外介绍的三个要点

1. **统一的是规程，不是工具** —— 三个 harness 各自保留原样，靠 skill 注入同一套规程
2. **状态全部落文件** —— 换会话、换工具、换机器都能恢复，不依赖对话上下文
3. **每个能力都有判据** —— `doctor` 证明统一，`selftest` 证明正确，`snapshot/projects` 证明可见

> 它不拦截任何命令（不是真 OS 内核），但**绕过即违规**，且会被 `doctor` 与 `selftest` 抓出来。
