# tasktrack.ps1 — 子任务跟踪看门狗（AgentOS drivercore）
# 目的：保证 Codex / Claude / DSH 子任务"不会无声消失"：注册 → 心跳 → 失联告警 → 验收销账。
# 原则：不信任任何单一状态文件；存活判定 = 进程存活(pid+启动时间防复用) + 日志新鲜度（双信号）。
# 状态语义：ok / starting（启动宽限期）/ STALLED? / NO-LOG? / LOST（未销账前持续告警）。
# 完成判定：日志出现 DONE / ROUND_DONE / DONE_T<数字>，或 wrapper 退出码为 0 -> watch 自动置 done。
#
# 本文件是 tasktrack 的唯一实现；设计来源：长任务看门狗需求，并与 AgentOS 的 issue/task/host 元数据对齐。
# 默认账本：<homebase>\devops\tasktrack\state；homebase 优先取 AGENTOS_HOME，否则从 drivercore/tasktrack 向上三级推导。
#
# 用法：
#   register  .\tasktrack.ps1 register -Kind codex -Name "review-v1" -Issue <issue> -Task <task> -Command "node xxx task ..."
#   adopt     .\tasktrack.ps1 adopt -ProcessId 1234 -Name "review-v1" -LogFile "<log-path>" -Kind codex -Issue <issue> -Task <task>
#   status    .\tasktrack.ps1 status [-Json]
#   list      .\tasktrack.ps1 list
#   watch     .\tasktrack.ps1 watch  [-Json]     # 巡检：完成信号自动 done；新失联标记 LOST；未销账的 LOST 持续告警；退出码 2=有失联
#                                                # -Json 输出 { autoDone: [...], alerts: [...] }
#   done      .\tasktrack.ps1 done -Id t-... -Note "已验收"

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet("register", "adopt", "status", "list", "watch", "done")]
  [string]$Action = "status",

  [ValidateSet("codex", "claude", "dsh", "bash")]
  [string]$Kind = "bash",

  [string]$Name = "",
  [string]$Command = "",
  [string]$Issue = "",
  [string]$Task = "",
  [Alias('Host')]
  [string]$HostName = "",
  [int]$ProcessId = 0,
  [string]$LogFile = "",
  [string]$ExitFile = "",
  [int]$StaleMinutes = 30,
  [int]$GraceMinutes = 5,
  [string]$Id = "",
  [string]$Note = "",
  [string]$StateDir = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if (-not $StateDir) {
  # 默认账本：<homebase>\devops\tasktrack\state；homebase 优先取 AGENTOS_HOME，否则从 drivercore/tasktrack 向上三级推导
  $homeBase = $env:AGENTOS_HOME
  if (-not $homeBase) {
    $homeBase = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
  }
  $StateDir = Join-Path $homeBase "devops\tasktrack\state"
}
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if (-not $HostName) { $HostName = [Environment]::MachineName }

function Read-Jobs {
  @(Get-ChildItem $StateDir -Filter "t-*.json" -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
}
function Write-Job($job) {
  ($job | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $StateDir "$($job.id).json") -Encoding UTF8
}
function New-JobId { "t-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + (Get-Random -Minimum 1000 -Maximum 9999) }
function Get-ProcStart([int]$procId) {
  if ($procId -le 0) { return $null }
  try { return (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToString("o") } catch { return $null }
}
function Test-Alive($job) {
  if (-not $job.pid -or $job.pid -le 0) { return $false }
  $p = Get-Process -Id $job.pid -ErrorAction SilentlyContinue
  if (-not $p) { return $false }
  # PID 复用防护：比对登记时的进程启动时间（±5s 容差）
  if ($job.procStartTime) {
    try {
      if ([math]::Abs(($p.StartTime - [datetime]$job.procStartTime).TotalSeconds) -gt 5) { return $false }
    } catch { }
  }
  return $true
}
function Get-LogHint([string]$path) {
  if ($path -and (Test-Path -LiteralPath $path)) {
    $info = Get-Item -LiteralPath $path
    return [pscustomobject]@{
      exists        = $true
      lastWrite     = $info.LastWriteTime
      silentMinutes = [math]::Round(((Get-Date) - $info.LastWriteTime).TotalMinutes, 1)
    }
  }
  return [pscustomobject]@{ exists = $false; lastWrite = $null; silentMinutes = $null }
}
function Get-JobAge([string]$startedAt) {
  if (-not $startedAt) { return 9999 }
  try { return [math]::Round(((Get-Date) - [datetime]$startedAt).TotalMinutes, 1) } catch { return 9999 }
}
function Get-ExitCode($job) {
  # wrapper 退出码 sidecar：优先 job.exitFile，其次按 id 推导（兼容旧记录 / 外部 wrapper）
  $file = $job.exitFile
  if (-not $file -and $job.id) { $file = Join-Path $StateDir "$($job.id).exit" }
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $null }
  try {
    $raw = (Get-Content -LiteralPath $file -Raw -ErrorAction Stop).Trim()
    $code = 0
    if ([int]::TryParse($raw, [ref]$code)) { return $code }
  } catch { }
  return $null
}
function Read-LogText([string]$path) {
  try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return $null }
  if (-not $text) { return $text }
  # 无 BOM 的 UTF-16LE 会被按 ANSI 解码成夹 NUL 的乱码；嗅探到 NUL 后按 Unicode 重读
  if ($text.IndexOf([char]0) -ge 0) {
    try {
      $uni = [IO.File]::ReadAllText($path, [Text.Encoding]::Unicode)
      if ($uni.IndexOf([char]0) -lt 0) { return $uni }
    } catch { }
  }
  return $text
}
function Get-LogCompletion([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
  $text = Read-LogText $path
  if (-not $text) { return $null }
  # DONE_T 后必须是数字任务号，且后面不能再接字母数字/下划线（DONE_T<task>_FAILED 不算）
  $marker = '(?<![A-Za-z0-9_])(ROUND_DONE|DONE(?:_T[0-9]+)?)(?![A-Za-z0-9_])'
  foreach ($line in ($text -split "\r?\n")) {
    $m = [regex]::Match($line, $marker)
    if (-not $m.Success) { continue }
    # 否定词必须紧邻标记（NOT [YET] / NEVER / WITHOUT），避免 "no errors, DONE_T1" 误伤
    if ($line.Substring(0, $m.Index) -match '(?i)\b(?:NOT(?:\s+YET)?|NEVER|WITHOUT)\s*$') { continue }
    return $m.Value
  }
  return $null
}
function Get-CompletionSignal($job) {
  $code = Get-ExitCode $job
  if ($null -ne $code -and $code -eq 0) {
    return [pscustomobject]@{ reason = "exit 0"; exitCode = $code; marker = $null }
  }
  $marker = Get-LogCompletion $job.logFile
  if ($marker) {
    return [pscustomobject]@{ reason = "log marker $marker"; exitCode = $code; marker = $marker }
  }
  return $null
}
function Get-LivenessVerdict($job) {
  $alive = Test-Alive $job
  $hint = Get-LogHint $job.logFile
  $age = Get-JobAge $job.startedAt
  if (-not $alive) {
    if ($age -le $GraceMinutes) { return "starting" }
    if ($hint.exists -and $hint.silentMinutes -le 2) { return "starting" }
    return "LOST"
  }
  if (-not $hint.exists) {
    if ($age -le $GraceMinutes) { return "starting" }
    return "NO-LOG?"    # 存活但日志缺失：双信号不满足，需人工核查
  }
  if ($hint.silentMinutes -gt $StaleMinutes) { return "STALLED?" }
  return "ok"
}
function Compute-Verdict($job) {
  if ($job.status -ne "running") { return $job.status }
  if (Get-CompletionSignal $job) { return "DONE" }
  return Get-LivenessVerdict $job
}

switch ($Action) {
  "register" {
    if (-not $Command) { throw "register 需要 -Command" }
    if (-not $Name) { $Name = $Command.Substring(0, [Math]::Min(48, $Command.Length)) }
    $id = New-JobId
    if (-not $LogFile) { $LogFile = Join-Path $StateDir "$id.log" }
    if (-not $ExitFile) { $ExitFile = Join-Path $StateDir "$id.exit" }
    $escapedLog = $LogFile.Replace("'", "''")   # PowerShell 单引号字面量转义（防路径含 ' 破坏语法）
    $escapedExit = $ExitFile.Replace("'", "''")
    # 命令正文写入独立 .ps1（UTF-8 BOM）；子进程用 -File 执行，避免长命令撞 Windows 命令行上限
    $childPath = Join-Path $StateDir "$id.run.ps1"
    $childLines = @(
      '$ErrorActionPreference = ''Stop''',
      '$LASTEXITCODE = $null',
      '$ec = 0',
      'try {',
      '  & { __TASKTRACK_COMMAND__ }',
      '  if ($null -ne $LASTEXITCODE) { $ec = $LASTEXITCODE } elseif (-not $?) { $ec = 1 }',
      '} catch { $ec = 1 }',
      'exit $ec'
    )
    $childText = (($childLines -join "`r`n") + "`r`n").Replace('__TASKTRACK_COMMAND__', $Command)
    [IO.File]::WriteAllText($childPath, $childText, (New-Object System.Text.UTF8Encoding($true)))
    $escapedChild = $childPath.Replace("'", "''")
    # 外层只用短 -EncodedCommand 启动子进程并落退出码 sidecar；watch 以 exit 0 作为完成信号
    $inner = "`$ec = 1; try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '$escapedChild' *> '$escapedLog'; " +
      "if (`$null -ne `$LASTEXITCODE) { `$ec = `$LASTEXITCODE } } catch { `$ec = 1 }; " +
      "Set-Content -LiteralPath '$escapedExit' -Value `$ec -Encoding ASCII"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $proc = Start-Process -FilePath "powershell.exe" `
      -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
      -WindowStyle Hidden -PassThru
    $job = [pscustomobject]@{
      id = $id; kind = $Kind; name = $Name; command = $Command; logFile = $LogFile; exitFile = $ExitFile
      issue = $Issue; task = $Task; host = $HostName
      pid = $proc.Id; procStartTime = (Get-ProcStart $proc.Id)
      startedAt = (Get-Date).ToString("o"); status = "running"; note = "registered"
    }
    Write-Job $job
    Write-Output "registered $id (pid=$($proc.Id)) issue=$Issue task=$Task host=$HostName log=$LogFile"
  }
  "adopt" {
    if ($ProcessId -le 0 -and -not $LogFile) { throw "adopt 至少需要 -ProcessId 或 -LogFile" }
    $id = if ($Id) { $Id } else { New-JobId }
    $job = [pscustomobject]@{
      id = $id; kind = $Kind; name = $Name; command = "(adopted)"; logFile = $LogFile; exitFile = $ExitFile
      issue = $Issue; task = $Task; host = $HostName
      pid = $ProcessId; procStartTime = (Get-ProcStart $ProcessId)
      startedAt = (Get-Date).ToString("o"); status = "running"; note = $Note
    }
    Write-Job $job
    Write-Output "adopted $id (pid=$ProcessId) issue=$Issue task=$Task host=$HostName"
  }
  "list" {
    Read-Jobs | Sort-Object startedAt | ForEach-Object {
      "{0}  {1,-7} {2,-9} {3,-12} {4,-8} {5}" -f $_.id, $_.kind, $_.status, $_.issue, $_.task, $_.name
    }
  }
  "status" {
    $rows = Read-Jobs | Sort-Object startedAt | ForEach-Object {
      $verdict = Compute-Verdict $_
      $hint = Get-LogHint $_.logFile
      [pscustomobject]@{
        id = $_.id; kind = $_.kind; name = $_.name; status = $_.status; verdict = $verdict
        issue = $_.issue; task = $_.task; host = $_.host
        pid = $_.pid; silentMinutes = $hint.silentMinutes; logFile = $_.logFile; note = $_.note
      }
    }
    if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 6 }
    else {
      $rows | ForEach-Object {
        "{0}  {1,-7} {2,-9} {3,-10} silence={4}min  {5} {6}/{7}" -f $_.id, $_.kind, $_.status, $_.verdict, $_.silentMinutes, $_.issue, $_.task, $_.name
      }
    }
  }
  "watch" {
    $alerts = @()
    $completed = @()
    Read-Jobs | Where-Object { $_.status -in @("running", "lost") } | ForEach-Object {
      # 每个任务只读一次日志/sidecar；running 无完成信号时再做存活判定
      $signal = Get-CompletionSignal $_
      if ($signal) {
        # 完成信号优先于存活判定：日志已 DONE / wrapper exit 0 即销账，避免误报 LOST
        $_.status = "done"
        $_.note = "watchdog: 自动完成（$($signal.reason)） @ $(Get-Date -Format o)"
        Write-Job $_
        $completed += [pscustomobject]@{ id = $_.id; kind = $_.kind; name = $_.name; issue = $_.issue; task = $_.task; reason = $signal.reason }
      } elseif ($_.status -eq "running") {
        if ((Get-LivenessVerdict $_) -eq "LOST") {
          $_.status = "lost"
          $_.note = "watchdog: 进程消失/身份不符且无新日志 @ $(Get-Date -Format o)"
          Write-Job $_
          $alerts += $_
        }
      } else {
        # 未销账（done）前持续告警，直到人工处理
        $alerts += $_
      }
    }
    if ($Json) {
      ConvertTo-Json -InputObject ([pscustomobject]@{ autoDone = @($completed); alerts = @($alerts) }) -Depth 6
    }
    else {
      $completed | ForEach-Object { "auto-done: $($_.id) [$($_.kind)] $($_.issue)/$($_.task) $($_.name) ($($_.reason))" }
      if ($alerts.Count -eq 0) { Write-Output "watch: 无失联任务" }
      else { $alerts | ForEach-Object { "ALERT LOST: $($_.id) [$($_.kind)] $($_.issue)/$($_.task) $($_.name) pid=$($_.pid) log=$($_.logFile)" } }
    }
    if ($alerts.Count -gt 0) { exit 2 }
  }
  "done" {
    if (-not $Id) { throw "done 需要 -Id" }
    $job = Read-Jobs | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $job) { throw "找不到任务 $Id" }
    $job.status = "done"
    if ($Note) { $job.note = $Note }
    Write-Job $job
    Write-Output "done $Id"
  }
}
exit 0
