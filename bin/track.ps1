<#
.SYNOPSIS
  AgentOS 任务生命周期台账：start / review / close / claim / release / list / lost。
.DESCRIPTION
  所有任务动作写追加式 ledger（JSONL），并同步 PLAN 节点状态。
  新增跨 harness 接管：claim（接手）/ release（交出）/ handoff（一步交接）。

  与 repo/devops/tasktrack 的分工：
    - tasktrack 管"进程级长任务"（防进程树被回收后失联）
    - track.ps1 管"任务节点的生命周期与归属"
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'review', 'close', 'claim', 'release', 'handoff', 'list', 'lost', 'who')]
    [string]$Command = 'list',
    [string]$Issue = '',
    [string]$Task = '',
    [string]$Owner = '',
    [string]$From = '',
    [string]$Reason = '',
    [string]$Note = '',
    [string]$AuthorizedBy = '',
    [string]$Repo = '',
    [string]$Plan = '',
    [string]$Ledger = '',
    [int]$StaleMinutes = 120,
    [switch]$Force,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 环境自推导：AGENTOS_HOME > agentos 仓的父目录（= 根据地根）
$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) {
    $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
if ([string]::IsNullOrWhiteSpace($Ledger)) {
    $Ledger = Join-Path $homeBase 'devops\agentos\ledger.jsonl'
}
$machine = -not $Human

# --- repo 归属：显式 > -Plan 所在仓 > 当前目录 ---
$repoName = $Repo
if (-not $repoName -and $Plan) {
    $d = Split-Path $Plan -Parent
    if ((Split-Path $d -Leaf) -eq 'plans') { $d = Split-Path (Split-Path $d -Parent) -Parent }
    $repoName = Split-Path $d -Leaf
}
if (-not $repoName) { $repoName = Split-Path (Get-Location) -Leaf }

function Add-Event {
    param([hashtable]$Event)
    $dir = Split-Path $Ledger -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Event['ts'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    if (-not $Event.ContainsKey('repo')) { $Event['repo'] = $repoName }
    ($Event | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Ledger -Encoding UTF8
}

function Sync-PlanState {
    param([string]$Status)
    if (-not $Plan) { return }
    $bin = Join-Path $PSScriptRoot 'plan.ps1'
    & $bin -Command state -Plan $Plan -Task $Task -Status $Status -Owner $Owner | Out-Null
}

function Get-OpenTasks {
    $open = @{}
    if (-not (Test-Path -LiteralPath $Ledger)) { return $open }
    foreach ($l in (Get-Content -LiteralPath $Ledger -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $e = $l | ConvertFrom-Json } catch { continue }
        # StrictMode 安全取值：历史事件可能缺字段
        function fieldOf($obj, [string]$name) {
            $prop = $obj.PSObject.Properties[$name]
            if ($null -eq $prop) { return '' }
            if ($null -eq $prop.Value) { return '' }
            return [string]$prop.Value
        }
        $k = (fieldOf $e 'issue') + '|' + (fieldOf $e 'task')
        $evOwner = fieldOf $e 'owner'
        $evTs = fieldOf $e 'ts'
        $evRepo = fieldOf $e 'repo'
        $evEvent = fieldOf $e 'event'
        switch ($evEvent) {
            'close' { $open.Remove($k) }
            'release' { if ($open.ContainsKey($k)) { $open[$k].owner = '' ; $open[$k].held = $false } }
            default { $open[$k] = [pscustomobject]@{ issue = (fieldOf $e 'issue'); task = (fieldOf $e 'task'); owner = $evOwner; ts = $evTs; repo = $evRepo; held = $true } }
        }
    }
    return $open
}

function Get-AgeMinutes {
    param([string]$Ts)
    try { return [math]::Round(((Get-Date) - [datetime]::ParseExact($Ts, 'yyyy-MM-ddTHH:mm:ss', $null)).TotalMinutes, 0) }
    catch { return -1 }
}

function Invoke-Dispatch {
switch ($Command) {
    'start' {
        if (-not $Task) { throw '-Task is required' }
        Add-Event @{ event = 'start'; issue = $Issue; task = $Task; owner = $Owner }
        Sync-PlanState 'running'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'start'; issue = $Issue; task = $Task; owner = $Owner; repo = $repoName; status = 'running' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("start: issue={0} task={1} owner={2}" -f $Issue, $Task, $Owner)
    }
    'review' {
        if (-not $Task) { throw '-Task is required' }
        Add-Event @{ event = 'review'; issue = $Issue; task = $Task; owner = $Owner }
        Sync-PlanState 'review'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'review'; issue = $Issue; task = $Task; owner = $Owner; status = 'review' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("review: issue={0} task={1}" -f $Issue, $Task)
    }
    'close' {
        if (-not $Task) { throw '-Task is required' }
        Add-Event @{ event = 'close'; issue = $Issue; task = $Task; owner = $Owner }
        Sync-PlanState 'done'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'close'; issue = $Issue; task = $Task; owner = $Owner; status = 'done' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("close: issue={0} task={1}" -f $Issue, $Task)
    }
    'claim' {
        if (-not $Task -or -not $Owner) { throw '-Task and -Owner are required' }
        $open = Get-OpenTasks
        $k = "$Issue|$Task"
        if (-not $open.ContainsKey($k)) { throw "no such open task: $k (start it first)" }
        $cur = $open[$k]
        $age = Get-AgeMinutes $cur.ts
        $isMine = ($cur.owner -eq $Owner)
        if ($isMine) {
            if ($machine) { [pscustomobject]@{ ok = $true; event = 'claim'; noop = $true; issue = $Issue; task = $Task; owner = $Owner; note = 'already owned by you' } | ConvertTo-Json -Depth 4; return }
            Write-Output 'already owned by you'
            return
        }
        $heldByOther = ($cur.owner -and $cur.held -and $cur.owner -ne $Owner)
        if ($heldByOther -and [string]::IsNullOrWhiteSpace($AuthorizedBy)) {
            throw ("跨 harness 接管未获授权：任务由 '{0}' 持有。仅在用户明确要求时才可接管，请加 -AuthorizedBy <用户名/指令来源>；否则请只报告不干预。" -f $cur.owner)
        }
        $stale = ($age -ge $StaleMinutes)
        if ($heldByOther -and -not $stale -and -not $Force) {
            throw ("task held by '{0}' ({1} min, threshold {2}). use -Force to override, or wait" -f $cur.owner, $age, $StaleMinutes)
        }
        Add-Event @{ event = 'claim'; issue = $Issue; task = $Task; owner = $Owner; from = $cur.owner; reason = $(if ($Reason) { $Reason } elseif ($heldByOther) { "stale $age min" } else { 'unowned' }) }
        Sync-PlanState 'running'
        if ($machine) {
            [pscustomobject]@{ ok = $true; event = 'claim'; issue = $Issue; task = $Task; owner = $Owner; from = $cur.owner; previous_age_min = $age; forced = [bool]$Force; repo = $repoName } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output ("claim: {0} took task {1} from '{2}' ({3} min)" -f $Owner, $Task, $cur.owner, $age)
    }
    'release' {
        if (-not $Task) { throw '-Task is required' }
        $open = Get-OpenTasks
        $k = "$Issue|$Task"
        if (-not $open.ContainsKey($k)) { throw "no such open task: $k" }
        $cur = $open[$k]
        if ($cur.owner -and $Owner -and $cur.owner -ne $Owner) {
            if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) {
                throw ("release 他人任务未获授权：任务由 '{0}' 持有。请加 -AuthorizedBy <用户名/指令来源>。" -f $cur.owner)
            }
        }
        Add-Event @{ event = 'release'; issue = $Issue; task = $Task; owner = $Owner; note = $Note }
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'release'; issue = $Issue; task = $Task; from = $cur.owner; note = $Note; state = 'available' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("release: task {0} is now available" -f $Task)
    }
    'handoff' {
        if (-not $Task -or -not $Owner) { throw '-Task and -Owner (receiver) are required' }
        if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) {
            throw 'handoff 必须由用户授权：请加 -AuthorizedBy <用户名/指令来源>'
        }
        $open = Get-OpenTasks
        $k = "$Issue|$Task"
        if (-not $open.ContainsKey($k)) { throw "no such open task: $k" }
        $cur = $open[$k]
        if ($From -and $cur.owner -and $cur.owner -ne $From) { throw "current owner is '$($cur.owner)', not -From '$From'" }
        Add-Event @{ event = 'handoff'; issue = $Issue; task = $Task; owner = $Owner; from = $cur.owner; reason = $Reason; note = $Note }
        Sync-PlanState 'running'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'handoff'; issue = $Issue; task = $Task; from = $cur.owner; to = $Owner; repo = $repoName } | ConvertTo-Json -Depth 4; return }
        Write-Output ("handoff: {0} -> {1} (task {2})" -f $cur.owner, $Owner, $Task)
    }
    'who' {
        $open = Get-OpenTasks
        $items = @()
        foreach ($k in $open.Keys) {
            $t = $open[$k]
            if (-not $t.held) { continue }
            $items += [pscustomobject]@{ issue = $t.issue; task = $t.task; owner = $t.owner; repo = $t.repo; started = $t.ts; age_min = (Get-AgeMinutes $t.ts); claimable = ((Get-AgeMinutes $t.ts) -ge $StaleMinutes) }
        }
        if ($machine) { [pscustomobject]@{ ok = $true; count = @($items).Count; items = @($items | Sort-Object age_min -Descending) } | ConvertTo-Json -Depth 5; return }
        $items | Sort-Object age_min -Descending | Format-Table issue, task, owner, repo, age_min, claimable -AutoSize
    }
    'list' {
        if (-not (Test-Path -LiteralPath $Ledger)) { if ($machine) { '{"ok":true,"items":[]}' } else { Write-Output 'ledger empty' }; return }
        if ($machine) {
            $items = @(Get-Content -LiteralPath $Ledger -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
            [pscustomobject]@{ ok = $true; ledger = $Ledger; count = $items.Count; items = $items } | ConvertTo-Json -Depth 6
            return
        }
        Get-Content -LiteralPath $Ledger -Encoding UTF8 | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            $e = $_ | ConvertFrom-Json
            Write-Output ("{0}  {1,-7} issue={2} task={3} owner={4}" -f $e.ts, $e.event, $e.issue, $e.task, $e.owner)
        }
    }
    'lost' {
        $open = Get-OpenTasks
        $found = @()
        foreach ($k in $open.Keys) {
            $t = $open[$k]
            $age = Get-AgeMinutes $t.ts
            if ($age -ge $StaleMinutes) { $found += [pscustomobject]@{ issue = $t.issue; task = $t.task; owner = $t.owner; repo = $t.repo; age_min = $age } }
        }
        if ($machine) { [pscustomobject]@{ ok = $true; count = @($found).Count; items = @($found) } | ConvertTo-Json -Depth 5; return }
        if (@($found).Count -eq 0) { Write-Output ("no LOST task within {0} min window" -f $StaleMinutes) }
        else { $found | ForEach-Object { Write-Output ("LOST started={0} issue={1} task={2} owner={3}" -f $_.age_min, $_.issue, $_.task, $_.owner) } }
    }
}
}

Invoke-Dispatch
exit 0
