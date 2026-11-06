<#
.SYNOPSIS
  AgentOS 远端资源管理：机器清单 / SSH 连通性 / 单机单任务租约。
.DESCRIPTION
  数据位置（环境自适配）：
    hosts : <homebase>/data/agentos/hosts.json      （真实清单，永不入 git）
    leases: <homebase>/devops/agentos/leases/*.json （生成物，永不入 git）

  子命令：list / check / acquire / release
  默认输出 JSON；-Human 出表。
  退出码：0 成功 / 1 租约冲突或操作失败 / 2 配置缺失
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'check', 'acquire', 'release')]
    [string]$Command = 'list',
    [Parameter(Position = 1)]
    [string]$HostAlias = '',
    [string]$Task = '',
    [string]$Note = '',
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

function Write-Err {
    param([int]$Code, [string]$Message)
    if ($machine) {
        [pscustomobject]@{ ok = $false; error = [pscustomobject]@{ code = $Code; message = $Message } } | ConvertTo-Json -Depth 4
    } else {
        Write-Output ('ERROR ' + $Message)
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
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-AllLeases {
    $map = @{}
    if (-not (Test-Path -LiteralPath $LeaseDir)) { return $map }
    foreach ($f in (Get-ChildItem -LiteralPath $LeaseDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $raw = [System.IO.File]::ReadAllText($f.FullName, $E)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        try { $j = $raw | ConvertFrom-Json } catch { continue }
        $map[[string]$j.host] = $j
    }
    return $map
}

$hostsObj = Load-Hosts
$hostNames = @($hostsObj.hosts.PSObject.Properties | ForEach-Object { $_.Name })

switch ($Command) {
    'list' {
        $leases = Get-AllLeases
        $rows = @()
        foreach ($n in $hostNames) {
            $h = $hostsObj.hosts.$n
            $lg = if ($leases.ContainsKey($n)) { $leases[$n] } else { $null }
            $rows += [pscustomobject]@{
                host     = $n
                hostname = [string]$h.hostname
                user     = [string]$h.user
                tags     = @($h.tags)
                purpose  = [string]$h.purpose
                lease    = $(if ($lg) { [string]$lg.task } else { 'free' })
                acquired = $(if ($lg) { [string]$lg.acquired_at } else { '' })
                note     = $(if ($lg) { [string]$lg.note } else { '' })
            }
        }
        $payload = [pscustomobject]@{ ok = $true; homebase = $HomeBase; count = $rows.Count; hosts = $rows }
        if ($machine) { $payload | ConvertTo-Json -Depth 6 }
        else {
            foreach ($r in $rows) {
                Write-Output ('{0,-10} {1,-16} lease={2,-46} acquired={3}' -f $r.host, $r.hostname, $r.lease, $r.acquired)
            }
            Write-Output ''
            Write-Output ('total=' + $rows.Count + '  free=' + @($rows | Where-Object { $_.lease -eq 'free' }).Count)
        }
        exit 0
    }
    'check' {
        $aliases = if ($HostAlias) { @($HostAlias) } else { $hostNames }
        $rows = @()
        foreach ($a in $aliases) {
            if (-not ($hostNames -contains $a)) { $rows += [pscustomobject]@{ host = $a; ok = $false; detail = 'unknown host' }; continue }
            $h = $hostsObj.hosts.$a
            $target = [string]$h.hostname
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $sshTarget = if ($h.user) { ([string]$h.user) + '@' + $target } else { $target }
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
        if (-not ($hostNames -contains $HostAlias)) { Write-Err 1 ('unknown host: ' + $HostAlias) }
        $existing = Read-Lease $HostAlias
        if ($null -ne $existing) {
            if ([string]$existing.task -eq $Task) {
                $payload = [pscustomobject]@{ ok = $true; host = $HostAlias; task = $Task; note = 'already owned by you'; acquired_at = [string]$existing.acquired_at }
                if ($machine) { $payload | ConvertTo-Json -Depth 4 } else { Write-Output 'already owned by you' }
                exit 0
            }
            Write-Err 1 ('host ' + $HostAlias + ' already leased by ''' + [string]$existing.task + ''' since ' + [string]$existing.acquired_at)
        }
        New-Item -ItemType Directory -Force -Path $LeaseDir | Out-Null
        $lease = [ordered]@{
            schema_version = 1
            host           = $HostAlias
            task           = $Task
            note           = $Note
            acquired_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $json = ($lease | ConvertTo-Json -Depth 4)
        [System.IO.File]::WriteAllText((Lease-Path $HostAlias), $json, (New-Object System.Text.UTF8Encoding($false)))
        if ($machine) { [pscustomobject]@{ ok = $true; host = $HostAlias; task = $Task; acquired_at = $lease.acquired_at } | ConvertTo-Json -Depth 4 }
        else { Write-Output ('acquired ' + $HostAlias + ' by ' + $Task) }
        exit 0
    }
    'release' {
        if (-not $HostAlias) { Write-Err 1 'release requires a host alias' }
        if (-not ($hostNames -contains $HostAlias)) { Write-Err 1 ('unknown host: ' + $HostAlias) }
        $p = Lease-Path $HostAlias
        if (-not (Test-Path -LiteralPath $p)) {
            if ($machine) { '{"ok":true,"note":"no lease"}' } else { Write-Output 'no lease' }
            exit 0
        }
        $lg = Read-Lease $HostAlias
        if ($null -ne $lg -and $Task -and ([string]$lg.task -ne $Task)) {
            Write-Err 1 ('lease held by ''' + [string]$lg.task + ''', not ''' + $Task + '''')
        }
        Remove-Item -LiteralPath $p -Force
        if ($machine) { [pscustomobject]@{ ok = $true; host = $HostAlias; released = $(if ($lg) { [string]$lg.task } else { '' }) } | ConvertTo-Json -Depth 4 }
        else { Write-Output ('released ' + $HostAlias) }
        exit 0
    }
}
