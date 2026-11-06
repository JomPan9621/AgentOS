<#
.SYNOPSIS
  跨仓项目总览：一次看清所有业务仓的计划、在飞任务、worktree 与 issue 源。
.DESCRIPTION
  补齐 project 层的统一感知：单仓用 snapshot，全局用 projects。
  exit 0 正常；exit 2 表示有仓超 worktree 上限或有在飞任务。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [int]$WorktreeLimit = 5,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$machine = -not $Human

if ([string]::IsNullOrWhiteSpace($Root)) {
    $homeBase = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    $Root = Join-Path $homeBase 'project'
}
if (-not (Test-Path -LiteralPath $Root)) { throw "project root not found: $Root（可用 -Root 或 AGENTOS_HOME 指定）" }

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

$repos = @()
foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
    $gitPath = Join-Path $dir.FullName '.git'
    if (-not (Test-Path -LiteralPath $gitPath)) { continue }
    # 只统计「真仓」：.git 必须是目录；worktree 检出的 .git 是文件，其 worktree 已算在父仓
    if (-not (Test-Path -LiteralPath $gitPath -PathType Container)) { continue }

    $remote = ''
    $r = Invoke-GitQuiet $dir.FullName @('remote', 'get-url', 'origin')
    if ($r.Code -eq 0 -and $r.Lines.Count -gt 0) { $remote = $r.Lines[0] }

    $wtLines = (Invoke-GitQuiet $dir.FullName @('worktree', 'list', '--porcelain')).Lines
    $wtCount = 0
    $managedCount = 0
    $curBranch = ''
    foreach ($wl in $wtLines) {
        if ($wl -like 'worktree *') { if ($curBranch -like 'task/*') { $managedCount++ }; $curBranch = ''; $wtCount++ }
        elseif ($wl -like 'branch refs/heads/*') { $curBranch = $wl.Substring(18) }
    }
    if ($curBranch -like 'task/*') { $managedCount++ }
    $wtCount = $wtCount - 1
    if ($wtCount -lt 0) { $wtCount = 0 }

    $plansDir = Join-Path $dir.FullName '.agentos\plans'
    $plans = @()
    if (Test-Path -LiteralPath $plansDir) {
        $plans = @(Get-ChildItem -LiteralPath $plansDir -Filter 'PLAN-*.md' -File -ErrorAction SilentlyContinue)
    }

    $active = 0
    if (Test-Path -LiteralPath $plansDir) {
        foreach ($sf in (Get-ChildItem -LiteralPath $plansDir -Filter '*.state.json' -File -ErrorAction SilentlyContinue)) {
            $raw = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            try { $obj = $raw | ConvertFrom-Json } catch { continue }
            foreach ($p in $obj.PSObject.Properties) {
                $v = $p.Value
                $st = $null
                if ($v -is [System.Collections.IDictionary]) { $st = $v['status'] } else { $st = $v.status }
                if ($st -in @('running', 'review')) { $active++ }
            }
        }
    }

    $repos += [pscustomobject]@{
        name        = $dir.Name
        path        = $dir.FullName
        issueSource = (Get-IssueSource $remote)
        plans       = $plans.Count
        active      = $active
        worktrees   = $wtCount
        managed     = $managedCount
        overLimit   = ($managedCount -gt $WorktreeLimit)
    }
}

$withPlans = @($repos | Where-Object { $_.plans -gt 0 })
$over = @($repos | Where-Object { $_.overLimit })
$inFlight = ($repos | Measure-Object -Property active -Sum).Sum
if (-not $inFlight) { $inFlight = 0 }
$wtTotal = ($repos | Measure-Object -Property worktrees -Sum).Sum
if (-not $wtTotal) { $wtTotal = 0 }

$summary = [pscustomobject]@{
    repos       = $repos.Count
    withPlans   = $withPlans.Count
    activeTasks = $inFlight
    worktrees   = $wtTotal
    overLimit   = $over.Count
    limit       = $WorktreeLimit
}

$attention = @()
foreach ($o in $over) { $attention += ("{0}: worktrees {1}/{2}" -f $o.name, $o.worktrees, $WorktreeLimit) }
if ($inFlight -gt 0) { $attention += ("{0} task(s) in flight across repos" -f $inFlight) }

$payload = [pscustomobject]@{
    ok        = $true
    ts        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    root      = $Root
    summary   = $summary
    repos     = @($repos | Sort-Object -Property worktrees, plans -Descending)
    attention = $attention
}

if ($machine) {
    $payload | ConvertTo-Json -Depth 6
} else {
    $repos | Sort-Object -Property worktrees -Descending | Select-Object -First 20 |
        Format-Table name, issueSource, plans, active, worktrees, overLimit -AutoSize
    Write-Output ''
    Write-Output ('repos={0}  withPlans={1}  activeTasks={2}  worktrees={3}  overLimit={4}' -f $summary.repos, $summary.withPlans, $summary.activeTasks, $summary.worktrees, $summary.overLimit)
    if ($attention.Count -gt 0) { $attention | ForEach-Object { Write-Output ('  ATTENTION ' + $_) } }
}

if ($attention.Count -gt 0) { exit 2 }
exit 0
