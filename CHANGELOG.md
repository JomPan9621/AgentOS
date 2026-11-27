# CHANGELOG

本文件只记录当前发布版本。历史版本（v0.1.0 / v0.2.0 / v0.3.0）已废弃，不再维护。

## v1.0.0-rc1 — 2026-11-27

**首个预发布版本（release candidate）。** AgentOS 首次在 Windows 与 Linux / macOS 两个平台同时可用，
Windows 行为零改动。

### 平台支持

| 平台 | PowerShell | 状态 |
|------|-----------|------|
| Windows | 5.1+ / 7.x | 完整支持（原有路径逐字节保留） |
| Linux / WSL2 | 7.x | **本版新增** |
| macOS | 7.x | 按 Linux 路径支持（未实机验证） |

### 新增能力

- **Linux / POSIX 安装**：`install.ps1` 在类 Unix 生成 `~/.agentos/bin/aos`（POSIX shim），
  PATH 交由 shell profile 管理；`uninstall.ps1` 对称清理。
- **跨平台 doctor**：`aos doctor` 按平台检查 shim 与 PATH；Unix 下读 `$env:PATH`
  （PowerShell 在 Unix 上环境变量大小写敏感）。
- **跨平台进程卫生**：`hygiene` 在 Unix 用 `ps` 枚举进程、`/proc/loadavg` 与 `/proc/meminfo` 读压力，
  Windows 仍用 CIM。
- **跨平台 tasktrack**：`register` 在 Unix 使用 `pwsh`，不传 `-ExecutionPolicy` / `-WindowStyle`。
- **worktree 默认分支自适应**：`wt new` 不再硬编码 `master`；`master` 不存在时回落
  `origin/HEAD`，再回落 `main`。

### 修复

- **policy 时间解析（影响 Windows 与 Linux 的 PS7）**：`ConvertFrom-Json` 会把 ISO8601 字符串
  自动转为 `[datetime]`，`[string]` 强转得到区域格式，导致 `yyyy-MM-ddTHH:mm:ss` 解析失败、
  policy 被判 `invalid`，`track start -Plan -Subagent` 直接抛错。现在统一归一化回 ISO 字符串。
- **`wt` 子目录判定**：`Test-UnderPath` 硬编码 `\`，Unix 下所有 worktree 被判为 outside，
  `wt prune` 候选恒为 0。改用平台分隔符。
- **artifact 越界校验**：根前缀比较硬编码 `\`，Unix 下误判。改用平台分隔符。
- **tasktrack 测试沙箱**：Windows 进程在 UNC 工作目录下运行时，`[IO.Path]::GetTempPath()`
  返回 `<UNC 当前目录>\tmp\`，导致测试产物写进仓库。新增 `Get-SafeTempRoot` 校验沙箱不在仓库内，
  `.gitignore` 增加兜底规则。

### 质量

- 同一份代码，两端各跑三套测试：

| 套件 | Linux (pwsh 7.5.4) | Windows (PS 5.1) |
|------|-------------------|------------------|
| `tests/selftest.ps1` | 209 / 209 PASS | 209 / 209 PASS |
| `tests/artifact.tests.ps1` | 24 / 24 PASS | 24 / 24 PASS |
| `drivercore/tasktrack/tests/tasktrack.tests.ps1` | 55 / 55 PASS | 55 / 55 PASS |

- `aos version` 输出 `agentos 1.0.0-rc1`；`aos doctor` 为 9 项公开 layout 检查。
- `.ps1` 必须为 UTF-8 with BOM。

### 已知限制

- 浏览器任务仅支持 Google Chrome（含 headless）。
- `powershell.exe -File` 在 Windows 上不支持 UNC 路径；仓库位于 `\\wsl.localhost\...` 时，
  Windows 端测试需在本地盘副本上运行（Linux 端无此限制）。
- macOS 按 POSIX 路径实现，未做实机验证。

### 安装

**Windows (PowerShell)**

```powershell
git clone https://github.com/JomPan9621/AgentOS.git <homebase>\agentos
cd <homebase>\agentos
.\install.ps1 -Target all          # skill + 全局规则块 + aos shim
.\install.ps1 -Target all -NoPath  # 不修改用户 PATH
```

**Linux / macOS (需要 PowerShell 7)**

```bash
git clone https://github.com/JomPan9621/AgentOS.git ~/DevSpace/AgentOS
cd ~/DevSpace/AgentOS
bash drivercore/bootstrap/bootstrap.sh          # 或直接 pwsh -File install.ps1 -Target all
export PATH="$HOME/.agentos/bin:$PATH"          # 加入 shell profile
```

验证：`aos version`（应输出 `agentos 1.0.0-rc1`）、`aos doctor`、三套测试。
