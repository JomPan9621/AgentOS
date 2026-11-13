# 三工具挂载

同一套 `aos` 脚本 + 同一份 `skills/agentos`，装到三个位置：

| 工具 | Skill 挂载点 | 规则读取 | session |
|---|---|---|---|
| Claude Code | `~/.claude/skills/agentos` | `CLAUDE.md` → `@AGENTS.md` | `aos session register|heartbeat|close|list` |
| Codex | `~/.codex/skills/agentos` | 原生读 `AGENTS.md` | 同上 |
| DSH | `~/.dsh/skills/agentos`（可用 `-DshSkills` 覆盖落点） | 原生读 `AGENTS.md` | 同上 |

## 派发是强制的

无论哪个 harness，每个 PLAN 节点必须由一个 subagent 执行，同一 wave 必须并行；harness 只决定机制（Claude Code：Task/Agent；Codex：本地并行执行；DSH：Agent Teams）。Master 只与用户交互、规划、派发、验收，不执行任务。

## 安装

```powershell
# 全部（只安装 skills/agentos）
.\install.ps1 -Target all

# 单个
.\install.ps1 -Target codex

# 只预演，不写用户目录
.\install.ps1 -Target all -DryRun
```

安装统一由 `install.ps1` 执行；它只复制 `skills/agentos`，不会安装本仓之外的 skill。

## PATH

`install.ps1` 默认把 `aos` shim 写入 `~/.agentos\bin`，并把该目录追加到用户 PATH（新 shell 生效）。
加 `-NoPath` 才会跳过；不改 PATH 时可直接用：

```powershell
& <homebase>\agentos\bin\aos.ps1 plan graph -Plan <file>
```

## 一致性保证

三个工具读的是**同一个 AGENTS.md 正本** + **同一份 skill 副本**，
所以规则与流程天然一致，不存在"Codex 一套、Claude 一套"。
