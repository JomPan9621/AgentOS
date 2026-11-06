# SECURITY.md

## 适用范围

AgentOS 是纯功能仓库：只含脚本、模板、skill 与文档，**不含任何真实数据**。

## 铁律

1. 仓库内**不得**出现：真实主机名、IP、用户名、token、密钥、任何公司资产信息（含具体硬件架构、ISA、产品名）。
2. 所有真实值放本机 `<homebase>\data\`，仓库内只留占位符。
3. 外发任何内容前必须脱敏。

## 脚本安全

- `wt.ps1 prune` 默认 dry-run，仅在显式 `-Apply` 时删除，且只删「路径在 project 下 + 非主工作区 + 三种脏状态全零 + HEAD 已进目标 ref」的 worktree。
- 所有销毁性动作写审计日志到 `devops/agentos/logs/`。
