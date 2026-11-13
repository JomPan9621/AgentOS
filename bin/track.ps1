<#
.SYNOPSIS
  AgentOS 任务生命周期台账：start / review / close / block / abandon / claim / release / list / lost。
.DESCRIPTION
  所有任务动作写追加式 ledger（JSONL），并同步 PLAN 节点状态。
  start 在带 -Plan 时执行 DAG 门禁：依赖必须 done、任务必须未完成、不能重复启动；每个节点必须记录执行它的 subagent。
  close 在带 -Plan 时自动对账 state/ledger（清理 stale DAG），并执行只读收工检查：
  audit（含 subagent 归属与 legacy 豁免）、wt prune 盘点、hygiene；绝不自动 -Apply / -Reap。

  ledger 事件模型统一由 bin/ledger.ps1 提供，audit / track / snapshot 不重复实现。
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'review', 'close', 'block', 'abandon', 'claim', 'release', 'handoff', 'list', 'lost', 'who')]
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
    [string]$Subagent = '',
    [string]$Wave = '',
    [string]$PfxPath = '',
    [string]$PfxPassword = '',
    [string]$Ledger = '',
    [int]$StaleMinutes = 120,
    [switch]$Force,
    [switch]$SkipReclaim,
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
if (-not [string]::IsNullOrWhiteSpace($Subagent)) { $Subagent = $Subagent.Trim() }
if (-not [string]::IsNullOrWhiteSpace($Owner)) { $Owner = $Owner.Trim() }
. (Join-Path $PSScriptRoot 'ledger.ps1')

# --- PLAN 路径先解析，repo 归属才准确 ---
if ($Plan -and (Test-Path -LiteralPath $Plan)) { $Plan = (Resolve-Path -LiteralPath $Plan).Path }
# -Issue 未传时从 PLAN 头部推导，避免 ledger 写出空 issue
if (-not $Issue -and $Plan) {
    $head = @(Get-Content -LiteralPath $Plan -Encoding UTF8 -TotalCount 80 -ErrorAction SilentlyContinue)
    foreach ($line in $head) {
        if ($line -match '^\s*-?\s*issue\s*:\s*#?(?<v>[A-Za-z0-9][A-Za-z0-9._/-]*)\s*$') { $Issue = $Matches['v'].Trim(); break }
    }
    if (-not $Issue) { $Issue = ([IO.Path]::GetFileNameWithoutExtension($Plan) -replace '^PLAN-', '') }
}

# --- repo 归属：显式 > -Plan 所在仓 > 当前目录 ---
$repoName = $Repo
if (-not $repoName -and $Plan) {
    $d = Split-Path $Plan -Parent
    if ((Split-Path $d -Leaf) -eq 'plans') { $d = Split-Path (Split-Path $d -Parent) -Parent }
    $repoName = Split-Path $d -Leaf
}
if (-not $repoName) { $repoName = Split-Path (Get-Location) -Leaf }

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# --- 资源门禁：GPU 是硬约束；env 只做 warning ---

function Get-HostGpuCountLocal {
    param($HostObj)
    $profile = Get-Prop $HostObj 'profile' $null
    $count = 0
    $gc = Get-Prop $profile 'gpu_count' $null
    if ($null -ne $gc -and ("$gc" -match '^\d+$')) { $count = [int]$gc }
    if ($count -le 0) {
        $hc = Get-Prop $HostObj 'gpu_count' $null
        if ($null -ne $hc -and ("$hc" -match '^\d+$')) { $count = [int]$hc }
    }
    if ($count -le 0) {
        foreach ($tag in @(Get-Prop $HostObj 'tags' @())) {
            $t = [string]$tag
            if ($t -match '^(?<n>\d+)gpu$') { $count = [int]$Matches['n']; break }
        }
    }
    return $count
}

function Get-HostProfileInfo {
    param($HostObj)
    $profile = Get-Prop $HostObj 'profile' $null
    return [pscustomobject]@{
        os        = [string](Get-Prop $profile 'os' '')
        runtime   = [string](Get-Prop $profile 'runtime' '')
        gpu_model = [string](Get-Prop $profile 'gpu_model' '')
        gpu_count = (Get-HostGpuCountLocal $HostObj)
        driver    = [string](Get-Prop $profile 'driver' '')
        image     = [string](Get-Prop $profile 'image' '')
    }
}

function Read-LeaseFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-LeaseAllocInfo {
    param($Lease, [int]$GpuCount)
    if ($null -eq $Lease) { return @() }
    $sv = Get-Prop $Lease 'schema_version' 1
    $schema = 1
    try { $schema = [int]$sv } catch { $schema = 1 }
    $allocProp = Get-Prop $Lease 'allocations' $null
    if ($schema -ge 2 -and $null -ne $allocProp) {
        $out = @()
        foreach ($a in @($allocProp)) {
            if ($null -eq $a) { continue }
            $ids = @()
            foreach ($g in @(Get-Prop $a 'gpus' @())) { if ("$g" -match '^\d+$') { $ids += [int]$g } }
            $out += [pscustomobject]@{
                task = [string](Get-Prop $a 'task' ''); issue = [string](Get-Prop $a 'issue' '')
                agent_task = [string](Get-Prop $a 'agent_task' ''); gpus = @($ids | Sort-Object -Unique)
                acquired_at = [string](Get-Prop $a 'acquired_at' ''); note = [string](Get-Prop $a 'note' '')
                legacy = $false; whole_host = $false
            }
        }
        return @($out)
    }
    $ids1 = @()
    for ($i = 0; $i -lt $GpuCount; $i++) { $ids1 += $i }
    return @([pscustomobject]@{
            task = [string](Get-Prop $Lease 'task' ''); issue = [string](Get-Prop $Lease 'issue' '')
            agent_task = [string](Get-Prop $Lease 'agent_task' ''); gpus = @($ids1)
            acquired_at = [string](Get-Prop $Lease 'acquired_at' ''); note = [string](Get-Prop $Lease 'note' '')
            legacy = $true; whole_host = $true
        })
}

function Test-AllocationTaskMatch {
    param($Alloc, [string]$TaskId, [string]$IssueId)
    $atask = [string](Get-Prop $Alloc 'task' '')
    $aagent = [string](Get-Prop $Alloc 'agent_task' '')
    $aissue = [string](Get-Prop $Alloc 'issue' '')
    if ($aissue -and $IssueId -and $aissue -ine $IssueId) { return $false }
    if ($atask -ieq $TaskId) { return $true }
    if ($aagent -ieq $TaskId) { return $true }
    if ($aagent -ieq ($IssueId + '|' + $TaskId)) { return $true }
    if ($aagent -ieq ($IssueId + '/' + $TaskId)) { return $true }
    if ([bool](Get-Prop $Alloc 'legacy' $false)) {
        # 旧租约常把 issue 号写进 task；保持兼容匹配。
        if ($atask -ieq $IssueId) { return $true }
        if ($aissue -ieq $IssueId) { return $true }
    }
    return $false
}

function Get-EnvGateStatus {
    param($TaskObj, $Profile)
    $envObj = Get-Prop $TaskObj 'envNeeds' $null
    $keys = @()
    if ($null -ne $envObj) {
        foreach ($p in $envObj.PSObject.Properties) { if ($p.Name) { $keys += $p.Name } }
    }
    if ($keys.Count -eq 0) { return [pscustomobject]@{ Status = 'n/a'; Warnings = @() } }
    $norm = { param([string]$s) return (($s.ToLowerInvariant() -replace '[_-]+', ' ' -replace '\s+', ' ').Trim()) }
    $hasMismatch = $false
    $hasUnknown = $false
    $warns = @()
    foreach ($k in $keys) {
        $expected = [string](Get-Prop $envObj $k '')
        $actual = [string](Get-Prop $Profile $k '')
        if ([string]::IsNullOrWhiteSpace($actual) -or [string]::IsNullOrWhiteSpace($expected)) {
            $hasUnknown = $true
            $warns += ('env.{0}: expected ''{1}'' host ''{2}'' (unknown; advisory only)' -f $k, $expected, $(if ($actual) { $actual } else { 'UNKNOWN' }))
            continue
        }
        $e = & $norm $expected
        $a = & $norm $actual
        if ($a.Contains($e) -or $e.Contains($a)) {
            $warns += ('env.{0}: expected ''{1}'' host ''{2}'' (match)' -f $k, $expected, $actual)
        } else {
            $hasMismatch = $true
            $warns += ('env.{0}: expected ''{1}'' host ''{2}'' (mismatch; advisory only)' -f $k, $expected, $actual)
        }
    }
    $status = if ($hasMismatch) { 'mismatch' } elseif ($hasUnknown) { 'unknown' } else { 'match' }
    return [pscustomobject]@{ Status = $status; Warnings = @($warns) }
}

function Get-HostFreeRows {
    param($HostsObj)
    $leaseDir = Join-Path $homeBase 'devops\agentos\leases'
    $rows = @()
    if ($null -eq $HostsObj) { return @() }
    foreach ($p in $HostsObj.hosts.PSObject.Properties) {
        $prof = Get-HostProfileInfo $p.Value
        $lease = Read-LeaseFile (Join-Path $leaseDir ($p.Name + '.json'))
        $allocs = @(Get-LeaseAllocInfo $lease $prof.gpu_count)
        $used = @()
        foreach ($a in $allocs) { foreach ($g in @($a.gpus)) { $used += [int]$g } }
        $used = @($used | Sort-Object -Unique)
        $rows += [pscustomobject]@{ host = $p.Name; free = [Math]::Max(0, $prof.gpu_count - $used.Count); gpu_count = $prof.gpu_count }
    }
    return @($rows | Where-Object { $_.free -gt 0 } | Sort-Object -Property @{ Expression = { $_.free }; Descending = $true }, @{ Expression = { $_.host }; Descending = $false })
}

function Assert-ResourceGate {
    param($TaskObj)
    $base = [pscustomobject]@{ Checked = $false; Host = ''; Gpus = @(); Env = 'n/a'; Warnings = @(); Schema = 0; Lease = '' }
    if ($null -eq $TaskObj) { return $base }
    $res = [string](Get-Prop $TaskObj 'resource' 'none')
    if ([string]::IsNullOrWhiteSpace($res) -or $res -eq 'none' -or $res -eq '-') { return $base }

    $hostsFile = Join-Path $homeBase 'data\agentos\hosts.json'
    $leaseDir = Join-Path $homeBase 'devops\agentos\leases'
    $hostsObj = $null
    if (Test-Path -LiteralPath $hostsFile) {
        try { $hostsObj = Get-Content -LiteralPath $hostsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $hostsObj = $null }
    }
    $hostAliases = @()
    if ($null -ne $hostsObj) { $hostAliases = @($hostsObj.hosts.PSObject.Properties | ForEach-Object { $_.Name }) }

    $aliases = @()
    if ($res -ieq 'auto') {
        $aliases = @($hostAliases)
        if (Test-Path -LiteralPath $leaseDir) {
            foreach ($lf in (Get-ChildItem -LiteralPath $leaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                $alias = [IO.Path]::GetFileNameWithoutExtension($lf.Name)
                if ($aliases -notcontains $alias) { $aliases += $alias }
            }
        }
    } else {
        $aliases = @($res)
    }

    $needSpec = [string](Get-Prop $TaskObj 'gpuSpec' '')
    $match = $null
    foreach ($alias in $aliases) {
        $hostObj = $null
        if ($null -ne $hostsObj -and ($hostAliases -contains $alias)) { $hostObj = $hostsObj.hosts.$alias }
        $prof = Get-HostProfileInfo $hostObj
        $lease = Read-LeaseFile (Join-Path $leaseDir ($alias + '.json'))
        if ($null -eq $lease) { continue }
        $allocs = @(Get-LeaseAllocInfo $lease $prof.gpu_count)
        foreach ($a in $allocs) {
            if (-not (Test-AllocationTaskMatch $a $Task $Issue)) { continue }
            $held = @($a.gpus)
            if ($needSpec -ieq 'all') {
                $cap = [int]$prof.gpu_count
                $satisfied = [bool]$a.whole_host -or ($cap -gt 0 -and $held.Count -eq $cap)
                if (-not $satisfied) {
                    throw ("resource gate: allocation on host '{0}' grants {1} GPU(s), but task {2} needs all{3}. Run 'aos room release {0} -Task {4}' then 'aos room acquire {0} -Task {4} -Issue {5} -Gpus all'. GPU is a hard constraint; track will not auto-acquire." -f $alias, $held.Count, $Task, $(if ($cap -gt 0) { " ($cap)" } else { '' }), $Task, $Issue)
                }
            } elseif ($needSpec -match '^\d+$') {
                $need = [int]$needSpec
                if (-not [bool]$a.whole_host -and $held.Count -lt $need) {
                    throw ("resource gate: allocation on host '{0}' grants {1} GPU(s), but task {2} needs {3}. Run 'aos room release {0} -Task {4}' then 'aos room acquire {0} -Task {4} -Issue {5} -Gpus {3}', or adjust needs. GPU is a hard constraint; track will not auto-acquire." -f $alias, $held.Count, $Task, $need, $Task, $Issue)
                }
            }
            $envr = Get-EnvGateStatus $TaskObj $prof
            $match = [pscustomobject]@{
                alias = $alias; alloc = $a; profile = $prof; env = $envr
            }
            break
        }
        if ($null -ne $match) { break }
    }

    if ($null -eq $match) {
        $alts = @(Get-HostFreeRows $hostsObj)
        $needCmd = if ($needSpec -ieq 'all') { 'all' } elseif ($needSpec -match '^\d+$') { $needSpec } else { '1' }
        $target = if ($res -ieq 'auto') { '<host>' } else { $res }
        $altText = (@($alts | ForEach-Object { '{0}(free {1}/{2})' -f $_.host, $_.free, $_.gpu_count }) -join ', ')
        if (-not $altText) { $altText = 'none (all hosts have 0 free GPU or are not registered)' }
        throw ("resource gate: no room allocation for task {0} (issue {1}) on resource '{2}'. Run: aos room acquire {3} -Task {0} -Issue {1} -Gpus {4}. Alternatives: {5}. Track will not auto-acquire." -f $Task, $Issue, $res, $target, $needCmd, $altText)
    }

    return [pscustomobject]@{
        Checked   = $true
        Host      = $match.alias
        Gpus      = @($match.alloc.gpus)
        Env       = $match.env.Status
        Warnings  = @($match.env.Warnings)
        Schema    = $(if ([bool]$match.alloc.legacy) { 1 } else { 2 })
        Lease     = [string]$match.alloc.task
        AgentTask = [string]$match.alloc.agent_task
        WholeHost = [bool]$match.alloc.whole_host
    }
}

function Add-Event {
    param([hashtable]$Event)
    $dir = Split-Path $Ledger -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Event['ts'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    if (-not $Event.ContainsKey('repo')) { $Event['repo'] = $repoName }
    ($Event | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Ledger -Encoding UTF8
}

function Get-PlanIssue {
    param([string]$PlanPath)
    if (-not $PlanPath -or -not (Test-Path -LiteralPath $PlanPath)) { return '' }
    $head = @(Get-Content -LiteralPath $PlanPath -Encoding UTF8 -TotalCount 80 -ErrorAction SilentlyContinue)
    foreach ($line in $head) {
        if ($line -match '^\s*-?\s*issue\s*:\s*#?(?<v>[A-Za-z0-9][A-Za-z0-9._/-]*)\s*$') { return $Matches['v'].Trim() }
    }
    return ([IO.Path]::GetFileNameWithoutExtension($PlanPath) -replace '^PLAN-', '')
}

function Assert-PlanIssueMatch {
    if (-not $Plan) { return }
    if (-not (Test-Path -LiteralPath $Plan)) { throw "PLAN not found: $Plan" }
    $planIssue = Get-PlanIssue $Plan
    if ($planIssue -and $Issue -and $planIssue -ne $Issue) {
        throw ("PLAN issue mismatch: -Issue '{0}' but '{1}' declares '{2}'. Refusing to write cross-plan state/ledger." -f $Issue, $Plan, $planIssue)
    }
}

function Set-PlanTaskState {
    param(
        [string]$PlanPath,
        [string]$TaskId,
        [string]$Status,
        [string]$OwnerName,
        [string]$EventNote,
        [switch]$NoLedger
    )
    $call = @{ Command = 'state'; Plan = $PlanPath; Task = $TaskId; Status = $Status; Owner = $OwnerName }
    if ($EventNote) { $call['Note'] = $EventNote }
    if ($NoLedger) { $call['NoLedger'] = $true }
    & (Join-Path $PSScriptRoot 'plan.ps1') @call | Out-Null
}

function Sync-PlanState {
    param([string]$Status)
    if (-not $Plan) { return }
    Set-PlanTaskState -PlanPath $Plan -TaskId $Task -Status $Status -OwnerName $Owner -EventNote $Note -NoLedger
}

function Get-AgeMinutes {
    param([string]$Ts)
    try { return [math]::Round(((Get-Date) - [datetime]::ParseExact($Ts, 'yyyy-MM-ddTHH:mm:ss', $null)).TotalMinutes, 0) }
    catch { return -1 }
}

function Get-PlanStateMap {
    param([string]$PlanPath)
    $map = @{}
    $statePath = [IO.Path]::ChangeExtension($PlanPath, '.state.json')
    if (-not (Test-Path -LiteralPath $statePath)) { return $map }
    $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
    try { $obj = $raw | ConvertFrom-Json } catch { return $map }
    foreach ($p in $obj.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [System.Collections.IDictionary]) {
            $map[$p.Name] = [pscustomobject]@{ Status = [string]$v['status']; Owner = [string]$v['owner']; Updated = [string]$v['updated'] }
        } else {
            $map[$p.Name] = [pscustomobject]@{ Status = [string]$v.status; Owner = [string]$v.owner; Updated = [string]$v.updated }
        }
    }
    return $map
}

function Get-OpenTasks {
    $events = Read-LedgerEvents -Path $Ledger
    return (Get-OpenLedgerTasks -Events $events)
}

function Assert-DispatchIdentity {
    if (-not $Plan) { return }
    if ([string]::IsNullOrWhiteSpace($Subagent)) {
        throw '-Subagent is required when -Plan is supplied: Master dispatches, subagent executes.'
    }
    if ($Owner -and $Subagent -eq $Owner) {
        throw '-Subagent must name the dispatched worker, not the owning harness/Master (Master may not execute in place of a subagent).'
    }
}

function Assert-StartGate {
    param([string]$PlanPath)
    if (-not $PlanPath) {
        return [pscustomobject]@{ Checked = $false; State = ''; MissingDeps = @(); Note = 'no -Plan supplied'; Task = $null }
    }
    if (-not (Test-Path -LiteralPath $PlanPath)) { throw "PLAN not found: $PlanPath" }
    $show = (& (Join-Path $PSScriptRoot 'plan.ps1') -Command show -Plan $PlanPath | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($show)) { throw "cannot read PLAN: $PlanPath" }
    $planObj = $show | ConvertFrom-Json
    $taskObj = @($planObj.tasks | Where-Object { [string]$_.id -eq $Task })
    if ($taskObj.Count -eq 0) { throw "no such task in PLAN: $Task" }
    $stateMap = Get-PlanStateMap $PlanPath
    $ledgerEvents = Read-LedgerEvents -Path $Ledger
    # ledger 的终态优先于可能过期的 state：避免旧 running 状态逼 Master 用 -Force 破 DAG
    function StatusOf([string]$id) {
        $lk = "$Issue|$id"
        $ls = ''
        if ($ledgerEvents.ContainsKey($lk)) { $ls = (Get-LedgerTaskInfo $ledgerEvents[$lk]).Status }
        if ($ls -in @('done', 'abandoned')) { return $ls }
        if ($stateMap.ContainsKey($id)) { return [string]$stateMap[$id].Status }
        if ($ls) { return $ls }
        return 'planned'
    }
    $missing = @()
    foreach ($d in @($taskObj[0].deps)) {
        $ds = StatusOf $d
        if ($ds -ne 'done') { $missing += ("{0}={1}" -f $d, $ds) }
    }
    if ($missing.Count -gt 0 -and -not $Force) {
        throw ("DAG gate: task {0} is not ready; deps not done: {1}. Use -Force only with a recorded reason." -f $Task, ($missing -join ', '))
    }
    $cur = StatusOf $Task
    if ($cur -in @('done', 'abandoned') -and -not $Force) {
        throw ("DAG gate: task {0} is already {1}; use -Force to reopen." -f $Task, $cur)
    }
    if ($cur -in @('running', 'review') -and -not $Force) {
        throw ("DAG gate: task {0} is already {1}; close/review it before starting again." -f $Task, $cur)
    }
    $open = Get-OpenTasks
    $k = "$Issue|$Task"
    if ($open.ContainsKey($k) -and $open[$k].held -and -not $Force) {
        throw ("DAG gate: task {0} is already open (owner='{1}', since {2}). Use review/close, or -Force with a reason." -f $Task, $open[$k].owner, $open[$k].ts)
    }
    return [pscustomobject]@{ Checked = $true; State = $cur; MissingDeps = @($missing); Note = ''; Task = $taskObj[0] }
}

function New-ReconcileError {
    param([string]$TaskId, [string]$Message)
    return [pscustomobject]@{ task = $TaskId; from = ''; to = ''; source = 'error'; error = $Message }
}

function Invoke-PlanReconcile {
    param([string]$PlanPath)
    $actions = @()
    if (-not $PlanPath -or -not (Test-Path -LiteralPath $PlanPath)) { return @() }
    $show = (& (Join-Path $PSScriptRoot 'plan.ps1') -Command show -Plan $PlanPath | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($show)) {
        return @((New-ReconcileError '' ("cannot read PLAN: " + $PlanPath)))
    }
    try { $planObj = $show | ConvertFrom-Json }
    catch { return @((New-ReconcileError '' ("cannot parse PLAN: " + $_.Exception.Message))) }
    $ledgerEvents = Read-LedgerEvents -Path $Ledger
    $stateMap = Get-PlanStateMap $PlanPath
    foreach ($t in @($planObj.tasks)) {
        $id = [string]$t.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $k = "$Issue|$id"
        $events = @()
        if ($ledgerEvents.ContainsKey($k)) { $events = @($ledgerEvents[$k]) }
        $li = Get-LedgerTaskInfo $events
        $hasState = $stateMap.ContainsKey($id)
        $ss = ''
        $so = ''
        if ($hasState) { $ss = [string]$stateMap[$id].Status; $so = [string]$stateMap[$id].Owner }
        $stateOwner = if ($li.Owner) { $li.Owner } else { $so }

        # ledger 终态 -> state 跟随（典型 stale DAG：close 已记账但 state 还停在 running/review）
        if ($li.Has -and $li.Status -in @('done', 'abandoned')) {
            if (-not $hasState -or $ss -ne $li.Status) {
                try {
                    Set-PlanTaskState -PlanPath $PlanPath -TaskId $id -Status $li.Status -OwnerName $stateOwner -NoLedger
                    $from = if ($hasState) { $ss } else { 'missing' }
                    $actions += [pscustomobject]@{ task = $id; from = $from; to = $li.Status; source = 'ledger' }
                } catch {
                    $actions += (New-ReconcileError $id $_.Exception.Message)
                }
            }
            continue
        }

        # 无 ledger 证据却停在 running/review -> 清回 planned，解除 stale DAG
        if (-not $li.Has) {
            if ($ss -in @('running', 'review')) {
                $noteText = "auto-reconciled: stale {0} state has no ledger evidence" -f $ss
                try {
                    Set-PlanTaskState -PlanPath $PlanPath -TaskId $id -Status 'planned' -OwnerName $so -EventNote $noteText
                    $actions += [pscustomobject]@{ task = $id; from = $ss; to = 'planned'; source = 'stale-state' }
                } catch {
                    $actions += (New-ReconcileError $id $_.Exception.Message)
                }
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($li.Status)) { continue }

        # state 已终态但 ledger 仍 open -> 补一条 state 事件收口，而不是把 state 拉回 running
        if ($ss -in @('done', 'abandoned')) {
            try {
                Add-Event @{
                    event = 'state'; issue = $Issue; task = $id; owner = $so; status = $ss; prev = $li.Status;
                    note = 'auto-reconciled: state already terminal, ledger still open';
                    plan = $PlanPath; source = 'reconcile'
                }
                $actions += [pscustomobject]@{ task = $id; from = $li.Status; to = $ss; source = 'state' }
            } catch {
                $actions += (New-ReconcileError $id $_.Exception.Message)
            }
            continue
        }

        # 其他不一致：以 ledger 为准补齐 state
        if (-not $hasState -or $ss -ne $li.Status) {
            try {
                Set-PlanTaskState -PlanPath $PlanPath -TaskId $id -Status $li.Status -OwnerName $stateOwner -NoLedger
                $from = if ($hasState) { $ss } else { 'missing' }
                $actions += [pscustomobject]@{ task = $id; from = $from; to = $li.Status; source = 'ledger' }
            } catch {
                $actions += (New-ReconcileError $id $_.Exception.Message)
            }
        }
    }
    return @($actions)
}

function Invoke-ReclaimCheck {
    param([string]$PlanPath)
    if ($SkipReclaim -or -not $PlanPath -or -not (Test-Path -LiteralPath $PlanPath)) { return $null }
    $planDir = Split-Path $PlanPath -Parent
    $agentosDir = Split-Path $planDir -Parent
    $repoRoot = Split-Path $agentosDir -Parent
    $checks = [ordered]@{}

    try {
        $raw = (& (Join-Path $PSScriptRoot 'audit.ps1') -Plan $PlanPath -Ledger $Ledger 2>&1 | Out-String).Trim()
        $audit = if ($raw) { $raw | ConvertFrom-Json } else { $null }
        $summary = Get-Prop $audit 'summary'
        $checks['audit'] = [pscustomobject]@{
            invoked          = $true
            ok               = [bool](Get-Prop $audit 'ok' $false)
            errors           = [int](Get-Prop $summary 'errors' -1)
            subagentMissing  = [int](Get-Prop $summary 'subagentMissing' 0)
            subagentWaived   = [int](Get-Prop $summary 'subagentWaived' 0)
            inFlight         = [int](Get-Prop $summary 'inFlight' 0)
            staleInFlight    = [int](Get-Prop $summary 'staleInFlight' 0)
            crossLayerErrors = [int](Get-Prop $summary 'crossLayerErrors' 0)
            policy           = Get-Prop $audit 'subagentPolicy'
        }
    } catch {
        $checks['audit'] = [pscustomobject]@{ invoked = $true; ok = $false; error = $_.Exception.Message; errors = -1; subagentMissing = 0; subagentWaived = 0; inFlight = 0; staleInFlight = 0; crossLayerErrors = 0 }
    }

    try {
        $raw = (& (Join-Path $PSScriptRoot 'wt.ps1') -Command prune -Repo $repoRoot 2>&1 | Out-String).Trim()
        $wt = if ($raw) { $raw | ConvertFrom-Json } else { $null }
        $items = @(Get-Prop $wt 'items' @())
        $candidates = @(Get-Prop $wt 'candidates' @())
        $dirty = @($items | Where-Object { [string](Get-Prop $_ 'Class' '') -eq 'dirty-or-artifacts' }).Count
        $checks['worktrees'] = [pscustomobject]@{
            invoked    = $true
            ok         = $true
            dryRun     = $true
            candidates = $candidates.Count
            dirty      = $dirty
            paths      = @($candidates | ForEach-Object { [string](Get-Prop $_ 'Path' '') })
        }
    } catch {
        $checks['worktrees'] = [pscustomobject]@{ invoked = $true; ok = $false; error = $_.Exception.Message; dryRun = $true; candidates = 0; dirty = 0; paths = @() }
    }

    try {
        $raw = (& (Join-Path $PSScriptRoot 'hygiene.ps1') 2>&1 | Out-String).Trim()
        $hyg = if ($raw) { $raw | ConvertFrom-Json } else { $null }
        $leaked = [int](Get-Prop $hyg 'leaked' 0)
        $checks['hygiene'] = [pscustomobject]@{
            invoked   = $true
            ok        = ($leaked -eq 0)
            dryRun    = $true
            leaked    = $leaked
            attention = @(Get-Prop $hyg 'attention' @())
        }
    } catch {
        $checks['hygiene'] = [pscustomobject]@{ invoked = $true; ok = $false; error = $_.Exception.Message; dryRun = $true; leaked = 0; attention = @() }
    }

    return [pscustomobject]@{
        mode               = 'read-only'
        destructiveApplied = $false
        audit              = $checks['audit']
        worktrees          = $checks['worktrees']
        hygiene            = $checks['hygiene']
        note               = 'wt prune and hygiene are dry-run; review before any -Apply/-Reap'
    }
}

function Write-ReclaimHuman {
    param($R)
    if ($null -eq $R) { return }
    $a = $R.audit
    $aerr = Get-Prop $a 'error' ''
    if ($aerr) {
        Write-Output ("  check audit     : ERROR " + $aerr)
    } else {
        $pol = Get-Prop $a 'policy' $null
        $pmode = Get-Prop $pol 'mode' 'legacy'
        Write-Output ("  check audit     : ok={0} errors={1} subagent-missing={2} waived={3} stale={4} cross-layer={5} policy={6}" -f (Get-Prop $a 'ok' $false), (Get-Prop $a 'errors' -1), (Get-Prop $a 'subagentMissing' 0), (Get-Prop $a 'subagentWaived' 0), (Get-Prop $a 'staleInFlight' 0), (Get-Prop $a 'crossLayerErrors' 0), $pmode)
    }
    $w = $R.worktrees
    $werr = Get-Prop $w 'error' ''
    if ($werr) {
        Write-Output ("  check wt prune  : ERROR " + $werr)
    } else {
        Write-Output ("  check wt prune  : dry-run candidates={0} dirty={1}" -f (Get-Prop $w 'candidates' 0), (Get-Prop $w 'dirty' 0))
    }
    foreach ($p in @(Get-Prop $w 'paths' @())) { if ($p) { Write-Output ("                    candidate: " + $p) } }
    $h = $R.hygiene
    $herr = Get-Prop $h 'error' ''
    if ($herr) {
        Write-Output ("  check hygiene   : ERROR " + $herr)
    } else {
        Write-Output ("  check hygiene   : dry-run leaked={0}" -f (Get-Prop $h 'leaked' 0))
    }
    foreach ($x in @(Get-Prop $h 'attention' @())) { if ($x) { Write-Output ("                    attention: " + $x) } }
    Write-Output ("  reclaim is read-only (no prune -Apply, no hygiene -Reap)")
}

function Invoke-Dispatch {
switch ($Command) {
    'start' {
        if (-not $Task) { throw '-Task is required' }
        Assert-PlanIssueMatch
        Assert-DispatchIdentity
        $gate = Assert-StartGate $Plan
        $resourceGate = Assert-ResourceGate $gate.Task
        Add-Event @{
            event = 'start'; issue = $Issue; task = $Task; owner = $Owner;
            subagent = $Subagent; wave = $Wave; plan = $Plan; forced = [bool]$Force
        }
        $policyStatus = 'not-applicable'
        if ($Plan -and $Subagent) {
            $policyState = Get-SubagentPolicy -LedgerPath $Ledger
            if ($policyState.Mode -in @('missing', 'orphan-file')) {
                # Auto policy is only allowed when a signing key is available.
                # Never write an unsigned policy: production initialization belongs to Master.
                $policyKey = Resolve-PolicyPfx -PfxPath $PfxPath -PfxPassword $PfxPassword
                if ($null -ne $policyKey) {
                    $policyAuth = if ($Owner) { $Owner } else { 'track-auto' }
                    $null = Add-LedgerPolicyEvent -LedgerPath $Ledger -Source 'track-start' -AuthorizedBy $policyAuth -Note 'auto policy initialization on first tracked dispatch' -PfxPath $PfxPath -PfxPassword $PfxPassword
                    $policyStatus = 'signed'
                } else {
                    $policyStatus = 'skipped-no-key'
                }
            } elseif ($policyState.Mode -ne 'active') {
                throw ("subagent policy is {0}; run audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who> (start will not overwrite tamper)" -f $policyState.Mode)
            } else {
                $policyStatus = 'active'
            }
        }
        Sync-PlanState 'running'
        if ($machine) {
            [pscustomobject]@{
                ok = $true; event = 'start'; issue = $Issue; task = $Task; owner = $Owner;
                subagent = $Subagent; wave = $Wave; repo = $repoName; status = 'running';
                policy = $policyStatus; gate = $gate; resource = $resourceGate; forced = [bool]$Force
            } | ConvertTo-Json -Depth 8
            return
        }
        Write-Output ("start: issue={0} task={1} owner={2} subagent={3} wave={4}" -f $Issue, $Task, $Owner, $Subagent, $Wave)
        if ($policyStatus -eq 'skipped-no-key') { Write-Output '  WARNING: no policy signing key; audit will report policy-missing until Master runs audit -InitPolicy -PfxPath ...' }
        if ($gate.Checked) { Write-Output ("gate: state={0} deps-ok={1}" -f $gate.State, (@($gate.MissingDeps).Count -eq 0)) }
        if ($resourceGate.Checked) {
            Write-Output ("resource: host={0} gpus={1} env={2}" -f $resourceGate.Host, (@($resourceGate.Gpus) -join ','), $resourceGate.Env)
            foreach ($w in @($resourceGate.Warnings)) { if ($w) { Write-Output ('  WARNING: ' + $w) } }
        }
    }
    'review' {
        if (-not $Task) { throw '-Task is required' }
        Assert-PlanIssueMatch
        Add-Event @{ event = 'review'; issue = $Issue; task = $Task; owner = $Owner; note = $Note; plan = $Plan }
        Sync-PlanState 'review'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'review'; issue = $Issue; task = $Task; owner = $Owner; status = 'review' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("review: issue={0} task={1}" -f $Issue, $Task)
    }
    'close' {
        if (-not $Task) { throw '-Task is required' }
        Assert-PlanIssueMatch
        $ledgerEvents = Read-LedgerEvents -Path $Ledger
        $k = "$Issue|$Task"
        $events = @()
        if ($ledgerEvents.ContainsKey($k)) { $events = @($ledgerEvents[$k]) }
        $pre = Get-LedgerTaskInfo $events
        $policyState = Get-SubagentPolicy -LedgerPath $Ledger
        $subagentStatus = Get-SubagentGapStatus -Info $pre -Policy $policyState
        $subagentMissing = ($subagentStatus -eq 'missing')
        Add-Event @{
            event = 'close'; issue = $Issue; task = $Task; owner = $Owner; note = $Note; plan = $Plan;
            subagent = $pre.StartSubagent; subagentMissing = $subagentMissing; subagentStatus = $subagentStatus; forced = [bool]$Force
        }
        $stateSyncError = ''
        try { Sync-PlanState 'done' } catch { $stateSyncError = $_.Exception.Message }
        $reconciled = @(Invoke-PlanReconcile $Plan)
        $reconcileErrors = @($reconciled | Where-Object { [string](Get-Prop $_ 'error' '') -ne '' })
        $reclaim = Invoke-ReclaimCheck $Plan
        $attention = @()
        if ($stateSyncError) { $attention += ('state sync failed: ' + $stateSyncError) }
        if ($reconcileErrors.Count -gt 0) {
            $detail = ($reconcileErrors | ForEach-Object { [string](Get-Prop $_ 'task' '?') + '=' + [string](Get-Prop $_ 'error' '') }) -join '; '
            $attention += ('reconcile errors: ' + $detail)
        }
        if ($subagentMissing) { $attention += 'no start event with -Subagent; audit will report subagent-missing' }
        if ($null -ne $reclaim) {
            $a = $reclaim.audit
            if (-not [bool](Get-Prop $a 'ok' $false)) {
                $attention += ('audit ok=false errors={0} subagentMissing={1}' -f (Get-Prop $a 'errors' -1), (Get-Prop $a 'subagentMissing' 0))
            }
            if ([int](Get-Prop $a 'staleInFlight' 0) -gt 0) { $attention += ('audit staleInFlight={0}' -f (Get-Prop $a 'staleInFlight' 0)) }
            if ([int](Get-Prop $a 'crossLayerErrors' 0) -gt 0) { $attention += ('audit crossLayerErrors={0}' -f (Get-Prop $a 'crossLayerErrors' 0)) }
            $w = $reclaim.worktrees
            if (-not [bool](Get-Prop $w 'ok' $true)) {
                $werr = [string](Get-Prop $w 'error' '')
                if ($werr) { $attention += ('wt prune check failed: ' + $werr) }
                else { $attention += 'wt prune check failed: ok=false' }
            }
            if ([int](Get-Prop $w 'dirty' 0) -gt 0) { $attention += ('dirty worktree(s) retained={0}' -f (Get-Prop $w 'dirty' 0)) }
            if ([int](Get-Prop $w 'candidates' 0) -gt 0) { $attention += ('wt prune safe candidates={0} (manual -Apply only)' -f (Get-Prop $w 'candidates' 0)) }
            $h = $reclaim.hygiene
            if (-not [bool](Get-Prop $h 'ok' $true)) {
                $herr = [string](Get-Prop $h 'error' '')
                if ($herr) { $attention += ('hygiene check failed: ' + $herr) }
                elseif ([int](Get-Prop $h 'leaked' 0) -le 0) { $attention += 'hygiene check failed: ok=false' }
            }
            if ([int](Get-Prop $h 'leaked' 0) -gt 0) { $attention += ('hygiene leaked groups={0}' -f (Get-Prop $h 'leaked' 0)) }
        }
        if ($machine) {
            [pscustomobject]@{
                ok = $true; event = 'close'; issue = $Issue; task = $Task; owner = $Owner; status = 'done';
                subagent = $pre.StartSubagent; subagentMissing = $subagentMissing; subagentStatus = $subagentStatus; forced = [bool]$Force;
                reconciled = @($reconciled); reclaim = $reclaim; attention = @($attention)
            } | ConvertTo-Json -Depth 8
            return
        }
        Write-Output ("close: issue={0} task={1} owner={2} subagent={3}" -f $Issue, $Task, $Owner, $pre.StartSubagent)
        if ($subagentMissing) { Write-Output '  WARNING: no start event with -Subagent; audit will report subagent-missing' }
        foreach ($a in $reconciled) {
            if ([string](Get-Prop $a 'error' '') -ne '') {
                Write-Output ("  reconcile-error: {0} {1}" -f (Get-Prop $a 'task' ''), (Get-Prop $a 'error' ''))
            } else {
                Write-Output ("  reconciled: {0} {1} -> {2} ({3})" -f $a.task, $a.from, $a.to, $a.source)
            }
        }
        if ($null -ne $reclaim) { Write-ReclaimHuman $reclaim }
        foreach ($msg in $attention) { Write-Output ("  ATTENTION: " + $msg) }
    }
    'block' {
        if (-not $Task) { throw '-Task is required' }
        Assert-PlanIssueMatch
        Add-Event @{ event = 'block'; issue = $Issue; task = $Task; owner = $Owner; reason = $Reason; note = $Note; plan = $Plan }
        Sync-PlanState 'blocked'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'block'; issue = $Issue; task = $Task; owner = $Owner; status = 'blocked' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("block: issue={0} task={1} reason={2}" -f $Issue, $Task, $Reason)
    }
    'abandon' {
        if (-not $Task) { throw '-Task is required' }
        if ([string]::IsNullOrWhiteSpace($Reason) -and [string]::IsNullOrWhiteSpace($Note)) {
            throw '-Reason or -Note is required when abandoning a task'
        }
        Assert-PlanIssueMatch
        Add-Event @{ event = 'abandon'; issue = $Issue; task = $Task; owner = $Owner; reason = $Reason; note = $Note; plan = $Plan }
        Sync-PlanState 'abandoned'
        if ($machine) { [pscustomobject]@{ ok = $true; event = 'abandon'; issue = $Issue; task = $Task; owner = $Owner; status = 'abandoned' } | ConvertTo-Json -Depth 4; return }
        Write-Output ("abandon: issue={0} task={1}" -f $Issue, $Task)
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
            $items += [pscustomobject]@{ issue = $t.issue; task = $t.task; owner = $t.owner; subagent = $t.subagent; wave = $t.wave; repo = $t.repo; started = $t.ts; age_min = (Get-AgeMinutes $t.ts); claimable = ((Get-AgeMinutes $t.ts) -ge $StaleMinutes) }
        }
        if ($machine) { [pscustomobject]@{ ok = $true; count = @($items).Count; items = @($items | Sort-Object age_min -Descending) } | ConvertTo-Json -Depth 5; return }
        $items | Sort-Object age_min -Descending | Format-Table issue, task, owner, subagent, wave, repo, age_min, claimable -AutoSize
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
            Write-Output ("{0}  {1,-7} issue={2} task={3} owner={4} subagent={5}" -f $e.ts, $e.event, $e.issue, $e.task, $e.owner, $e.subagent)
        }
    }
    'lost' {
        $open = Get-OpenTasks
        $found = @()
        foreach ($k in $open.Keys) {
            $t = $open[$k]
            if (-not $t.held) { continue }
            $age = Get-AgeMinutes $t.ts
            if ($age -ge $StaleMinutes) { $found += [pscustomobject]@{ issue = $t.issue; task = $t.task; owner = $t.owner; subagent = $t.subagent; repo = $t.repo; age_min = $age } }
        }
        if ($machine) { [pscustomobject]@{ ok = $true; count = @($found).Count; items = @($found) } | ConvertTo-Json -Depth 5; return }
        if (@($found).Count -eq 0) { Write-Output ("no LOST task within {0} min window" -f $StaleMinutes) }
        else { $found | ForEach-Object { Write-Output ("LOST started={0} issue={1} task={2} owner={3} subagent={4}" -f $_.age_min, $_.issue, $_.task, $_.owner, $_.subagent) } }
    }
}
}

Invoke-Dispatch
exit 0
