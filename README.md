# AgentOS

**以 skill 形式分发给 agent 的操作规程。**

它不是真实的操作系统——没有内核、没有守护进程、不拦截任何命令。
它靠 `skills/agentos/SKILL.md` 注入 **Claude Code / Codex / DSH**，效力来自"agent 被要求遵守"。
配套脚本 `bin/aos.ps1` 是规程用的工具；agent 绕过去 = 违规，不是被拦截。

优先级：用户指令 > 仓库最高优先级规则 > **本规程** > agent 默认习惯。

## 解决什么

| 痛点 | 现状 | AgentOS 的做法 |
|---|---|---|
| worktree 越开越多、用完不回收 | 一个仓挂过数十个 worktree | 写型任务向 Master 申请槽位，验收后 `aos wt prune` 回收 |
| 并行靠感觉 | 想到哪干到哪 | `aos plan graph` 算 wave；每个节点一个 subagent 并行 |
| 任务失联 | 不知道子代理干到哪 | `aos track` 记录生命周期，`lost` 检陈旧任务 |
| 三个工具三套规则 | 各自一套习惯 | 同一份 `AGENTS.md` 正本 + 同一份 skill |

## 这是一套方法论

AgentOS 交付的是**方法**，不是环境。

- **不写死环境**：homebase 由 `AGENTOS_HOME` 或「本仓所在位置的父目录」推导；仓库路径由 `-Repo` 传入；GitLab 主机由 `AGENTOS_GITLAB_HOSTS` 提供。
- **不携带业务**：仓库内零项目名、零仓名、零 issue 号、零设备型号。
- **形状即契约**：AgentOS 定义 PLAN / STATE / LEDGER / WORKTREE 四种契约，业务仓自己提供实例。

所以它可以被放在任何机器、任何路径、服务任何项目——**agent 按自己的环境自动适配**。

## drivercore（v0.3.0，architecture-only）

v0.3.0 起公开仓包含 drivercore 驱动职责层：`bootstrap/`（bootstrap 入口）、`harness/`（三 harness 适配模板与 manifest）、`session/`（会话在场模型）、`tasktrack/`（长任务看门狗）、`worktree/`（兼容转发器）。

公开的是**架构与实现**，不是运行现场：

- 不含任何运行数据、真实主机名、凭据、任务状态、日志、租约或 PFX；
- `drivercore/skills` 不随包（内部与第三方 skill 不对外）；
- 安装只复制 `skills/agentos`；bootstrap 只做前置检查、模板发布与安装委托。

架构边界与设计细节见 [docs/drivercore.md](docs/drivercore.md)。

## AI-native 契约（第一宗旨）

**所有产出以 agent 为第一消费者。**

```powershell
aos snapshot -Repo <path> -Plan <file> | ConvertFrom-Json
```

一次调用返回 `repo` / `plan` / `schedule` / `worktrees` / `active` / `sessions` / `resources` / `ledger` / `attention`。
`attention` 非空即刻停下处理；`exit 2` 表示需要治理。
所有命令默认 JSON，人类表格是可选的 `-Human`。

详见 [docs/ai-native.md](docs/ai-native.md)、[docs/output-contract.md](docs/output-contract.md)。

## 核心概念

```
人 ─▸ Master（只交互/规划/派发/验收）
        │  产出 PLAN（任务表）
        ▼
   ┌────┴────┐
 subagent   subagent      ← DAG 算出的并发 wave
 (write)    (read)
        │
        └─ Sub-Master（subagent 编排者，深度 ≤ 3）
                │
                ▼
        证据 → review → close -Plan → reclaim（只读）→ 人工 prune -Apply
```

## 派发模型

- **Master（主会话）**只与用户交互、规划、派发、验收，**不执行任务**。
- **每个 PLAN 节点由一个 subagent 执行**；同一 wave 必须并行派发；串行执行可并行任务 = 违规。
- **subagent 归属可审计**：节点执行必须落 `track start -Plan -Subagent`；`plan state` 不是执行通道，`audit` 报 `subagent-missing`。
- **policy 签名**：policy 事件 append-only 于 ledger，必须由 PFX 私钥签名；未签名 / 钥匙不匹配 / 签名被篡改一律拒绝。`audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>` 是唯一显式初始化入口（生产初始化由 Master 执行）。无 PFX 时 audit 报 `policy-missing`，这是可选签名能力，不阻塞普通命令。
- **会话在场**：`aos session register|heartbeat|close|list` 记录 harness 会话，必须绑定已 start 的 issue/task，事件只写统一 ledger。
- **git 仓库必须走 issue tracker**（GitHub/GitLab）；**非 git 任务必须建本地 issue + PLAN**，DAG 能力一致。
- 没有 issue/PLAN 不得派发；派发必须带目标、边界、输入、验收、回传。
- **浏览器只用 Chrome**：需要浏览器的任务只允许 Google Chrome（含 headless）；禁止 Edge、Firefox、Safari、Brave、Chromium；Chrome 不可用则停止并报告。

## 安装

```powershell
git clone https://github.com/JomPan9621/AgentOS.git <homebase>\agentos
cd <homebase>\agentos
.\install.ps1 -Target all          # 装 skill + 规则块 + aos shim
.\install.ps1 -Target all -NoPath  # 不修改用户 PATH
```

安装只复制 `skills/agentos`，不会安装本仓之外的 skill；`drivercore/skills` 不随包，bootstrap 不要求额外 skill 目录。

验证：

```powershell
& <homebase>\agentos\bin\aos.ps1 doctor
```

`doctor` 需要 skill / 规则块 / PATH 已安装；在未安装的干净目录里运行会 exit 2，这是预期行为。

## 快速开始

```powershell
# 1. 判定 issue 源
aos issue detect -Repo <repo-path>

# 2. 建计划
aos plan new -Issue <id> -Title "<title>" -Repo <repo-path>

# 3. 算并发
aos plan validate -Plan <repo>\.agentos\plans\PLAN-<id>.md
aos plan graph    -Plan <repo>\.agentos\plans\PLAN-<id>.md

# 4. 按 wave 派发，写型节点开槽
aos wt new -Issue <id> -Slug <slug> -Repo <repo-path>

# 5. 生命周期（start 必须带 -Subagent；-Plan 会做 DAG 门禁）
aos track start  -Issue <id> -Task T1 -Owner codex -Plan <file> -Subagent worker-a
aos track review -Issue <id> -Task T1
aos track close  -Issue <id> -Task T1 -Plan <file>   # 自动对账 + 只读 audit/wt prune/hygiene
aos track block  -Issue <id> -Task T1 -Reason "waiting"

# 6. 会话在场（必须绑定已 start 的任务；只写统一 ledger）
aos session register  -Issue <id> -Task T1 -Role worker -Host <machine>
aos session heartbeat -Id <sid>
aos session close     -Id <sid>

# 7. 生成物收口 / 资源 / 审计
aos artifact path -Repo <repo> -Issue <id> -Task T1
aos plan resources -Plan <file>      # GPU 预检；不足 exit 2
aos room acquire <host> -Task T1 -Issue <id> -Gpus <n|all>
aos audit                            # 对账；-Backfill 只修复可证明缺口
aos wt prune                         # 只读盘点；安全候选才可手动 -Apply
aos hygiene                          # 只读检查；-Reap 需确认
```

## 命令速查

| 组 | 命令 |
|---|---|
| plan | `new` `validate` `graph` `next` `state` `show` `resources` |
| wt | `list` `new` `status` `prune` |
| issue | `detect` `new` `show` `list` |
| track | `start` `review` `close` `block` `abandon` `claim` `release` `handoff` `who` `list` `lost` |
| session | `register` `heartbeat` `close` `list` —— harness 会话在场，绑定任务，只写统一 ledger |
| room | `list` `show` `check` `acquire` `release` —— 远端资源与 GPU 子租约 |
| hygiene | `aos hygiene` —— 检测泄漏 helper 进程与机器压力，只读 |
| artifact | `path` `list` —— 生成物统一收口到固定根 |
| audit | `aos audit` —— PLAN / state / ledger / lease 对账；policy 必须签名；`-Backfill` 只修可证明的缺口 |
| snapshot | `aos snapshot` —— 单仓全量 JSON 状态（AI-native 主入口） |
| projects | `aos projects` —— 跨仓总览：默认扫当前目录，可 `-Root` |
| gc | `aos gc` —— 台账压缩 + 已完结计划归档（默认 dry-run；policy/session 事件永不压缩） |
| doctor | `aos doctor` —— 三 harness + scripts 统一性自检 |

## 版本

当前 **v0.3.0**。变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 仓库架构 + workspace 架构两张图、一次任务的完整路径 |
| [docs/drivercore.md](docs/drivercore.md) | **drivercore 架构边界**：bootstrap / harness / session / tasktrack / worktree，数据与 skill 边界 |
| [docs/data-model.md](docs/data-model.md) | **四类数据结构 + 能力×数据映射矩阵 + 不变量 + 解耦边界** |
| [docs/ai-native.md](docs/ai-native.md) | AI-native 五条硬契约（机器可读 / 快照 / 退出码 / 状态落文件 / 幂等） |
| [docs/output-contract.md](docs/output-contract.md) | 每个命令的输出形状与退出码契约 |
| [docs/lifecycle.md](docs/lifecycle.md) | 任务状态机、生命周期回收、**跨 harness 接管** |
| [docs/concurrency.md](docs/concurrency.md) | 并发判定三条、全局热点清单、并发上限 |
| [docs/roles.md](docs/roles.md) | Master / Sub-Master / Worker 与派发话术模板 |
| [docs/dispatch.md](docs/dispatch.md) | 派发协议：五要素、subagent 约束、证据回传与验收 |
| [docs/artifacts.md](docs/artifacts.md) | 生成物固定根、目录结构、路径安全 |
| [docs/resource.md](docs/resource.md) | 资源管理：worktree 槽位 + 机器租约 |
| [docs/resource-model.md](docs/resource-model.md) | GPU 精细资源模型（子租约 v2、needs 列、预检） |
| [docs/priority.md](docs/priority.md) | 优先级链、以及"为什么不做真 OS" |
| [docs/global-install.md](docs/global-install.md) | 全局安装：skill + 规则块 + PATH |
| [docs/add-harness.md](docs/add-harness.md) | 接入任意新 harness 的三步 |
| [docs/adapters.md](docs/adapters.md) | Claude / Codex / DSH 挂载点对照 |

## 目录

```
bin/         aos.ps1 (入口) + plan / wt / issue / track / session / room / audit / ledger / artifact
drivercore/  驱动职责层：bootstrap / harness / session / tasktrack / worktree（architecture-only）
schema/      任务节点与资源 JSON Schema
templates/   PLAN 模板
docs/        生命周期 / 并发 / 角色 / 适配器 / 资源模型 / drivercore
skills/      装到三工具的 skill 包（agentos 规程正文）
examples/    可用示例
tests/       selftest + artifact 测试
```

## 验证

```powershell
.\tests\selftest.ps1                        # 隔离沙箱，不碰真实仓库
.\tests\artifact.tests.ps1                  # 生成物固定根与路径安全
.\drivercore\tasktrack\tests\tasktrack.tests.ps1   # tasktrack 完成判定（55 条）
```

当前状态：`tests/selftest.ps1` **209/209 PASS**，`tests/artifact.tests.ps1` **24/24 PASS**，`drivercore/tasktrack/tests/tasktrack.tests.ps1` **55/55 PASS**（2026-11-12）。改动脚本后必须重跑。

## 平台

Windows / PowerShell 5.1+。所有路径使用 Windows 原生形式；`.ps1` 必须 UTF-8 with BOM。

## 安全

公开仓只含**功能**（脚本 / 模板 / skill / 文档），不含任何真实数据、主机名、IP、用户名、token 或密钥。
真实数据放 `<homebase>\data\`，生成物放 `<homebase>\devops\`，两者都永不入 git。详见 `SECURITY.md`。
