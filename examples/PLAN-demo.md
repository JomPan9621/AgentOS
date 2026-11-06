# PLAN-900 — AgentOS 自检示例

- issue: 900
- created: 2026-11-06
- repo: <homebase>\agentos
- remote: <repo-remote-url>
- target_ref: origin/master

## Tasks

| id | title | kind | deps | touches | resource | worktree | accept |
|----|-------|------|------|---------|----------|----------|--------|
| T1 | 盘点现有 worktree 现状 | read | - | - | none | - | 输出分类表 |
| T2 | 实现 plan 引擎 | write | T1 | bin/plan.ps1 | none | agentos-900-plan | plan.ps1 语法通过 |
| T3 | 实现 worktree 管理 | write | T1 | bin/wt.ps1 | none | agentos-900-wt | wt.ps1 语法通过 |
| T4 | 补文档 | write | T2, T3 | docs/ | none | agentos-900-docs | docs 覆盖四篇 |
| T5 | 独立审计（与 T2/T3 可并行） | read | T1 | - | none | - | 审计报告 |

## Notes

- T2 与 T3 的 touches 不重叠 → 可并行
- T4 依赖 T2/T3 → 串行
- T5 是读型，与 T2/T3 可同 wave 并行
