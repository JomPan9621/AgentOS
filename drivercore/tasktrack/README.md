# tasktrack — 子任务跟踪看门狗（drivercore 唯一实现）

保证 **Codex / Claude / DSH 子任务不会无声消失**。

> 实战中曾发生子代理会话结束导致后台任务被进程树连带回收、状态文件仍显示 `running` 的事故（"尸体说活着"）。本机制由此而生。

## 设计原则

1. **双信号存活判定**：`pid 存活（含启动时间防 PID 复用）` + `日志文件新鲜度` 交叉验证；不信任任何单一状态文件。
2. **账本持久化**：任务记录存 `<homebase>/devops/tasktrack/state/`（生成物层，永不入 git；可用 `-StateDir` 覆盖）。默认 homebase 优先取 `AGENTOS_HOME`，缺省时由 `drivercore/tasktrack` 向上三级推导。
3. **生命周期去子代理化**：长任务只允许从主会话或本工具（detached 启动）发起；禁止在 subagent 内发起长任务。
4. **闭环**：`register/adopt` → `watch` 巡检 → `LOST` 告警 → 处理（resume/重跑）→ `done` 销账。
5. **完成判定（自动销账）**：`watch` 发现日志出现 `DONE` / `ROUND_DONE` / `DONE_T<数字任务号>`，或 wrapper 退出码为 `0`，自动置 `done`；已是 `done` 的任务不会被覆盖。

## 状态语义

| verdict | 含义 | 动作 |
|---|---|---|
| `ok` | 进程在（身份匹配）且日志新鲜 | 正常 |
| `starting` | 启动宽限期内，或最近 2 分钟仍有日志 | 等待 |
| `STALLED?` | 进程在但日志静默超阈值（默认 30 分钟） | 人工判断 |
| `NO-LOG?` | 进程在但日志文件缺失 | 人工核查 |
| `DONE`（verdict） | `running` 任务已检出完成信号 | `watch` 自动置 `done` |
| `LOST` | 进程消失/身份不符且无新日志，且无完成信号 | **必须处理**；`done` 前持续告警 |

## 完成信号

- **日志标记**：独立 token `DONE`、`ROUND_DONE` 或 `DONE_T<数字>`。`DONE_TIMEOUT`、`DONE_TODO`、`DONE_T1_FAILED` 不算；否定词只在紧邻标记时生效（`NOT DONE` 不算，`no errors, DONE_T1` 算）。
- **wrapper 退出码**：`register` 把命令正文写入 `<state>\<id>.run.ps1`（UTF-8 BOM），用 `powershell.exe -File` 执行；真实退出码落 `<state>\<id>.exit`，`watch` 仅在 0 时判完成。`adopt` 外部 wrapper 可用 `-ExitFile`。
- 非终止错误：子进程 `$ErrorActionPreference='Stop'`，未捕获错误得到非 0 退出码。
- 完成信号优先于存活判定；非 0 退出且无日志标记仍按 `LOST` 处理。

## 元数据（与 AgentOS 关联）

`register` / `adopt` 接受并落盘：

```powershell
-Issue <issue>   # 任务单号
-Task <task>     # PLAN 节点
-Host <host>     # 默认本机名
```

`aos audit` 的 cross-layer 用 `issue` / `task` / `host` 把 tasktrack 任务与 `aos track` 未关闭节点、`aos room` 租约关联：

- `host` 缺失的历史 job：audit 只从数据层 `<homebase>\data\agentos\hosts.json` 的别名 / hostname 匹配（`-HostsFile` 可覆盖）；代码不含机器名前缀，匹配不到即 `tasktrack-no-host` error。

- `tasktrack-lost` / `tasktrack-no-host` / `tasktrack-running-no-lease` → error
- `tasktrack-no-agent-task` / `lease-stale` / `agent-task-no-tasktrack` → warning

## 用法

```powershell
# 新任务（detached 启动 + 自动记账 + 日志心跳）
.\tasktrack.ps1 register -Kind codex -Name "review-v1" -Issue <issue> -Task <task> -Command "node ... task ..."

# 已存在的进程
.\tasktrack.ps1 adopt -ProcessId 1234 -Kind codex -Name "review-v1" -Issue <issue> -Task <task> -LogFile "<log-path>"

# 查看 / 巡检 / 销账
.\tasktrack.ps1 status
.\tasktrack.ps1 watch          # 退出码 2 = 存在未处理的失联任务
.\tasktrack.ps1 watch -Json    # { autoDone: [...], alerts: [...] }
.\tasktrack.ps1 done -Id t-<yyyyMMdd-HHmmss>-<rand> -Note "<note>"
```

## 巡检接入（逐机部署，不随 clone/bootstrap 自动生效）

1. 预演（不写文件、不注册）：
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\install-watch-task.ps1 -DryRun`
2. 注册计划任务（Windows）：
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\install-watch-task.ps1`
   → 每 10 分钟执行 `drivercore\tasktrack\tasktrack.ps1 watch`，输出追加到 `<homebase>\devops\tasktrack\watch.log`（退出码 2 = 有未处理失联）。
3. 查看最近输出：`Get-Content <homebase>\devops\tasktrack\watch.log -Tail 20`
4. 注销：同脚本加 `-Remove`。

- 任务名默认 `agentos-tasktrack-watch`，可用 `-TaskName` 覆盖。
- `watch-hidden.vbs` 是模板（占位符 `__WATCH_TASK_CMD__`），由安装脚本按本机路径生成；仓库内不含真实机器路径。
- 注册是逐机显式动作；本工具不自动注册/注销任何计划任务。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\tests\tasktrack.tests.ps1
```

覆盖：`DONE` / `ROUND_DONE` / `DONE_T<数字>`（含无 BOM UTF-16LE）自动完成、wrapper exit 0、`exit 7` / `throw` / 非终止错误仍 LOST、否定标记与 `DONE_TIMEOUT` / `DONE_T<task>_FAILED` 仍 LOST、5K/10K 长命令、已 `done` 不覆盖、`watch -Json` 字段。共 55 个断言，独立套件，测试根在 `%TEMP%` 且运行后清理。

## 边界

- "保证" = 机制层面的三重保险（主会话通知 + 账本看门狗 + 周期巡检），不覆盖物理故障。
- 日志静默阈值、启动宽限期可用 `-StaleMinutes` / `-GraceMinutes` 调整。
- `ROUND_DONE` 按契约视为最终完成标记；分轮任务不得在中途输出。
- `<id>.run.ps1` 保留在账本目录（含命令正文，与 job JSON 同等敏感）。
