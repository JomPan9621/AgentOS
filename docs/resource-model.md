# GPU 精细资源模型（v2）

本文描述 AgentOS 远端资源模型：**GPU 是硬约束，OS / runtime / driver / image 是软感知**。
真实机器清单与租约只存在于数据层，仓库内代码与文档不写真实主机名 / IP / 业务数据。

- 机器清单（只读）：`<homebase>/data/agentos/hosts.json`
- 租约（生成物）：`<homebase>/devops/agentos/leases/<host>.json`

## 1. 版本与兼容

### v1 legacy（整机单租约）

历史文件保持可读：

```json
{
  "schema_version": 1,
  "host": "gpu-a",
  "task": "T1",
  "issue": "100",
  "agent_task": "",
  "note": "",
  "acquired_at": "2026-01-01T00:00:00Z"
}
```

- 读取时视为**整机占用**：该 host 的全部 GPU 都归此 task。
- `release` 保持旧行为：不带 `-Task` 可释放整机；带 `-Task` 时必须与租约持有者一致。
- 新代码不再写 v1；新 acquire 一律写 v2。

### v2（GPU 子租约）

```json
{
  "schema_version": 2,
  "host": "gpu-a",
  "updated_at": "2026-01-01T00:00:00Z",
  "allocations": [
    {
      "task": "T1",
      "issue": "100",
      "agent_task": "worker-1",
      "gpus": [0, 1],
      "acquired_at": "2026-01-01T00:00:00Z",
      "note": "jit compile"
    },
    {
      "task": "T2",
      "issue": "100",
      "agent_task": "",
      "gpus": [2],
      "acquired_at": "2026-01-01T00:05:00Z",
      "note": ""
    }
  ]
}
```

- 同一 host 可以挂多个 allocation，但 **GPU id 集合不得重叠**。
- allocation 身份 = **`task + issue`**；`issue` 为空时按空匹配。同 task 不同 issue 是不同 allocation。
- GPU id 从 `0` 开始，取值范围 `0..gpu_count-1`。
- 写入使用临时文件 + 原子替换，并用 host 级租约锁串行化读改写。

## 2. host profile（只读）

`hosts.json` 中每台机器可带：

```json
{
  "hostname": "<data-layer>",
  "gpu_count": 8,
  "profile": {
    "os": "ubuntu-22.04",
    "runtime": "runtime-a",
    "gpu_model": "<model>",
    "gpu_count": 8,
    "driver": "<driver>",
    "image": "<image>"
  }
}
```

- `gpu_count` 解析顺序：`profile.gpu_count` → host 顶层 `gpu_count` → `tags` 中的 `<n>gpu`。
- profile 缺失时 `room show` 显示 `UNKNOWN`，不阻断；`gpu_count` 未知（0）时无法分配 GPU。
- env 字段只用于提示，不参与分配阻断。

## 3. room 命令

```powershell
aos room list                     # 每个 host 的 profile / gpu 数 / 已用 / 空闲 / allocations
aos room show <host>              # 单机 profile + allocations；profile 缺失显示 UNKNOWN
aos room acquire <host> -Task T1 -Issue 100 -Gpus 2
aos room acquire <host> -Task T1 -Issue 100 -Gpus all   # 显式整机
aos room release <host> -Task T1 -Issue 100
aos room check <host>             # SSH 连通性（不变）
```

### acquire 语义（硬约束）

- **必须显式 `-Gpus <n|all>`**；缺省直接拒绝（exit 1）。
- 自动分配**最低空闲 GPU id**（例如 0,1）。
- `-Gpus all` 表示整机；要求 host 当前完全空闲。
- 空间不足时 exit 1，JSON 至少包含：
  - `used` / `free` / `gpu_count` / `used_gpu_ids` / `free_gpu_ids`
  - `alternatives`：其他 host 的空闲 GPU 数
  - `error.message` 含持有者与替代建议
- 同一 `task + issue` 重复 acquire：已持有足够卡时幂等返回（含 `issue` 字段）；请求更多卡时拒绝并提示先 release。
- 同一 task、不同 issue 的 acquire 是**不同身份**，会各自分配不同 GPU id；不会误判 already owned。
- v1 整机租约存在时，该 host 视为已占满，不再分配子租约。

### release 语义

- v2：身份 = `task + issue`。必须带 `-Task`；若该 task 存在 issue 作用域 allocation，必须显式 `-Issue`（否则拒绝，避免误删其他 issue）。
- v2 release 只移除 `task + issue` 匹配的 allocation；移除最后一个 allocation 后删除文件。task/issue 不匹配时 exit 1，并列出 holders（含 issue）。
- v1 legacy：保留旧行为（不带 `-Task` 释放整机；带 `-Task` 只按 task 匹配，issue 视为空/忽略）。

## 4. PLAN needs 列（可选第 9 列）

```markdown
| id | title | kind | deps | touches | resource | worktree | accept | needs |
|----|-------|------|------|---------|----------|----------|--------|-------|
| T1 | 编译 kernel | write | - | src/ | gpu-a | wt-100 | 通过 | gpus=2;env.os=ubuntu-22.04;env.runtime=runtime-a |
| T2 | 数据集准备 | read | - | - | auto | - | 完成 | gpus=1 |
| T3 | 文档 | read | - | - | none | - | 完成 | - |
```

- `gpus=<n>`：硬需求；`gpus=all`：显式整机。
- `env.os` / `env.runtime` / `env.driver` / `env.gpu_model` / `env.image`：软感知，只产生 warning。
- `resource`：host alias、`auto` 或 `none`。
- 旧 8 列表格继续可读；8 列 resource 视为 **legacy 整机**并 warning。
- 9 列表格中 `resource` 非 `none` 但缺 `gpus` → validation error。
- `gpus` 出现在 `resource=none` 上 → validation error。

### plan validate

- host 必须存在于 `hosts.json`（`auto` 除外）→ 否则 error。
- GPU 数必须为正整数或 `all`；不得超过 host `gpu_count` → error。
- 同一 wave 同 host 的 GPU 总数不得超过 `gpu_count` → error（调度器同时会强制串行）。
- env 不匹配 / 未知 → 仅 warning，不影响 exit code。
- 已存在的 allocation 只 warning（计划阶段不阻断）。
- **JSON/machine 模式与 Human 模式一致：`ok=false` 时 exit 1**（合法时 exit 0）。

### plan graph / 冲突

- 同 host 多任务：GPU 总数 ≤ `gpu_count` 时**可同 wave**；超容量时强制串行，`ForcedSerial` 记录 `resource:<host>:gpus`。
- legacy 8 列 resource：仍按整机冲突（等价于占满全部 GPU）。
- env 不参与冲突判定。
- `auto` 在 graph 阶段不绑定 host；由 `plan resources` 预检选机。

## 5. plan resources（资源预检）

```powershell
aos plan resources -Plan .agentos/plans/PLAN-100.md
```

- 动态读取 hosts + leases，按 wave/任务顺序为每个任务预留 GPU。
- 输出每任务：`host` / `gpus`（需求） / `gpu_ids` / `free` / `env=match|mismatch|unknown|n/a` / `status`。
- **预检采用 wave + task id 的贪心预留，不是最优装箱**：同一 wave 内前置任务占用的 GPU 可能让后续任务得到保守的不足结论。输出会给出替代 host / 减少卡数 / 等待释放的建议；可按建议调整 `needs` 或串行重排后重跑。
- **GPU 不足 → exit 2**，并给建议：
  - 改用其他有空闲 GPU 的 host（`alternatives` 结构化列出）
  - 减少 `gpus` 需求
  - 等待现有 allocation 释放（列出持有者）
- 候选 host 的 `gpu_count` 全部未知（0）→ exit 2，`status=unknown-gpu-count`，提示补 `profile.gpu_count` / host `gpu_count` / `<n>gpu` tag；不会抛空引用。
- env mismatch / unknown → 仅 warning，exit 0 不因 env 改变。
- `auto`：优先选择 env 不 mismatch、空闲足够的 host；否则退化为任意有空闲的 host。
- 同一 task 已有匹配 allocation 时，预检视为已满足（`leased=true`）。

## 6. track start 门禁

`aos track start -Plan <file>` 对 resource 非 `none` 的任务：

1. 必须存在匹配的 room allocation（`task` / `agent_task`，issue 同时匹配）。
2. allocation 的 GPU 数必须 ≥ `needs gpus`；`gpus=all` 要求整机。
3. 缺失 / GPU 不足 → **拒绝启动**，提示：
   `aos room acquire <host> -Task <task> -Issue <issue> -Gpus <n>`
   并列出替代 host；**不会自动 acquire**。
4. env mismatch / unknown → 仅 warning，任务照常启动。
5. subagent / policy / DAG 行为不变。

v1 整机租约可用于 legacy 任务（视为整机满足任意 GPU 数）。

## 7. snapshot / audit

- `aos snapshot` 的 `resources` 增加：`gpu_count` / `gpus_used` / `gpus_free` / `allocations` / `hosts[].profile` / `hosts[].allocations`。
- `resources.envWarnings` 汇总 Plan 中的 env mismatch/unknown；**不进入 attention，不影响 exit code**。
- `aos audit` 增加：
  - `resourceSummary`：hosts / GPUs 总量、已用、空闲、allocation 数、legacy 租约数。
  - GPU overlap / 越界 / 超容量 → `severity=error`（GPU 硬约束）。
  - env mismatch / unknown → `severity=warning`，只计数 `envWarnings`，不计入 errors。
- cross-layer 检查按 allocation 展开 v2 租约；v1 行为保持不变。

## 8. 典型流程

```powershell
# 1. 计划阶段
aos plan validate -Plan .agentos/plans/PLAN-100.md
aos plan resources -Plan .agentos/plans/PLAN-100.md     # GPU 不足 exit 2

# 2. 占卡（显式 GPU 数）
aos room acquire gpu-a -Task T1 -Issue 100 -Gpus 2

# 3. 启动（track 会校验 allocation）
aos track start -Issue 100 -Task T1 -Owner claude -Plan .agentos/plans/PLAN-100.md -Subagent worker-1

# 4. 收工释放
aos room release gpu-a -Task T1 -Issue 100
```

## 9. 错误语义速查

| 场景 | 退出码 | 是否阻断 |
|---|---|---|
| room acquire 缺 `-Gpus` | 1 | 是 |
| room acquire 无空闲 GPU | 1 | 是，附替代 host |
| room acquire host 不存在 / hosts.json 缺失 | 1 / 2 | 是 |
| room release task 不匹配 | 1 | 是 |
| PLAN 9 列 resource 缺 gpus | validate exit 1 | 是 |
| PLAN gpus 非法 / 超 host 容量 | validate exit 1 | 是 |
| PLAN env mismatch / unknown | validate exit 0 | 否（warning） |
| plan resources GPU 不足 | 2 | 是，附建议 |
| plan resources host gpu_count 未知 | 2 | 是，提示补 gpu_count |
| plan resources env mismatch | 0 | 否（warning） |
| track start 无 allocation | 抛错拒绝 | 是 |
| track start GPU 不足 | 抛错拒绝 | 是 |
| track start env mismatch | 0 | 否（warning） |
| audit env mismatch | 0（无其他错误时） | 否（warning） |
| audit GPU overlap / 越界 | 2 | 是 |
