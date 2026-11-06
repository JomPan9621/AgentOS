# 接入一个新的 harness

AgentOS 的规则文本与 skill 内容是**同一份**，与 harness 无关。
接一个新 harness 只需要三步，不改任何脚本逻辑。

## 三步

### 1. 找到它的规则入口

| harness | 规则入口 | 备注 |
|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` | 内建注入 |
| Codex | `~/.codex/AGENTS.md` | 内建注入 |
| DSH | `~/.dsh/AGENTS.md` | 内建注入 |
| 其他 / 未来 harness | 它自己的用户级指令文件 | 用 `-ExtraRules` 注入 |

如果它读的是**仓库内** `AGENTS.md`，那么它天然就吃到了（所有工程仓的 `AGENTS.md` 都带 §4 执行规程），无需额外注入。

### 2. 注入规则块

```powershell
.\install.ps1 -Target all -NoPath -ExtraRules "$env:USERPROFILE\.newharness\INSTRUCTIONS.md"
```

会写入同一段受管块（`<!-- >>> agentos managed (global) >>> -->` 包裹），
与三个内建 harness 用**完全相同的文本**，幂等可卸。

### 3. 装 skill（如果它支持 skill 目录）

```powershell
.\install.ps1 -Target all -NoPath -DshSkills "$env:USERPROFILE\.newharness\skills\agentos"
```

## 判据

接完后，该 harness 的规则入口里应能看到：

```
<!-- >>> agentos managed (global) >>> -->
## AgentOS 执行规程（全局 · 最高优先级）
...
<!-- <<< agentos managed <<< -->
```

`aos doctor` 会检查三个内建 harness；`-ExtraRules` 注入的文件可用
`Select-String -Pattern 'agentos managed'` 自检。

## 为什么这样就够

规程的有效性来自两件事：
1. **agent 每次会话都能读到这段规则**（规则入口 + skill 目录）
2. **规则文本唯一**（同一份 `skills/agentos/SKILL.md`）

只要这两条成立，harness 是什么不重要。
