# AI-native 契约

> **宗旨**：所有产出以 **agent 为第一消费者**。人读的格式是附加能力，不是默认。

## 五条硬约束

### 1. 机器可读优先

每条命令默认输出**单个 JSON 对象**到 stdout，不掺杂日志、颜色、进度条。
人类可读渲染必须走显式开关（`-Human`）。

```
aos plan graph -Plan x.md -Json     # machine
aos plan graph -Plan x.md           # human（可选）
```

### 2. 单一快照入口

agent 不应连续调用 N 个命令拼上下文。一次 `aos snapshot` 返回：

```json
{
  "ok": true,
  "repo":      { "remote": "...", "issueSource": "gitlab", "mustUseIssue": false },
  "plan":      { "tasks": [...] },
  "schedule":  { "Waves": [...], "ForcedSerial": [...] },
  "worktrees": { "total": 37, "limit": 5, "overLimit": true, "items": [...] },
  "ledger":    [ ...最近 20 条... ],
  "attention": [ "worktrees over limit: 37/5" ]
}
```

`attention` 字段是**自解释的待办**——agent 读完就知道下一步该干什么。

### 3. 严格退出码

| 码 | 含义 | agent 应做什么 |
|---|---|---|
| 0 | 成功 | 继续 |
| 1 | 错误 | 读 `error` 字段，修正后重试 |
| 2 | 需治理 | 读 `attention`，先处理阻塞项 |

不允许"成功但有问题"的模糊状态——有问题就是 2。

### 4. 状态放文件，不放对话

agent 换会话、换工具、被换掉重来，都能从三处恢复：

- `<repo>/.agentos/plans/PLAN-<issue>.md` —— 计划（人+机共读）
- `<repo>/.agentos/plans/PLAN-<issue>.state.json` —— 节点状态
- `<homebase>\devops\agentos\ledger.jsonl` —— 追加式流水

**任何只存在于对话里的上下文都是会丢的**。

### 5. 幂等可重入

- `plan new` 已存在则报错，不覆盖
- `track start` 可重复调用，覆盖当前状态
- `wt new` 路径或分支已存在则拒绝
- `wt prune` 默认 dry-run

agent 重试必须安全。

## 对产出的要求

| 产出 | 要求 |
|---|---|
| 脚本 | 结构化输出、退出码、无交互、不依赖 TTY |
| 文档 | 面向 agent：when-to-use、命令契约、踩坑点，而非营销话术 |
| 计划 | 表格化，字段可解析（`kind/deps/touches/resource/worktree/accept`） |
| 报告 | 先给结论与数字，再给解释；避免散文 |
| skill | 就是给 agent 的 API 文档 |

## 反面清单（禁止）

- ❌ 只输出人类表格、靠肉眼解析
- ❌ 用自然语言描述状态（"大概还有几个"）
- ❌ 需要交互确认才能继续（agent 无法回答）
- ❌ 状态只活在本轮对话里
- ❌ 输出里混入时间戳/颜色导致不可稳定解析
