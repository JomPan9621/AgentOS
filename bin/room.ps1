<#
.SYNOPSIS
  AgentOS 远端资源管理：机器清单 / SSH 连通性 / GPU 子租约。
.DESCRIPTION
  数据位置（环境自适配）：
    hosts : <homebase>/data/agentos/hosts.json      （真实清单，永不入 git）
    leases: <homebase>/devops/agentos/leases/*.json （生成物，永不入 git）

  租约版本：
    v1 legacy：<host>.json 单租约，整机一个 task（保持兼容，读取时视为整机占用）。
    v2        ：<host>.json { schema_version: 2, allocations: [...] }；
                同一 host 可挂多个不重叠 GPU allocation。
                allocation 字段：task / issue / agent_task / gpus / acquired_at / note。

  GPU 是硬约束：acquire 必须显式 -Gpus <n|all>，自动分配最低空闲 GPU；
  不足时 exit 1，输出已用/空闲与替代 host 的空闲 GPU 数。
  环境 profile（os/runtime/gpu_model/gpu_count/driver/image）只读感知；
  profile 缺失时显示 UNKNOWN，不作为分配阻断条件。

  子命令：list / check / acquire / release / show
  退出码：0 成功 / 1 租约冲突或操作失败 / 2 配置缺失
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'check', 'acquire', 'release', 'show')]
    [string]$Command = 'list',
    [Parameter(Position = 1)]
    [string]$HostAlias = '',
    [string]$Task = '',
    [string]$Issue = '',
    [string]$AgentTask = '',
    [string]$Note = '',
    [string]$Gpus = '',
    [int]$TimeoutSec = 8,
    [string]$HomeBase = '',
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$machine = -not $Human
$E = [System.Text.Encoding]::UTF8

# --- 环境自适配 ---
if ([string]::IsNullOrWhiteSpace($HomeBase)) {
    $HomeBase = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($HomeBase)) {
        $HomeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }
}
$HostsFile = Join-Path $HomeBase 'data\agentos\hosts.json'
$LeaseDir  = Join-Path $HomeBase 'devops\agentos\leases'

function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Write-Err {
    param([int]$Code, [string]$Message, $Extra = $null)
    if ($machine) {
        $payload = [ordered]@{ ok = $false; error = [pscustomobject]@{ code = $Code; message = $Message } }
        if ($null -ne $Extra) {
            foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }
        }
        $payload | ConvertTo-Json -Depth 8
    } else {
        Write-Output ('ERROR ' + $Message)
        if ($null -ne $Extra -and $Extra.Contains('alternatives')) {
            foreach ($a in @($Extra['alternatives'])) {
                Write-Output ('  alternative: {0} free={1}/{2}' -f $a.host, $a.free, $a.gpu_count)
            }
        }
    }
    exit $Code
}

function Load-Hosts {
    if (-not (Test-Path -LiteralPath $HostsFile)) { Write-Err 2 ('hosts file not found: ' + $HostsFile) }
    $raw = [System.IO.File]::ReadAllText($HostsFile, $E)
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Err 2 'hosts file empty' }
    try { $obj = $raw | ConvertFrom-Json } catch { Write-Err 2 ('cannot parse hosts: ' + $_.Exception.Message) }
    $set = $obj.hosts
    if ($null -eq $set) { Write-Err 2 'no hosts table in hosts.json' }
    return $obj
}

function Lease-Path {
    param([string]$Alias)
    return (Join-Path $LeaseDir ($Alias + '.json'))
}

function Read-Lease {
    param([string]$Alias)
    $p = Lease-Path $Alias
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $raw = [System.IO.File]::ReadAllText($p, $E)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    # TODO(L1): 损坏 JSON / 空文件当前按“无租约”处理（fail-open），会低估已用 GPU；
    # 下游 plan/track 只读时也会跳过坏文件。后续应改为显式报错（exit 2），
    # 避免静默把坏租约当空闲。本次不改数据与行为。
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-LeaseSchema {
    param($Lease)
    if ($null -eq $Lease) { return 0 }
    $sv = Get-Prop $Lease 'schema_version' 1
    try { return [int]$sv } catch { return 1 }
}

function Get-HostProfile {
    param($HostObj)
    $profile = Get-Prop $HostObj 'profile' $null
    $os = [string](Get-Prop $profile 'os' '')
    $runtime = [string](Get-Prop $profile 'runtime' '')
    $gpuModel = [string](Get-Prop $profile 'gpu_model' '')
    $driver = [string](Get-Prop $profile 'driver' '')
    $image = [string](Get-Prop $profile 'image' '')
    $gpuCount = 0
    $gc = Get-Prop $profile 'gpu_count' $null
    if ($null -ne $gc -and ("$gc" -match '^\d+$')) { $gpuCount = [int]$gc }
    if ($gpuCount -le 0) {
        $hc = Get-Prop $HostObj 'gpu_count' $null
        if ($null -ne $hc -and ("$hc" -match '^\d+$')) { $gpuCount = [int]$hc }
    }
    if ($gpuCount -le 0) {
        foreach ($tag in @(Get-Prop $HostObj 'tags' @())) {
            $t = [string]$tag
            if ($t -match '^(?<n>\d+)gpu$') { $gpuCount = [int]$Matches['n']; break }
        }
    }
    $known = (($os -ne '') -or ($runtime -ne '') -or ($gpuModel -ne '') -or ($driver -ne '') -or ($image -ne ''))
    return [pscustomobject]@{
        os        = $os
        runtime   = $runtime
        gpu_model = $gpuModel
        gpu_count = $gpuCount
        driver    = $driver
        image     = $image
        status    = $(if ($known) { 'known' } else { 'UNKNOWN' })
    }
}

function Get-LeaseAllocations {
    param($Lease, [int]$GpuCount)
    if ($null -eq $Lease) { return @() }
    $schema = Get-LeaseSchema $Lease
    $allocProp = Get-Prop $Lease 'allocations' $null
    if ($schema -ge 2 -and $null -ne $allocProp) {
        $out = @()
        foreach ($a in @($allocProp)) {
            if ($null -eq $a) { continue }
            $ids = @()
            foreach ($g in @(Get-Prop $a 'gpus' @())) {
                if ("$g" -match '^\d+$') { $ids += [int]$g }
            }
            $out += [pscustomobject]@{
                task        = [string](Get-Prop $a 'task' '')
                issue       = [string](Get-Prop $a 'issue' '')
                agent_task  = [string](Get-Prop $a 'agent_task' '')
                gpus        = @($ids | Sort-Object -Unique)
                acquired_at = [string](Get-Prop $a 'acquired_at' '')
                note        = [string](Get-Prop $a 'note' '')
                legacy      = $false
                whole_host  = $false
            }
        }
        return @($out)
    }
    # v1 legacy：整机单租约
    $ids1 = @()
    for ($i = 0; $i -lt $GpuCount; $i++) { $ids1 += $i }
    return @([pscustomobject]@{
            task        = [string](Get-Prop $Lease 'task' '')
            issue       = [string](Get-Prop $Lease 'issue' '')
            agent_task  = [string](Get-Prop $Lease 'agent_task' '')
            gpus        = @($ids1)
            acquired_at = [string](Get-Prop $Lease 'acquired_at' '')
            note        = [string](Get-Prop $Lease 'note' '')
            legacy      = $true
            whole_host  = $true
        })
}

function Get-UsedGpuIds {
    param($Allocations)
    $used = @()
    foreach ($a in @($Allocations)) {
        foreach ($g in @(Get-Prop $a 'gpus' @())) { $used += [int]$g }
    }
    return @($used | Sort-Object -Unique)
}

function Test-AllocationIdentity {
    # v2 allocation 身份 = task + issue：issue 为空时按空匹配，不能只按 task。
    param($Alloc, [string]$TaskId, [string]$IssueId)
    if ([string](Get-Prop $Alloc 'task' '') -ine $TaskId) { return $false }
    $aIssue = [string](Get-Prop $Alloc 'issue' '')
    $want = [string]$IssueId
    return ($aIssue -ieq $want)
}

function Format-AllocationHolders {
    param($Allocations)
    $items = @()
    foreach ($a in @($Allocations)) {
        $t = [string](Get-Prop $a 'task' '')
        if (-not $t) { continue }
        $i = [string](Get-Prop $a 'issue' '')
        if ($i) { $items += ($t + '(issue=' + $i + ')') } else { $items += $t }
    }
    return (($items | Select-Object -Unique) -join ',')
}

function Get-AllocationSummary {
    param($Allocations)
    return @(@($Allocations) | ForEach-Object {
            [pscustomobject]@{
                task        = [string]$_.task
                issue       = [string]$_.issue
                agent_task  = [string]$_.agent_task
                gpus        = @($_.gpus)
                acquired_at = [string]$_.acquired_at
                note        = [string]$_.note
                legacy      = [bool]$_.legacy
                whole_host  = [bool]$_.whole_host
            }
        })
}

function Get-CapacityRows {
    param([string]$ExcludeAlias = '')
    $rows = @()
    foreach ($n in $hostNames) {
        if ($n -eq $ExcludeAlias) { continue }
        $h = $hostsObj.hosts.$n
        $prof = Get-HostProfile $h
        $lease = Read-Lease $n
        $allocs = @(Get-LeaseAllocations $lease $prof.gpu_count)
        $usedIds = @(Get-UsedGpuIds $allocs)
        $rows += [pscustomobject]@{
            host      = $n
            gpu_count = $prof.gpu_count
            used      = $usedIds.Count
            free      = [Math]::Max(0, $prof.gpu_count - $usedIds.Count)
        }
    }
    return @($rows)
}

function Get-AlternativeHosts {
    param([string]$ExcludeAlias, [int]$Need)
    $rows = @(Get-CapacityRows -ExcludeAlias $ExcludeAlias | Where-Object { $_.free -gt 0 })
    if ($Need -gt 0) {
        $enough = @($rows | Where-Object { $_.free -ge $Need })
        if ($enough.Count -gt 0) { $rows = $enough }
    }
    return @($rows | Sort-Object -Property @{ Expression = { $_.free }; Descending = $true }, @{ Expression = { $_.host }; Descending = $false })
}

function Write-LeaseAtomic {
    param([string]$Alias, [string]$Json)
    New-Item -ItemType Directory -Force -Path $LeaseDir | Out-Null
    $path = Lease-Path $Alias
    $tmp = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-LeaseV2Json {
    param([string]$Alias, $Allocations)
    $list = @()
    foreach ($a in @($Allocations)) {
        $list += [ordered]@{
            task        = [string](Get-Prop $a 'task' '')
            issue       = [string](Get-Prop $a 'issue' '')
            agent_task  = [string](Get-Prop $a 'agent_task' '')
            gpus        = @(@(Get-Prop $a 'gpus' @()) | ForEach-Object { [int]$_ })
            acquired_at = [string](Get-Prop $a 'acquired_at' '')
            note        = [string](Get-Prop $a 'note' '')
        }
    }
    $obj = [ordered]@{
        schema_version = 2
        host           = $Alias
        updated_at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        allocations    = @($list)
    }
    return ($obj | ConvertTo-Json -Depth 8)
}

function Invoke-WithLeaseLock {
    param([string]$Alias, [scriptblock]$Body)
    New-Item -ItemType Directory -Force -Path $LeaseDir | Out-Null
    $lockPath = Join-Path $LeaseDir ($Alias + '.lock')
    $handle = $null
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $handle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $handle) { Write-Err 1 ('lease lock busy: ' + $Alias) }
    try {
        return (& $Body)
    } finally {
        if ($null -ne $handle) { $handle.Close(); $handle.Dispose() }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-HostRow {
    param([string]$Name)
    $h = $hostsObj.hosts.$Name
    $prof = Get-HostProfile $h
    $lease = Read-Lease $Name
    $schema = Get-LeaseSchema $lease
    $allocs = @(Get-LeaseAllocations $lease $prof.gpu_count)
    $usedIds = @(Get-UsedGpuIds $allocs)
    $used = $usedIds.Count
    $free = [Math]::Max(0, $prof.gpu_count - $used)
    $leaseMode = if ($null -eq $lease) { 'free' } elseif ($schema -lt 2) { 'legacy' } else { 'allocations' }
    $leaseLabel = if ($null -eq $lease) { 'free' } elseif ($schema -lt 2) { [string](Get-Prop $lease 'task' '') } else { 'allocated' }
    return [pscustomobject]@{
        host        = $Name
        hostname    = [string](Get-Prop $h 'hostname' '')
        user        = [string](Get-Prop $h 'user' '')
        tags        = @(Get-Prop $h 'tags' @())
        purpose     = [string](Get-Prop $h 'purpose' '')
        profile     = $prof
        gpu_count   = $prof.gpu_count
        gpus_used   = $used
        gpus_free   = $free
        lease_mode  = $leaseMode
        lease       = $leaseLabel
        acquired    = $(if ($null -ne $lease) { [string](Get-Prop $lease 'acquired_at' '') } else { '' })
        note        = $(if ($null -ne $lease) { [string](Get-Prop $lease 'note' '') } else { '' })
        allocations = @(Get-AllocationSummary $allocs)
    }
}

function Read-RequestedGpus {
    $trimmed = ([string]$Gpus).Trim()
    if ($trimmed -ieq 'all') { return [pscustomobject]@{ Valid = $true; All = $true; Count = 0 } }
    if ($trimmed -match '^\d+$' -and [int]$trimmed -ge 1) { return [pscustomobject]@{ Valid = $true; All = $false; Count = [int]$trimmed } }
    return [pscustomobject]@{ Valid = $false; All = $false; Count = 0 }
}

$hostsObj = Load-Hosts
$hostNames = @($hostsObj.hosts.PSObject.Properties | ForEach-Object { $_.Name })

switch ($Command) {
    'list' {
        $rows = @()
        foreach ($n in $hostNames) { $rows += Get-HostRow $n }
        $totalGpus = 0; $usedGpus = 0; $freeGpus = 0; $allocCount = 0
        foreach ($r in $rows) {
            $totalGpus += [int]$r.gpu_count
            $usedGpus += [int]$r.gpus_used
            $freeGpus += [int]$r.gpus_free
            $allocCount += @($r.allocations).Count
        }
        $payload = [pscustomobject]@{
            ok         = $true
            homebase   = $HomeBase
            count      = $rows.Count
            gpu_count  = $totalGpus
            gpus_used  = $usedGpus
            gpus_free  = $freeGpus
            allocations = $allocCount
            hosts      = $rows
        }
        if ($machine) { $payload | ConvertTo-Json -Depth 8 }
        else {
            foreach ($r in $rows) {
                $os = if ($r.profile.os) { $r.profile.os } else { 'UNKNOWN' }
                $runtime = if ($r.profile.runtime) { $r.profile.runtime } else { 'UNKNOWN' }
                Write-Output ('{0,-12} {1,-16} os={2,-18} runtime={3,-14} gpu={4} used={5} free={6} lease={7}' -f $r.host, $r.hostname, $os, $runtime, $r.gpu_count, $r.gpus_used, $r.gpus_free, $r.lease_mode)
                foreach ($a in @($r.allocations)) {
                    $gpuText = if ($a.whole_host) { 'whole-host' } else { (@($a.gpus) -join ',') }
                    Write-Output ('    task={0,-12} issue={1,-6} gpus={2,-12} agent_task={3} acquired={4}' -f $a.task, $a.issue, $gpuText, $a.agent_task, $a.acquired_at)
                }
            }
            Write-Output ''
            Write-Output ('total={0}  free-hosts={1}  gpus={2}/{3} free  allocations={4}' -f $rows.Count, @($rows | Where-Object { $_.lease_mode -eq 'free' }).Count, $freeGpus, $totalGpus, $allocCount)
        }
        exit 0
    }
    'show' {
        if (-not $HostAlias) { Write-Err 1 'show requires a host alias' }
        if (-not ($hostNames -contains $HostAlias)) { Write-Err 1 ('unknown host: ' + $HostAlias) }
        $row = Get-HostRow $HostAlias
        if ($machine) {
            [pscustomobject]@{ ok = $true; host = $row } | ConvertTo-Json -Depth 8
        } else {
            $p = $row.profile
            Write-Output ('host      : ' + $row.host + '  (' + $row.hostname + ')')
            Write-Output ('purpose   : ' + $row.purpose)
            Write-Output ('profile   : ' + $p.status)
            Write-Output ('  os      : ' + $(if ($p.os) { $p.os } else { 'UNKNOWN' }))
            Write-Output ('  runtime : ' + $(if ($p.runtime) { $p.runtime } else { 'UNKNOWN' }))
            Write-Output ('  gpu     : ' + $(if ($p.gpu_model) { $p.gpu_model } else { 'UNKNOWN' }) + '  count=' + $row.gpu_count)
            Write-Output ('  driver  : ' + $(if ($p.driver) { $p.driver } else { 'UNKNOWN' }))
            Write-Output ('  image   : ' + $(if ($p.image) { $p.image } else { 'UNKNOWN' }))
            Write-Output ('usage     : used=' + $row.gpus_used + ' free=' + $row.gpus_free + ' lease=' + $row.lease_mode)
            foreach ($a in @($row.allocations)) {
                $gpuText = if ($a.whole_host) { 'whole-host (legacy)' } else { (@($a.gpus) -join ',') }
                Write-Output ('  allocation: task={0} issue={1} gpus={2} agent_task={3} acquired={4}' -f $a.task, $a.issue, $gpuText, $a.agent_task, $a.acquired_at)
            }
        }
        exit 0
    }
    'check' {
        $aliases = if ($HostAlias) { @($HostAlias) } else { $hostNames }
        $rows = @()
        foreach ($a in $aliases) {
            if (-not ($hostNames -contains $a)) { $rows += [pscustomobject]@{ host = $a; ok = $false; detail = 'unknown host' }; continue }
            $h = $hostsObj.hosts.$a
            $target = [string](Get-Prop $h 'hostname' '')
            $user = [string](Get-Prop $h 'user' '')
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $sshTarget = if ($user) { $user + '@' + $target } else { $target }
            $out = @(& ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" -o StrictHostKeyChecking=no $sshTarget 'whoami; hostname' 2>&1)
            $rc = $LASTEXITCODE
            $ErrorActionPreference = $prev
            $rows += [pscustomobject]@{
                host   = $a
                target = $target
                ok     = ($rc -eq 0)
                detail = $(if ($rc -eq 0) { ($out -join ' ').Trim() } else { 'ssh failed' })
            }
        }
        $payload = [pscustomobject]@{ ok = $true; count = $rows.Count; results = $rows }
        if ($machine) { $payload | ConvertTo-Json -Depth 5 }
        else {
            foreach ($r in $rows) { Write-Output ('{0,-10} {1,-18} ok={2,-6} {3}' -f $r.host, $r.target, $r.ok, $r.detail) }
        }
        if (@($rows | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
        exit 0
    }
    'acquire' {
        if (-not $HostAlias) { Write-Err 1 'acquire requires a host alias' }
        if (-not $Task) { Write-Err 1 'acquire requires -Task' }
        if ([string]::IsNullOrWhiteSpace($Gpus)) { Write-Err 1 'acquire requires -Gpus <n|all> (GPU 是硬约束，必须显式声明)' }
        if (-not ($hostNames -contains $HostAlias)) { Write-Err 1 ('unknown host: ' + $HostAlias) }
        $req = Read-RequestedGpus
        if (-not $req.Valid) { Write-Err 1 ('-Gpus must be a positive integer or "all", got: ' + $Gpus) }

        $hostObj = $hostsObj.hosts.$HostAlias
        $prof = Get-HostProfile $hostObj
        $cap = [int]$prof.gpu_count
        $result = Invoke-WithLeaseLock -Alias $HostAlias -Body {
            $existing = Read-Lease $HostAlias
            $schema = Get-LeaseSchema $existing
            if ($cap -le 0) {
                $alts = @(Get-AlternativeHosts -ExcludeAlias $HostAlias -Need $(if ($req.All) { 1 } else { $req.Count }))
                Write-Err 1 ('host ' + $HostAlias + ' has no known gpu_count; update profile.gpu_count / host gpu_count / tags (<n>gpu)') -Extra @{
                    host = $HostAlias; gpu_count = $cap; used = 0; free = 0; alternatives = $alts
                }
            }
            if ($null -ne $existing -and $schema -lt 2) {
                $legacyTask = [string](Get-Prop $existing 'task' '')
                if ($legacyTask -ieq $Task) {
                    return [pscustomobject]@{
                        ok = $true; host = $HostAlias; task = $Task; schema_version = 1; legacy = $true;
                        issue = [string](Get-Prop $existing 'issue' '');
                        gpus = @(); note = 'already owned by you (legacy whole-host lease)';
                        acquired_at = [string](Get-Prop $existing 'acquired_at' '')
                    }
                }
                $alts = @(Get-AlternativeHosts -ExcludeAlias $HostAlias -Need $(if ($req.All) { 1 } else { $req.Count }))
                Write-Err 1 ('host ' + $HostAlias + ' already leased by ''' + $legacyTask + ''' (legacy whole-host lease since ' + [string](Get-Prop $existing 'acquired_at' '') + ')') -Extra @{
                    host = $HostAlias; gpu_count = $cap; used = $cap; free = 0; used_gpu_ids = @(); free_gpu_ids = @(); alternatives = $alts
                }
            }

            $allocs = @(Get-LeaseAllocations $existing $cap)
            $need = if ($req.All) { $cap } else { $req.Count }
            $mine = @($allocs | Where-Object { Test-AllocationIdentity $_ $Task $Issue })
            if ($mine.Count -gt 0) {
                $heldIds = @()
                foreach ($m in $mine) { $heldIds += @($m.gpus) }
                $heldIds = @($heldIds | Sort-Object -Unique)
                if ($heldIds.Count -ge $need -and ((-not $req.All) -or $heldIds.Count -eq $cap)) {
                    return [pscustomobject]@{
                        ok = $true; host = $HostAlias; task = $Task; issue = $Issue; schema_version = 2;
                        gpus = @($heldIds); gpu_count = $cap; note = 'already owned by you';
                        acquired_at = [string]$mine[0].acquired_at
                    }
                }
                Write-Err 1 ('task ' + $Task + ' (issue ''' + $Issue + ''') already holds ' + $heldIds.Count + ' GPU(s) on ' + $HostAlias + '; release before acquiring ' + $need + ' (release requires matching -Task and -Issue)') -Extra @{
                    host = $HostAlias; issue = $Issue; gpu_count = $cap; held_gpus = @($heldIds); requested = $need
                }
            }

            $usedIds = @(Get-UsedGpuIds $allocs)
            $freeIds = @()
            for ($i = 0; $i -lt $cap; $i++) { if ($usedIds -notcontains $i) { $freeIds += $i } }
            if ($freeIds.Count -lt $need) {
                $alts = @(Get-AlternativeHosts -ExcludeAlias $HostAlias -Need $need)
                $holders = Format-AllocationHolders $allocs
                Write-Err 1 ('no free GPU on ' + $HostAlias + ': used=' + $usedIds.Count + '/' + $cap + ' free=' + $freeIds.Count + ' need=' + $need + $(if ($holders) { ' (holders: ' + $holders + ')' } else { '' })) -Extra @{
                    host = $HostAlias; gpu_count = $cap; used = $usedIds.Count; free = $freeIds.Count; need = $need;
                    used_gpu_ids = @($usedIds); free_gpu_ids = @($freeIds); alternatives = $alts
                }
            }

            $assign = @($freeIds | Select-Object -First $need)
            $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $allocs += [pscustomobject]@{
                task = $Task; issue = $Issue; agent_task = $AgentTask; gpus = @($assign);
                acquired_at = $now; note = $Note; legacy = $false; whole_host = $false
            }
            Write-LeaseAtomic -Alias $HostAlias -Json (ConvertTo-LeaseV2Json $HostAlias $allocs)
            $freeAfter = [Math]::Max(0, $cap - $usedIds.Count - $assign.Count)
            return [pscustomobject]@{
                ok = $true; host = $HostAlias; task = $Task; issue = $Issue; agent_task = $AgentTask;
                schema_version = 2; gpus = @($assign); gpu_count = $cap; used = ($usedIds.Count + $assign.Count);
                free = $freeAfter; acquired_at = $now; note = $Note
            }
        }
        if ($machine) { $result | ConvertTo-Json -Depth 8 }
        else {
            Write-Output ('acquired ' + $result.host + ' by ' + $result.task + ' gpus=' + (@($result.gpus) -join ',') + ' free=' + [string](Get-Prop $result 'free' ''))
        }
        exit 0
    }
    'release' {
        if (-not $HostAlias) { Write-Err 1 'release requires a host alias' }
        if (-not ($hostNames -contains $HostAlias)) { Write-Err 1 ('unknown host: ' + $HostAlias) }
        $prof = Get-HostProfile $hostsObj.hosts.$HostAlias
        $cap = [int]$prof.gpu_count
        $result = Invoke-WithLeaseLock -Alias $HostAlias -Body {
            $existing = Read-Lease $HostAlias
            if ($null -eq $existing) {
                return [pscustomobject]@{ ok = $true; host = $HostAlias; released = ''; issue = $Issue; note = 'no lease' }
            }
            $schema = Get-LeaseSchema $existing
            if ($schema -lt 2) {
                # v1 legacy：保持 task 匹配语义，issue 视为空/忽略。
                $legacyTask = [string](Get-Prop $existing 'task' '')
                if ($Task -and $legacyTask -ine $Task) {
                    Write-Err 1 ('lease held by ''' + $legacyTask + ''', not ''' + $Task + '''')
                }
                Remove-Item -LiteralPath (Lease-Path $HostAlias) -Force
                return [pscustomobject]@{
                    ok = $true; host = $HostAlias; released = $legacyTask; issue = [string](Get-Prop $existing 'issue' '');
                    legacy = $true; gpus = @()
                }
            }
            if (-not $Task) { Write-Err 1 'release requires -Task for a v2 allocation lease' }
            $allocs = @(Get-LeaseAllocations $existing $cap)
            # v2 身份 = task + issue：task 已有 issue 作用域 allocation 时必须显式 -Issue，避免误删。
            $taskAllocs = @($allocs | Where-Object { [string](Get-Prop $_ 'task' '') -ieq $Task })
            $scoped = @($taskAllocs | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-Prop $_ 'issue' '')) })
            if ([string]::IsNullOrWhiteSpace($Issue) -and $scoped.Count -gt 0) {
                $issues = (@($scoped | ForEach-Object { [string](Get-Prop $_ 'issue' '') }) | Select-Object -Unique) -join ','
                Write-Err 1 ('release requires -Issue when task ''' + $Task + ''' has issue-scoped allocations on ' + $HostAlias + ' (issues: ' + $issues + ')')
            }
            $match = @($allocs | Where-Object { Test-AllocationIdentity $_ $Task $Issue })
            if ($match.Count -eq 0) {
                $holders = Format-AllocationHolders $allocs
                Write-Err 1 ('no allocation for task ''' + $Task + ''' issue ''' + $Issue + ''' on ' + $HostAlias + ' (holders: ' + $holders + ')')
            }
            $releasedIds = @()
            foreach ($m in $match) { $releasedIds += @($m.gpus) }
            $releasedIds = @($releasedIds | Sort-Object -Unique)
            $remain = @($allocs | Where-Object { -not (Test-AllocationIdentity $_ $Task $Issue) })
            if ($remain.Count -eq 0) {
                Remove-Item -LiteralPath (Lease-Path $HostAlias) -Force
            } else {
                Write-LeaseAtomic -Alias $HostAlias -Json (ConvertTo-LeaseV2Json $HostAlias $remain)
            }
            return [pscustomobject]@{
                ok = $true; host = $HostAlias; released = $Task; issue = $Issue; gpus = @($releasedIds);
                remaining = @($remain | ForEach-Object { [string]$_.task })
            }
        }
        if ($machine) { $result | ConvertTo-Json -Depth 6 }
        else { Write-Output ('released ' + $HostAlias + ' task=' + $result.released + ' issue=' + $result.issue + ' gpus=' + (@($result.gpus) -join ',')) }
        exit 0
    }
}
