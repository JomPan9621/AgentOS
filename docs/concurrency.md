# 并发判定

## 三条判定（全满足才并行）

节点 P 与 Q 可并行 **当且仅当**：

1. **DAG 无偏序** —— 不存在 P→…→Q 或 Q→…→P 的路径
2. **`touches` 无交集** —— 路径前缀互不包含；且都不碰全局热点
   （仓库根、构建入口、`INDEX.md`、`AGENTS.md`、`pyproject.toml`）
3. **`resource` 不相交** —— 不同独占资源标签（设备 / 主机 / 会话 / 外部租约，由业务侧自定义）

任一不满足 → 串行，**并在任务记录中写明原因**。

## 全局热点清单（等同独占）

这些路径默认视为"全社会争抢"，同时只允许一个写者：

```
.                    (仓库根)
.gitignore
AGENTS.md
INDEX.md
Makefile / CMakeLists.txt / BUILD.bazel
pyproject.toml / setup.py
```

## 并发上限

| 类型 | 是否占 worktree | 上限 |
|---|---|---|
| 写型 `write` | 独占 | 5（`aos wt status` 会告警） |
| 读型 `read` | 共享工作区 | 10 |

超过上限时 `aos wt new` 会拒绝创建，需先 `aos wt prune`。

## 怎么用

```powershell
aos plan graph -Plan <file>    # 输出 wave 与强制串行原因
aos plan next  -Plan <file>    # 输出当前可并行派发的批次
```

`graph` 的 wave 就是派发单位：**一个 wave = 一批 subagent；每个节点一个 subagent，同一 wave 必须并行；Master 只派发，不执行。**

## 并行：AgentOS 强制派发，harness 决定机制

**AgentOS 规定必须派发 subagent、同 wave 必须并行；harness 只决定用什么机制。**

| 层 | 谁负责 | 内容 |
|---|---|---|
| **边界 + 派发** | AgentOS（我们） | 从 PLAN 算出 wave；每个节点一个 subagent；同 wave 必须并行 |
| **机制** | 各 harness（自己） | 用什么机制（Task/Agent、Agent Teams、子代理池）把 subagent 真正并行跑起来 |

### 各 harness 用自己的方式做到极致

- **Claude Code**：subagent / Task 并行派发
- **Codex**：codex 插件 / 本地并行执行
- **DSH**：Agent Teams / 子代理池
- 未来新 harness：它有什么就用什么

**AgentOS 规定必须派发与并行，机制由 harness 决定**：`aos plan graph` 报出 N 个 PARALLEL wave，就必须真的把 N 批节点分别派发给 subagent 并并行跑，不允许串行假装并行，也不允许 Master 自己执行。

### 一条硬要求

**凡是被判定可并行的任务，必须由 harness 用自己的并行能力同时推进。**

- 串行执行本可并行的任务 = 违规
- 并行度受 harness 自身能力限制（比如某 harness 只能同时 3 个），要在任务记录里写明
- 但**不能因为"习惯串行"就放弃并行**

换句话说：**AgentOS 负责算清楚能并行到什么程度并强制派发，harness 负责把它跑到那个程度。**
