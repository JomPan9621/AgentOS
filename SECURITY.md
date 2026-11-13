# SECURITY.md

## 适用范围

AgentOS 是纯功能仓库：只含脚本、模板、skill 与文档，**不含任何真实数据**。

## 铁律

1. 仓库内**不得**出现：真实主机名、IP、用户名、token、密钥、任何公司资产信息（含具体硬件架构、ISA、产品名）。
2. 所有真实值放本机 `<homebase>\data\`，生成物放 `<homebase>\devops\`；两者都**永不入 git**。
3. 外发任何内容前必须脱敏。

## 脚本安全

- `wt.ps1 prune` 默认 dry-run，仅在显式 `-Apply` 时删除，且只删「路径在允许根下 + 非主工作区 + 三种脏状态全零 + HEAD 已进目标 ref」的 worktree。
- `room` 租约与 `artifact` 生成物只写本机数据层；真实机器清单由用户自备，仓库只带 schema 与占位示例。
- `audit` 的 policy 事件用 PFX 私钥签名；PFX 文件与密码不得入库，只通过 `-PfxPath` / `-PfxPassword` 或 `AGENTOS_POLICY_PFX` / `AGENTOS_POLICY_PFX_PASSWORD` 环境变量传入。
- `artifact` 固定根内的路径经过规范化与越界检查；仓库内不写生成物。
- 所有销毁性动作写审计日志到 `<homebase>\devops\agentos\logs\`。
