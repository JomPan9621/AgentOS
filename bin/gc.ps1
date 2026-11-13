<#
.SYNOPSIS
  生命周期回收：台账压缩 + 已完成计划归档。默认 dry-run。
.DESCRIPTION
  解决"任务数据无限堆叠"：
    1. ledger.jsonl 压缩 —— 只保留「最近 N 天」或「仍未关闭」的任务事件
    2. 已完结计划归档 —— 所有节点都 done/abandoned 的 PLAN 移到 archive/
  默认扫描 <homebase>\project 与 <homebase>\repo（含 deliveries 等嵌套目录）；linked worktree 不算独立仓。
  exit 0 正常 / 1 错误 / 2 有可回收项（dry-run 时）
#>
[CmdletBinding()]
param(
    [string]$Ledger = '',
    [string]$ArchiveRoot = '',
    [string]$ProjectRoot = '',
    [string[]]$Roots = @(),
    [int]$KeepDays = 30,
    [switch]$Apply,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
if ([string]::IsNullOrWhiteSpace($Ledger)) { $Ledger = Join-Path $homeBase 'devops\agentos\ledger.jsonl' }
if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $homeBase 'devops\agentos\archive' }
# 统一 ledger 模型：任务未关闭判定复用 bin/ledger.ps1，不维护第二套状态机
. (Join-Path $PSScriptRoot 'ledger.ps1')
$machine = -not $Human
$cutoff = (Get-Date).AddDays(-$KeepDays)

$searchRoots = @()
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $searchRoots += $ProjectRoot }
if (@($Roots).Count -gt 0) { $searchRoots += @($Roots) }
if (@($searchRoots).Count -eq 0) {
    $searchRoots = @(
        (Join-Path $homeBase 'project'),
        (Join-Path $homeBase 'repo')
    )
}
$searchRoots = @($searchRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path } | Select-Object -Unique)

function Find-PlanDirs {
    param([string[]]$SearchRoots)
    $found = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $skip = @('.git', 'node_modules', '.venv', 'venv', 'out', 'build', 'dist', '.cache', '__pycache__', 'archive', '.idea', '.vscode')
    function Add-Dir([string]$Dir) {
        $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $found.Add($full) }
    }
    foreach ($root in $SearchRoots) {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ Path = $root; Depth = 0 })
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $dir = $item.Path
            $depth = [int]$item.Depth
            if ($depth -gt 8) { continue }
            if ($depth -gt 0 -and $skip -contains (Split-Path $dir -Leaf)) { continue }
            $plans = Join-Path $dir '.agentos\plans'
            if (Test-Path -LiteralPath $plans) { Add-Dir $plans }
            if ($depth -ge 8) { continue }
            foreach ($child in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
                if ($skip -contains $child.Name) { continue }
                $stack.Push([pscustomobject]@{ Path = $child.FullName; Depth = $depth + 1 })
            }
        }
    }
    return @($found | Sort-Object)
}

function Get-LedgerStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Total = 0; Keep = 0; Drop = 0; Bytes = 0; OpenTasks = 0 }
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # 未关闭任务集合由 bin/ledger.ps1 统一计算（已排除 policy/session 事件）
    $open = Get-OpenLedgerTasks -Events (Read-LedgerEvents -Path $Path)

    $keep = @()
    $drop = 0
    foreach ($l in $lines) {
        $e = $null
        try { $e = $l | ConvertFrom-Json } catch { $keep += $l; continue }
        $ev = [string]$e.event
        # policy（append-only 授权链）与 session（在场证明）永不压缩
        if ($ev -eq 'policy' -or $ev -like 'session-*') { $keep += $l; continue }
        $k = [string]$e.issue + '|' + [string]$e.task
        $isOpen = $open.ContainsKey($k)
        $isRecent = $true
        try { $isRecent = ([datetime]::ParseExact([string]$e.ts, 'yyyy-MM-ddTHH:mm:ss', $null) -ge $cutoff) } catch { }
        if ($isOpen -or $isRecent) { $keep += $l } else { $drop++ }
    }
    return [pscustomobject]@{
        Exists    = $true
        Total     = $lines.Count
        Keep      = $keep.Count
        Drop      = $drop
        Bytes     = (Get-Item -LiteralPath $Path).Length
        OpenTasks = $open.Count
        KeepLines = $keep
    }
}

function Get-PlanBacklog {
    param([string[]]$PlanDirs, [int]$Days)
    $rows = @()
    foreach ($dir in $PlanDirs) {
        foreach ($plan in (Get-ChildItem -LiteralPath $dir -Filter 'PLAN-*.md' -File -ErrorAction SilentlyContinue)) {
            $statePath = [IO.Path]::ChangeExtension($plan.FullName, '.state.json')
            $statuses = @{}
            if (Test-Path -LiteralPath $statePath) {
                $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    try {
                        $obj = $raw | ConvertFrom-Json
                        foreach ($p in $obj.PSObject.Properties) {
                            $v = $p.Value
                            $s = $null
                            if ($v -is [System.Collections.IDictionary]) { $s = $v['status'] } else { $s = $v.status }
                            if ($s) { $statuses[$p.Name] = $s }
                        }
                    } catch { }
                }
            }
            $values = @($statuses.Values)
            $closed = ($statuses.Count -gt 0) -and (@($values | Where-Object { $_ -notin @('done', 'abandoned') }).Count -eq 0)
            $age = ((Get-Date) - $plan.LastWriteTime).Days
            $repoDir = Split-Path (Split-Path $dir -Parent) -Parent
            $repo = Split-Path $repoDir -Leaf
            $isWorktree = Test-Path -LiteralPath (Join-Path $repoDir '.git') -PathType Leaf
            $rows += [pscustomobject]@{
                Plan       = $plan.FullName
                State      = $statePath
                Repo       = $repo
                Worktree   = $isWorktree
                Nodes      = $statuses.Count
                Closed     = $closed
                AgeDays    = $age
                Archivable = ($closed -and $age -ge $Days -and -not $isWorktree)
            }
        }
    }
    return @($rows)
}

$planDirs = @(Find-PlanDirs $searchRoots)
$stats = Get-LedgerStats $Ledger
$plans = @(Get-PlanBacklog $planDirs $KeepDays)
$archivable = @($plans | Where-Object { $_.Archivable })

$report = [pscustomobject]@{
    ok         = $true
    dryRun     = (-not $Apply)
    cutoff     = $cutoff.ToString('yyyy-MM-dd')
    roots      = @($searchRoots)
    ledger     = [pscustomobject]@{
        path      = $Ledger
        exists    = $stats.Exists
        total     = $stats.Total
        keep      = $stats.Keep
        drop      = $stats.Drop
        bytes     = $stats.Bytes
        openTasks = $stats.OpenTasks
    }
    plans      = [pscustomobject]@{
        scanned    = $plans.Count
        closed     = @($plans | Where-Object { $_.Closed }).Count
        archivable = $archivable.Count
    }
    candidates = @($archivable | ForEach-Object { $_.Plan })
}

if (-not $Apply) {
    if ($machine) {
        $report | ConvertTo-Json -Depth 6
    } else {
        Write-Output ('LEDGER  total={0} keep={1} drop={2} open={3}' -f $stats.Total, $stats.Keep, $stats.Drop, $stats.OpenTasks)
        Write-Output ('PLANS   scanned={0} closed={1} archivable={2}' -f $plans.Count, @($plans | Where-Object { $_.Closed }).Count, $archivable.Count)
        foreach ($a in $archivable) { Write-Output ('  ARCHIVE ' + $a.Plan) }
    }
    if ($stats.Drop -gt 0 -or $archivable.Count -gt 0) { exit 2 }
    exit 0
}

# --- 实际执行 ---
$actions = @()
if ($stats.Exists -and $stats.Drop -gt 0) {
    $tmp = $Ledger + '.compact-' + $PID
    $stats.KeepLines | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item $tmp $Ledger -Force
    $actions += ('ledger-compacted dropped=' + $stats.Drop + ' kept=' + $stats.Keep)
}
foreach ($a in $archivable) {
    $repoDir = Join-Path $ArchiveRoot $a.Repo
    New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
    Move-Item $a.Plan (Join-Path $repoDir (Split-Path $a.Plan -Leaf)) -Force
    if (Test-Path -LiteralPath $a.State) {
        Move-Item $a.State (Join-Path $repoDir (Split-Path $a.State -Leaf)) -Force
    }
    $actions += ('archived ' + $a.Plan)
}

$report | Add-Member -NotePropertyName applied -NotePropertyValue $actions -Force
if ($machine) { $report | ConvertTo-Json -Depth 6 }
else { $actions | ForEach-Object { Write-Output ('  ' + $_) } }
exit 0
