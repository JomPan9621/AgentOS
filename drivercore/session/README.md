# session — harness 会话在场模型

`aos session` 记录 **哪个 harness 会话（role）在哪个 host 上执行哪个已跟踪任务**。它不是任务生命周期，而是执行者的在场证明。

## 模型

| 字段 | 含义 |
|---|---|
| `session` | 会话 id（`s-<yyyyMMdd-HHmmss>-<4hex>`，或 `-Id` 显式指定） |
| `role` | `master` / `sub-master` / `worker` |
| `issue` / `task` | 绑定的任务；**必须是 ledger 中 running/review 的已 start 任务** |
| `host` | 机器名；默认 `[Environment]::MachineName` |
| `ts` | register / heartbeat / close 的时间戳 |
| `note` | 可选说明 |

## 事件（append-only，统一 ledger）

```json
{"ts":"...","event":"session-register","session":"s-...","role":"worker","issue":"<issue>","task":"<task>","host":"<host>"}
{"ts":"...","event":"session-heartbeat","session":"s-...","role":"worker","issue":"<issue>","task":"<task>","host":"<host>"}
{"ts":"...","event":"session-close","session":"s-...","role":"worker","issue":"<issue>","task":"<task>","host":"<host>"}
```

- 只写 `<homebase>\devops\agentos\ledger.jsonl`，不建 `sessions.json`。
- `bin/ledger.ps1` 的 `Read-LedgerEvents` 跳过 `session-*`，session 不会污染任务状态机。
- `gc` 永不压缩 policy / session 事件。
- `snapshot` 输出当前未关闭会话。

## 命令

```powershell
aos session register  -Issue <issue> -Task <task> -Role worker [-Host <host>] [-Id <sid>]
aos session heartbeat -Id <sid> [-Note "<note>"]
aos session close     -Id <sid>
aos session list [-All] [-Human] [-TtlMinutes 120]
```

- **绑定校验**：register 前必须有 `aos track start -Issue <issue> -Task <task> -Plan <file> -Subagent <label>`；否则拒绝。
- heartbeat / close 只能作用于已登记的 open session；close 幂等（重复 close 返回 `alreadyClosed=true`）。
- `list` 默认只列 open；`-All` 含已关闭；`stale` 由 `-TtlMinutes` 判定。

## 与 track 的边界

- `track` = 任务生命周期（start/review/close），ledger 的任务事件。
- `session` = 执行者在场（register/heartbeat/close），ledger 的 session 事件。
- 两者通过 `issue+task` 关联，但互不替代：任务完成不自动关闭 session；session 断开不等于任务失败。
