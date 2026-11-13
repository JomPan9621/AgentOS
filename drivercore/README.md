# drivercore — AgentOS 驱动职责层

`drivercore/` 是 AgentOS 的驱动职责层：把"怎么驱动 agent"收口到一处。
公开版只含**架构与实现**：bootstrap、harness 适配模板、session 模型、tasktrack 看门狗与 worktree 转发器；
**不含任何运行数据、真实主机信息、凭据或内部/第三方 skill**。

## 目录

| 目录 | 职责 | 唯一实现 / 入口 |
|---|---|---|
| `bootstrap/` | 新机器 bootstrap：Windows `bootstrap.ps1` + POSIX `bootstrap.sh`（需要 pwsh） | 委托 `install.ps1`；不复制第二套安装逻辑 |
| `tasktrack/` | 长任务看门狗：register / 双信号存活 / 完成判定 / 失联告警 / 周期巡检接入 | `tasktrack.ps1`；巡检 `install-watch-task.ps1` |
| `session/` | harness 会话在场模型：register / heartbeat / close / list | `bin/session.ps1`（事件只写统一 ledger） |
| `harness/` | Claude / Codex / DSH 的 bootstrap、session、adapter 说明与安装模板 | `install.ps1`（安装唯一入口） |
| `worktree/` | worktree 兼容转发器 | `bin/wt.ps1`（`drivercore/worktree/wt.ps1` 仅转发） |

公开版不包含 `drivercore/skills/`：内部与第三方 skill 不随包；安装只复制 `skills/agentos`。

## 单一来源（去重边界）

- **ledger**：`bin/ledger.ps1` 是任务 / policy / session 事件的唯一解析与写入模型；`plan` / `track` / `audit` / `snapshot` / `projects` / `gc` 均复用该模型。
- **policy**：append-only 于 ledger，PFX 签名；`subagent-policy.json` 只是缓存，不是权威。
- **session**：append-only 于 ledger（`session-register|heartbeat|close`），不另建状态文件。
- **tasktrack**：`drivercore/tasktrack/tasktrack.ps1` 是本仓唯一维护实现；不要在 drivercore 之外再建第二份 tasktrack。
- **worktree**：唯一实现 `bin/wt.ps1`。`drivercore/worktree/wt.ps1` 只是兼容转发器，参数原样转发（`-RepoRoot` → `-Repo`），不维护第二份实现。
- **bootstrap / install**：唯一安装实现 `install.ps1`。`drivercore/bootstrap/bootstrap.ps1` 只做前置检查、homebase 模板发布与安装调用；`bootstrap.sh` 是 POSIX 入口，转译到同一个 ps1。
- **skills**：`skills/agentos/SKILL.md` 是唯一规程正文；公开版不随包 `drivercore/skills`。
- **host 解析**：`audit` 只认 tasktrack 显式 `host`，缺失时用数据层 `<homebase>\data\agentos\hosts.json` 的别名 / hostname 匹配；代码不含任何机器名前缀，未知 host 报 `tasktrack-no-host`。

## 状态与数据边界

- 代码在本仓；运行状态只落在生成物层，永不入 git：
  - `<homebase>\devops\agentos\ledger.jsonl`
  - `<homebase>\devops\agentos\subagent-policy.json`（缓存）
  - `<homebase>\devops\tasktrack\state\`
  - `<homebase>\devops\tasktrack\watch.log`
  - `<homebase>\devops\agentos\leases\`
- 本层只含功能与模板：**不含真实主机名 / 凭据 / 业务数据**；真实值只进 `<homebase>\data\`（永不入 git）。

## 安装与巡检（显式动作）

本仓不在任务执行中安装或注册计划任务；由使用者逐机显式执行：

```powershell
# 全局安装（skill + 规则块 + PATH）；bootstrap 是同一条安装路径的入口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Force

# 只预演 bootstrap，不写用户主目录 / homebase / PATH
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\bootstrap\bootstrap.ps1 -DryRun

# tasktrack 周期巡检（逐机、手动；-DryRun 只打印）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\install-watch-task.ps1 -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\install-watch-task.ps1
```

计划任务名默认 `agentos-tasktrack-watch`，可用 `-TaskName` 覆盖；脚本不自动注册，需逐机显式执行。

## 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\selftest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\artifact.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\tests\tasktrack.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File bin\aos.ps1 doctor
```

架构边界与设计细节见 [docs/drivercore.md](../docs/drivercore.md)。
