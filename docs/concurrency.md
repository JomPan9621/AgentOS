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

`graph` 的 wave 就是派发单位：**一个 wave = 一批 subagent**。

## 并行：方法论给边界，harness 给实现

**AgentOS 不说"怎么并行"，只说"什么可以并行"。**

| 层 | 谁负责 | 内容 |
|---|---|---|
| **边界** | AgentOS（我们） | 从 PLAN 的 `deps` / `touches` / `resource` 算出哪些节点可并行（`aos plan graph` 的 wave） |
| **实现** | 各 harness（自己） | 用什么机制把同一 wave 的任务真正并行跑起来 |

### 各 harness 用自己的方式做到极致

- **Claude Code**：subagent / Task 并行派发
- **Codex**：codex 插件 / 本地并行执行
- **DSH**：Agent Teams / 子代理池
- 未来新 harness：它有什么就用什么

**AgentOS 不规定机制，只验收结果**：`aos plan graph` 报出 N 个 PARALLEL wave，就必须真的并行跑 N 批，不允许串行假装并行。

### 一条硬要求

**凡是被判定可并行的任务，必须由 harness 用自己的并行能力同时推进。**

- 串行执行本可并行的任务 = 违规
- 并行度受 harness 自身能力限制（比如某 harness 只能同时 3 个），要在任务记录里写明
- 但**不能因为"习惯串行"就放弃并行**

换句话说：**AgentOS 负责算清楚能并行到什么程度，harness 负责把它跑到那个程度。**
