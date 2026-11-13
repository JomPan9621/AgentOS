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
    [int]$WorktreeLimit = 8,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bin = $PSScriptRoot
. (Join-Path $bin 'ledger.ps1')
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

function Get-HostProfileLocal {
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

function Get-LeaseAllocationsLocal {
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

function Get-EnvWarningStatus {
    param($TaskObj, $Profile)
    $envObj = Get-Prop $TaskObj 'envNeeds' $null
    $keys = @()
    if ($null -ne $envObj) {
        foreach ($p in $envObj.PSObject.Properties) { if ($p.Name) { $keys += $p.Name } }
    }
    if ($keys.Count -eq 0) { return [pscustomobject]@{ Status = 'n/a'; Details = @() } }
    $norm = { param([string]$s) return (($s.ToLowerInvariant() -replace '[_-]+', ' ' -replace '\s+', ' ').Trim()) }
    $hasMismatch = $false
    $hasUnknown = $false
    $details = @()
    foreach ($k in $keys) {
        $expected = [string](Get-Prop $envObj $k '')
        $actual = [string](Get-Prop $Profile $k '')
        if ([string]::IsNullOrWhiteSpace($actual) -or [string]::IsNullOrWhiteSpace($expected)) {
            $hasUnknown = $true
            $details += ('env.{0}: expected ''{1}'' host ''{2}'' (unknown)' -f $k, $expected, $(if ($actual) { $actual } else { 'UNKNOWN' }))
            continue
        }
        $e = & $norm $expected
        $a = & $norm $actual
        if ($a.Contains($e) -or $e.Contains($a)) {
            $details += ('env.{0}: expected ''{1}'' host ''{2}'' (match)' -f $k, $expected, $actual)
        } else {
            $hasMismatch = $true
            $details += ('env.{0}: expected ''{1}'' host ''{2}'' (mismatch)' -f $k, $expected, $actual)
        }
    }
    $status = if ($hasMismatch) { 'mismatch' } elseif ($hasUnknown) { 'unknown' } else { 'match' }
    return [pscustomobject]@{ Status = $status; Details = @($details) }
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
# 统一由 bin/ledger.ps1 解析；session/policy 事件不会污染任务视图。
if (Test-Path -LiteralPath $ledgerPath) {
    $ledgerEvents = Read-LedgerEvents -Path $ledgerPath
    $openMap = Get-OpenLedgerTasks -Events $ledgerEvents
    $seen = @{}
    foreach ($a in $active) { $seen[[string]$a.task] = $true }
    foreach ($k in $openMap.Keys) {
        $e = $openMap[$k]
        if (-not $e.held) { continue }
        if ($seen.ContainsKey([string]$e.task)) { continue }
        $active += [pscustomobject]@{
            plan     = 'ledger-only'
            issue    = [string]$e.issue
            task     = [string]$e.task
            status   = [string]$e.status
            owner    = [string]$e.owner
            subagent = [string]$e.subagent
            wave     = [string]$e.wave
            updated  = [string]$e.ts
        }
    }
}

# --- 会话（harness presence，统一 ledger 事件）---
$sessions = @()
if (Test-Path -LiteralPath $ledgerPath) {
    foreach ($s in @(Get-LedgerSessions -Path $ledgerPath)) {
        if ($s.closed) { continue }
        $sessions += [pscustomobject]@{ id = $s.id; role = $s.role; issue = $s.issue; task = $s.task; host = $s.host; started = $s.started; lastHeartbeat = $s.lastHeartbeat }
    }
}

# --- 资源（远端 GPU 子租约 / v1 legacy 整机租约）---
$resources = $null
$hostsFile3 = Join-Path $homeBase 'data\agentos\hosts.json'
$leaseDir3  = Join-Path $homeBase 'devops\agentos\leases'
if (Test-Path -LiteralPath $hostsFile3) {
    try {
        $hostsObj3 = (Get-Content -LiteralPath $hostsFile3 -Raw -Encoding UTF8 | ConvertFrom-Json)
        $leases3 = @{}
        if (Test-Path -LiteralPath $leaseDir3) {
            foreach ($lf3 in (Get-ChildItem -LiteralPath $leaseDir3 -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                try {
                    $lj3 = (Get-Content -LiteralPath $lf3.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
                    $alias3 = [string](Get-Prop $lj3 'host' '')
                    if (-not $alias3) { $alias3 = [IO.Path]::GetFileNameWithoutExtension($lf3.Name) }
                    $leases3[$alias3] = $lj3
                } catch { }
            }
        }
        $resRows = @()
        $hostProfiles = @{}
        foreach ($hp3 in $hostsObj3.hosts.PSObject.Properties) {
            $alias3 = $hp3.Name
            $prof3 = Get-HostProfileLocal $hp3.Value
            $hostProfiles[$alias3] = $prof3
            $lg3 = if ($leases3.ContainsKey($alias3)) { $leases3[$alias3] } else { $null }
            $allocs3 = @(Get-LeaseAllocationsLocal $lg3 ([int]$prof3.gpu_count))
            $used3 = @()
            foreach ($a3 in $allocs3) { foreach ($g3 in @($a3.gpus)) { $used3 += [int]$g3 } }
            $used3 = @($used3 | Sort-Object -Unique)
            $schema3 = 1
            if ($null -ne $lg3) {
                $sv3 = Get-Prop $lg3 'schema_version' 1
                try { $schema3 = [int]$sv3 } catch { $schema3 = 1 }
            }
            $resRows += [pscustomobject]@{
                host        = $alias3
                hostname    = [string](Get-Prop $hp3.Value 'hostname' '')
                profile     = $prof3
                gpu_count   = [int]$prof3.gpu_count
                gpus_used   = $used3.Count
                gpus_free   = [Math]::Max(0, [int]$prof3.gpu_count - $used3.Count)
                lease_mode  = $(if ($null -eq $lg3) { 'free' } elseif ($schema3 -lt 2) { 'legacy' } else { 'allocations' })
                lease       = $(if ($null -eq $lg3) { 'free' } elseif ($schema3 -lt 2) { [string](Get-Prop $lg3 'task' '') } else { 'allocated' })
                acquired    = $(if ($null -ne $lg3) { [string](Get-Prop $lg3 'acquired_at' '') } else { '' })
                note        = $(if ($null -ne $lg3) { [string](Get-Prop $lg3 'note' '') } else { '' })
                allocations = @($allocs3 | ForEach-Object {
                        [pscustomobject]@{
                            task = $_.task; issue = $_.issue; agent_task = $_.agent_task;
                            gpus = @($_.gpus); acquired_at = $_.acquired_at; legacy = [bool]$_.legacy
                        }
                    })
            }
        }
        # env mismatch/unknown 只是软感知：放入 envWarnings，不进入 attention / exit code。
        $envWarnings = @()
        if ($null -ne $planObj) {
            foreach ($t3 in @(Get-Prop $planObj 'tasks' @())) {
                $res3 = [string](Get-Prop $t3 'resource' 'none')
                if ([string]::IsNullOrWhiteSpace($res3) -or $res3 -eq 'none' -or $res3 -eq '-' -or $res3 -ieq 'auto') { continue }
                if (-not $hostProfiles.ContainsKey($res3)) { continue }
                $envr3 = Get-EnvWarningStatus $t3 $hostProfiles[$res3]
                if ($envr3.Status -in @('mismatch', 'unknown')) {
                    $envWarnings += [pscustomobject]@{
                        task = [string](Get-Prop $t3 'id' ''); host = $res3; status = $envr3.Status;
                        detail = (@($envr3.Details) -join '; ')
                    }
                }
            }
        }
        $totalGpus3 = 0; $usedGpus3 = 0; $freeGpus3 = 0; $allocCount3 = 0
        foreach ($r3 in $resRows) {
            $totalGpus3 += [int]$r3.gpu_count
            $usedGpus3 += [int]$r3.gpus_used
            $freeGpus3 += [int]$r3.gpus_free
            $allocCount3 += @($r3.allocations).Count
        }
        $resources = [pscustomobject]@{
            total       = $resRows.Count
            free        = @($resRows | Where-Object { $_.lease_mode -eq 'free' }).Count
            gpu_count   = $totalGpus3
            gpus_used   = $usedGpus3
            gpus_free   = $freeGpus3
            allocations = $allocCount3
            envWarnings = @($envWarnings)
            hosts       = $resRows
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
    agentos   = '1.3.0'
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
    sessions  = $sessions
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
