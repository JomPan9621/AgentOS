<#
.SYNOPSIS
  PLAN / state / ledger 三方对账：找出丢账、孤账、未登记和失联任务。
.DESCRIPTION
  默认递归扫描当前目录（跨仓用 -Root 指定），跳过 linked worktree。
  对每个 PLAN 节点比较任务表、*.state.json 与全局 ledger.jsonl。
  ledger 中无 PLAN 的 issue|task：该 issue 有 PLAN 时仍是 ledger-only 错误；无 PLAN 且登记在
  <homebase>\data\agentos\audit-history.json 的历史键归入 unplanned-historical（warning）；
  其余计入 unplanned-ledger。历史文件缺失视为空；历史文件格式错误直接报错，不静默豁免。

  - state-only    : state 已变更（running/review/done/abandoned/blocked），ledger 没有任何事件
  - state-missing : ledger 有事件，PLAN state 没有该节点
  - ledger-only   : ledger 有事件，PLAN 任务表没有该行
  - mismatch      : state 与 ledger 的最终状态不一致
  - subagent-missing : 有执行证据，但 ledger 没有带 -Subagent 的 start（Master 直接执行 / plan state 绕过）
  - in-flight     : ledger 仍有未关闭节点（state 只作补充）
  - dormant       : PLAN 存在但没有任何 state/ledger 记录（不是错误，只是游离计划）

  -Backfill 只处理可证明的缺口：state-only -> 追加带 backfilled=true 的 state 事件；
  state-missing -> 从 ledger 末次事件恢复 state（不伪造 ledger）。ledger-only 必须人工补 PLAN 行。
  exit 0 = 无错误；2 = 有错账或失联；1 = 参数/执行错误。
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Plan = '',
    [string]$Ledger = '',
    [string]$LeaseDir = '',
    [string]$HostsFile = '',
    [string]$HistoryFile = '',
    [int]$CrossLayerGraceMinutes = 15,
    [string]$SubagentSince = '',
    [switch]$InitPolicy,
    [string]$AuthorizedBy = '',
    [string]$PfxPath = '',
    [string]$PfxPassword = '',
    [int]$StaleMinutes = 120,
    [switch]$Backfill,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
if ([string]::IsNullOrWhiteSpace($Ledger)) { $Ledger = Join-Path $homeBase 'devops\agentos\ledger.jsonl' }
if ([string]::IsNullOrWhiteSpace($LeaseDir)) { $LeaseDir = Join-Path $homeBase 'devops\agentos\leases' }
if ([string]::IsNullOrWhiteSpace($HostsFile)) { $HostsFile = Join-Path $homeBase 'data\agentos\hosts.json' }
if ([string]::IsNullOrWhiteSpace($HistoryFile)) { $HistoryFile = Join-Path $homeBase 'data\agentos\audit-history.json' }
$machine = -not $Human
. (Join-Path $PSScriptRoot 'ledger.ps1')

$roots = @()
if (-not [string]::IsNullOrWhiteSpace($Root)) {
    $roots = @($Root)
} else {
    $roots = @((Get-Location).Path)
}
$roots = @($roots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })

function Get-Field {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

function Find-PlanFiles {
    param([string[]]$SearchRoots)
    if (-not [string]::IsNullOrWhiteSpace($Plan)) {
        if (-not (Test-Path -LiteralPath $Plan)) { throw "PLAN not found: $Plan" }
        return @((Resolve-Path -LiteralPath $Plan).Path)
    }
    $files = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $skip = @('.git', 'node_modules', '.venv', 'venv', 'out', 'build', 'dist', '.cache', '__pycache__', 'archive', '.idea', '.vscode')
    foreach ($root in $SearchRoots) {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push([pscustomobject]@{ Path = $root; Depth = 0 })
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $dir = $item.Path
            $depth = [int]$item.Depth
            if ($depth -gt 8) { continue }
            if ($depth -gt 0 -and $skip -contains (Split-Path $dir -Leaf)) { continue }
            $plansDir = Join-Path $dir '.agentos\plans'
            if (Test-Path -LiteralPath $plansDir) {
                foreach ($f in (Get-ChildItem -LiteralPath $plansDir -Filter 'PLAN-*.md' -File -ErrorAction SilentlyContinue)) {
                    $full = $f.FullName
                    $key = $full.ToLowerInvariant()
                    if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $files.Add($full) }
                }
            }
            if ($depth -ge 8) { continue }
            foreach ($child in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
                if ($skip -contains $child.Name) { continue }
                $stack.Push([pscustomobject]@{ Path = $child.FullName; Depth = $depth + 1 })
            }
        }
    }
    return @($files | Sort-Object)
}

function Read-PlanIssue {
    param([string]$Path)
    $head = @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 80 -ErrorAction SilentlyContinue)
    foreach ($line in $head) {
        if ($line -match '^\s*-?\s*issue\s*:\s*#?(?<v>[A-Za-z0-9][A-Za-z0-9._/-]*)\s*$') { return $Matches['v'].Trim() }
    }
    return ([IO.Path]::GetFileNameWithoutExtension($Path) -replace '^PLAN-', '')
}

function Read-PlanTasks {
    param([string]$Path)
    $tasks = [System.Collections.Generic.List[object]]::new()
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match '^##\s+(?<name>.+?)\s*$') { $section = $Matches['name'].Trim().ToLowerInvariant(); continue }
        if ($section -ne 'tasks') { continue }
        $t = $line.Trim()
        if (-not $t.StartsWith('|')) { continue }
        $cells = @($t.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 8) { continue }
        if ($cells[0] -eq 'id' -or $cells[0] -match '^:?-+:?$') { continue }
        $resource = $cells[5].Trim()
        if ([string]::IsNullOrWhiteSpace($resource) -or $resource -eq '-') { $resource = 'none' }
        $needs = if ($cells.Count -ge 9) { $cells[8] } else { '' }
        $tasks.Add([pscustomobject]@{
            Id       = $cells[0]
            Title    = $cells[1]
            Kind     = $cells[2].ToLowerInvariant()
            Deps     = @($cells[3] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
            Worktree = $cells[6]
            Accept   = $cells[7]
            Resource = $resource
            Needs    = $needs
        })
    }
    return $tasks.ToArray()
}

function Read-StateMap {
    param([string]$PlanPath)
    $map = @{}
    $statePath = [IO.Path]::ChangeExtension($PlanPath, '.state.json')
    if (-not (Test-Path -LiteralPath $statePath)) { return $map }
    $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
    try { $obj = $raw | ConvertFrom-Json } catch { return $map }
    foreach ($p in $obj.PSObject.Properties) {
        $v = $p.Value
        $h = @{}
        if ($v -is [System.Collections.IDictionary]) {
            $h['status'] = [string]$v['status']; $h['owner'] = [string]$v['owner']
            $h['prev'] = [string]$v['prev']; $h['updated'] = [string]$v['updated']
            if ($v.Contains('source')) { $h['source'] = [string]$v['source'] }
        } else {
            $h['status'] = [string]$v.status; $h['owner'] = [string]$v.owner
            $h['prev'] = [string]$v.prev; $h['updated'] = [string]$v.updated
            if ($null -ne $v.PSObject.Properties['source']) { $h['source'] = [string]$v.source }
        }
        $map[$p.Name] = $h
    }
    return $map
}

function Write-StateMap {
    param([string]$PlanPath, [hashtable]$Map)
    $statePath = [IO.Path]::ChangeExtension($PlanPath, '.state.json')
    $Map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    return $statePath
}

function Read-LedgerModel {
    param([string]$Path)
    $events = Read-LedgerEvents -Path $Path
    $open = Get-OpenLedgerTasks -Events $events
    return [pscustomobject]@{ Events = $events; Open = $open }
}

function Read-AuditHistory {
    param([string]$Path)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) { return $map }
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "audit history file is empty: $Path" }
    try { $obj = $raw | ConvertFrom-Json } catch { throw ("audit history file is invalid JSON: {0}: {1}" -f $Path, $_.Exception.Message) }
    if ($null -eq $obj) { throw ("audit history file has an invalid top-level JSON value: {0}" -f $Path) }
    $schemaProp = $obj.PSObject.Properties['schema_version']
    $schema = -1
    if ($null -ne $schemaProp -and $null -ne $schemaProp.Value) {
        try { $schema = [int]$schemaProp.Value } catch { $schema = -1 }
    }
    if ($schema -ne 1) { throw ("audit history file has unsupported schema_version (expected 1): {0}" -f $Path) }
    $entriesProp = $obj.PSObject.Properties['entries']
    if ($null -eq $entriesProp -or $null -eq $entriesProp.Value) { throw ("audit history file has no entries array: {0}" -f $Path) }
    foreach ($entry in @($entriesProp.Value)) {
        if ($null -eq $entry) { throw ("audit history file has a null entry: {0}" -f $Path) }
        $keyProp = $entry.PSObject.Properties['key']
        $key = if ($null -ne $keyProp) { [string]$keyProp.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($key)) { throw ("audit history file has an entry without key: {0}" -f $Path) }
        $reasonProp = $entry.PSObject.Properties['reason']
        $reason = if ($null -ne $reasonProp -and $null -ne $reasonProp.Value) { [string]$reasonProp.Value } else { '' }
        $map[$key] = $reason
    }
    return $map
}

function Get-Opt {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-HostGpuCountAudit {
    param($HostObj)
    $profile = Get-Opt $HostObj 'profile' $null
    $count = 0
    $gc = Get-Opt $profile 'gpu_count' $null
    if ($null -ne $gc -and ("$gc" -match '^\d+$')) { $count = [int]$gc }
    if ($count -le 0) {
        $hc = Get-Opt $HostObj 'gpu_count' $null
        if ($null -ne $hc -and ("$hc" -match '^\d+$')) { $count = [int]$hc }
    }
    if ($count -le 0) {
        foreach ($tag in @(Get-Opt $HostObj 'tags' @())) {
            $t = [string]$tag
            if ($t -match '^(?<n>\d+)gpu$') { $count = [int]$Matches['n']; break }
        }
    }
    return $count
}

function Get-HostProfileAudit {
    param($HostObj)
    $profile = Get-Opt $HostObj 'profile' $null
    return [pscustomobject]@{
        os = [string](Get-Opt $profile 'os' ''); runtime = [string](Get-Opt $profile 'runtime' '')
        gpu_model = [string](Get-Opt $profile 'gpu_model' ''); driver = [string](Get-Opt $profile 'driver' '')
        image = [string](Get-Opt $profile 'image' ''); gpu_count = (Get-HostGpuCountAudit $HostObj)
    }
}

function ConvertFrom-NeedsAudit {
    param([string]$Raw)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $map }
    foreach ($part in ($Raw -split ';')) {
        $kv = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($kv) -or $kv -eq '-') { continue }
        $i = $kv.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $kv.Substring(0, $i).Trim().ToLowerInvariant()
        $v = $kv.Substring($i + 1).Trim()
        if ($k) { $map[$k] = $v }
    }
    return $map
}

function Test-EnvMatchAudit {
    param([string]$Expected, [string]$Actual)
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return 'unknown' }
    $norm = { param([string]$s) return (($s.ToLowerInvariant() -replace '[_-]+', ' ' -replace '\s+', ' ').Trim()) }
    $e = & $norm $Expected
    $a = & $norm $Actual
    if ([string]::IsNullOrWhiteSpace($e) -or [string]::IsNullOrWhiteSpace($a)) { return 'unknown' }
    if ($a.Contains($e) -or $e.Contains($a)) { return 'match' }
    return 'mismatch'
}

function Get-ResourceAudit {
    param([string]$HostsFilePath, [string]$LeaseDirPath, $PlanRows)
    $findings = [System.Collections.Generic.List[object]]::new()
    $hosts = @{}
    if (Test-Path -LiteralPath $HostsFilePath) {
        try {
            $hj = Get-Content -LiteralPath $HostsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $hj.hosts.PSObject.Properties) {
                $hosts[$p.Name] = [pscustomobject]@{
                    name = $p.Name; gpu_count = (Get-HostGpuCountAudit $p.Value); profile = (Get-HostProfileAudit $p.Value)
                }
            }
        } catch { }
    }
    $allocations = @()
    $legacyLeases = 0
    if (Test-Path -LiteralPath $LeaseDirPath) {
        foreach ($f in (Get-ChildItem -LiteralPath $LeaseDirPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $lj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $alias = [string](Get-Opt $lj 'host' '')
            if (-not $alias) { $alias = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $cap = 0
            if ($hosts.ContainsKey($alias)) { $cap = [int]$hosts[$alias].gpu_count }
            $sv = Get-Opt $lj 'schema_version' 1
            $schema = 1
            try { $schema = [int]$sv } catch { $schema = 1 }
            $allocProp = Get-Opt $lj 'allocations' $null
            if ($schema -ge 2 -and $null -ne $allocProp) {
                foreach ($a in @($allocProp)) {
                    if ($null -eq $a) { continue }
                    $ids = @()
                    foreach ($g in @(Get-Opt $a 'gpus' @())) { if ("$g" -match '^\d+$') { $ids += [int]$g } }
                    $allocations += [pscustomobject]@{
                        host = $alias; task = [string](Get-Opt $a 'task' ''); issue = [string](Get-Opt $a 'issue' '')
                        agent_task = [string](Get-Opt $a 'agent_task' ''); gpus = @($ids | Sort-Object -Unique)
                        legacy = $false; whole_host = $false
                    }
                }
            } else {
                $legacyLeases++
                $ids = @()
                for ($i = 0; $i -lt $cap; $i++) { $ids += $i }
                $allocations += [pscustomobject]@{
                    host = $alias; task = [string](Get-Opt $lj 'task' ''); issue = [string](Get-Opt $lj 'issue' '')
                    agent_task = [string](Get-Opt $lj 'agent_task' ''); gpus = @($ids)
                    legacy = $true; whole_host = $true
                }
            }
        }
    }

    $usedByHost = @{}
    $gpuErrors = 0
    foreach ($a in $allocations) {
        if (-not $usedByHost.ContainsKey($a.host)) { $usedByHost[$a.host] = @() }
        foreach ($g in @($a.gpus)) {
            if ($usedByHost[$a.host] -contains $g) {
                $gpuErrors++
                $findings.Add([pscustomobject]@{
                    kind = 'gpu-overlap'; repo = ''; plan = ''; issue = $a.issue; task = $a.task; severity = 'error';
                    detail = ("GPU {0} on host '{1}' is allocated more than once" -f $g, $a.host)
                })
            } else {
                $usedByHost[$a.host] += $g
            }
            if ($hosts.ContainsKey($a.host) -and [int]$hosts[$a.host].gpu_count -gt 0 -and (($g -lt 0) -or ($g -ge [int]$hosts[$a.host].gpu_count))) {
                $gpuErrors++
                $findings.Add([pscustomobject]@{
                    kind = 'gpu-out-of-range'; repo = ''; plan = ''; issue = $a.issue; task = $a.task; severity = 'error';
                    detail = ("GPU id {0} on host '{1}' is outside gpu_count={2}" -f $g, $a.host, $hosts[$a.host].gpu_count)
                })
            }
        }
    }
    foreach ($h in @($usedByHost.Keys)) {
        if ($hosts.ContainsKey($h) -and [int]$hosts[$h].gpu_count -gt 0 -and @($usedByHost[$h]).Count -gt [int]$hosts[$h].gpu_count) {
            $gpuErrors++
            $findings.Add([pscustomobject]@{
                kind = 'gpu-overcapacity'; repo = ''; plan = ''; issue = ''; task = ''; severity = 'error';
                detail = ("host '{0}' has {1} allocated GPUs > gpu_count={2}" -f $h, @($usedByHost[$h]).Count, $hosts[$h].gpu_count)
            })
        }
    }

    $envWarnings = 0
    foreach ($rec in @($PlanRows)) {
        $issue = [string]$rec.Issue
        foreach ($t in @($rec.Tasks)) {
            $res = [string](Get-Opt $t 'Resource' 'none')
            if ([string]::IsNullOrWhiteSpace($res) -or $res -eq 'none' -or $res -eq '-' -or $res -ieq 'auto') { continue }
            if (-not $hosts.ContainsKey($res)) { continue }
            $needsRaw = [string](Get-Opt $t 'Needs' '')
            if ([string]::IsNullOrWhiteSpace($needsRaw)) { continue }
            $nm = ConvertFrom-NeedsAudit $needsRaw
            foreach ($k in @($nm.Keys | Where-Object { $_.StartsWith('env.') })) {
                $field = $k.Substring(4)
                $expected = [string]$nm[$k]
                $actual = [string](Get-Opt $hosts[$res].profile $field '')
                $st = Test-EnvMatchAudit $expected $actual
                if ($st -ne 'match') {
                    $envWarnings++
                    $findings.Add([pscustomobject]@{
                        kind = ('env-' + $st); repo = [string]$rec.Repo; plan = [string]$rec.Path; issue = $issue; task = [string]$t.Id;
                        severity = 'warning';
                        detail = ("env.{0}: expected '{1}' host '{2}' ({3}; advisory only)" -f $field, $expected, $(if ($actual) { $actual } else { 'UNKNOWN' }), $st)
                    })
                }
            }
        }
    }

    # 租约里出现过、但 hosts.json 未登记的 host 也列出（gpu_count 未知）
    foreach ($a in $allocations) {
        if (-not $hosts.ContainsKey($a.host)) {
            $hosts[$a.host] = [pscustomobject]@{
                name = $a.host; gpu_count = 0; profile = (Get-HostProfileAudit $null)
            }
        }
    }
    $hostRows = @()
    $total = 0; $usedTotal = 0; $freeTotal = 0
    foreach ($hn in @($hosts.Keys | Sort-Object)) {
        $h = $hosts[$hn]
        $used = @()
        if ($usedByHost.ContainsKey($hn)) { $used = @($usedByHost[$hn] | Sort-Object -Unique) }
        $free = [Math]::Max(0, [int]$h.gpu_count - $used.Count)
        $total += [int]$h.gpu_count
        $usedTotal += $used.Count
        $freeTotal += $free
        $hostRows += [pscustomobject]@{
            host = $hn; gpu_count = [int]$h.gpu_count; used = $used.Count; free = $free;
            allocations = @($allocations | Where-Object { $_.host -eq $hn }).Count;
            legacy = (@($allocations | Where-Object { $_.host -eq $hn -and $_.legacy }).Count -gt 0)
        }
    }
    $summary = [pscustomobject]@{
        hosts = $hostRows.Count; gpusTotal = $total; gpusUsed = $usedTotal; gpusFree = $freeTotal;
        allocations = $allocations.Count; legacyLeases = $legacyLeases;
        gpuErrors = $gpuErrors; envWarnings = $envWarnings; errors = $gpuErrors
    }
    return [pscustomobject]@{ ok = ($gpuErrors -eq 0); summary = $summary; findings = @($findings); hosts = @($hostRows) }
}

function Get-AgeMinutes {
    param([string]$Ts)
    try { return [math]::Round(((Get-Date) - [datetime]::ParseExact($Ts, 'yyyy-MM-ddTHH:mm:ss', $null)).TotalMinutes, 0) }
    catch { return -1 }
}

function Add-LedgerEvent {
    param([hashtable]$Event)
    $dir = Split-Path $Ledger -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not $Event.ContainsKey('ts') -or [string]::IsNullOrWhiteSpace([string]$Event['ts'])) {
        $Event['ts'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    }
    ($Event | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Ledger -Encoding UTF8
}

function Invoke-Backfill {
    param($Report)
    $actions = @()
    foreach ($f in @($Report.Findings)) {
        if ($f.kind -eq 'state-only') {
            Add-LedgerEvent @{
                event = 'state'; issue = $f.issue; task = $f.task; owner = $f.stateOwner;
                status = $f.stateStatus; prev = $f.statePrev;
                note = ("audit backfill from PLAN state updated {0}" -f $f.stateUpdated);
                plan = $f.plan; repo = $f.repo; backfilled = $true; source = 'state'; ts = $f.stateUpdated
            }
            $actions += [pscustomobject]@{ kind = 'state-only'; issue = $f.issue; plan = $f.plan; task = $f.task; status = $f.stateStatus; action = 'ledger-state-appended' }
        } elseif ($f.kind -eq 'state-missing') {
            if ([string]::IsNullOrWhiteSpace($f.ledgerStatus)) { continue }
            $map = Read-StateMap $f.plan
            if (-not $map.ContainsKey($f.task)) {
                $prev = 'planned'
                $map[$f.task] = @{
                    status = $f.ledgerStatus; owner = $f.ledgerOwner; prev = $prev;
                    updated = $f.ledgerTs; source = 'ledger-backfill'
                }
                $statePath = Write-StateMap $f.plan $map
                $actions += [pscustomobject]@{ kind = 'state-missing'; issue = $f.issue; plan = $f.plan; task = $f.task; status = $f.ledgerStatus; action = 'state-restored'; state = $statePath }
            }
        } elseif ($f.kind -eq 'state-file-missing') {
            $map = Read-StateMap $f.plan
            $changed = $false
            foreach ($item in @($f.tasks)) {
                if ([string]::IsNullOrWhiteSpace($item.ledgerStatus)) { continue }
                if ($map.ContainsKey($item.task)) { continue }
                $map[$item.task] = @{
                    status = $item.ledgerStatus; owner = $item.ledgerOwner; prev = 'planned';
                    updated = $item.ledgerTs; source = 'ledger-backfill'
                }
                $changed = $true
                $actions += [pscustomobject]@{ kind = 'state-file-missing'; issue = $f.issue; plan = $f.plan; task = $item.task; status = $item.ledgerStatus; action = 'state-restored'; state = ([IO.Path]::ChangeExtension($f.plan, '.state.json')) }
            }
            if ($changed) { $null = Write-StateMap $f.plan $map }
        }
    }
    return @($actions)
}

function Get-AuditReport {
    $ledgerModel = Read-LedgerModel $Ledger
    $history = Read-AuditHistory $HistoryFile
    $policy = Get-SubagentPolicy -LedgerPath $Ledger
    $planFiles = @(Find-PlanFiles $roots)
    $planRows = @()
    $planTaskIndex = @{}
    $issuePlans = @{}
    foreach ($pf in $planFiles) {
        $repoDir = Split-Path (Split-Path (Split-Path $pf -Parent) -Parent) -Parent
        $issue = Read-PlanIssue $pf
        $rec = [pscustomobject]@{
            Path = $pf
            Repo = (Split-Path $repoDir -Leaf)
            Issue = $issue
            Tasks = @(Read-PlanTasks $pf)
            State = (Read-StateMap $pf)
            StateFile = [IO.Path]::ChangeExtension($pf, '.state.json')
            StateFileExists = (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($pf, '.state.json')))
        }
        $planRows += $rec
        if (-not $issuePlans.ContainsKey($issue)) { $issuePlans[$issue] = [System.Collections.Generic.List[object]]::new() }
        $issuePlans[$issue].Add($rec)
        foreach ($t in $rec.Tasks) {
            $k = "$issue|$($t.Id)"
            if (-not $planTaskIndex.ContainsKey($k)) { $planTaskIndex[$k] = [System.Collections.Generic.List[object]]::new() }
            $planTaskIndex[$k].Add($rec)
        }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    $dormant = [System.Collections.Generic.List[object]]::new()
    $inFlight = [System.Collections.Generic.List[object]]::new()
    $seenOpen = @{}
    $stateOnly = 0
    $stateMissing = 0
    $stateFileMissing = 0
    $ledgerOnly = 0
    $mismatch = 0
    $subagentMissing = 0
    $subagentWaived = 0
    $stale = 0
    $unplanned = @{}
    $unplannedHistorical = 0
    $policyErrors = 0
    if ($policy.Mode -ne 'active') {
        $policyErrors++
        $findings.Add([pscustomobject]@{
            kind = ('policy-' + $policy.Mode); repo = ''; plan = ''; issue = ''; task = '';
            detail = $policy.Error; severity = 'error'
        })
    } elseif ($policy.FileStatus -eq 'missing') {
        $findings.Add([pscustomobject]@{
            kind = 'policy-file-missing'; repo = ''; plan = ''; issue = ''; task = '';
            detail = 'policy cache file missing; ledger policy event is authoritative'; severity = 'warning'
        })
    } elseif ($policy.FileStatus -in @('mismatch', 'invalid')) {
        $policyErrors++
        $findings.Add([pscustomobject]@{
            kind = ('policy-file-' + $policy.FileStatus); repo = ''; plan = ''; issue = ''; task = '';
            detail = 'policy cache file disagrees with ledger policy event (tamper evidence)'; severity = 'error'
        })
    }

    foreach ($rec in $planRows) {
        $hadRecord = $false
        $taskKeys = @{}
        $planLedgerItems = @()
        foreach ($t in $rec.Tasks) {
            $taskKeys[$t.Id] = $true
            $k = "$($rec.Issue)|$($t.Id)"
            $events = @()
            if ($ledgerModel.Events.ContainsKey($k)) { $events = @($ledgerModel.Events[$k]) }
            $li = Get-LedgerTaskInfo $events
            $hasState = $rec.State.ContainsKey($t.Id)
            $se = $null
            if ($hasState) { $se = $rec.State[$t.Id] }
            if ($hasState -or $li.Has) { $hadRecord = $true }

            if ($li.HasExecution -and -not ($li.HasStart -and $li.StartSubagent)) {
                # 只有 active policy 且首次执行早于切点才 legacy waived；no-policy / future / invalid 一律报错。
                $gap = Get-SubagentGapStatus -Info $li -Policy $policy
                if ($gap -eq 'legacy') {
                    $subagentWaived++
                    $findings.Add([pscustomobject]@{
                        kind = 'subagent-legacy'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                        stateStatus = $(if ($hasState) { $se.status } else { '' });
                        ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                        detail = ('pre-policy execution without -Subagent (waived since {0})' -f $policy.Since)
                    })
                } elseif ($gap -eq 'missing') {
                    $subagentMissing++
                    $findings.Add([pscustomobject]@{
                        kind = 'subagent-missing'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                        stateStatus = $(if ($hasState) { $se.status } else { '' });
                        stateOwner = $(if ($hasState) { $se.owner } else { '' });
                        statePrev = $(if ($hasState) { $se.prev } else { '' });
                        stateUpdated = $(if ($hasState) { $se.updated } else { '' });
                        ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                        detail = 'executed without a track start carrying -Subagent (policy active/missing)'
                    })
                }
            }

            if ($hasState -and -not $li.Has -and $se.status -notin @('planned', 'ready')) {
                $stateOnly++
                $findings.Add([pscustomobject]@{
                    kind = 'state-only'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                    stateStatus = $se.status; stateOwner = $se.owner; statePrev = $se.prev; stateUpdated = $se.updated;
                    ledgerStatus = ''; ledgerTs = ''; detail = 'state changed but ledger has no event'
                })
            }
            if (-not $hasState -and $li.Has) {
                if ($rec.StateFileExists) {
                    $stateMissing++
                    $findings.Add([pscustomobject]@{
                        kind = 'state-missing'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                        stateStatus = ''; stateOwner = ''; statePrev = ''; stateUpdated = '';
                        ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                        detail = 'ledger has events but PLAN state is missing'
                    })
                } else {
                    $planLedgerItems += [pscustomobject]@{
                        task = $t.Id; ledgerStatus = $li.Status; ledgerOwner = $li.Owner; ledgerTs = $li.Ts
                    }
                }
            }
            if ($hasState -and $li.Has -and $li.Status -and $se.status -and $li.Status -ne $se.status) {
                $mismatch++
                $findings.Add([pscustomobject]@{
                    kind = 'mismatch'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                    stateStatus = $se.status; stateOwner = $se.owner; statePrev = $se.prev; stateUpdated = $se.updated;
                    ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                    detail = 'state and ledger disagree'
                })
            }
            if ($hasState -and $se.status -in @('running', 'review') -and -not $ledgerModel.Open.ContainsKey($k)) {
                $inFlight.Add([pscustomobject]@{
                    repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = $t.Id;
                    owner = $se.owner; subagent = $li.StartSubagent; wave = ''; since = $se.updated; ageMin = (Get-AgeMinutes $se.updated); source = 'state'
                })
                $seenOpen[$k] = $true
            }
        }
        if (-not $rec.StateFileExists -and @($planLedgerItems).Count -gt 0) {
            $stateFileMissing++
            $findings.Add([pscustomobject]@{
                kind = 'state-file-missing'; repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; task = '';
                stateStatus = ''; stateOwner = ''; statePrev = ''; stateUpdated = '';
                ledgerStatus = 'mixed'; ledgerTs = ''; ledgerOwner = '';
                tasks = @($planLedgerItems);
                detail = ('state file is missing; {0} ledger task(s) need restore' -f @($planLedgerItems).Count)
            })
        }
        if (-not $hadRecord -and @($rec.Tasks).Count -gt 0) {
            $dormant.Add([pscustomobject]@{ repo = $rec.Repo; plan = $rec.Path; issue = $rec.Issue; tasks = @($rec.Tasks | ForEach-Object { $_.Id }) })
        }
    }

    foreach ($k in $ledgerModel.Events.Keys) {
        if ($planTaskIndex.ContainsKey($k)) { continue }
        $issue = $k.Split('|')[0]
        $li = Get-LedgerTaskInfo $ledgerModel.Events[$k]
        if (-not $li.Has) { continue }
        if ($issuePlans.ContainsKey($issue)) {
            $ledgerOnly++
            $findings.Add([pscustomobject]@{
                kind = 'ledger-only'; repo = ''; plan = ''; issue = $issue; task = $k.Split('|')[1];
                stateStatus = ''; stateOwner = ''; statePrev = ''; stateUpdated = '';
                ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                detail = 'ledger has this task but no PLAN row'
            })
        } elseif ($history.ContainsKey($k)) {
            $unplannedHistorical++
            $findings.Add([pscustomobject]@{
                kind = 'unplanned-history'; repo = ''; plan = ''; issue = $issue; task = $k.Split('|')[1];
                stateStatus = ''; stateOwner = ''; statePrev = ''; stateUpdated = '';
                ledgerStatus = $li.Status; ledgerTs = $li.Ts; ledgerOwner = $li.Owner;
                historyReason = $history[$k];
                detail = 'historical ledger task without PLAN (registered in audit history)'; severity = 'warning'
            })
        } else {
            if (-not $unplanned.ContainsKey($issue)) { $unplanned[$issue] = 0 }
            $unplanned[$issue]++
        }
    }

    foreach ($k in $ledgerModel.Open.Keys) {
        if ($seenOpen.ContainsKey($k)) { continue }
        $t = $ledgerModel.Open[$k]
        $age = Get-AgeMinutes $t.ts
        $isStale = ($age -ge $StaleMinutes)
        if ($isStale) { $stale++ }
        $inFlight.Add([pscustomobject]@{
            repo = $t.repo; plan = ''; issue = $t.issue; task = $t.task;
            owner = $t.owner; subagent = $t.subagent; wave = $t.wave; since = $t.ts; ageMin = $age; source = 'ledger'; stale = $isStale
        })
    }

    # --- 资源摘要：room allocation / GPU 使用；overlap/越界是硬错误，env 仅 warning ---
    $resourceAudit = Get-ResourceAudit -HostsFilePath $HostsFile -LeaseDirPath $LeaseDir -PlanRows $planRows
    foreach ($rf in @($resourceAudit.findings)) { $findings.Add($rf) }
    $errors = $stateOnly + $stateMissing + $stateFileMissing + $ledgerOnly + $mismatch + $subagentMissing + $policyErrors + [int]$resourceAudit.summary.errors
    $summary = [pscustomobject]@{
        plans = $planRows.Count
        tasks = (@($planRows | ForEach-Object { @($_.Tasks).Count } ) | Measure-Object -Sum).Sum
        stateOnly = $stateOnly
        stateMissing = $stateMissing
        stateFileMissing = $stateFileMissing
        ledgerOnly = $ledgerOnly
        mismatch = $mismatch
        subagentMissing = $subagentMissing
        subagentWaived = $subagentWaived
        policyErrors = $policyErrors
        inFlight = $inFlight.Count
        staleInFlight = $stale
        dormant = $dormant.Count
        unplannedLedger = (@($unplanned.Values) | Measure-Object -Sum).Sum
        unplannedHistorical = $unplannedHistorical
        gpuErrors = [int]$resourceAudit.summary.gpuErrors
        envWarnings = [int]$resourceAudit.summary.envWarnings
        errors = $errors
    }
    if ($null -eq $summary.tasks) { $summary.tasks = 0 }
    if ($null -eq $summary.unplannedLedger) { $summary.unplannedLedger = 0 }
    $ok = ($errors -eq 0)
    return [pscustomobject]@{
        ok = $ok; ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); ledger = $Ledger; roots = @($roots);
        subagentPolicy = [pscustomobject]@{ mode = $policy.Mode; since = $policy.Since; source = $policy.Source; authorizedBy = $policy.AuthorizedBy; thumbprint = $policy.Thumbprint; fileStatus = $policy.FileStatus; fileSince = $policy.FileSince; error = $policy.Error };
        summary = $summary; findings = @($findings); inFlight = @($inFlight); dormant = @($dormant);
        resourceSummary = $resourceAudit.summary; resourceHosts = @($resourceAudit.hosts);
        unplannedLedgerIssues = @($unplanned.Keys | Sort-Object)
        needsAttention = (($errors -gt 0) -or ($stale -gt 0))
    }
}

function Get-CrossLayerReport {
    param($Report, [string]$LeaseDirPath, [int]$GraceMinutes)

    $findings = [System.Collections.Generic.List[object]]::new()

    $leases = @()
    if (Test-Path -LiteralPath $LeaseDirPath) {
        foreach ($f in (Get-ChildItem -LiteralPath $LeaseDirPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $hostName = Get-Field $j 'host'
            if (-not $hostName) { $hostName = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $sv = Get-Opt $j 'schema_version' 1
            $schema = 1
            try { $schema = [int]$sv } catch { $schema = 1 }
            $allocProp = Get-Opt $j 'allocations' $null
            if ($schema -ge 2 -and $null -ne $allocProp) {
                foreach ($a in @($allocProp)) {
                    if ($null -eq $a) { continue }
                    $aIssue = [string](Get-Opt $a 'issue' '')
                    $aTask = [string](Get-Opt $a 'agent_task' '')
                    $aLabel = [string](Get-Opt $a 'task' '')
                    if (-not $aTask) { $aTask = $aLabel }
                    if (-not $aIssue -and $aLabel -match '(?<i>\d+)[-_]t(?<t>\d+)') {
                        $aIssue = $Matches['i']
                        if (-not $aTask) { $aTask = 'T' + $Matches['t'] }
                    }
                    $leases += [pscustomobject]@{
                        host = $hostName; task = $aTask; issue = $aIssue; label = $aLabel;
                        acquired = [string](Get-Opt $a 'acquired_at' '')
                    }
                }
                continue
            }
            $issue = Get-Field $j 'issue'
            $task = Get-Field $j 'agent_task'
            $leaseTask = Get-Field $j 'task'
            if (-not $task -and $leaseTask -match '(?<i>\d+)[-_]t(?<t>\d+)') {
                if (-not $issue) { $issue = $Matches['i'] }
                $task = 'T' + $Matches['t']
            }
            $leases += [pscustomobject]@{ host = $hostName; task = $task; issue = $issue; label = $leaseTask; acquired = (Get-Field $j 'acquired_at') }
        }
    }

    $agentOpen = @($Report.inFlight)

    foreach ($l in $leases) {
        if (-not $l.host) { continue }
        $hasAgent = $false
        if ($l.task) { $hasAgent = @($agentOpen | Where-Object { $_.task -eq $l.task }).Count -gt 0 }
        if (-not $hasAgent) {
            $findings.Add([pscustomobject]@{ severity = 'warning'; kind = 'lease-stale'; id = ''; host = $l.host; issue = $l.issue; task = $l.task; detail = $l.label })
        }
    }
    foreach ($a in $agentOpen) {
        if ($a.ageMin -lt $GraceMinutes) { continue }
        $hasLease = @($leases | Where-Object { $_.task -and $_.task -eq $a.task }).Count -gt 0
        if (-not $hasLease) {
            $findings.Add([pscustomobject]@{ severity = 'warning'; kind = 'agent-task-no-lease'; id = ''; host = ''; issue = $a.issue; task = $a.task; detail = ('open {0} min' -f $a.ageMin) })
        }
    }

    $errors = @($findings | Where-Object { $_.severity -eq 'error' }).Count
    $warnings = @($findings | Where-Object { $_.severity -eq 'warning' }).Count
    return [pscustomobject]@{
        ok = ($errors -eq 0)
        leases = @($leases)
        findings = @($findings)
        errors = $errors
        warnings = $warnings
    }
}

$policyAction = $null
if ($InitPolicy) {
    if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) { throw '-InitPolicy requires -AuthorizedBy <who>' }
    if ($null -eq (Resolve-PolicyPfx -PfxPath $PfxPath -PfxPassword $PfxPassword)) {
        throw '-InitPolicy requires a signing key: -PfxPath/-PfxPassword or AGENTOS_POLICY_PFX/AGENTOS_POLICY_PFX_PASSWORD'
    }
    $since = if ($SubagentSince) { $SubagentSince } else { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    $policyAction = Add-LedgerPolicyEvent -LedgerPath $Ledger -Since $since -Source 'audit-init' -AuthorizedBy $AuthorizedBy -Note 'explicit policy initialization' -PfxPath $PfxPath -PfxPassword $PfxPassword
} elseif ($SubagentSince -or $env:AGENTOS_SUBAGENT_SINCE) {
    $since = if ($SubagentSince) { $SubagentSince } else { $env:AGENTOS_SUBAGENT_SINCE }
    $auth = if ($AuthorizedBy) { $AuthorizedBy } elseif ($env:AGENTOS_SUBAGENT_AUTHORIZED_BY) { $env:AGENTOS_SUBAGENT_AUTHORIZED_BY } else { '' }
    if ([string]::IsNullOrWhiteSpace($auth)) { throw 'policy override requires -AuthorizedBy or AGENTOS_SUBAGENT_AUTHORIZED_BY' }
    if ($null -eq (Resolve-PolicyPfx -PfxPath $PfxPath -PfxPassword $PfxPassword)) {
        throw 'policy override requires a signing key: -PfxPath/-PfxPassword or AGENTOS_POLICY_PFX/AGENTOS_POLICY_PFX_PASSWORD'
    }
    $src = if ($SubagentSince) { 'audit-override' } else { 'env-override' }
    $policyAction = Add-LedgerPolicyEvent -LedgerPath $Ledger -Since $since -Source $src -AuthorizedBy $auth -Note 'explicit policy override' -PfxPath $PfxPath -PfxPassword $PfxPassword
}

$report = Get-AuditReport
$actions = @()
if ($Backfill) {
    $actions = @(Invoke-Backfill $report)
    $report = Get-AuditReport
    $report | Add-Member -NotePropertyName backfilled -NotePropertyValue @($actions) -Force
}
$cross = Get-CrossLayerReport -Report $report -LeaseDirPath $LeaseDir -GraceMinutes $CrossLayerGraceMinutes
$report | Add-Member -NotePropertyName crossLayer -NotePropertyValue $cross -Force
$report.summary | Add-Member -NotePropertyName crossLayerErrors -NotePropertyValue $cross.errors -Force
$report.summary | Add-Member -NotePropertyName crossLayerWarnings -NotePropertyValue $cross.warnings -Force
if ($cross.errors -gt 0) { $report | Add-Member -NotePropertyName ok -NotePropertyValue $false -Force }
if ($null -ne $policyAction) { $report | Add-Member -NotePropertyName policyAction -NotePropertyValue $policyAction -Force }

if ($machine) {
    $report | ConvertTo-Json -Depth 8
} else {
    Write-Output ('AUDIT  plans={0} tasks={1} errors={2}' -f $report.summary.plans, $report.summary.tasks, $report.summary.errors)
    Write-Output ('  state-only={0} state-missing={1} state-file-missing={2} ledger-only={3} mismatch={4} subagent-missing={5} subagent-waived={6} policy-errors={7} in-flight={8} stale={9} dormant={10} unplanned-ledger={11} unplanned-historical={12}' -f $report.summary.stateOnly, $report.summary.stateMissing, $report.summary.stateFileMissing, $report.summary.ledgerOnly, $report.summary.mismatch, $report.summary.subagentMissing, $report.summary.subagentWaived, $report.summary.policyErrors, $report.summary.inFlight, $report.summary.staleInFlight, $report.summary.dormant, $report.summary.unplannedLedger, $report.summary.unplannedHistorical)
    Write-Output ('  RESOURCES hosts={0} gpus={1}/{2} allocations={3} gpu-errors={4} env-warnings={5}' -f $report.resourceSummary.hosts, $report.resourceSummary.gpusUsed, $report.resourceSummary.gpusTotal, $report.resourceSummary.allocations, $report.resourceSummary.gpuErrors, $report.resourceSummary.envWarnings)
    Write-Output ('  POLICY mode={0} since={1} source={2} authorizedBy={3} file={4} thumbprint={5}' -f $report.subagentPolicy.mode, $report.subagentPolicy.since, $report.subagentPolicy.source, $report.subagentPolicy.authorizedBy, $report.subagentPolicy.fileStatus, $report.subagentPolicy.thumbprint)
    if ($null -ne $policyAction) { Write-Output ('  POLICY ACTION source={0} since={1} authorizedBy={2} thumbprint={3}' -f $policyAction.Source, $policyAction.Since, $policyAction.AuthorizedBy, $policyAction.Thumbprint) }
    Write-Output ('  cross-layer leases={0} errors={1} warnings={2}' -f @($cross.leases).Count, $cross.errors, $cross.warnings)
    foreach ($f in $report.findings) {
        $extra = if ($f.kind -eq 'subagent-missing' -or $f.kind -eq 'subagent-legacy' -or $f.kind -like 'policy-*' -or $f.kind -like 'gpu-*' -or $f.kind -like 'env-*') { '  ' + $f.detail } else { '' }
        Write-Output ("  {0,-16} {1}  {2}/{3}{4}" -f $f.kind, $f.plan, $f.issue, $f.task, $extra)
    }
    foreach ($c in $cross.findings) {
        Write-Output ("  CROSS {0,-7} {1,-30} host={2} issue={3} task={4} {5}" -f $c.severity, $c.kind, $c.host, $c.issue, $c.task, $c.detail)
    }
    foreach ($i in $report.inFlight) {
        Write-Output ("  IN-FLIGHT      issue={0} task={1} owner={2} age={3}m" -f $i.issue, $i.task, $i.owner, $i.ageMin)
    }
    foreach ($d in $report.dormant) {
        Write-Output ("  DORMANT        {0}" -f $d.plan)
    }
    if ($actions.Count -gt 0) {
        Write-Output ''
        foreach ($a in $actions) { Write-Output ("  BACKFILL {0} {1} {2} -> {3}" -f $a.kind, $a.issue, $a.task, $a.status) }
    }
}

if (-not $report.ok) { exit 2 }
if ($report.summary.staleInFlight -gt 0) { exit 2 }
exit 0
