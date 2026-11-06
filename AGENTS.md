# AGENTS.md — AgentOS 规则正本

> 本文件是 AgentOS 仓库的唯一规则正文，所有 agent（Claude Code / Codex / DSH）共用。
> Claude Code 经同目录 `CLAUDE.md` 的 `@AGENTS.md` 导入；Codex 原生读取本文件。

## 定位

AgentOS 是 **本机最高权限的执行系统**，以 skill 形式分发给所有 agent。

它不是真实的操作系统：没有内核、没有守护进程、不拦截系统调用、不做 PATH 强制。
它靠 `skills/agentos/SKILL.md` 注入 Claude Code / Codex / DSH，**效力来自"agent 被要求遵守"**。

配套脚本（`bin/aos.ps1`）是给规程用的工具，不是强制层——agent 可以选择不用，那就是违规，不是被拦截。

优先级链见 `docs/priority.md`：**AgentOS（系统层）** > 用户直接指令（唯一可临时覆盖） > 根据地三条铁律 > 本规程 > agent 默认习惯。

它只包含**功能**（脚本 / 模板 / skill / 文档），不含任何数据、主机名、密钥。

**交付的是方法，不是环境**：根据地根由 `AGENTOS_HOME` 或本仓位置推导，仓库路径由 `-Repo` 传入，GitLab 主机由 `AGENTOS_GITLAB_HOSTS` 提供。放到任何机器、任何路径都能自适配。

## 第一原则：与业务数据解耦

**AgentOS 是基础 infra，不是业务系统。仓库内零业务数据。**

- **不允许出现**：任何项目名、仓名、issue 号、设备型号、硬件架构、公司产品名、业务路径（如 `<homebase>\project\<某仓>`）。
- **只允许出现**：契约形状（字段名、类型、枚举）、占位符（`<repo>` `<issue>` `<slug>` `<device>`）、本仓库自身的远端地址。
- 业务数据由业务仓通过 `.agentos/` 目录**自带**；AgentOS 只读取契约，不拥有内容。
- 脚本里**禁止硬编码业务默认值**；需要路径时由调用方传 `-Repo`，或取当前工作目录。
- 环境相关值（如自建 GitLab 主机）走环境变量（`AGENTOS_GITLAB_HOSTS`），不写死。

判据：`aos doctor` 通过 + 用业务关键词扫描仓库应为零命中。

## 第一宗旨：AI-native

**所有产出以 agent 为第一消费者。** 人读的格式是附加能力，不是默认。

1. **机器可读优先**：命令默认输出单个 JSON 到 stdout，不掺日志/颜色/进度；人类渲染走 `-Human`
2. **单一快照入口**：agent 用 `aos snapshot` 一次拿全上下文，不靠连续调用拼装
3. **严格退出码**：0 成功 / 1 错误 / 2 需治理；不允许"成功但有问题"
4. **状态放文件不放对话**：PLAN + state.json + ledger 三处可恢复
5. **幂等可重入**：agent 重试必须安全

细则：`docs/ai-native.md`；输出契约：`docs/output-contract.md`

## 三条硬规则

1. **计划先行**：任何非单步任务必须先产出 `PLAN-<issue>.md`，不得边想边干。
2. **并发由 DAG 决定**：并行不是人拍的，是从 `deps` / `touches` / `resource` 三个字段算出来的。**AgentOS 给边界（哪些能并行），harness 给实现（用 Agent Teams / subagent / 自研机制跑到极致）**。
3. **写型任务必须独占 worktree**，由 Master 派发前创建、验收后回收；Worker 不得自建 worktree。

## Issue 源

| 仓库类型 | 判定 | Issue 来源 |
|---|---|---|
| GitHub | remote 含 `github.com` | **必须**走 GitHub issue（`gh` CLI 或 API） |
| GitLab | remote 含 `gitlab`，或命中 `AGENTOS_GITLAB_HOSTS` 环境变量 | GitLab issue API |
| 其他 / 无远端 | 兜底 | 本地 `.agentos/issues/ISSUE-<id>.md` |

## 角色

Master（人操作的窗口）/ Sub-Master（可递归）/ Worker。**角色不是工具**：Claude、Codex、DSH 都可任任一角色；唯一约束是**只有 Master 能派发**。

递归深度 ≤ 3；Sub-Master 必须同步等待其子代理，禁止 fire-and-forget。

**隔离原则（最高优先）**：harness 正在执行的任务是各自私域，默认**互不可干扰**——不改对方文件、不抢对方任务、不碰对方进程；超时也只报告不接管。跨 harness 操作必须由用户明确授权（`track claim/handoff -AuthorizedBy`）。

**harness 内部能力不建模**：Agent Teams、子代理池、任务板、UI 会话、审批流都属于 harness 自己的事，AgentOS 只管「哪个 harness 认领了哪个 task、什么时候销账」。

## 目录

- `bin/` — 可执行脚本（`aos.ps1` 是统一入口）
- `schema/` — 数据结构定义
- `templates/` — PLAN / 规则片段模板
- `docs/` — 生命周期、并发、角色、适配器说明
- `skills/` — 供三工具安装的 skill 包
- `tests/` — 自检套件（`selftest.ps1`，44 用例）

## 开发

- 平台：Windows / PowerShell 5.1+（宿主默认 5.1，禁用 PS7-only 特性如 `-AsHashtable`）
- **所有 `.ps1` 必须存为 UTF-8 with BOM**——PS5.1 对无 BOM 文件按 GBK 解码，中文会变乱码并导致语法错误
- 改动脚本后必须跑 `bin/aos.ps1 doctor`
- 任何脚本改动后必须跑 `tests/selftest.ps1`，44 个用例全绿才允许提交
