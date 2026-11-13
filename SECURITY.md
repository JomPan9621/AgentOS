# SECURITY.md

## 适用范围

AgentOS 是纯功能仓库：只含脚本、模板、skill 与文档，**不含任何真实数据**。

## 铁律

1. 仓库内**不得**出现：真实主机名、IP、用户名、token、密钥、任何受限或敏感信息（内部资料、未公开架构、产品名等）。
2. 所有真实值放本机 `<homebase>\data\`，生成物放 `<homebase>\devops\`；两者都**永不入 git**。
3. 外发任何内容前必须脱敏。

## 脚本安全

- `wt.ps1 prune` 默认 dry-run，仅在显式 `-Apply` 时删除，且只删「路径在允许根下 + 非主工作区 + 三种脏状态全零 + HEAD 已进目标 ref」的 worktree。
- `room` 租约与 `artifact` 生成物只写本机数据层；真实机器清单由用户自备，仓库只带 schema 与占位示例。
- `audit` 的 policy 事件用 PFX 私钥签名；PFX 文件与密码不得入库，只通过 `-PfxPath` / `-PfxPassword` 或 `AGENTOS_POLICY_PFX` / `AGENTOS_POLICY_PFX_PASSWORD` 环境变量传入。
- `artifact` 固定根内的路径经过规范化与越界检查；仓库内不写生成物。
- 所有销毁性动作写审计日志到 `<homebase>\devops\agentos\logs\`。

## drivercore 公开版边界

- 公开树只含 drivercore 的**架构与实现**（bootstrap / harness / session / tasktrack / worktree）；不含任何运行数据、真实值或内部/第三方 skill。
- `drivercore/skills` 不随包；安装只复制 `skills/agentos`。
- tasktrack 的任务记录、日志与 `<id>.run.ps1` 命令正文只写 `<homebase>\devops\tasktrack\`（含命令正文，与 job JSON 同等敏感，永不入 git）。
- tasktrack 周期巡检是**逐机显式动作**：`install-watch-task.ps1` 默认只预演；注册/注销需人工执行。
- `drivercore/bootstrap/bootstrap.ps1` 只做前置检查、homebase 模板发布与 `install.ps1` 委托；`-DryRun` 不写用户目录、homebase 或 PATH。
