# drivercore — 驱动职责层架构

> v0.3.0 起，公开仓包含 drivercore 的**架构与实现**。本页说明它的边界、组成与运行假设。
> 公开版只含方法：**不含任何运行数据、真实主机名、凭据、内部或第三方 skill**。

## 1. 定位

AgentOS 是"以 skill 形式分发给 agent 的操作规程"。drivercore 是它的**驱动职责层**：
把 bootstrap、harness 适配、会话在场、长任务看门狗与 worktree 转发收口到一处，避免每个 harness 各自一套。

| 层 | 内容 | 是否公开 |
|---|---|---|
| 规程层 | `skills/agentos`、`bin/aos.ps1`、`docs/` | 是 |
| 驱动层 | `drivercore/` 的 bootstrap / harness / session / tasktrack / worktree | 是（仅架构与实现） |
| 额外 skill | `drivercore/skills/`（内部流程与第三方 skill） | **否，不随包** |
| 数据层 | `data/`、`devops/`（运行状态、租约、日志） | **否，永不入 git** |

## 2. 目录

```
drivercore/
├─ README.md
├─ bootstrap/          # 新机器 bootstrap（Windows / POSIX）
├─ harness/            # 三 harness 的 adapter 矩阵、模板与 manifest
├─ session/            # 会话在场模型说明
├─ tasktrack/          # 长任务看门狗 + 周期巡检 + 测试
└─ worktree/           # worktree 兼容转发器
```

## 3. tasktrack

**目标**：保证 Codex / Claude / DSH 子任务不会无声消失。

**双信号存活判定**：`pid 存活（含启动时间防 PID 复用，±5s 容差）` 与 `日志文件新鲜度` 交叉验证，不信任任何单一状态文件。

| verdict | 含义 | 动作 |
|---|---|---|
| `ok` | 进程在（身份匹配）且日志新鲜 | 正常 |
| `starting` | 启动宽限期内，或最近 2 分钟仍有日志 | 等待 |
| `STALLED?` | 进程在但日志静默超阈值（默认 30 分钟） | 人工判断 |
| `NO-LOG?` | 进程在但日志文件缺失 | 人工核查 |
| `DONE` | `running` 任务已检出完成信号，`watch` 自动置 `done` | 收口 |
| `LOST` | 进程消失/身份不符且无新日志，且无完成信号 | **必须处理** |

**完成信号**：

- 日志独立 token：`DONE`、`ROUND_DONE`、`DONE_T<数字>`；`DONE_TIMEOUT`、`DONE_TODO`、`DONE_T<task>_FAILED` 不算；否定词只在紧邻标记时生效（`NOT DONE` 不算，`no errors, DONE_T1` 算）。
- wrapper 退出码：`register` 把命令正文写入 `<state>\<id>.run.ps1`（UTF-8 BOM），用 `powershell.exe -File` 执行；真实退出码落 `<state>\<id>.exit`，`watch` 仅在 0 时判完成。
- 完成信号优先于存活判定；非 0 退出且无日志标记仍按 `LOST` 处理。

**状态落点**：`<homebase>\devops\tasktrack\state\`（生成物层，永不入 git）；homebase 优先取 `AGENTOS_HOME`，缺省从 `drivercore/tasktrack` 向上三级推导；`-StateDir` 可显式覆盖。

**周期巡检**：`install-watch-task.ps1` 逐机显式注册计划任务（默认名 `agentos-tasktrack-watch`，可用 `-TaskName` 覆盖），每 10 分钟执行 `tasktrack.ps1 watch`；`-DryRun` 只打印，不写文件、不注册。

## 4. bootstrap

`drivercore/bootstrap/bootstrap.ps1`（Windows）与 `bootstrap.sh`（POSIX，需要 pwsh）只做三件事：

1. 前置检查：`git` + 至少一个 harness CLI（Claude / Codex / DSH）；`-DryRun` 缺工具只告警。
2. 发布 homebase 模板：`AGENTS.template.md` / `CLAUDE.template.md`（`{{HOMEBASE}}` 占位符，已存在时需 `-Force` 覆盖）。
3. 委托安装：调用仓库根 `install.ps1 -Target all`；bootstrap 不复制第二套安装逻辑。

默认 homebase = 仓库父目录；`-HomeBase` 或 `AGENTOS_HOME` 可覆盖。`-DryRun` 不写用户目录、homebase 或 PATH，不注册计划任务。

## 5. harness 适配

| harness | skill 目录（用户级） | 规则文件（用户级） | 规则模式 |
|---|---|---|---|
| Claude Code | `~/.claude/skills/agentos` | `~/.claude/CLAUDE.md` | managed block |
| Codex | `~/.codex/skills/agentos` | `~/.codex/AGENTS.md` | managed block |
| DSH | `~/.dsh/skills/agentos`（`-DshSkills` 可覆盖） | `~/.dsh/AGENTS.md` | managed block |

`drivercore/harness/adapters.json` 是机器可读 manifest：`schema_version`、`installer`、agents（claude / codex / dsh）、templates 与 skills。公开版 `skills.names` 只有 `agentos`。

## 6. session

`aos session register|heartbeat|close|list` 记录**哪个 harness 会话（role）在哪个 host 上执行哪个已跟踪任务**。

- 事件只写统一 ledger（`<homebase>\devops\agentos\ledger.jsonl`），不建 `sessions.json`。
- 必须绑定已 `aos track start -Plan -Subagent` 的任务；close 幂等。
- `track` 是任务生命周期，`session` 是执行者在场；两者通过 `issue+task` 关联，互不替代。

## 7. worktree

唯一实现是 `bin/wt.ps1`；`drivercore/worktree/wt.ps1` 只是兼容转发器（`-RepoRoot` → `-Repo`），参数原样转发，不维护第二份实现。

回收候选必须同时满足：路径在项目根下、非主工作区、tracked/untracked/ignored 全零、HEAD 已进目标 ref、分支非 detached。`prune` 默认 dry-run，不 fetch、不删远端分支、不强制删除。

## 8. 数据边界

| 类别 | 落点 | 是否入 git |
|---|---|---|
| 代码 / 模板 / 文档 | 本仓 | 是 |
| 真实机器清单 | `<homebase>\data\agentos\hosts.json` | 否 |
| ledger / policy 缓存 | `<homebase>\devops\agentos\` | 否 |
| tasktrack 状态 / 日志 / `.run.ps1` | `<homebase>\devops\tasktrack\` | 否 |
| 租约 | `<homebase>\devops\agentos\leases\` | 否 |
| 生成物 | `<homebase>\devops\agentos\artifacts\` | 否 |

公开树不含数据、日志、租约、PFX、任务状态或真实值；真实值只以运行时推导或占位符（`<homebase>` / `<repo>` / `<host>`）出现。

## 9. 验证

```powershell
.\tests\selftest.ps1                                # 公开 layout + drivercore 布局/dry-run
.\tests\artifact.tests.ps1                          # 生成物固定根与路径安全
.\drivercore\tasktrack\tests\tasktrack.tests.ps1    # tasktrack 完成判定（55 条）
.\bin\aos.ps1 version                               # agentos 0.3.0
```
