<#
.SYNOPSIS
  Harness 进程卫生：发现并回收僵尸助手进程，报告机器资源压力。
.DESCRIPTION
  harness 每个会话会拉起 helper（状态栏 / MCP / 语言服务），退出时未必回收。
  长期堆积会吃掉数 GB 内存，拖慢所有 agent 的调度。

  判定：同一命令行签名的进程数超过 -MaxCount 即视为泄漏。
  默认只读；-Reap 才终止，且只终止「命中安全签名 + 超过 -MinAgeHours」的进程。
  退出码：0 正常 / 2 有泄漏待处理。
#>
[CmdletBinding()]
param(
    [int]$MaxCount = 20,
    [int]$StaleHours = 24,
    [int]$MinAgeHours = 1,
    [string[]]$SafePatterns = @('ccstatusline'),
    [switch]$Reap,
    [switch]$Human
)
$ErrorActionPreference = 'Continue'
$machine = -not $Human

function Get-Sig {
    param([string]$Cmd)
    if ([string]::IsNullOrWhiteSpace($Cmd)) { return '(unknown)' }
    $m = [regex]::Match($Cmd, '([^\\/"]+\.(js|mjs|cjs))')
    if ($m.Success) { return $m.Groups[1].Value }
    $m2 = [regex]::Match($Cmd, '([^\\/"]+\.exe)')
    if ($m2.Success) { return $m2.Groups[1].Value }
    return $Cmd.Substring(0, [Math]::Min(60, $Cmd.Length))
}

$targets = @()
if ($env:OS -eq 'Windows_NT') {
    # --- Windows：原逻辑（WMI/CIM）逐字节保留 ---
    $rawProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    foreach ($rp in $rawProcs) {
        if ($rp.Name -ne 'node.exe' -and $rp.Name -ne 'python.exe') { continue }
        $targets += [pscustomobject]@{
            Pid = [int]$rp.ProcessId
            Sig = (Get-Sig ([string]$rp.CommandLine))
        }
    }
} else {
    # --- Linux / macOS：用 ps 枚举 node / python 进程 ---
    $psOut = @(& ps -eo pid=,comm=,args= 2>$null)
    foreach ($line in $psOut) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '^\s*(?<pid>\d+)\s+(?<comm>\S+)\s*(?<args>.*)$')
        if (-not $m.Success) { continue }
        $comm = $m.Groups['comm'].Value
        $base = [IO.Path]::GetFileName($comm)
        if ($base -ne 'node' -and $base -ne 'python' -and $base -ne 'python3') { continue }
        $targets += [pscustomobject]@{
            Pid = [int]$m.Groups['pid'].Value
            Sig = (Get-Sig ([string]$m.Groups['args'].Value))
        }
    }
}

$live = @{}
foreach ($gp in (Get-Process -ErrorAction SilentlyContinue)) { $live[[int]$gp.Id] = $gp }

$now = Get-Date
$grouped = @()
foreach ($g in ($targets | Group-Object Sig)) {
    $rows = @()
    foreach ($x in $g.Group) {
        $pr = $live[$x.Pid]
        if ($null -eq $pr) { continue }
        $ageH = -1
        try { $ageH = [math]::Round(($now - $pr.StartTime).TotalHours, 1) } catch { $ageH = -1 }
        $rows += [pscustomobject]@{
            pid = $x.Pid
            age = $ageH
            mb  = [math]::Round($pr.WorkingSet64 / 1MB, 0)
        }
    }
    if ($rows.Count -eq 0) { continue }
    $memSum = ($rows | Measure-Object -Property mb -Sum).Sum
    if ($null -eq $memSum) { $memSum = 0 }
    $maxAge = ($rows | Measure-Object -Property age -Maximum).Maximum
    if ($null -eq $maxAge) { $maxAge = 0 }
    $grouped += [pscustomobject]@{
        signature = [string]$g.Name
        count     = $rows.Count
        mem_mb    = [int]$memSum
        max_age_h = [double]$maxAge
        leaked    = ($rows.Count -gt $MaxCount)
        rows      = $rows
    }
}

$leakedGroups = @($grouped | Where-Object { $_.leaked })
$leakMem = 0
if ($leakedGroups.Count -gt 0) { $leakMem = [int](($leakedGroups | Measure-Object -Property mem_mb -Sum).Sum) }

$cpuPct = 0
$memUsedGb = 0; $memTotalGb = 0
if ($env:OS -eq 'Windows_NT') {
    # --- Windows：原逻辑（CIM）逐字节保留 ---
    try {
        $c = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        if ($c) { $cpuPct = [int](($c | Measure-Object -Property LoadPercentage -Average).Average) }
    } catch { $cpuPct = 0 }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $memTotalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $memUsedGb = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
        }
    } catch { }
} else {
    # --- Linux / macOS：从 /proc 或 ps/vm_stat 读取，读不到则保持 0（仅感知，不阻断）---
    try {
        $load = @(& cat /proc/loadavg 2>$null)
        if ($load -and $load[0]) {
            $oneMin = [double](($load[0] -split '\s+')[0])
            $ncpu = [int](@(& nproc 2>$null)[0])
            if ($ncpu -gt 0) { $cpuPct = [int][math]::Min(100, [math]::Round(($oneMin / $ncpu) * 100)) }
        }
    } catch { }
    try {
        $meminfo = @(& cat /proc/meminfo 2>$null)
        $totalKb = 0; $availKb = 0
        foreach ($ln in $meminfo) {
            if ($ln -match '^MemTotal:\s+(\d+)') { $totalKb = [double]$Matches[1] }
            elseif ($ln -match '^MemAvailable:\s+(\d+)') { $availKb = [double]$Matches[1] }
        }
        if ($totalKb -gt 0) {
            $memTotalGb = [math]::Round($totalKb / 1MB, 1)
            $memUsedGb = [math]::Round(($totalKb - $availKb) / 1MB, 1)
        }
    } catch { }
}

$reaped = @()
if ($Reap -and $leakedGroups.Count -gt 0) {
    foreach ($lg in $leakedGroups) {
        $isSafe = $false
        foreach ($pat in $SafePatterns) {
            if ($lg.signature -like ('*' + $pat + '*')) { $isSafe = $true; break }
        }
        if (-not $isSafe) { continue }
        foreach ($r in $lg.rows) {
            if ($r.age -lt $MinAgeHours) { continue }
            $pr = $live[$r.pid]
            if ($null -eq $pr) { continue }
            try { Stop-Process -Id $r.pid -Force -ErrorAction Stop; $reaped += $r.pid } catch { }
        }
    }
}

$out = [pscustomobject]@{
    ok          = ($leakedGroups.Count -eq 0)
    dryRun      = (-not $Reap)
    thresholds  = [pscustomobject]@{ maxCount = $MaxCount; staleHours = $StaleHours; minAgeHours = $MinAgeHours }
    machine     = [pscustomobject]@{ cpu_percent = $cpuPct; mem_used_gb = $memUsedGb; mem_total_gb = $memTotalGb }
    scanned     = $targets.Count
    leaked      = $leakedGroups.Count
    leaked_mem_mb = $leakMem
    reaped      = @($reaped)
    groups      = @($grouped | Sort-Object -Property mem_mb -Descending | ForEach-Object {
        [pscustomobject]@{ signature = $_.signature; count = $_.count; mem_mb = $_.mem_mb; max_age_h = $_.max_age_h; leaked = $_.leaked }
    })
    attention   = @($leakedGroups | ForEach-Object { ('{0}: {1} 个 / {2} MB / 最老 {3} 小时' -f $_.signature, $_.count, $_.mem_mb, $_.max_age_h) })
}

if ($machine) {
    $out | ConvertTo-Json -Depth 6
} else {
    Write-Output ('machine   : CPU {0}%   RAM {1}/{2} GB' -f $cpuPct, $memUsedGb, $memTotalGb)
    Write-Output ('scanned   : {0} 个 node/python 进程' -f $targets.Count)
    Write-Output ('leaked    : {0} 组 / {1} MB' -f $leakedGroups.Count, $leakMem)
    if ($leakedGroups.Count -gt 0) {
        $leakedGroups | Sort-Object -Property mem_mb -Descending | ForEach-Object {
            Write-Output ('  {0,-40} {1,4} 个  {2,6} MB  最老 {3} 小时' -f $_.signature, $_.count, $_.mem_mb, $_.max_age_h)
        }
    }
    if ($reaped.Count -gt 0) { Write-Output ('reaped    : {0} 个进程' -f $reaped.Count) }
}

if ($leakedGroups.Count -gt 0) { exit 2 }
exit 0
