# AgentOS

**以 skill 形式分发给 agent 的操作规程。**

它不是真实的操作系统——没有内核、没有守护进程、不拦截任何命令。
它靠 `skills/agentos/SKILL.md` 注入 **Claude Code / Codex / DSH**，效力来自"agent 被要求遵守"。
配套脚本 `bin/aos.ps1` 是规程用的工具；agent 绕过去 = 违规，不是被拦截。

优先级：用户指令 > 根据地最高优先级规则 > **本规程** > agent 默认习惯。

## 解决什么

| 痛点 | 现状 | AgentOS 的做法 |
|---|---|---|
| worktree 越开越多、用完不回收 | 一个仓挂过 45 个 worktree | 写型任务向 Master 申请槽位，验收后 `aos wt prune` 回收 |
| 并行靠感觉 | 想到哪干到哪 | `aos plan graph` 从任务表算出 wave |
| 任务失联 | 不知道子代理干到哪 | `aos track` 记录生命周期，`lost` 检陈旧任务 |
| 三个工具三套规则 | 各自一套习惯 | 同一份 `AGENTS.md` 正本 + 同一份 skill |

## 这是一套方法论

AgentOS 交付的是**方法**，不是环境。

- **不写死环境**：根据地根目录由 `AGENTOS_HOME` 或「本仓所在位置的父目录」推导；仓库路径由 `-Repo` 传入；GitLab 主机由 `AGENTOS_GITLAB_HOSTS` 提供。
- **不携带业务**：仓库内零项目名、零仓名、零 issue 号、零设备型号。
- **形状即契约**：AgentOS 定义 PLAN / STATE / LEDGER / WORKTREE 四种契约，业务仓自己提供实例。

所以它可以被放在任何机器、任何路径、服务任何项目——**agent 按自己的环境自动适配**。

## AI-native 契约（第一宗旨）

**所有产出以 agent 为第一消费者。**

```powershell
aos snapshot -Repo <path> -Plan <file> | ConvertFrom-Json
```

一次调用返回 `repo` / `plan` / `schedule` / `worktrees` / `ledger` / `attention`。
`attention` 非空即刻停下处理；`exit 2` 表示需要治理。
所有命令默认 JSON，人类表格是可选的 `-Human`。

详见 [docs/ai-native.md](docs/ai-native.md)、[docs/output-contract.md](docs/output-contract.md)。

## 核心概念

```
人 ─▸ Master（规划/派发/验收）
        │  产出 PLAN（任务表）
        ▼
   ┌────┴────┐
 write      read           ← DAG 算出的并发 wave
 (独占       (共享
  worktree)   工作区)
        │
        └─ Sub-Master（可递归，深度 ≤ 3）
                │
                ▼
        验收 → aos wt prune → 槽位回收
```

## 安装

```powershell
git clone https://github.com/JomPan9621/AgentOS.git <homebase>\agentos
cd <homebase>\agentos
.\install.ps1 -Target all          # 装 skill 到 Claude / Codex / DSH
.\install.ps1 -Target all -AddPath # 额外装 aos 别名
```

验证：

```powershell
& <homebase>\agentos\bin\aos.ps1 doctor
```

## 快速开始

```powershell
# 1. 判定 issue 源
aos issue detect -Repo <repo-path>

# 2. 建计划
aos plan new -Issue <id> -Title "<title>" -Repo <repo-path>

# 3. 算并发
aos plan validate -Plan <repo>\.agentos\plans\PLAN-271.md
aos plan graph    -Plan <repo>\.agentos\plans\PLAN-271.md

# 4. 按 wave 派发，写型节点开槽
aos wt new -Issue <id> -Slug <slug> -Repo <repo-path>

# 5. 生命周期
aos track start  -Issue 271 -Task T1 -Owner codex
aos track close  -Issue 271 -Task T1

# 6. 回收
aos wt prune        # 只读
aos wt prune -Apply # 只删安全候选
```

## 命令速查

| 组 | 命令 |
|---|---|
| plan | `new` `validate` `graph` `next` `state` `show` |
| wt | `list` `new` `status` `prune` |
| issue | `detect` `new` `show` `list` |
| track | `start` `review` `close` `claim` `release` `handoff` `who` `list` `lost` |
| snapshot | `aos snapshot` —— 单仓全量 JSON 状态（AI-native 主入口） |
| projects | `aos projects` —— 跨仓总览：计划/在飞/worktree/issue 源 |
| gc | `aos gc` —— 台账压缩 + 已完结计划归档（默认 dry-run） |
| doctor | `aos doctor` —— 三 harness 统一性自检（9 项） |

## 版本

当前 **v0.1.0**（首个公开版）。变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 仓库架构 + workspace 架构两张图、一次任务的完整路径 |
| [docs/data-model.md](docs/data-model.md) | **四类数据结构 + 能力×数据映射矩阵 + 不变量 + 解耦边界** |
| [docs/ai-native.md](docs/ai-native.md) | AI-native 五条硬契约（机器可读 / 快照 / 退出码 / 状态落文件 / 幂等） |
| [docs/output-contract.md](docs/output-contract.md) | 每个命令的输出形状与退出码契约 |
| [docs/lifecycle.md](docs/lifecycle.md) | 任务状态机、生命周期回收、**跨 harness 接管** |
| [docs/concurrency.md](docs/concurrency.md) | 并发判定三条、全局热点清单、并发上限 |
| [docs/roles.md](docs/roles.md) | Master / Sub-Master / Worker 与派发话术模板 |
| [docs/resource.md](docs/resource.md) | 资源管理：worktree 槽位 + 机器租约 |
| [docs/priority.md](docs/priority.md) | 优先级链、以及"为什么不做真 OS" |
| [docs/global-install.md](docs/global-install.md) | 全局安装：skill + 规则块 + PATH |
| [docs/add-harness.md](docs/add-harness.md) | 接入任意新 harness 的三步 |
| [docs/adapters.md](docs/adapters.md) | Claude / Codex / DSH 挂载点对照 |

## 目录

```
bin/         aos.ps1 (入口) + plan / wt / issue / track
schema/      任务节点 JSON Schema
templates/   PLAN 模板
docs/        生命周期 / 并发 / 角色 / 适配器
skills/      装到三工具的 skill 包
examples/    可用示例
```

## 验证

```powershell
.\tests\selftest.ps1        # 42 个用例，隔离沙箱，不碰真实仓库
```

当前状态：**44/44 PASS**（2026-11-06）。改动脚本后必须重跑。

## 平台

Windows / PowerShell 7。所有路径使用 Windows 原生形式。

## 安全

仓库内只含**功能**（脚本 / 模板 / skill / 文档），不含任何真实数据。
仓库内只含功能，真实数据放 `<homebase>\data\`。详见 `SECURITY.md`。
