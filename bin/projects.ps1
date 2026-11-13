<#
.SYNOPSIS
  跨仓项目总览：一次看清所有业务仓的计划、在飞任务、worktree 与 issue 源。
.DESCRIPTION
  补齐 project 层的统一感知：单仓用 snapshot，全局用 projects。
  默认递归发现当前目录下的仓（跨仓用 -Root 指定），worktree 检出目录不算独立仓；在飞任务同时看 state 和 ledger，避免只写 ledger 的任务丢失。
  exit 0 正常；exit 2 表示有仓超 worktree 上限、有在飞任务或台账缺账。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Ledger = '',
    [int]$WorktreeLimit = 8,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$machine = -not $Human

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
if ([string]::IsNullOrWhiteSpace($Ledger)) { $Ledger = Join-Path $homeBase 'devops\agentos\ledger.jsonl' }
# 统一 ledger 模型：任务 / policy / session 的解析只走 bin/ledger.ps1
. (Join-Path $PSScriptRoot 'ledger.ps1')

$roots = @()
if (-not [string]::IsNullOrWhiteSpace($Root)) {
    $roots = @($Root)
} else {
    $roots = @((Get-Location).Path)
}
$roots = @($roots | Where-Object { Test-Path -LiteralPath $_ })

function Get-Field {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

function Find-AgentosRepos {
    param([string[]]$SearchRoots)
    $found = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $skip = @('.git', 'node_modules', '.venv', 'venv', 'out', 'build', 'dist', '.cache', '__pycache__', 'archive', '.idea', '.vscode')
    function Add-Repo([string]$Dir) {
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $found.Add($full)
        }
    }
    foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $rootFull = (Resolve-Path -LiteralPath $root).Path
        $rootGit = Join-Path $rootFull '.git'
        if ((Test-Path -LiteralPath $rootGit -PathType Container) -or (Test-Path -LiteralPath (Join-Path $rootFull '.agentos\plans'))) {
            Add-Repo $rootFull
        }
        foreach ($child in (Get-ChildItem -LiteralPath $rootFull -Directory -ErrorAction SilentlyContinue)) {
            if ($skip -contains $child.Name) { continue }
            $git = Join-Path $child.FullName '.git'
            if ((Test-Path -LiteralPath $git -PathType Container) -or (Test-Path -LiteralPath (Join-Path $child.FullName '.agentos\plans'))) {
                Add-Repo $child.FullName
            }
        }
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ Path = $rootFull; Depth = 0 })
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $dir = $item.Path
            $depth = [int]$item.Depth
            if ($depth -gt 8) { continue }
            if ($depth -gt 0 -and $skip -contains (Split-Path $dir -Leaf)) { continue }
            if (Test-Path -LiteralPath (Join-Path $dir '.agentos\plans')) { Add-Repo $dir }
            if ($depth -ge 8) { continue }
            foreach ($child in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
                if ($skip -contains $child.Name) { continue }
                $stack.Push([pscustomobject]@{ Path = $child.FullName; Depth = $depth + 1 })
            }
        }
    }
    return @($found | Sort-Object)
}

function Read-PlanIssue {
    param([string]$Path)
    $head = @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 80 -ErrorAction SilentlyContinue)
    foreach ($line in $head) {
        if ($line -match '^\s*-?\s*issue\s*:\s*#?(?<v>[A-Za-z0-9][A-Za-z0-9._/-]*)\s*$') { return $Matches['v'].Trim() }
    }
    return ([IO.Path]::GetFileNameWithoutExtension($Path) -replace '^PLAN-', '')
}

function Read-PlanTaskIds {
    param([string]$Path)
    $ids = @{}
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^##\s+(?<name>.+?)\s*$') { $section = $Matches['name'].Trim().ToLowerInvariant(); continue }
        if ($section -ne 'tasks') { continue }
        $t = $line.Trim()
        if (-not $t.StartsWith('|')) { continue }
        $cells = @($t.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 8) { continue }
        if ($cells[0] -eq 'id' -or $cells[0] -match '^:?-+:?$') { continue }
        $ids[$cells[0]] = $true
    }
    return $ids
}

function Invoke-GitQuiet {
    param([string]$Dir, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @(& git --no-optional-locks -c "safe.directory=$Dir" -C $Dir @GitArgs 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Lines = @($out | ForEach-Object { [string]$_ }) }
}

function Get-IssueSource {
    param([string]$Remote)
    if ([string]::IsNullOrWhiteSpace($Remote)) { return 'local' }
    if ($Remote -match 'github\.com') { return 'github' }
    $hosts = $env:AGENTOS_GITLAB_HOSTS
    if ($hosts) {
        foreach ($h in ($hosts -split ',')) {
            if ($h.Trim() -and $Remote -match [regex]::Escape($h.Trim())) { return 'gitlab' }
        }
    }
    if ($Remote -match 'gitlab') { return 'gitlab' }
    return 'local'
}

$openLedger = Get-OpenLedgerTasks -Events (Read-LedgerEvents -Path $Ledger)
$repos = @()
$allIssues = @{}
foreach ($dir in (Find-AgentosRepos $roots)) {
    $remote = ''
    $r = Invoke-GitQuiet $dir @('remote', 'get-url', 'origin')
    if ($r.Code -eq 0 -and $r.Lines.Count -gt 0) { $remote = $r.Lines[0] }

    $isWorktree = Test-Path -LiteralPath (Join-Path $dir '.git') -PathType Leaf
    $wtCount = 0
    $managedCount = 0
    if (-not $isWorktree) {
        $wtLines = (Invoke-GitQuiet $dir @('worktree', 'list', '--porcelain')).Lines
        $curBranch = ''
        foreach ($wl in $wtLines) {
            if ($wl -like 'worktree *') { if ($curBranch -like 'task/*') { $managedCount++ }; $curBranch = ''; $wtCount++ }
            elseif ($wl -like 'branch refs/heads/*') { $curBranch = $wl.Substring(18) }
        }
        if ($curBranch -like 'task/*') { $managedCount++ }
        $wtCount = $wtCount - 1
        if ($wtCount -lt 0) { $wtCount = 0 }
    }

    $plansDir = Join-Path $dir '.agentos\plans'
    $plans = @()
    if (Test-Path -LiteralPath $plansDir) {
        $plans = @(Get-ChildItem -LiteralPath $plansDir -Filter 'PLAN-*.md' -File -ErrorAction SilentlyContinue)
    }

    $issueSet = @{}
    $planTaskIds = @{}
    foreach ($plan in $plans) {
        $issue = Read-PlanIssue $plan.FullName
        if (-not [string]::IsNullOrWhiteSpace($issue)) {
            $issueSet[$issue] = $true
            $allIssues[$issue] = $true
        }
        foreach ($id in (Read-PlanTaskIds $plan.FullName).Keys) { $planTaskIds[$id] = $true }
    }

    $activeKeys = @{}
    if (Test-Path -LiteralPath $plansDir) {
        foreach ($sf in (Get-ChildItem -LiteralPath $plansDir -Filter '*.state.json' -File -ErrorAction SilentlyContinue)) {
            $raw = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            try { $obj = $raw | ConvertFrom-Json } catch { continue }
            foreach ($p in $obj.PSObject.Properties) {
                $v = $p.Value
                $st = $null
                if ($v -is [System.Collections.IDictionary]) { $st = $v['status'] } else { $st = $v.status }
                if ($st -in @('running', 'review')) { $activeKeys[$p.Name] = $true }
            }
        }
    }

    $openCount = 0
    $ledgerOnly = 0
    foreach ($k in $openLedger.Keys) {
        $t = $openLedger[$k]
        if (-not $issueSet.ContainsKey($t.issue)) { continue }
        if ($t.held) { $openCount++ }
        if (-not $planTaskIds.ContainsKey($t.task)) { $ledgerOnly++; continue }
        if ($t.held -and $t.status -in @('running', 'review')) { $activeKeys[$t.task] = $true }
    }

    $repos += [pscustomobject]@{
        name        = (Split-Path $dir -Leaf)
        path        = $dir
        worktree    = $isWorktree
        issueSource = (Get-IssueSource $remote)
        plans       = $plans.Count
        active      = $activeKeys.Count
        open        = $openCount
        ledgerOnly  = $ledgerOnly
        worktrees   = $wtCount
        managed     = $managedCount
        overLimit   = ($managedCount -gt $WorktreeLimit)
    }
}

$orphanOpen = @($openLedger.Keys | Where-Object { $openLedger[$_].held -and -not $allIssues.ContainsKey($openLedger[$_].issue) })
$withPlans = @($repos | Where-Object { $_.plans -gt 0 })
$over = @($repos | Where-Object { $_.overLimit })
$inFlight = 0
$openTotal = 0
$ledgerOnlyTotal = 0
$wtTotal = 0
if (@($repos).Count -gt 0) {
    $inFlight = ($repos | Measure-Object -Property active -Sum).Sum
    $openTotal = ($repos | Measure-Object -Property open -Sum).Sum
    $ledgerOnlyTotal = ($repos | Measure-Object -Property ledgerOnly -Sum).Sum
    $wtTotal = ($repos | Measure-Object -Property worktrees -Sum).Sum
}
if (-not $inFlight) { $inFlight = 0 }
if (-not $openTotal) { $openTotal = 0 }
if (-not $ledgerOnlyTotal) { $ledgerOnlyTotal = 0 }
if (-not $wtTotal) { $wtTotal = 0 }

$summary = [pscustomobject]@{
    repos       = $repos.Count
    withPlans   = $withPlans.Count
    activeTasks = $inFlight
    openTasks   = $openTotal
    ledgerOnly  = $ledgerOnlyTotal
    orphanTasks = @($orphanOpen).Count
    worktrees   = $wtTotal
    overLimit   = $over.Count
    limit       = $WorktreeLimit
}

$attention = @()
foreach ($o in $over) { $attention += ("{0}: worktrees {1}/{2}" -f $o.name, $o.worktrees, $WorktreeLimit) }
if ($inFlight -gt 0) { $attention += ("{0} task(s) in flight across repos" -f $inFlight) }
if ($ledgerOnlyTotal -gt 0) { $attention += ("{0} ledger task(s) have no PLAN row" -f $ledgerOnlyTotal) }
if (@($orphanOpen).Count -gt 0) { $attention += ("{0} ledger task(s) have no PLAN/issue owner" -f @($orphanOpen).Count) }

$payload = [pscustomobject]@{
    ok        = $true
    ts        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    root      = ($roots -join ';')
    roots     = @($roots)
    ledger    = $Ledger
    summary   = $summary
    repos     = @($repos | Sort-Object -Property worktrees, plans -Descending)
    attention = $attention
}

if ($machine) {
    $payload | ConvertTo-Json -Depth 6
} else {
    $repos | Sort-Object -Property worktrees -Descending | Select-Object -First 20 |
        Format-Table name, issueSource, plans, active, open, ledgerOnly, worktrees, overLimit -AutoSize
    Write-Output ''
    Write-Output ('repos={0}  withPlans={1}  activeTasks={2}  openTasks={3}  ledgerOnly={4}  orphanTasks={5}  worktrees={6}  overLimit={7}' -f $summary.repos, $summary.withPlans, $summary.activeTasks, $summary.openTasks, $summary.ledgerOnly, $summary.orphanTasks, $summary.worktrees, $summary.overLimit)
    if ($attention.Count -gt 0) { $attention | ForEach-Object { Write-Output ('  ATTENTION ' + $_) } }
}

if ($attention.Count -gt 0) { exit 2 }
exit 0
