# AGENTS.md — homebase 规则（入口壳）

> 本文件由 `drivercore/bootstrap/bootstrap.ps1` 依据本模板生成，是**homebase 规则的唯一正文**，所有 agent（Claude Code / Codex / DSH）共用。
> 规则正文不在本模板里展开：AgentOS 规程是唯一来源（`{{HOMEBASE}}\agentos\skills\agentos\SKILL.md`）。
> Claude Code 经同目录 `CLAUDE.md` 的 `@AGENTS.md` 导入读取；Codex / DSH 原生读取本文件。

## 系统：AgentOS（最高权限）

**本机的执行系统是 AgentOS** —— `{{HOMEBASE}}\agentos`。

- 一切 agent 在任何目录、任何 harness 下，都由 AgentOS 驱动，不允许各自一套习惯。
- 唯一可临时覆盖它的是**用户直接指令**；覆盖时须在任务记录中写明理由。
- 系统以 skill 形式注入，不做内核拦截；绕过即违规，由 `aos doctor` 与 `tests/selftest.ps1` 裁决。

## 最高优先级规则（不可违反）

### 1. 工作区域锚定
- **本目录 `{{HOMEBASE}}` 是工作根目录，所有工作必须以它为根。**
- 不得擅自跳到 `{{HOMEBASE}}` 之外创建、修改、删除文件。
- 唯一例外：用户明确指示或同意操作特定外部路径时，仅限该范围，事后立即回到根目录视角。

### 2. 功能与数据解耦（铁律）
- 仓库只含功能（模板 / 脚本 / skill / 文档），绝不包含真实主机名、IP、用户名、密钥、token、机器特定或业务信息。
- 数据一律放 `{{HOMEBASE}}\data`（生成物放 `{{HOMEBASE}}\devops`），永不入 git。
- 写文件前自检：含真实值 → 改占位符，真实值进数据层。

### 3. 信息安全：受限信息不外流
- 受限 / 敏感信息（内部资料、未公开架构、凭据等）绝不外流；不写入公网位置、不粘贴进公网工具或在线服务。
- 含真实值的仓库只推送到你信任的私有远端；禁止把真实值推送到任何公网平台。
- MCP 政策：除搜索类外，所有 MCP 必须本地部署。

### 4. 执行规程（AgentOS 运行法）
- 开工前取快照：`aos snapshot -Repo <repo>`；`attention` 非空先处理。
- 非单步任务先出 `PLAN-<issue>.md`，并通过 `aos plan validate`。
- 并发由 `aos plan graph` 的 wave 决定；写型任务独占 worktree（`aos wt new`，唯一实现 `bin/wt.ps1`）。
- 任务全程写生命周期：`aos track start|review|close`；状态落文件，不认对话里的“做完了”。
- 会话在场：`aos session register|heartbeat|close|list`，必须绑定已 start 的任务。
- 收工回收：`aos wt prune` 只读盘点；安全候选才可 `-Apply`，dirty 一律保留。

## 目录结构

- `agentos/` — 操作规程 + 驱动层：`skills/agentos`、`bin/aos.ps1`、`drivercore/`。
- `data/` — 数据层：真实机器清单（`data/agentos/hosts.json`）等，永不入 git。
- `project/` — 业务层：项目代码（各自独立 git）。
- `devops/` — 本机生成物与运维现场（不入 git）。

## 生成物收口（artifact）

- harness 生成的图片、截图、HTML、图表、报告、trace 等**一律写入固定根**：`{{HOMEBASE}}\devops\agentos\artifacts\<repo>\<issue>\<task>\<run-id>\`。
- 固定根内按 `screenshots\` / `html\` / `reports\` / `traces\` 分类；`run-id` 默认时间戳。优先用 `aos artifact path -Repo <repo> -Issue <n> -Task <t>` 生成，不要手拼路径。
- **项目真实源码与交付 HTML 仍留在各自仓库**：固定根只收口生成物，不存放需要入 git 的交付内容。
- **生成物不得写进 AgentOS 或项目 git 仓库**；仓库内不出现截图、报告、trace 等运行产物。
- 回看生成物用 `aos artifact list`（只读）；历史散落文件不自动搬迁，先人工确认再收口。

## 远端资源管理（AgentOS room）

- `aos room list|show|check|acquire|release`；真实机器清单 `data/agentos/hosts.json`；租约状态 `devops/agentos/leases/`（生成物）。
- GPU 子租约：`aos room acquire <host> -Task <task> -Issue <issue> -Gpus <n|all>`；同一 host 可多个不重叠 allocation；旧 v1 单租约兼容。
- GPU 数量/租约是硬约束；OS/runtime/driver 只做 `room show` / `plan resources` / `track start` 的软感知，不匹配只 warning。
- `aos plan resources -PLAN <PLAN>` 预检；`aos track start -Plan -Subagent` 必须匹配 allocation。

## Worktree 生命周期

- 任务必须绑定 issue、branch 和独立 worktree；验收后 `aos wt prune` 盘点。
- 唯一实现：`{{HOMEBASE}}\agentos\bin\wt.ps1`；`drivercore/worktree/wt.ps1` 仅为兼容转发器。
- 只有路径在项目根下、非主工作区、tracked/untracked/ignored 全干净、HEAD 已入目标 ref、分支非 detached 同时满足，才允许 `-Apply`。
- dirty / 未合入 / 用途不明的 worktree 一律保留，不得用 stash、reset 或历史改写掩盖现场。

## 协作模型

- agent 固定：Claude Code / Codex / DSH；角色不绑定工具，都可任 Master / Sub-Master / Worker。
- Master 只做用户交互、规划、派发、验收；每个 PLAN 节点由 subagent 执行，同 wave 并行。
- 委派边界：不授权 push、deploy、破坏性清理（除非用户明确指示）。

## 子任务跟踪铁律

- 跨会话 / 长时子任务必须先登记：`{{HOMEBASE}}\agentos\drivercore\tasktrack\tasktrack.ps1 register|adopt`，并带 `-Issue` / `-Task` / `-Host`。
- **禁止在 subagent 内发起长任务 / 后台任务**（生命周期结束会连带回收进程树）。
- `LOST` 在销账前持续告警：必须立即处理并 `done` 销账。
- 周期巡检由 `drivercore/tasktrack/install-watch-task.ps1` 显式注册（逐机、不自动）。
