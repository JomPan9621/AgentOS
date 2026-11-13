<#
.SYNOPSIS
  Harness 会话台账：register / heartbeat / close / list。
.DESCRIPTION
  会话事件只追加到统一 ledger（<homebase>\devops\agentos\ledger.jsonl），不另建状态文件。
  会话必须绑定一个已 start 的任务（issue + task）：session 是执行者的在场证明，不是任务本身。

  事件：session-register / session-heartbeat / session-close
  字段：session（会话 id）/ role（master|sub-master|worker）/ issue / task / host / ts / note
#>
[CmdletBinding()]
param(
    [ValidateSet('register', 'heartbeat', 'close', 'list')]
    [string]$Command = 'list',
    [string]$Id = '',
    [ValidateSet('master', 'sub-master', 'worker')]
    [string]$Role = 'worker',
    [string]$Issue = '',
    [string]$Task = '',
    [Alias('Host')]
    [string]$HostName = '',
    [string]$Note = '',
    [string]$Ledger = '',
    [int]$TtlMinutes = 120,
    [switch]$All,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) {
    $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
if ([string]::IsNullOrWhiteSpace($Ledger)) {
    $Ledger = Join-Path $homeBase 'devops\agentos\ledger.jsonl'
}
$machine = -not $Human
. (Join-Path $PSScriptRoot 'ledger.ps1')

function Get-AgeMinutes {
    param([string]$Ts)
    try { return [math]::Round(((Get-Date) - [datetime]::ParseExact($Ts, 'yyyy-MM-ddTHH:mm:ss', $null)).TotalMinutes, 0) }
    catch { return -1 }
}

function Get-OpenSession {
    param([string]$SessionId)
    $all = @(Get-LedgerSessions -Path $Ledger)
    $hit = @($all | Where-Object { $_.id -eq $SessionId })
    if ($hit.Count -eq 0) { throw "session not found: $SessionId" }
    return $hit[0]
}

function Get-SessionRows {
    param([switch]$IncludeClosed)
    $rows = @()
    foreach ($s in @(Get-LedgerSessions -Path $Ledger)) {
        if ($s.closed -and -not $IncludeClosed) { continue }
        $age = Get-AgeMinutes $s.lastHeartbeat
        $rows += [pscustomobject]@{
            id = $s.id; role = $s.role; issue = $s.issue; task = $s.task; host = $s.host
            started = $s.started; lastHeartbeat = $s.lastHeartbeat; ageMin = $age
            stale = ($age -ge $TtlMinutes); open = (-not $s.closed); closedTs = $s.closedTs; note = $s.note
        }
    }
    return @($rows | Sort-Object lastHeartbeat -Descending)
}

function Write-SessionEvent {
    param([string]$Event, [string]$SessionId, [string]$EvIssue, [string]$EvTask, [string]$EvRole, [string]$EvHost)
    Add-LedgerRecord -Path $Ledger -Event @{
        event = $Event; session = $SessionId; role = $EvRole; issue = $EvIssue; task = $EvTask;
        host = $EvHost; note = $Note
    }
}

switch ($Command) {
    'register' {
        if ([string]::IsNullOrWhiteSpace($Issue)) { throw '-Issue is required to bind a session' }
        if ([string]::IsNullOrWhiteSpace($Task)) { throw '-Task is required to bind a session' }
        if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = [Environment]::MachineName }
        $events = Read-LedgerEvents -Path $Ledger
        $k = "$Issue|$Task"
        $info = $null
        if ($events.ContainsKey($k)) { $info = Get-LedgerTaskInfo $events[$k] }
        if ($null -eq $info -or -not $info.Has -or -not ($info.Status -in @('running', 'review'))) {
            throw ("session must bind to an open tracked task: {0} is not running/review. Run 'aos track start -Issue {1} -Task {2} -Subagent <label>' first." -f $k, $Issue, $Task)
        }
        $sessions = @(Get-LedgerSessions -Path $Ledger)
        $sid = $Id
        if ([string]::IsNullOrWhiteSpace($sid)) {
            $sid = 's-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
        }
        if (@($sessions | Where-Object { $_.id -eq $sid -and -not $_.closed }).Count -gt 0) { throw "session already open: $sid" }
        Write-SessionEvent -Event 'session-register' -SessionId $sid -EvIssue $Issue -EvTask $Task -EvRole $Role -EvHost $HostName
        if ($machine) {
            [pscustomobject]@{ ok = $true; event = 'register'; session = $sid; role = $Role; issue = $Issue; task = $Task; host = $HostName; started = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output ("register: session={0} role={1} issue={2} task={3} host={4}" -f $sid, $Role, $Issue, $Task, $HostName)
    }
    'heartbeat' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw '-Id is required' }
        $s = Get-OpenSession $Id
        if ($s.closed) { throw "session already closed: $Id" }
        Write-SessionEvent -Event 'session-heartbeat' -SessionId $s.id -EvIssue $s.issue -EvTask $s.task -EvRole $s.role -EvHost $s.host
        if ($machine) {
            [pscustomobject]@{ ok = $true; event = 'heartbeat'; session = $s.id; issue = $s.issue; task = $s.task; lastHeartbeat = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output ("heartbeat: session={0}" -f $s.id)
    }
    'close' {
        if ([string]::IsNullOrWhiteSpace($Id)) { throw '-Id is required' }
        $s = Get-OpenSession $Id
        if ($s.closed) {
            if ($machine) { [pscustomobject]@{ ok = $true; event = 'close'; session = $s.id; alreadyClosed = $true } | ConvertTo-Json -Depth 4; return }
            Write-Output ("close: session={0} already closed" -f $s.id)
            return
        }
        Write-SessionEvent -Event 'session-close' -SessionId $s.id -EvIssue $s.issue -EvTask $s.task -EvRole $s.role -EvHost $s.host
        if ($machine) {
            [pscustomobject]@{ ok = $true; event = 'close'; session = $s.id; issue = $s.issue; task = $s.task; status = 'closed' } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output ("close: session={0} issue={1} task={2}" -f $s.id, $s.issue, $s.task)
    }
    'list' {
        $rows = @(Get-SessionRows -IncludeClosed:$All)
        if ($machine) {
            [pscustomobject]@{ ok = $true; ledger = $Ledger; count = @($rows).Count; ttlMinutes = $TtlMinutes; items = @($rows) } | ConvertTo-Json -Depth 5
            return
        }
        if (@($rows).Count -eq 0) { Write-Output 'no open sessions'; return }
        $rows | Format-Table id, role, issue, task, host, ageMin, stale, open -AutoSize
    }
}
exit 0
