# 三工具挂载

同一套 `aos` 脚本 + 同一份 `skills/agentos`，装到三个位置：

| 工具 | Skill 挂载点 | 规则读取 |
|---|---|---|
| Claude Code | `~/.claude/skills/agentos` | `CLAUDE.md` → `@AGENTS.md` |
| Codex | `~/.codex/skills/agentos` | 原生读 `AGENTS.md` |
| DSH | `~/.dsh/skills/agentos`（可用 `-DshSkills` 覆盖） | 原生读 `AGENTS.md` |

## 安装

```powershell
# 全部
.\install.ps1 -Target all

# 单个
.\install.ps1 -Target codex

# 只更新 skill 内容，不动别的
.\install.ps1 -Target all -SkillsOnly
```

## PATH

`install.ps1` 默认**不改**用户 PATH。加 `-AddPath` 才会往 `$PROFILE` 追加一行。

不改 PATH 时的用法：

```powershell
& <homebase>\agentos\bin\aos.ps1 plan graph -Plan <file>
```

## 一致性保证

三个工具读的是**同一个 AGENTS.md 正本** + **同一份 skill 副本**，
所以规则与流程天然一致，不存在"Codex 一套、Claude 一套"。
