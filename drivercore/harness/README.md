# harness — Claude / Codex / DSH bootstrap、session 与 adapter

三个 harness 共用同一套 AgentOS 规程；本目录记录**适配面**、**bootstrap 入口**、**session 入口**与**安装模板**。
实际安装仍由仓库根 `install.ps1` 执行；本目录不写入 `<user-profile>`、不注册计划任务。

## Adapter 矩阵

| harness | skill 目录（用户级） | 规则文件（用户级） | bootstrap 入口 | session 入口 |
|---|---|---|---|---|
| Claude Code | `~/.claude/skills/agentos` | `~/.claude/CLAUDE.md`（managed block） | `drivercore/bootstrap/bootstrap.ps1` | `aos session register|heartbeat|close|list` |
| Codex | `~/.codex/skills/agentos` | `~/.codex/AGENTS.md`（managed block） | 同上 | 同上 |
| DSH | `~/.dsh/skills/agentos`（可用 `-DshSkills` 覆盖落点） | `~/.dsh/AGENTS.md`（managed block） | `drivercore/bootstrap/bootstrap.ps1`（Linux/macOS 用 `.sh`） | 同上 |

所有入口都由 `install.ps1` 的受管块维护；重复安装只替换 `agentos managed (global)` 块，不动用户手写内容。
公开版只安装 `skills/agentos`；`drivercore/skills` 不随包，额外 skill 目录可选且缺省不存在。

## bootstrap 入口

```powershell
# Windows（-DryRun 只预演，不实际安装）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\bootstrap\bootstrap.ps1 -DryRun

# Linux / macOS（POSIX 入口；需要 pwsh）
bash drivercore/bootstrap/bootstrap.sh --dry-run
```

- **唯一安装实现**是 `install.ps1`；bootstrap 只做前置检查、homebase 模板发布与安装调用，不复制第二套 skill 安装逻辑。
- `-DryRun` 不写 `<user-profile>`、不写 homebase、不改 PATH、不注册计划任务。
- homebase 模板（`AGENTS.template.md` / `CLAUDE.template.md`）只含占位符与规则骨架，不含真实主机 / 凭据 / 业务数据。

## session 入口

`aos session register|heartbeat|close|list`（实现 `bin/session.ps1`，事件只写统一 ledger）。
session 必须绑定已 `aos track start -Plan -Subagent` 的任务；role 可为 `master` / `sub-master` / `worker`。

```powershell
aos session register  -Issue <issue> -Task <task> -Role worker -Host <host>
aos session heartbeat -Id <sid>
aos session close     -Id <sid>
aos session list
```

## 模板与 manifest

- `AGENTS.template.md` — homebase 规则入口壳（`{{HOMEBASE}}` 占位符）；不复制 AgentOS 规程正文。
- `CLAUDE.template.md` — Claude Code 入口壳：`@AGENTS.md`。
- `adapters.json` — 机器可读的 adapter / bootstrap / session / skill 目标；`schema_version` / `installer` / claude+codex+dsh 三项是稳定契约，避免模板与安装面漂移。

## 边界

- 本目录只含功能与模板，不含真实主机名 / 凭据 / 机器特定信息。
- 安装是显式动作：`install.ps1` 未运行为默认状态；`aos doctor` 允许 skill hash 因未安装而失败，但 scripts 必须全过。
- drivercore 只保留一套安装实现：bootstrap 委托 `install.ps1`，不维护第二份安装逻辑。
