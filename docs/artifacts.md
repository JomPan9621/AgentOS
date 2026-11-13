# 生成物收口（artifact）

> 目标：harness 生成的图片、截图、HTML、图表、报告、trace 等统一收口到固定根，避免散落在项目仓库和临时目录。
> 本页只讲**生成物**；项目真实源码与需要入 git 的交付 HTML 不属于生成物，仍留在各自仓库。

## 固定根

`<homebase>\devops\agentos\artifacts`

`<homebase>` 是 AgentOS 根据地：命令优先读 `AGENTOS_HOME` 环境变量，未设置时取 `agentos` 仓库的上一级。固定根位于 `devops/` 生成物层，**永不入 git**。

## 目录结构

```text
<root>\<repo>\<issue>\<task>\<run-id>\
  screenshots\
  html\
  reports\
  traces\
```

- `<repo>` / `<issue>` / `<task>` / `<run-id>` 都是单段名称，不允许路径分隔符、`..`、绝对路径、Windows 非法字符与保留设备名。
- `<run-id>` 省略时使用时间戳（`yyyyMMdd-HHmmss`）。
- `path` 负责创建 run 目录及四个子目录；重复调用幂等。
- 历史散落文件不自动搬迁；只提供收口入口和只读清单。

## 命令

### path

```powershell
aos artifact path -Repo <repo> -Issue <n> -Task <t> [-RunId <id>] [-Json]
```

创建并返回固定根下的本次 run 目录。默认 JSON：

```json
{
  "ok": true,
  "root": "<homebase>\\devops\\agentos\\artifacts",
  "repo": "<repo>",
  "issue": "<n>",
  "task": "<t>",
  "runId": "<run-id>",
  "path": "<root>\\<repo>\\<n>\\<t>\\<run-id>",
  "subdirs": ["screenshots", "html", "reports", "traces"],
  "created": true
}
```

`-Human` 只输出路径，便于脚本拼接。同一 run 目录重复调用时返回 `created: false`，目录与子目录保留。

### list

```powershell
aos artifact list [-Repo <repo> [-Issue <n> [-Task <t>]]] [-Json]
```

只读列出固定根下的目录与文件数，不创建任何目录：

| 参数 | 列出的层级 |
|---|---|
| 无 | `<root>\<repo>` 仓库目录 |
| `-Repo` | 该仓库下的 issue 目录 |
| `-Repo -Issue` | 该 issue 下的 task 目录 |
| `-Repo -Issue -Task` | 该 task 下的 run 目录 |

每项返回 `kind` / `name` / `path` / `files`（递归文件数）。目录不存在时返回 `count: 0`，不会创建。

`list` 不接受 `-RunId`；传入会返回 `unsupported-arg` 错误。

## 数据与功能解耦

- 命令与模板只包含相对名称和占位路径，不包含真实主机名、IP、用户名或业务数据。
- 生成物全部落在 `<homebase>\devops\agentos\artifacts`，AgentOS 仓库与项目仓库只保留功能与源码。
- 仓库内不得出现截图、报告、trace、临时 HTML 等运行产物。

## 迁移边界

- **不自动搬迁历史文件**：已有的散落生成物保持原位，人工确认后再决定是否移入固定根。
- `path` 只创建固定根下的目录；`list` 只读扫描固定根，不写仓库、不写临时目录。
- 本能力不修改 git 状态，不参与 `wt prune` / `hygiene` 的回收流程。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\artifact.tests.ps1
```

测试使用 `AGENTOS_HOME` 沙箱，覆盖固定根、目录结构、非法名称 / 路径穿越拒绝、`list` 只读与仓库不被污染。
