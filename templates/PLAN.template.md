# PLAN-{{ISSUE}} — {{TITLE}}

- issue: {{ISSUE}}
- created: {{DATE}}
- repo: {{REPO}}
- remote: {{REMOTE}}
- target_ref: origin/master

## Tasks

| id | title | kind | deps | touches | resource | worktree | accept |
|----|-------|------|------|---------|----------|----------|--------|
| T1 | 梳理现状并锁定改动面 | read | - | - | none | - | 输出改动面清单 |
| T2 | 实现主改动 | write | T1 | src/example | none | REPO-{{ISSUE}}-impl | 单测通过 |
| T3 | 独立审计（可与 T2 并行） | read | T1 | - | none | - | 审计报告 |

## Notes

- 写型节点必须填 `touches` 与 `worktree`
- 读型节点 `worktree` 留 `-`，不占槽位
- 并行不是拍脑袋：跑 `aos plan graph -Plan <file>` 看系统算出的 wave
