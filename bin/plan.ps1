<#
.SYNOPSIS
  AgentOS 计划引擎：PLAN 校验、任务 DAG、并发调度、状态追踪。
.DESCRIPTION
  PLAN 是 Markdown，任务表格式固定：
    | id | title | kind | deps | touches | resource | worktree | accept |
  kind: write|read | deps: 逗号分隔或 - | touches: 路径前缀 | resource: 独占资源或 none
#>
[CmdletBinding()]
param(
    [ValidateSet('new', 'validate', 'graph', 'next', 'state', 'show')]
    [string]$Command = 'show',
    [string]$Plan = '',
    [string]$Issue = '',
    [string]$Title = '',
    [string]$Repo = '',
    [string]$Task = '',
    [ValidateSet('planned', 'ready', 'running', 'review', 'done', 'blocked', 'abandoned')]
    [string]$Status = 'planned',
    [string]$Owner = '',
    [switch]$Human,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$machine = -not $Human
if ($machine) { $machine = $true }

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
            $tasks.Add([pscustomobject]@{
                    Id       = $cells[0]
                    Title    = $cells[1]
                    Kind     = $cells[2].ToLowerInvariant()
                    Deps     = @($cells[3] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
                    Touches  = @($cells[4] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '-' })
                    Resource = $cells[5]
                    Worktree = $cells[6]
                    Accept   = $cells[7]
                })
            continue
        }
        if ($section -eq '' -and $line -match '^\s*-\s*(?<k>[A-Za-z_]+)\s*:\s*(?<v>.+)$') {
            $header[$Matches['k'].ToLowerInvariant()] = $Matches['v'].Trim()
        }
    }
    return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Header = $header; Tasks = $tasks.ToArray() }
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
    param($T1, $T2)
    if ($T1.Resource -ne 'none' -and $T2.Resource -ne 'none' -and $T1.Resource -eq $T2.Resource) { return "resource:$($T1.Resource)" }
    if (Test-PathOverlap $T1.Touches $T2.Touches) { return 'touches' }
    return $null
}

function Get-Schedule {
    param($Tasks, $Levels)
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
                foreach ($w in $wave) { $bad = Test-Conflict $t $w; if ($bad) { $blocker = $w.Id; break } }
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

    # 资源租约检查（软约束：只警告，不阻断）
    $homeBase2 = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($homeBase2)) { $homeBase2 = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    $hostsFile2 = Join-Path $homeBase2 'data\agentos\hosts.json'
    $leaseDir2  = Join-Path $homeBase2 'devops\agentos\leases'
    if (Test-Path -LiteralPath $hostsFile2) {
        $hostsObj2 = $null
        try { $hostsObj2 = (Get-Content -LiteralPath $hostsFile2 -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $hostsObj2 = $null }
        if ($null -ne $hostsObj2) {
            $knownHosts = @($hostsObj2.hosts.PSObject.Properties | ForEach-Object { $_.Name })
            $leases2 = @{}
            if (Test-Path -LiteralPath $leaseDir2) {
                foreach ($lf in (Get-ChildItem -LiteralPath $leaseDir2 -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                    try {
                        $lj = (Get-Content -LiteralPath $lf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
                        $leases2[[string]$lj.host] = $lj
                    } catch { }
                }
            }
            foreach ($t in $tasks) {
                if ([string]::IsNullOrWhiteSpace($t.Resource) -or $t.Resource -eq 'none') { continue }
                if ($knownHosts -notcontains $t.Resource) {
                    $warns.Add("$($t.Id): resource '$($t.Resource)' 不在 hosts.json 清单内")
                    continue
                }
                if ($leases2.ContainsKey($t.Resource)) {
                    $holder = [string]$leases2[$t.Resource].task
                    $warns.Add("$($t.Id): 资源 '$($t.Resource)' 已被 '$holder' 租用")
                }
            }
        }
    }
    if ($errors.Count -eq 0) {
        $waves = (Get-Schedule $tasks (Get-Levels $tasks $idx)).Waves
        $parallel = @($waves | Where-Object { $_.Tasks.Count -gt 1 })
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
    $sched = Get-Schedule $o.Tasks (Get-Levels $o.Tasks $idx)
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
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $ready) {
        $placed = $false
        foreach ($g in $groups) {
            $conflict = $false
            foreach ($x in $g) { if (Test-Conflict $t $x) { $conflict = $true; break } }
            if (-not $conflict) { $g.Add($t); $placed = $true; break }
        }
        if (-not $placed) { $g2 = [System.Collections.Generic.List[object]]::new(); $g2.Add($t); $groups.Add($g2) }
    }
    if ($machine) {
        $batches = @()
        foreach ($g in $groups) {
            $batch = @()
            foreach ($t in $g) { $batch += [pscustomobject]@{ id = $t.Id; kind = $t.Kind; worktree = $t.Worktree; resource = $t.Resource; title = $t.Title } }
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

function Invoke-StateUpdate {
    $o = Read-PlanFile $Plan
    if (-not $Task) { throw '-Task is required' }
    $exists = @($o.Tasks | Where-Object { $_.Id -eq $Task })
    if ($exists.Count -eq 0) { throw "no such task in PLAN: $Task" }
    $st = Read-State $o.Path
    $prev = if ($st.ContainsKey($Task) -and $st[$Task].ContainsKey('status')) { $st[$Task]['status'] } else { 'planned' }
    $st[$Task] = @{ status = $Status; owner = $Owner; prev = $prev; updated = $script:Now }
    $p = Write-State $o.Path $st
    if ($machine) {
        [pscustomobject]@{ ok = $true; task = $Task; from = $prev; to = $Status; owner = $Owner; state = $p } | ConvertTo-Json -Depth 4
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
        if ($machine) { [pscustomobject]@{ ok = $r.Ok; errors = @($r.Errors); warnings = @($r.Warnings) } | ConvertTo-Json -Depth 5; return }
        foreach ($e in $r.Errors) { Write-Output ("ERROR " + $e) }
        foreach ($w in $r.Warnings) { Write-Output ("WARN  " + $w) }
        if ($r.Ok) { Write-Output 'OK plan is valid' } else { exit 1 }
    }
    'graph' { Invoke-Graph }
    'next' { Invoke-Next }
    'state' { Invoke-StateUpdate }
    default { Invoke-Show }
}

exit 0
