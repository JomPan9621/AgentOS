<#
.SYNOPSIS
  AI-native 状态快照：一次调用返回 agent 所需的全部结构化上下文。
.DESCRIPTION
  默认输出单个 JSON 对象到 stdout，可直接被 agent 解析。
  人类可读渲染走 -Human。这是给 AI 的主入口。

  exit 0 = 正常；exit 2 = 需要治理；exit 1 = 错误
#>
[CmdletBinding()]
param(
    [string]$Repo = '',
    [string]$Plan = '',
    [int]$LedgerTail = 20,
    [int]$WorktreeLimit = 5,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bin = $PSScriptRoot
$RepoPath = if ($Repo) { (Resolve-Path -LiteralPath $Repo).Path } else { (Get-Location).Path }

function Invoke-Json {
    param([scriptblock]$Call)
    try {
        $raw = (& $Call 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

$issue = Invoke-Json { & (Join-Path $bin 'issue.ps1') -Command detect -Repo $RepoPath -Json }
$wt = Invoke-Json { & (Join-Path $bin 'wt.ps1') -Command status -Repo $RepoPath -Limit $WorktreeLimit -Json }

$planObj = $null
$waves = $null
if ($Plan -and (Test-Path -LiteralPath $Plan)) {
    $planObj = Invoke-Json { & (Join-Path $bin 'plan.ps1') -Command show -Plan $Plan -Json }
    $waves = Invoke-Json { & (Join-Path $bin 'plan.ps1') -Command graph -Plan $Plan -Json }
}

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$ledgerPath = Join-Path $homeBase 'devops\agentos\ledger.jsonl'
$ledger = @()
if (Test-Path -LiteralPath $ledgerPath) {
    $all = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $start = [Math]::Max(0, $all.Count - $LedgerTail)
    for ($i = $start; $i -lt $all.Count; $i++) { $ledger += ($all[$i] | ConvertFrom-Json) }
}

# --- 跨 agent 感知：当前有哪些任务正在被谁执行 ---
$active = @()
$planDir = Join-Path $RepoPath '.agentos\plans'
if (Test-Path -LiteralPath $planDir) {
    foreach ($sf in (Get-ChildItem -LiteralPath $planDir -Filter '*.state.json' -File -ErrorAction SilentlyContinue)) {
        $raw = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        try { $obj = $raw | ConvertFrom-Json } catch { continue }
        $planName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($sf.Name))
        foreach ($p in $obj.PSObject.Properties) {
            $v = $p.Value
            $st = $null; $own = ''; $upd = ''
            if ($v -is [System.Collections.IDictionary]) { $st = $v['status']; $own = [string]$v['owner']; $upd = [string]$v['updated'] }
            else { $st = $v.status; $own = [string]$v.owner; $upd = [string]$v.updated }
            if ($st -in @('running', 'review')) {
                $active += [pscustomobject]@{ plan = $planName; task = $p.Name; status = $st; owner = $own; updated = $upd }
            }
        }
    }
}

# --- 补：ledger 中未关闭、但 PLAN state 里没有的任务（只走 track 未挂 plan 的情况）---
if (Test-Path -LiteralPath $ledgerPath) {
    $openMap = @{}
    foreach ($line in (Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        $k = [string]$e.issue + '|' + [string]$e.task
        if ($e.event -eq 'close') { $openMap.Remove($k) }
        else { $openMap[$k] = $e }
    }
    $seen = @{}
    foreach ($a in $active) { $seen[[string]$a.task] = $true }
    foreach ($k in $openMap.Keys) {
        $e = $openMap[$k]
        if ($seen.ContainsKey([string]$e.task)) { continue }
        $active += [pscustomobject]@{
            plan    = 'ledger-only'
            task    = [string]$e.task
            status  = [string]$e.event
            owner   = [string]$e.owner
            updated = [string]$e.ts
        }
    }
}

# --- 资源（远端机器租约）---
$resources = $null
$hostsFile3 = Join-Path $homeBase 'data\agentos\hosts.json'
$leaseDir3  = Join-Path $homeBase 'devops\agentos\leases'
if (Test-Path -LiteralPath $hostsFile3) {
    try {
        $hostsObj3 = (Get-Content -LiteralPath $hostsFile3 -Raw -Encoding UTF8 | ConvertFrom-Json)
        $leases3 = @{}
        if (Test-Path -LiteralPath $leaseDir3) {
            foreach ($lf3 in (Get-ChildItem -LiteralPath $leaseDir3 -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                try { $lj3 = (Get-Content -LiteralPath $lf3.FullName -Raw -Encoding UTF8 | ConvertFrom-Json); $leases3[[string]$lj3.host] = $lj3 } catch { }
            }
        }
        $resRows = @()
        foreach ($hp3 in $hostsObj3.hosts.PSObject.Properties) {
            $alias3 = $hp3.Name
            $lg3 = if ($leases3.ContainsKey($alias3)) { $leases3[$alias3] } else { $null }
            $resRows += [pscustomobject]@{
                host     = $alias3
                lease    = $(if ($lg3) { [string]$lg3.task } else { 'free' })
                acquired = $(if ($lg3) { [string]$lg3.acquired_at } else { '' })
            }
        }
        $resources = [pscustomobject]@{
            total = $resRows.Count
            free  = @($resRows | Where-Object { $_.lease -eq 'free' }).Count
            hosts = $resRows
        }
    } catch { $resources = $null }
}

$attention = @()
if ($null -ne $wt) {
    if ((Get-Prop $wt 'overLimit' $false) -eq $true) {
        $attention += ("worktrees over limit: {0}/{1}" -f (Get-Prop $wt 'total' 0), (Get-Prop $wt 'limit' 0))
    }
}
if ($null -ne $planObj) {
    $tasks = @(Get-Prop $planObj 'tasks' @())
    $missing = @($tasks | Where-Object { $_.kind -eq 'write' -and ($_.worktree -eq '-' -or [string]::IsNullOrWhiteSpace($_.worktree)) })
    if ($missing.Count -gt 0) { $attention += ("{0} write task(s) without worktree" -f $missing.Count) }
}

if ($active.Count -gt 0) {
    $desc = ($active | ForEach-Object { $_.task + '@' + $_.owner }) -join ','
    $attention += ('{0} task(s) in flight: {1}' -f $active.Count, $desc)
}

$snapshot = [pscustomobject]@{
    ok        = $true
    ts        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    agentos   = '0.1.0'
    repo      = [pscustomobject]@{
        path         = $RepoPath
        name         = (Split-Path $RepoPath -Leaf)
        remote       = (Get-Prop $issue 'remote' '')
        issueSource  = (Get-Prop $issue 'source' 'unknown')
        mustUseIssue = (Get-Prop $issue 'mustUseIssue' $false)
    }
    plan      = $planObj
    schedule  = $waves
    worktrees = $wt
    active    = $active
    resources = $resources
    ledger    = $ledger
    attention = $attention
}

if ($Human) {
    Write-Output ("repo      : {0} [{1}]" -f $RepoPath, $snapshot.repo.issueSource)
    Write-Output ("worktrees : {0} / limit {1}" -f (Get-Prop $wt 'total' 0), (Get-Prop $wt 'limit' 0))
    if ($null -ne $planObj) { Write-Output ("plan      : {0} task(s)" -f @($planObj.tasks).Count) }
    if ($attention.Count -gt 0) { $attention | ForEach-Object { Write-Output ("ATTENTION : " + $_) } }
} else {
    $snapshot | ConvertTo-Json -Depth 8
}

if ($attention.Count -gt 0) { exit 2 }
exit 0
