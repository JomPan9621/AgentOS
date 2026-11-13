# CHANGELOG

## v0.2.0 — 2026-11-13

公开版功能增量。v0.2.0 是纯功能子集：不含任何业务数据、真实主机清单或内部运行架构。

### 新增能力

- **生成物收口**：`aos artifact path|list` —— harness 生成的截图 / HTML / 报告 / trace 统一落到固定根，仓库不污染；路径穿越被拒绝。
- **会话在场**：`aos session register|heartbeat|close|list` —— 会话必须绑定已 start 的 issue/task，事件只写统一 ledger。
- **统一台账**：`bin/ledger.ps1` —— task / policy / session 的唯一解析与写入模型；`track`、`audit`、`snapshot`、`projects`、`gc` 复用。
- **审计与对账**：`aos audit` —— PLAN / state / ledger / lease 对账；`subagent-missing`、`-Backfill`、可选 PFX 签名 policy；`track close -Plan` 自动对账并消费只读 `reclaim`。
- **GPU 子租约**：`aos room` v2（`task + issue` 身份、`-Gpus <n|all>`、不重叠 allocation）与 `aos plan resources` 预检；真实主机清单由用户数据层提供，仓库不含任何机器名。
- **track 强化**：DAG 门禁、`-Subagent` 归属强制、`block` / `abandon`、`claim` / `release` / `handoff`、close 自动对账 + 只读 audit / wt prune / hygiene。
- **snapshot / projects / gc 增量**：sessions / resources 汇总、session 回归、policy 与 session 事件永不压缩。
- **文档**：新增 `docs/artifacts.md`、`docs/dispatch.md`、`docs/resource-model.md`；更新 architecture / lifecycle / output-contract / adapters / global-install 等。

### 契约

| 结构 | 落点 | 说明 |
|---|---|---|
| PLAN | `<repo>/.agentos/plans/PLAN-<issue>.md` | 任务表（8 字段固定，可选第 9 列 `needs`） |
| STATE | `<repo>/.agentos/plans/*.state.json` | 节点状态与归属 |
| LEDGER | `<homebase>/devops/agentos/ledger.jsonl` | 追加式审计流水 |
| WORKTREE | `<repo-parent>/<repo>-<issue>-<slug>` | 写型任务独占槽位 |
| ARTIFACT | `<homebase>/devops/agentos/artifacts/<repo>/<issue>/<task>/<run-id>/` | 生成物固定根 |

### 质量

- 自检套件：`tests/selftest.ps1` **202/202 PASS** + `tests/artifact.tests.ps1` **24/24 PASS**（2026-11-13），全部在 `%TEMP%` 隔离沙箱运行，不写真实用户目录。
- 版本统一 `0.2.0`；`aos doctor` 只检查公开 layout（scripts / skill / rules / shim / PATH）。
- 平台：Windows / PowerShell 5.1+（`.ps1` 必须 UTF-8 with BOM）。

### 安装

```powershell
git clone https://github.com/JomPan9621/AgentOS.git <homebase>\agentos
cd <homebase>\agentos
.\install.ps1 -Target all          # skill + 全局规则块 + aos shim
.\install.ps1 -Target all -NoPath  # 不修改用户 PATH
```

验证：`aos version`（应 `agentos 0.2.0`）与 `.\tests\selftest.ps1`。

## v0.1.0 — 2026-11-06

首个公开版本。AgentOS 是**基础 infra**：为 Claude Code / Codex / DSH 三个 agent 提供统一的协作方法论。

### 核心能力

- **计划与 DAG**：`aos plan new|validate|graph|next|state|show` —— 任务图、拓扑校验、并发 wave 计算
- **worktree 资源隔离**：`aos wt list|new|status|prune` —— 写型任务独占槽位，上限 5，三重安全回收边界
- **任务生命周期**：`aos track start|review|close|list|lost` —— 状态落文件，不依赖对话
- **跨 harness 接管**：`aos track claim|release|handoff|who` —— 任务归属显式记录，可交接、可强接、可追溯
- **互相感知**：`aos snapshot`（单仓全量）/ `aos projects`（跨仓总览）
- **生命周期回收**：`aos gc` —— 台账压缩 + 已完结计划归档，默认 dry-run
- **统一性判据**：`aos doctor` —— 9 项检查，覆盖三个 harness 的 skill / 规则块 / PATH
- **issue 源解析**：`aos issue detect|new|show|list` —— GitHub / GitLab / 本地兜底

### 设计原则

1. **AI-native**：命令默认输出 JSON，`-Human` 才出表格；退出码 0/1/2 语义严格
2. **与业务数据解耦**：仓库内零业务数据；契约形状归我们，实例由业务仓自带
3. **交付的是方法，不是环境**：homebase 由 `AGENTOS_HOME` 或本仓位置推导，仓库路径由 `-Repo` 传入，GitLab 主机由 `AGENTOS_GITLAB_HOSTS` 提供
4. **harness 无关**：新 harness 只需 `-ExtraRules` 注入同一份规程

### 契约

| 结构 | 落点 | 说明 |
|---|---|---|
| PLAN | `<repo>/.agentos/plans/PLAN-<issue>.md` | 任务表（8 字段固定） |
| STATE | `<repo>/.agentos/plans/*.state.json` | 节点状态与归属 |
| LEDGER | `<AGENTOS_HOME>/devops/agentos/ledger.jsonl` | 追加式审计流水 |
| WORKTREE | `<repo-parent>/<repo>-<issue>-<slug>` | 写型任务独占槽位 |

### 质量

- 自检套件：`tests/selftest.ps1`，隔离沙箱，不污染生产台账
- 统一性判据：`aos doctor`，**9 项**，三 harness 全绿
- 平台：Windows / PowerShell 5.1+（`.ps1` 必须 UTF-8 with BOM）

### 文档

起点 `docs/architecture.md`（对外介绍版），索引见 README。

### 安装

```powershell
git clone https://github.com/JomPan9621/AgentOS.git <homebase>/agentos
cd <homebase>/agentos
.\install.ps1 -Target all -Force     # skill + 全局规则块
.\install.ps1 -Target all -NoPath    # 可选：不修改 PATH
```

验证：`aos doctor`（应 `ok=true`）与 `.\tests\selftest.ps1`。
