# 全局安装

目标：**本机任意 agent、任意目录，都能自动加载 AgentOS 并调用 `aos`。**

## 装了什么

`install.ps1` 做三件事：

| # | 内容 | 落点 | 生效范围 |
|---|---|---|---|
| 1 | skill 副本（仅 `skills/agentos`） | `~/.claude/skills/`、`~/.codex/skills/`、`~/.dsh/skills/` 下对应 skill 目录 | 用户级，任意目录可见 |
| 2 | 全局规则块（受管） | `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`、`~/.dsh/AGENTS.md` | 用户级，任意目录自动加载 |
| 3 | `aos` 命令 | `~/.agentos/bin/aos.cmd` + 用户 PATH | 任意目录可调用 |

`-DryRun` 只打印计划，不写 `<user-profile>`、不写 homebase、不改 PATH。

## 受管块

注入内容用标记包裹，**幂等可重装、可干净卸载**：

```html
<!-- >>> agentos managed (global) >>> -->
... 六条 MUST ...
<!-- <<< agentos managed <<< -->
```

重装只替换标记之间的内容，你在这三个文件里手写的其他内容不受影响。

## 命令

```powershell
.\install.ps1 -Target all            # 全量（skill + 规则 + PATH）
.\install.ps1 -Target all -Force     # 覆盖已有 skill
.\install.ps1 -Target codex          # 只装某一个工具
.\install.ps1 -NoPath                # 不碰 PATH
.\install.ps1 -NoRules               # 不注入全局规则块
.\uninstall.ps1 -Target all          # 反向清理
```

## 验证

```powershell
# 1. 三处规则文件都应有受管块
Select-String -Path "$env:USERPROFILE\.claude\CLAUDE.md","$env:USERPROFILE\.codex\AGENTS.md","$env:USERPROFILE\.dsh\AGENTS.md" -Pattern 'agentos managed'

# 2. shim 可用
& "$env:USERPROFILE\.agentos\bin\aos.cmd" version

# 3. 开一个新 shell 后，任意目录直接：
aos doctor
aos snapshot -Repo <任意仓库>
```

## 已知限制

1. **PATH 只对新 shell 生效**——当前会话需要开新终端或直接用全路径。
2. **全局规程与工作区规则分层**——AgentOS 规程全局生效；工作区自己的 `AGENTS.md` 规则只在对应目录内适用，不冲突。
3. **PS 5.1 兼容**——所有 `.ps1` 必须 UTF-8 with BOM，否则中文乱码导致解析失败。
