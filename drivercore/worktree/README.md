# worktree — 兼容转发器（唯一实现仍在 bin/wt.ps1）

## 唯一实现

`bin/wt.ps1` —— 仓库：https://github.com/JomPan9621/AgentOS.git

`drivercore/worktree/wt.ps1` 是**兼容转发器**：
参数原样转发（旧 `-RepoRoot` 映射到 `-Repo`），不维护第二份实现。新代码应使用本目录或直接 `aos wt`。

## 用法

```powershell
# 推荐：走统一入口
aos wt list   -Repo <repo>
aos wt status -Repo <repo>
aos wt prune            # 只读盘点
aos wt prune -Apply     # 只删安全候选

# 兼容：旧调用路径（等价）
powershell.exe -File drivercore\worktree\wt.ps1 -Command status -RepoRoot <repo>
```

## 安全边界

只有以下**全部满足**才是可回收候选：

- 路径在项目根下，且不是主工作区
- tracked / untracked / ignored 全部为零
- `HEAD` 已进入目标 ref（缺 origin 时回退到本地 HEAD）
- 分支不是 detached

脚本**不 fetch、不删远端分支、不强制删除**；`prune` 默认 dry-run。
dirty / 未跟踪 / ignored / 未合入的 worktree 一律保留，先归档或人工核销；
不得用 `git stash`、`reset` 或历史改写掩盖现场。

## 新 worktree

```powershell
aos wt new -Issue <issue> -Slug <slug> -Repo <repo>
```

命名 `<repo>-<issue>-<slug>`，分支 `task/<issue>-<slug>`；活跃槽位上限 8。
Worker 严禁 `git worktree add`；只有 Master 能开 worktree。
