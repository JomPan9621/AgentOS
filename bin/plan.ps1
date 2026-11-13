<#
.SYNOPSIS
  AgentOS 计划引擎：PLAN 校验、任务 DAG、并发调度、状态追踪。
.DESCRIPTION
  PLAN 是 Markdown，任务表格式固定 8 列（legacy）或 9 列（v2）：
    | id | title | kind | deps | touches | resource | worktree | accept | needs |
  kind: write|read | deps: 逗号分隔或 - | touches: 路径前缀 | resource: host alias / auto / none
  needs: 可选；`gpus=<n|all>` 为硬约束，`env.os=...;env.runtime=...` 为软感知（只 warning）。
  旧 8 列 resource 视为 legacy 整机占用并 warning。
#>
[CmdletBinding()]
param(
    [ValidateSet('new', 'validate', 'graph', 'next', 'state', 'show', 'resources')]
    [string]$Command = 'show',
    [string]$Plan = '',
    [string]$Issue = '',
    [string]$Title = '',
    [string]$Repo = '',
    [string]$Task = '',
    [ValidateSet('planned', 'ready', 'running', 'review', 'done', 'blocked', 'abandoned')]
    [string]$Status = 'planned',
    [string]$Owner = '',
    [string]$Note = '',
    [string]$Ledger = '',
    [switch]$NoLedger,
    [switch]$Human,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ledger.ps1')
$script:Now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$machine = -not $Human
if ($machine) { $machine = $true }

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function ConvertFrom-NeedsMap {
    param([string]$Raw)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $map }
    foreach ($part in ($Raw -split ';')) {
        $kv = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($kv) -or $kv -eq '-') { continue }
        $i = $kv.IndexOf('=')
        if ($i -lt 1) { $map['!invalid'] = $kv; continue }
        $k = $kv.Substring(0, $i).Trim().ToLowerInvariant()
        $v = $kv.Substring($i + 1).Trim()
        if ($k) { $map[$k] = $v }
    }
    return $map
}

function Read-PlanFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "PLAN not found: $Path" }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $header = @{}
    $tasks = [System.Collections.Generic.List[object]]::new()
    $section = ''
    foreach ($line in $lines) {
        if ($line -match '^##\s+(?<name>.+?)\s*$') { $section = $Matches['name'].Trim().ToLowerInvariant(); continue }
        if ($section -eq 'tasks') {
            $t = $line.Trim()
            if (-not $t.StartsWith('|')) { continue }
            $cells = @($t.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($cells.Count -lt 8) { continue }
            if ($cells[0] -eq 'id') { continue }
            if ($cells[0] -match '^:?-+:?$') { continue }
            $needsRaw = if ($cells.Count -ge 9) { $cells[8] } else { '' }
            $needsMap = ConvertFrom-NeedsMap $needsRaw
            $envMap = @{}
            foreach ($k in @($needsMap.Keys)) {
                if ($k.StartsWith('env.')) { $envMap[$k.Substring(4)] = [string]$needsMap[$k] }
            }
            $resource = $cells[5].Trim()
            if ([string]::IsNullOrWhiteSpace($resource) -or $resource -eq '-') { $resource = 'none' }
            $gpuSpec = ''
            if ($needsMap.ContainsKey('gpus')) { $gpuSpec = [string]$needsMap['gpus'] }
            $envObj = [pscustomobject]$envMap
            $tasks.Add([pscustomobject]@{
                    Id             = $cells[0]
                    Title          = $cells[1]
                    Kind           = $cells[2].ToLowerInvariant()
                    Deps           = @($cells[3] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
                    Touches        = @($cells[4] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
                    Resource       = $resource
                    Worktree       = $cells[6]
                    Accept         = $cells[7]
                    Needs          = $needsRaw
                    NeedsMap       = $needsMap
                    GpuSpec        = $gpuSpec
                    HasGpus        = $needsMap.ContainsKey('gpus')
                    HasNeedsColumn = ($cells.Count -ge 9)
                    EnvNeeds       = $envObj
                })
            continue
        }
        if ($section -eq '' -and $line -match '^\s*-\s*(?<k>[A-Za-z_]+)\s*:\s*(?<v>.+)$') {
            $header[$Matches['k'].ToLowerInvariant()] = $Matches['v'].Trim()
        }
    }
    return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Header = $header; Tasks = $tasks.ToArray() }
}

# --- GPU / 环境资源模型（hosts.json 为只读数据层，代码不含真实值） ---

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

function Get-LeaseAllocLocal {
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

function Get-HomeBasePath {
    $hb = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($hb)) { $hb = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    return $hb
}

function Get-ResourceContext {
    $hb = Get-HomeBasePath
    $hostsFile = Join-Path $hb 'data\agentos\hosts.json'
    $leaseDir = Join-Path $hb 'devops\agentos\leases'
    $ctx = [pscustomobject]@{ Available = $false; Error = ''; Hosts = @{}; HostsFile = $hostsFile; LeaseDir = $leaseDir }
    if (-not (Test-Path -LiteralPath $hostsFile)) {
        $ctx.Error = 'hosts.json not found: ' + $hostsFile
        return $ctx
    }
    try {
        $hostsObj = Get-Content -LiteralPath $hostsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $ctx.Error = 'cannot parse hosts.json: ' + $_.Exception.Message
        return $ctx
    }
    if ($null -eq (Get-Prop $hostsObj 'hosts' $null)) {
        $ctx.Error = 'hosts.json has no hosts table'
        return $ctx
    }
    $map = @{}
    foreach ($p in $hostsObj.hosts.PSObject.Properties) {
        $prof = Get-HostProfileLocal $p.Value
        $map[$p.Name] = [pscustomobject]@{
            Name = $p.Name; GpuCount = $prof.gpu_count; Profile = $prof; Allocations = @(); Used = @(); Legacy = $false
        }
    }
    if (Test-Path -LiteralPath $leaseDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $leaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $lease = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $alias = [string](Get-Prop $lease 'host' '')
            if (-not $alias) { $alias = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $cap = 0
            if ($map.ContainsKey($alias)) { $cap = [int]$map[$alias].GpuCount }
            $allocs = @(Get-LeaseAllocLocal $lease $cap)
            $used = @()
            foreach ($a in $allocs) { foreach ($g in @($a.gpus)) { $used += [int]$g } }
            $used = @($used | Sort-Object -Unique)
            if ($map.ContainsKey($alias)) {
                $map[$alias].Allocations = @($allocs)
                $map[$alias].Used = @($used)
                $map[$alias].Legacy = (@($allocs | Where-Object { $_.legacy }).Count -gt 0)
            } else {
                $map[$alias] = [pscustomobject]@{
                    Name = $alias; GpuCount = 0; Profile = (Get-HostProfileLocal $null); Allocations = @($allocs); Used = @($used); Legacy = $true
                }
            }
        }
    }
    $ctx.Hosts = $map
    $ctx.Available = $true
    return $ctx
}

function Get-TaskResourceName {
    param($TaskObj)
    if ($null -eq $TaskObj) { return 'none' }
    $r = [string](Get-Prop $TaskObj 'resource' 'none')
    if ([string]::IsNullOrWhiteSpace($r) -or $r -eq '-' -or $r -eq 'none') { return 'none' }
    return $r
}

function Get-NeedCount {
    param($TaskObj, [int]$Cap)
    if ($null -eq $TaskObj) { return 0 }
    if (-not [bool](Get-Prop $TaskObj 'hasGpus' $false)) { return $Cap }
    $spec = [string](Get-Prop $TaskObj 'gpuSpec' '')
    if ($spec -ieq 'all') { return $Cap }
    if ($spec -match '^\d+$') { return [int]$spec }
    return -1
}

function Test-EnvValueMatch {
    param([string]$Expected, [string]$Actual)
    if ([string]::IsNullOrWhiteSpace($Actual)) { return 'unknown' }
    if ([string]::IsNullOrWhiteSpace($Expected)) { return 'unknown' }
    $norm = {
        param([string]$s)
        return (($s.ToLowerInvariant() -replace '[_-]+', ' ' -replace '\s+', ' ').Trim())
    }
    $e = & $norm $Expected
    $a = & $norm $Actual
    if ([string]::IsNullOrWhiteSpace($e) -or [string]::IsNullOrWhiteSpace($a)) { return 'unknown' }
    if ($a.Contains($e) -or $e.Contains($a)) { return 'match' }
    return 'mismatch'
}

function Get-TaskEnvStatus {
    param($TaskObj, $Profile)
    $envObj = Get-Prop $TaskObj 'envNeeds' $null
    $keys = @()
    if ($null -ne $envObj) {
        foreach ($p in $envObj.PSObject.Properties) { if ($p.Name) { $keys += $p.Name } }
    }
    if ($keys.Count -eq 0) { return [pscustomobject]@{ Status = 'n/a'; Details = @() } }
    $details = @()
    $hasMismatch = $false
    $hasUnknown = $false
    foreach ($k in $keys) {
        $expected = [string](Get-Prop $envObj $k '')
        $actual = [string](Get-Prop $Profile $k '')
        $st = Test-EnvValueMatch $expected $actual
        if ($st -eq 'mismatch') { $hasMismatch = $true }
        if ($st -eq 'unknown') { $hasUnknown = $true }
        $details += ('env.{0}: expected ''{1}'' host ''{2}'' ({3})' -f $k, $expected, $(if ($actual) { $actual } else { 'UNKNOWN' }), $st)
    }
    $status = if ($hasMismatch) { 'mismatch' } elseif ($hasUnknown) { 'unknown' } else { 'match' }
    return [pscustomobject]@{ Status = $status; Details = @($details) }
}


function Get-StatePath { param([string]$PlanPath) [IO.Path]::ChangeExtension($PlanPath, '.state.json') }

function ConvertTo-HashtableDeep {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $Obj.PSObject.Properties) { $h[$prop.Name] = ConvertTo-HashtableDeep $prop.Value }
        return $h
    }
    return $Obj
}

function Read-State {
    param([string]$PlanPath)
    $statePath = Get-StatePath $PlanPath
    if (-not (Test-Path -LiteralPath $statePath)) { return @{} }
    $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $conv = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    if ($conv -is [System.Collections.IDictionary]) { return $conv }
    return @{}
}

function Write-State {
    param([string]$PlanPath, [hashtable]$State)
    $p = Get-StatePath $PlanPath
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

function Get-LedgerPath {
    if (-not [string]::IsNullOrWhiteSpace($Ledger)) { return $Ledger }
    $hb = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($hb)) { $hb = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    return (Join-Path $hb 'devops\agentos\ledger.jsonl')
}

function Add-LedgerEvent {
    param([hashtable]$Event)
    Add-LedgerRecord -Path (Get-LedgerPath) -Event $Event -Ts $script:Now
}

function Get-TaskIndex {
    param($Tasks)
    $idx = @{}
    foreach ($t in $Tasks) { $idx[$t.Id] = $t }
    return $idx
}

function Test-Cycle {
    param($Tasks, $Index)
    $mark = @{}
    function Visit([string]$id) {
        if ($mark.ContainsKey($id)) { return ($mark[$id] -eq 2) }
        $mark[$id] = 1
        foreach ($d in $Index[$id].Deps) { if (-not (Visit $d)) { return $false } }
        $mark[$id] = 2
        return $true
    }
    foreach ($t in $Tasks) { if (-not (Visit $t.Id)) { return $false } }
    return $true
}

function Get-Levels {
    param($Tasks, $Index)
    $memo = @{}
    function Level([string]$id) {
        if ($memo.ContainsKey($id)) { return $memo[$id] }
        $deps = @($Index[$id].Deps)
        if ($deps.Count -eq 0) { $memo[$id] = 1; return 1 }
        $max = 0
        foreach ($d in $deps) { $v = Level $d; if ($v -gt $max) { $max = $v } }
        $memo[$id] = $max + 1
        return $max + 1
    }
    $out = @{}
    foreach ($t in $Tasks) { $out[$t.Id] = (Level $t.Id) }
    return $out
}

function Test-PathOverlap {
    param([string[]]$A, [string[]]$B)
    foreach ($a in $A) {
        foreach ($b in $B) {
            $x = $a.TrimEnd('/').Replace('\', '/')
            $y = $b.TrimEnd('/').Replace('\', '/')
            if ($x -eq $y) { return $true }
            if ($x.StartsWith($y + '/') -or $y.StartsWith($x + '/')) { return $true }
        }
    }
    return $false
}

function Test-Conflict {
    param($T1, $T2, $Ctx = $null)
    $r1 = Get-TaskResourceName $T1
    $r2 = Get-TaskResourceName $T2
    if ($r1 -ne 'none' -and $r2 -ne 'none' -and $r1 -ine 'auto' -and $r2 -ine 'auto' -and $r1 -ieq $r2) {
        $cap = 0
        if ($null -ne $Ctx -and [bool](Get-Prop $Ctx 'available' $false) -and $Ctx.Hosts.ContainsKey($r1)) {
            $cap = [int]$Ctx.Hosts[$r1].GpuCount
        }
        if ($cap -le 0) { return "resource:$r1" }
        $n1 = Get-NeedCount $T1 $cap
        $n2 = Get-NeedCount $T2 $cap
        if ($n1 -le 0) { $n1 = $cap }
        if ($n2 -le 0) { $n2 = $cap }
        if (($n1 + $n2) -gt $cap) { return ('resource:{0}:gpus' -f $r1) }
    }
    if (Test-PathOverlap $T1.Touches $T2.Touches) { return 'touches' }
    return $null
}

function Get-Schedule {
    param($Tasks, $Levels, $Ctx = $null)
    $waves = [System.Collections.Generic.List[object]]::new()
    $forced = [System.Collections.Generic.List[object]]::new()
    $byLevel = $Tasks | Group-Object { $Levels[$_.Id] } | Sort-Object { [int]$_.Name }
    foreach ($g in $byLevel) {
        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($t in $g.Group) { $remaining.Add($t) }
        $sub = 0
        while ($remaining.Count -gt 0) {
            $sub++
            $wave = [System.Collections.Generic.List[object]]::new()
            $rest = [System.Collections.Generic.List[object]]::new()
            foreach ($t in $remaining) {
                $bad = $null
                $blocker = $null
                foreach ($w in $wave) { $bad = Test-Conflict $t $w $Ctx; if ($bad) { $blocker = $w.Id; break } }
                if ($bad) {
                    $rest.Add($t)
                    $forced.Add([pscustomobject]@{ Id = $t.Id; BlockedBy = $blocker; Level = [int]$g.Name; Reason = $bad })
                }
                else { $wave.Add($t) }
            }
            if ($wave.Count -eq 0 -and $rest.Count -gt 0) { $wave.Add($rest[0]); $rest.RemoveAt(0) }
            $waves.Add([pscustomobject]@{ Level = [int]$g.Name; Sub = $sub; Tasks = @($wave | ForEach-Object { $_.Id }); Detail = $wave })
            $remaining = $rest
        }
    }
    return [pscustomobject]@{ Waves = $waves; ForcedSerial = $forced }
}

function Invoke-Validate {
    param($PlanObj)
    $errors = [System.Collections.Generic.List[string]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()
    $tasks = @($PlanObj.Tasks)
    if ($tasks.Count -eq 0) { $errors.Add('task table is empty') }
    $seen = @{}
    foreach ($t in $tasks) {
        if ($seen.ContainsKey($t.Id)) { $errors.Add("duplicate id: $($t.Id)") }
        $seen[$t.Id] = $true
        if ($t.Kind -notin @('write', 'read')) { $errors.Add("$($t.Id): kind must be write or read") }
        if ($t.Kind -eq 'write') {
            if ($t.Worktree -eq '-' -or [string]::IsNullOrWhiteSpace($t.Worktree)) { $errors.Add("$($t.Id): write task requires worktree") }
            if ($t.Touches.Count -eq 0) { $errors.Add("$($t.Id): write task requires touches") }
        }
    }
    $idx = Get-TaskIndex $tasks
    foreach ($t in $tasks) {
        foreach ($d in $t.Deps) { if (-not $idx.ContainsKey($d)) { $errors.Add("$($t.Id): missing dep '$d'") } }
        if ($t.Deps -contains $t.Id) { $errors.Add("$($t.Id): self dependency") }
    }
    if ($errors.Count -eq 0 -and -not (Test-Cycle $tasks $idx)) { $errors.Add('dependency cycle detected') }

    # --- 资源模型校验：GPU 硬约束（结构/容量），env 软感知（只 warning） ---
    $ctx = Get-ResourceContext
    if (-not $ctx.Available) {
        $warns.Add('resource registry unavailable: ' + $ctx.Error + ' (host/GPU checks skipped)')
    }
    foreach ($t in $tasks) {
        $res = Get-TaskResourceName $t
        foreach ($k in @($t.NeedsMap.Keys)) {
            if ($k -eq '!invalid') {
                $errors.Add("$($t.Id): malformed needs entry '$($t.NeedsMap[$k])' (expected key=value;...)")
                continue
            }
            if ($k -ne 'gpus' -and -not $k.StartsWith('env.')) {
                $warns.Add("$($t.Id): unknown needs key '$k' (ignored)")
            }
        }
        if ($res -eq 'none') {
            if ($t.HasGpus) { $errors.Add("$($t.Id): needs declares gpus but resource is none; set resource to a host alias or auto") }
            continue
        }
        if (-not $t.HasGpus) {
            if ($t.HasNeedsColumn) {
                $errors.Add("$($t.Id): resource '$res' requires needs gpus=<n|all> in the 9-column task table")
            } else {
                $warns.Add("$($t.Id): legacy 8-column resource '$res' means whole host; add needs gpus=<n|all>")
            }
        } else {
            $spec = [string]$t.GpuSpec
            if ($spec -ine 'all' -and -not ($spec -match '^\d+$' -and [int]$spec -ge 1)) {
                $errors.Add("$($t.Id): invalid needs gpus '$spec' (expected positive integer or all)")
            }
        }
        if ($res -ieq 'auto') {
            if ($t.HasGpus) { $warns.Add("$($t.Id): resource auto is resolved by 'aos plan resources'") }
            continue
        }
        if (-not $ctx.Available) { continue }
        if (-not $ctx.Hosts.ContainsKey($res)) {
            $errors.Add("$($t.Id): resource host '$res' not found in hosts.json")
            continue
        }
        $hin = $ctx.Hosts[$res]
        $cap = [int]$hin.GpuCount
        if ($cap -le 0) {
            $warns.Add("$($t.Id): host '$res' gpu_count unknown (profile.gpu_count / gpu_count / <n>gpu tag); GPU capacity cannot be verified")
        } elseif ($t.HasGpus -and $t.GpuSpec -match '^\d+$' -and [int]$t.GpuSpec -gt $cap) {
            $errors.Add("$($t.Id): needs gpus=$($t.GpuSpec) exceeds host '$res' gpu_count=$cap")
        }
        if (@($t.EnvNeeds.PSObject.Properties).Count -gt 0) {
            $envr = Get-TaskEnvStatus $t $hin.Profile
            foreach ($d in @($envr.Details)) { $warns.Add("$($t.Id): " + $d + ' [soft]') }
        }
        $allocated = @($hin.Used).Count
        if ($allocated -gt 0 -or $hin.Legacy) {
            $holders = (@($hin.Allocations | ForEach-Object { [string]$_.task }) | Where-Object { $_ } | Select-Object -Unique) -join ','
            $extra = if ($holders) { " (holders: $holders)" } else { '' }
            $warns.Add("$($t.Id): host '$res' has $allocated/$cap GPU(s) allocated$extra")
        }
    }
    if ($errors.Count -eq 0) {
        $levels = Get-Levels $tasks $idx
        $sched = Get-Schedule $tasks $levels $ctx
        foreach ($w in $sched.Waves) {
            $byHost = @{}
            foreach ($t in @($w.Detail)) {
                $res = Get-TaskResourceName $t
                if ($res -eq 'none' -or $res -ieq 'auto') { continue }
                if (-not $ctx.Available -or -not $ctx.Hosts.ContainsKey($res)) { continue }
                $cap = [int]$ctx.Hosts[$res].GpuCount
                if ($cap -le 0) { continue }
                $n = Get-NeedCount $t $cap
                if ($n -le 0) { $n = $cap }
                if (-not $byHost.ContainsKey($res)) { $byHost[$res] = 0 }
                $byHost[$res] += $n
            }
            foreach ($k in @($byHost.Keys)) {
                $cap2 = [int]$ctx.Hosts[$k].GpuCount
                if ($byHost[$k] -gt $cap2) {
                    $errors.Add("wave L$($w.Level).$($w.Sub): host '$k' requires $($byHost[$k]) GPUs > gpu_count=$cap2")
                }
            }
        }
        $parallel = @($sched.Waves | Where-Object { $_.Tasks.Count -gt 1 })
        if ($parallel.Count -gt 0) { $warns.Add("$($parallel.Count) parallel wave(s): must dispatch multiple subagents") }
    }
    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors; Warnings = $warns }
}

function Invoke-New {
    $repoPath = if ($Repo) { (Resolve-Path -LiteralPath $Repo).Path } else { (Get-Location).Path }
    if (-not $Issue) { throw '-Issue is required' }
    $dir = Join-Path $repoPath '.agentos\plans'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir ("PLAN-{0}.md" -f $Issue)
    if (Test-Path -LiteralPath $file) { throw "already exists: $file" }
    $remote = ''
    try { $remote = [string](& git -C $repoPath remote get-url origin 2>$null) } catch { $remote = '' }
    $tpl = Join-Path $PSScriptRoot '..\templates\PLAN.template.md'
    if (Test-Path -LiteralPath $tpl) {
        $body = Get-Content -LiteralPath $tpl -Raw -Encoding UTF8
    } else {
        $body = (@('# PLAN-{{ISSUE}}', '', '## Tasks', '') -join [Environment]::NewLine)
    }
    $body = $body.Replace('{{ISSUE}}', $Issue).Replace('{{TITLE}}', $Title).Replace('{{REPO}}', $repoPath).Replace('{{REMOTE}}', $remote).Replace('{{DATE}}', (Get-Date -Format 'yyyy-MM-dd'))
    Set-Content -LiteralPath $file -Value $body -Encoding UTF8
    if ($machine) {
        [pscustomobject]@{ ok = $true; created = $file; issue = $Issue; repo = $repoPath; remote = $remote } | ConvertTo-Json -Depth 4
        return
    }
    Write-Output "created=$file"
}

function Invoke-Show {
    $o = Read-PlanFile $Plan
    if ($machine) {
        [pscustomobject]@{ ok = $true; path = $o.Path; header = $o.Header; tasks = $o.Tasks } | ConvertTo-Json -Depth 6
        return
    }
    Write-Output ("PLAN   : " + $o.Path)
    foreach ($k in $o.Header.Keys) { Write-Output ("  {0,-10}= {1}" -f $k, $o.Header[$k]) }
    Write-Output ("tasks  : " + $o.Tasks.Count)
    $o.Tasks | Format-Table Id, Kind, @{n = 'Deps'; e = { ($_.Deps -join ',') } }, @{n = 'Touches'; e = { ($_.Touches -join ',') } }, Resource, Worktree -AutoSize
}

function Invoke-Graph {
    $o = Read-PlanFile $Plan
    $idx = Get-TaskIndex $o.Tasks
    if (-not (Test-Cycle $o.Tasks $idx)) { throw 'dependency cycle, cannot schedule' }
    $ctx = Get-ResourceContext
    $sched = Get-Schedule $o.Tasks (Get-Levels $o.Tasks $idx) $ctx
    if ($machine) { $sched | ConvertTo-Json -Depth 6; return }
    Write-Output 'mermaid:'
    Write-Output 'graph LR'
    foreach ($t in $o.Tasks) {
        if ($t.Kind -eq 'write') { Write-Output ("  {0}[{0} {1}]" -f $t.Id, $t.Title) }
        else { Write-Output ("  {0}({0} {1})" -f $t.Id, $t.Title) }
    }
    foreach ($t in $o.Tasks) { foreach ($d in $t.Deps) { Write-Output ("  {0} --> {1}" -f $d, $t.Id) } }
    Write-Output ''
    Write-Output 'concurrency schedule (write=exclusive worktree, read=shared):'
    $n = 0
    foreach ($w in $sched.Waves) {
        $n++
        $tag = if ($w.Tasks.Count -gt 1) { 'PARALLEL' } else { 'serial' }
        Write-Output ("  W{0,-2} L{1}.{2} [{3,-8}] {4}" -f $n, $w.Level, $w.Sub, $tag, ($w.Tasks -join ' + '))
    }
    if ($sched.ForcedSerial.Count -gt 0) {
        Write-Output ''
        Write-Output 'forced serial (record reason in task log):'
        foreach ($f in $sched.ForcedSerial) { Write-Output ("  {0}  <- conflicts with {1} ({2})" -f $f.Id, $f.BlockedBy, $f.Reason) }
    }
    $parallel = @($sched.Waves | Where-Object { $_.Tasks.Count -gt 1 })
    Write-Output ''
    if ($parallel.Count -gt 0) { Write-Output ("RESULT: {0} parallel wave(s) - dispatch multiple subagents" -f $parallel.Count) }
    else { Write-Output 'RESULT: no parallelism available, chain is serial' }
}

function Invoke-Next {
    $o = Read-PlanFile $Plan
    $st = Read-State $o.Path
    function Get-TaskStatus([string]$id) {
        if ($st.ContainsKey($id) -and $st[$id].ContainsKey('status')) { return $st[$id]['status'] }
        return 'planned'
    }
    $ready = @()
    foreach ($t in $o.Tasks) {
        if ((Get-TaskStatus $t.Id) -ne 'planned') { continue }
        $ok = $true
        foreach ($d in $t.Deps) { if ((Get-TaskStatus $d) -ne 'done') { $ok = $false; break } }
        if ($ok) { $ready += $t }
    }
    if ($ready.Count -eq 0) { Write-Output 'no ready task'; return }
    $ctx = Get-ResourceContext
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $ready) {
        $placed = $false
        foreach ($g in $groups) {
            $conflict = $false
            foreach ($x in $g) { if (Test-Conflict $t $x $ctx) { $conflict = $true; break } }
            if (-not $conflict) { $g.Add($t); $placed = $true; break }
        }
        if (-not $placed) { $g2 = [System.Collections.Generic.List[object]]::new(); $g2.Add($t); $groups.Add($g2) }
    }
    if ($machine) {
        $batches = @()
        foreach ($g in $groups) {
            $batch = @()
            foreach ($t in $g) { $batch += [pscustomobject]@{ id = $t.Id; kind = $t.Kind; worktree = $t.Worktree; resource = $t.Resource; needs = $t.Needs; title = $t.Title } }
            $batches += , $batch
        }
        [pscustomobject]@{ ok = $true; batches = $batches } | ConvertTo-Json -Depth 8
        return
    }
    $i = 0
    foreach ($g in $groups) {
        $i++
        Write-Output ("batch {0}  ({1} task(s), parallel dispatchable)" -f $i, $g.Count)
        foreach ($t in $g) {
            Write-Output ("  {0}  [{1}]  worktree={2}  resource={3}" -f $t.Id, $t.Kind, $t.Worktree, $t.Resource)
            Write-Output ("       {0}" -f $t.Title)
        }
        Write-Output ''
    }
}

function Invoke-Resources {
    $o = Read-PlanFile $Plan
    $ctx = Get-ResourceContext
    $errors = [System.Collections.Generic.List[string]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()
    $suggestions = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()

    if (-not $ctx.Available) {
        $msg = 'resource registry unavailable: ' + $ctx.Error
        if ($machine) {
            [pscustomobject]@{
                ok = $false; plan = $o.Path; ts = $script:Now; error = $msg; tasks = @();
                errors = @($msg); warnings = @(); suggestions = @('create data/agentos/hosts.json with gpu_count/profile')
            } | ConvertTo-Json -Depth 8
        } else {
            Write-Output ('ERROR ' + $msg)
        }
        exit 1
    }

    $idx = Get-TaskIndex $o.Tasks
    if (-not (Test-Cycle $o.Tasks $idx)) { throw 'dependency cycle, cannot preflight resources' }
    $levels = Get-Levels $o.Tasks $idx

    $reserved = @{}
    foreach ($name in $ctx.Hosts.Keys) { $reserved[$name] = @($ctx.Hosts[$name].Used) }

    function Get-HostState([string]$Name) {
        $hin = $ctx.Hosts[$Name]
        $cap = [int]$hin.GpuCount
        $used = @($reserved[$Name])
        $freeIds = @()
        for ($i = 0; $i -lt $cap; $i++) { if ($used -notcontains $i) { $freeIds += $i } }
        return [pscustomobject]@{
            Host = $Name; Cap = $cap; Used = @($used); FreeIds = @($freeIds);
            Profile = $hin.Profile; Allocations = @($hin.Allocations)
        }
    }

    function Test-MyAllocation($Alloc, [string]$TaskId, [string]$IssueId) {
        $atask = [string](Get-Prop $Alloc 'task' '')
        $aagent = [string](Get-Prop $Alloc 'agent_task' '')
        $aissue = [string](Get-Prop $Alloc 'issue' '')
        if ($aissue -and $IssueId -and $aissue -ine $IssueId) { return $false }
        if ($atask -ieq $TaskId) { return $true }
        if ($aagent -ieq $TaskId) { return $true }
        if ($aagent -ieq ($IssueId + '|' + $TaskId)) { return $true }
        if ([bool](Get-Prop $Alloc 'legacy' $false)) {
            if ($atask -ieq $IssueId) { return $true }
            if ($aissue -ieq $IssueId) { return $true }
        }
        return $false
    }

    $issueId = ''
    if ($o.Header.ContainsKey('issue')) { $issueId = [string]$o.Header['issue'] }
    if (-not $issueId) { $issueId = [IO.Path]::GetFileNameWithoutExtension($o.Path) -replace '^PLAN-', '' }

    $ordered = @($o.Tasks | Sort-Object -Property @{ Expression = { [int]$levels[$_.Id] }; Descending = $false }, @{ Expression = { $_.Id }; Descending = $false })

    foreach ($t in $ordered) {
        $res = Get-TaskResourceName $t
        $wave = [int]$levels[$t.Id]
        if ($res -eq 'none') {
            $rows.Add([pscustomobject]@{
                id = $t.Id; resource = 'none'; host = '-'; gpus = 0; gpu_ids = @(); free = '-'; env = 'n/a';
                status = 'skip'; wave = $wave; legacy = $false; leased = $false; detail = 'no remote resource'
            })
            continue
        }
        $legacy = (-not $t.HasGpus)
        if ($legacy) { $warns.Add("$($t.Id): legacy 8-column resource '$res' occupies the whole host") }
        if ($t.HasGpus) {
            $spec = [string]$t.GpuSpec
            if ($spec -ine 'all' -and -not ($spec -match '^\d+$' -and [int]$spec -ge 1)) {
                $errors.Add("$($t.Id): invalid needs gpus '$spec'")
                $rows.Add([pscustomobject]@{
                    id = $t.Id; resource = $res; host = '-'; gpus = 0; gpu_ids = @(); free = '-'; env = 'n/a';
                    status = 'invalid'; wave = $wave; legacy = $false; leased = $false; detail = "invalid gpus spec '$spec'"
                })
                continue
            }
        }
        $candidateNames = @()
        if ($res -ieq 'auto') {
            $candidateNames = @($ctx.Hosts.Keys | Sort-Object)
        } elseif ($ctx.Hosts.ContainsKey($res)) {
            $candidateNames = @($res)
        } else {
            $errors.Add("$($t.Id): resource host '$res' not found in hosts.json")
            $rows.Add([pscustomobject]@{
                id = $t.Id; resource = $res; host = $res; gpus = 0; gpu_ids = @(); free = '-'; env = 'n/a';
                status = 'unknown-host'; wave = $wave; legacy = $legacy; leased = $false; detail = 'host not registered'
            })
            continue
        }

        $evals = @()
        $unknownNames = @()
        foreach ($hn in $candidateNames) {
            $st = Get-HostState $hn
            if ($st.Cap -le 0) { $unknownNames += $hn; continue }
            $need = Get-NeedCount $t $st.Cap
            if ($need -le 0) { continue }
            $mine = @($st.Allocations | Where-Object { Test-MyAllocation $_ $t.Id $issueId })
            $envr = Get-TaskEnvStatus $t $st.Profile
            $ok = $false; $leased = $false; $allocIds = @()
            if ($mine.Count -gt 0) {
                $ids = @()
                foreach ($m in $mine) { $ids += @($m.gpus) }
                $ids = @($ids | Sort-Object -Unique)
                if ($ids.Count -ge $need) { $ok = $true; $leased = $true; $allocIds = @($ids) }
            } elseif ($st.FreeIds.Count -ge $need) {
                $ok = $true; $allocIds = @($st.FreeIds | Select-Object -First $need)
            }
            $evals += [pscustomobject]@{
                Host = $hn; State = $st; Need = $need; Ok = $ok; Leased = $leased; AllocIds = @($allocIds);
                Env = $envr; FreeNow = $st.FreeIds.Count
            }
        }

        # GPU 硬约束：候选 host 的 gpu_count 全部未知时给结构化错误（不得空引用）
        if ($evals.Count -eq 0 -and $unknownNames.Count -gt 0) {
            $hostLabel = if ($res -ieq 'auto') { 'auto' } else { $res }
            $detail = if ($res -ieq 'auto') {
                'no candidate host has a known gpu_count'
            } else {
                ('host ''{0}'' gpu_count unknown (0)' -f $unknownNames[0])
            }
            $needUnknown = 0
            if ($t.HasGpus -and $t.GpuSpec -match '^\d+$') { $needUnknown = [int]$t.GpuSpec }
            $envStatus = 'unknown'
            if ($res -ine 'auto' -and $ctx.Hosts.ContainsKey($res)) {
                $envStatus = (Get-TaskEnvStatus $t $ctx.Hosts[$res].Profile).Status
            }
            $errors.Add("$($t.Id): $detail; cannot allocate GPUs")
            $suggestions.Add("set profile.gpu_count / host gpu_count / tags '<n>gpu' for '$hostLabel' in hosts.json")
            $alts = @()
            foreach ($hn in @($ctx.Hosts.Keys | Where-Object { $_ -ne $hostLabel } | Sort-Object)) {
                $st2 = Get-HostState $hn
                if ($st2.Cap -le 0) { continue }
                $free2 = $st2.FreeIds.Count
                if ($free2 -le 0) { continue }
                $alts += [pscustomobject]@{ host = $hn; free = $free2; gpu_count = $st2.Cap }
                if ($needUnknown -gt 0 -and $free2 -ge $needUnknown) {
                    $suggestions.Add("use host '$hn' (free $free2/$($st2.Cap) GPUs)")
                }
            }
            if (@($alts).Count -eq 0) { $suggestions.Add('no alternative host has free GPUs; fix gpu_count in hosts.json or wait') }
            $rows.Add([pscustomobject]@{
                id = $t.Id; resource = $res; host = $hostLabel; gpus = $needUnknown; gpu_ids = @(); free = '-';
                env = $envStatus; status = 'unknown-gpu-count'; wave = $wave; legacy = $legacy; leased = $false;
                detail = $detail; alternatives = @($alts)
            })
            continue
        }

        $chosen = $null
        if ($evals.Count -gt 0) {
            $okEvals = @($evals | Where-Object { $_.Ok })
            if ($okEvals.Count -gt 0) {
                $preferred = @($okEvals | Where-Object { $_.Env.Status -ne 'mismatch' })
                if ($preferred.Count -eq 0) { $preferred = $okEvals }
                $chosen = @($preferred | Sort-Object -Property @{ Expression = { $_.FreeNow }; Descending = $true }, @{ Expression = { $_.Host }; Descending = $false })[0]
            }
        }

        if ($null -ne $chosen) {
            $reserved[$chosen.Host] = @(@(@($reserved[$chosen.Host]) + @($chosen.AllocIds)) | Sort-Object -Unique)
            foreach ($d in @($chosen.Env.Details)) { $warns.Add("$($t.Id): " + $d) }
            if ($chosen.Env.Status -eq 'mismatch') {
                $warns.Add("$($t.Id): env mismatch on '$($chosen.Host)' is advisory only; task is NOT blocked")
            }
            $freeAfter = [Math]::Max(0, [int]$chosen.State.Cap - @($reserved[$chosen.Host]).Count)
            $rows.Add([pscustomobject]@{
                id = $t.Id; resource = $res; host = $chosen.Host; gpus = $chosen.Need; gpu_ids = @($chosen.AllocIds);
                free = $freeAfter; env = $chosen.Env.Status; status = 'ok'; wave = $wave; legacy = $legacy;
                leased = $chosen.Leased; detail = ''
            })
            continue
        }

        # 失败：报告对象取 pinned host 或 auto 中空闲最多者
        $reportEval = $null
        if ($evals.Count -gt 0) {
            $reportEval = @($evals | Sort-Object -Property @{ Expression = { $_.FreeNow }; Descending = $true }, @{ Expression = { $_.Host }; Descending = $false })[0]
        }
        $hostLabel = if ($null -ne $reportEval) { $reportEval.Host } else { $(if ($res -ieq 'auto') { 'auto' } else { $res }) }
        $freeNow = if ($null -ne $reportEval) { $reportEval.FreeNow } else { 0 }
        $capNow = if ($null -ne $reportEval) { [int]$reportEval.State.Cap } else { 0 }
        $needNow = if ($null -ne $reportEval) { $reportEval.Need } else { $(if ($t.HasGpus -and $t.GpuSpec -match '^\d+$') { [int]$t.GpuSpec } else { 1 }) }
        $envStatus = if ($null -ne $reportEval) { $reportEval.Env.Status } else { 'n/a' }
        $errors.Add("$($t.Id): insufficient free GPUs on '$hostLabel': need $needNow, free $freeNow/$capNow")
        $alts = @()
        foreach ($hn in @($ctx.Hosts.Keys | Where-Object { $_ -ne $hostLabel } | Sort-Object)) {
            $st2 = Get-HostState $hn
            if ($st2.Cap -le 0) { continue }
            $free2 = $st2.FreeIds.Count
            if ($free2 -le 0) { continue }
            $alts += [pscustomobject]@{ host = $hn; free = $free2; gpu_count = $st2.Cap }
            if ($free2 -ge $needNow) { $suggestions.Add("use host '$hn' (free $free2/$($st2.Cap) GPUs)") }
        }
        if ($freeNow -gt 0) { $suggestions.Add("reduce $($t.Id) needs gpus to $freeNow on '$hostLabel'") }
        $holders = ''
        if ($null -ne $reportEval) {
            $holders = (@($reportEval.State.Allocations | ForEach-Object { [string]$_.task }) | Where-Object { $_ } | Select-Object -Unique) -join ','
        }
        if ($holders) { $suggestions.Add("wait for allocation release on '$hostLabel' (holders: $holders)") }
        if (@($alts).Count -eq 0) { $suggestions.Add('no alternative host has free GPUs; add capacity or wait') }
        $rows.Add([pscustomobject]@{
            id = $t.Id; resource = $res; host = $hostLabel; gpus = $needNow; gpu_ids = @(); free = $freeNow;
            env = $envStatus; status = 'insufficient'; wave = $wave; legacy = $legacy; leased = $false;
            detail = "need $needNow GPU(s), free $freeNow"; alternatives = @($alts)
        })
    }

    $hostRows = @()
    foreach ($hn in @($ctx.Hosts.Keys | Sort-Object)) {
        $st = Get-HostState $hn
        $hostRows += [pscustomobject]@{
            host = $hn; gpu_count = $st.Cap; used = @($st.Used).Count; free = $st.FreeIds.Count; profile = $st.Profile
        }
    }
    $ok = ($errors.Count -eq 0)
    $payload = [pscustomobject]@{
        ok = $ok; plan = $o.Path; ts = $script:Now; tasks = @($rows); warnings = @($warns);
        errors = @($errors); suggestions = @($suggestions); hosts = @($hostRows)
    }
    if ($machine) {
        $payload | ConvertTo-Json -Depth 8
    } else {
        Write-Output ('RESOURCE PREFLIGHT ' + $o.Path)
        foreach ($r in $rows) {
            $gpuText = if (@($r.gpu_ids).Count -gt 0) { (@($r.gpu_ids) -join ',') } else { '-' }
            Write-Output ('  {0,-4} host={1,-14} gpus={2,-4} ids={3,-10} free={4,-4} env={5,-8} status={6}' -f $r.id, $r.host, $r.gpus, $gpuText, $r.free, $r.env, $r.status)
        }
        foreach ($w in $warns) { Write-Output ('WARN    ' + $w) }
        foreach ($e in $errors) { Write-Output ('ERROR   ' + $e) }
        foreach ($s in $suggestions) { Write-Output ('SUGGEST ' + $s) }
        if ($ok) { Write-Output 'RESULT: resources sufficient' }
        else { Write-Output 'RESULT: GPU resources insufficient (env mismatch alone never blocks)' }
    }
    if (-not $ok) { exit 2 }
}

function Invoke-StateUpdate {
    $o = Read-PlanFile $Plan
    if (-not $Task) { throw '-Task is required' }
    $exists = @($o.Tasks | Where-Object { $_.Id -eq $Task })
    if ($exists.Count -eq 0) { throw "no such task in PLAN: $Task" }
    $st = Read-State $o.Path
    $prev = if ($st.ContainsKey($Task) -and $st[$Task].ContainsKey('status')) { $st[$Task]['status'] } else { 'planned' }
    $st[$Task] = @{ status = $Status; owner = $Owner; prev = $prev; updated = $script:Now }
    $p = Write-State $o.Path $st
    if (-not $NoLedger) {
        $issueId = ''
        if ($o.Header.ContainsKey('issue')) { $issueId = [string]$o.Header['issue'] }
        if ([string]::IsNullOrWhiteSpace($issueId)) {
            $issueId = [IO.Path]::GetFileNameWithoutExtension($o.Path) -replace '^PLAN-', ''
        }
        $repoName = ''
        if (-not [string]::IsNullOrWhiteSpace($Repo)) {
            $repoName = Split-Path $Repo -Leaf
        } else {
            $repoDir = Split-Path (Split-Path (Split-Path $o.Path -Parent) -Parent) -Parent
            $repoName = Split-Path $repoDir -Leaf
        }
        Add-LedgerEvent @{
            event  = 'state'
            issue  = $issueId
            task   = $Task
            owner  = $Owner
            status = $Status
            prev   = $prev
            note   = $Note
            plan   = $o.Path
            repo   = $repoName
        }
    }
    if ($machine) {
        [pscustomobject]@{ ok = $true; task = $Task; from = $prev; to = $Status; owner = $Owner; state = $p; ledger = (-not $NoLedger) } | ConvertTo-Json -Depth 4
        return
    }
    Write-Output ("{0}: {1} -> {2} (owner={3})" -f $Task, $prev, $Status, $Owner)
    Write-Output "state=$p"
}

switch ($Command) {
    'new' { Invoke-New }
    'validate' {
        $o = Read-PlanFile $Plan
        $r = Invoke-Validate $o
        if ($machine) {
            [pscustomobject]@{ ok = $r.Ok; errors = @($r.Errors); warnings = @($r.Warnings) } | ConvertTo-Json -Depth 5
            if (-not $r.Ok) { exit 1 }
            exit 0
        }
        foreach ($e in $r.Errors) { Write-Output ("ERROR " + $e) }
        foreach ($w in $r.Warnings) { Write-Output ("WARN  " + $w) }
        if ($r.Ok) { Write-Output 'OK plan is valid' } else { exit 1 }
    }
    'graph' { Invoke-Graph }
    'next' { Invoke-Next }
    'resources' { Invoke-Resources }
    'state' { Invoke-StateUpdate }
    default { Invoke-Show }
}

exit 0
