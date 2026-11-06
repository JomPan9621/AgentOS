<#
.SYNOPSIS
  生命周期回收：台账压缩 + 已完成计划归档。默认 dry-run。
.DESCRIPTION
  解决"任务数据无限堆叠"：
    1. ledger.jsonl 压缩 —— 只保留「最近 N 天」或「仍未关闭」的任务事件
    2. 已完结计划归档 —— 所有节点都 done/abandoned 的 PLAN 移到 archive/
  exit 0 正常 / 1 错误 / 2 有可回收项（dry-run 时）
#>
[CmdletBinding()]
param(
    [string]$Ledger = '',
    [string]$ArchiveRoot = '',
    [string]$ProjectRoot = '',
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
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Join-Path $homeBase 'project' }
$machine = -not $Human
$cutoff = (Get-Date).AddDays(-$KeepDays)

function Get-LedgerStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Total = 0; Keep = 0; Drop = 0; Bytes = 0; OpenTasks = 0 }
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $events = @()
    foreach ($l in $lines) { try { $events += ($l | ConvertFrom-Json) } catch { } }

    # 判定哪些 task 仍未关闭
    $open = @{}
    foreach ($e in $events) {
        $k = [string]$e.issue + '|' + [string]$e.task
        if ($e.event -eq 'close') { $open.Remove($k) }
        else { $open[$k] = $true }
    }

    $keep = @()
    $drop = 0
    foreach ($l in $lines) {
        $e = $null
        try { $e = $l | ConvertFrom-Json } catch { $keep += $l; continue }
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
    param([string]$Root, [int]$Days)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $rows = @()
    foreach ($plan in (Get-ChildItem -LiteralPath $Root -Recurse -Filter 'PLAN-*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\\.agentos\\plans\\' })) {
        $statePath = [IO.Path]::ChangeExtension($plan.FullName, '.state.json')
        $statuses = @{}
        if (Test-Path -LiteralPath $statePath) {
            $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) {
                    $v = $p.Value
                    $s = $null
                    if ($v -is [System.Collections.IDictionary]) { $s = $v['status'] } else { $s = $v.status }
                    if ($s) { $statuses[$p.Name] = $s }
                }
            }
        }
        $values = @($statuses.Values)
        $closed = ($statuses.Count -gt 0) -and (@($values | Where-Object { $_ -notin @('done', 'abandoned') }).Count -eq 0)
        $age = ((Get-Date) - $plan.LastWriteTime).Days
        $rows += [pscustomobject]@{
            Plan     = $plan.FullName
            State    = $statePath
            Repo     = (Split-Path (Split-Path (Split-Path $plan.FullName -Parent) -Parent) -Parent | Split-Path -Leaf)
            Nodes    = $statuses.Count
            Closed   = $closed
            AgeDays  = $age
            Archivable = ($closed -and $age -ge $Days)
        }
    }
    return @($rows)
}

$stats = Get-LedgerStats $Ledger
$plans = @(Get-PlanBacklog $ProjectRoot $KeepDays)
$archivable = @($plans | Where-Object { $_.Archivable })

$report = [pscustomobject]@{
    ok         = $true
    dryRun     = (-not $Apply)
    cutoff     = $cutoff.ToString('yyyy-MM-dd')
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
