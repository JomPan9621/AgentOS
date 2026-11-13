# tasktrack completion detection tests (Windows PowerShell 5.1)
# Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\tasktrack\tests\tasktrack.tests.ps1
# Coverage:
#   - log marker DONE / ROUND_DONE / DONE_T<digits>   -> auto done (no LOST)
#   - wrapper exit 0 (register sidecar)               -> auto done
#   - wrapper exit != 0 / no marker                   -> still LOST
#   - PowerShell-level exit 7 / throw real exit codes -> still LOST
#   - negated markers and DONE_TIMEOUT/DONE_T*_FAILED -> still LOST
#   - negation words away from marker                 -> still auto done
#   - non-terminating PowerShell errors               -> nonzero sidecar, LOST
#   - 5K/10K long commands via child .ps1 + -File     -> registrable, auto done
#   - no-BOM UTF-16LE log                             -> detected
#   - already done jobs are never overwritten by watch
#   - watch -Json carries autoDone and alerts
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:tasktrack = (Resolve-Path (Join-Path (Split-Path $PSScriptRoot -Parent) "tasktrack.ps1")).Path
$script:root = Join-Path ([IO.Path]::GetTempPath()) ("agentos-tasktrack-tests-" + [guid]::NewGuid().ToString("N"))
$script:passed = 0
$script:failed = 0

function Assert-True {
  param([string]$Name, [bool]$Condition, [string]$Detail = "")
  if ($Condition) {
    $script:passed++
    Write-Host "[PASS] $Name"
  } else {
    $script:failed++
    Write-Host "[FAIL] $Name :: $Detail" -ForegroundColor Red
  }
}

function New-TestStateDir {
  param([string]$Name)
  $dir = Join-Path $script:root $Name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function New-TestJob {
  param(
    [string]$StateDir,
    [string]$Id,
    [string]$Status = "running",
    [int]$JobPid = 0,
    [string]$LogFile = "",
    [string]$ExitFile = "",
    [string]$Note = "test fixture"
  )
  $job = [ordered]@{
    id = $Id; kind = "bash"; name = $Id; command = "(test)"
    logFile = $LogFile; exitFile = $ExitFile
    pid = $JobPid; procStartTime = $null
    startedAt = (Get-Date).AddMinutes(-60).ToString("o")
    status = $Status; note = $Note
  }
  $job | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $StateDir "$Id.json") -Encoding UTF8
}

function New-OldLog {
  param([string]$Path, [string[]]$Lines, [string]$Encoding = "UTF8")
  Set-Content -LiteralPath $Path -Value $Lines -Encoding $Encoding
  (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddMinutes(-10)
}

function New-OldLogUtf16NoBom {
  param([string]$Path, [string[]]$Lines)
  [IO.File]::WriteAllBytes($Path, [Text.Encoding]::Unicode.GetBytes(($Lines -join "`r`n")))
  (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddMinutes(-10)
}

function Get-TestJob {
  param([string]$StateDir, [string]$Id)
  return (Get-Content -LiteralPath (Join-Path $StateDir "$Id.json") -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Set-JobAged {
  param([string]$StateDir, [string]$Id)
  $j = Get-TestJob $StateDir $Id
  $j.startedAt = (Get-Date).AddMinutes(-60).ToString("o")
  $j | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $StateDir "$Id.json") -Encoding UTF8
  if ($j.logFile -and (Test-Path -LiteralPath $j.logFile)) {
    (Get-Item -LiteralPath $j.logFile).LastWriteTime = (Get-Date).AddMinutes(-10)
  }
  return $j
}

function Invoke-Watch {
  param([string]$StateDir)
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tasktrack watch -StateDir $StateDir -Json 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
  } finally { $ErrorActionPreference = $old }
}

function Invoke-Tasktrack {
  param([string[]]$Arguments)
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:tasktrack @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
  } finally { $ErrorActionPreference = $old }
}

function Wait-ExitFile {
  param([string]$Path, [int]$TimeoutSec = 20)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $Path) {
      try {
        $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
        $code = 0
        if ([int]::TryParse($raw, [ref]$code)) { return $code }
      } catch { }
    }
    Start-Sleep -Milliseconds 200
  }
  return $null
}

function Wait-ProcessGone {
  param([int]$ProcId, [int]$TimeoutSec = 10)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return $false
}

function Get-RegisteredId {
  param([string]$Output)
  if ($Output -match 'registered\s+(t-\S+)') { return $Matches[1] }
  return $null
}

Write-Host "tasktrack completion tests"
Write-Host "  script: $script:tasktrack"
Write-Host "  temp:   $script:root"

try {
  Assert-True "test root is under the system temp path" ($script:root.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) "root=$($script:root) temp=$([IO.Path]::GetTempPath())"

  # ---------- 1. log marker: DONE ----------
  $d = New-TestStateDir "done-marker"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("step 1", "step 2", "DONE")
  New-TestJob -StateDir $d -Id "t-1001" -LogFile $log
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1001"
  Assert-True "DONE marker -> status done" ($j.status -eq "done") "status=$($j.status) watchExit=$($w.ExitCode) out=$($w.Output)"
  Assert-True "DONE marker -> watch exit 0 (no LOST alert)" ($w.ExitCode -eq 0) "watchExit=$($w.ExitCode) out=$($w.Output)"
  Assert-True "DONE marker -> note records reason" ($j.note -match "DONE") "note=$($j.note)"

  # idempotency: second watch must not rewrite the auto-done note
  $noteBefore = $j.note
  $null = Invoke-Watch $d
  $j2 = Get-TestJob $d "t-1001"
  Assert-True "auto-done job not overwritten on later watch" ($j2.status -eq "done" -and $j2.note -eq $noteBefore) "status=$($j2.status)"

  # ---------- 2. log marker: ROUND_DONE ----------
  $d = New-TestStateDir "round-done"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("round 1 ok", "round 2 ok", "ROUND_DONE round=2")
  New-TestJob -StateDir $d -Id "t-1002" -LogFile $log
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1002"
  Assert-True "ROUND_DONE marker -> status done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  Assert-True "ROUND_DONE marker -> watch exit 0" ($w.ExitCode -eq 0) "watchExit=$($w.ExitCode)"

  # ---------- 3. log marker: DONE_T* (UTF-16LE log, same as register redirect) ----------
  $d = New-TestStateDir "done-t"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("worker rc 0", "DONE_T1 2026-01-01T00:00:00+00:00 results=<path>") -Encoding "Unicode"
  New-TestJob -StateDir $d -Id "t-1003" -LogFile $log
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1003"
  Assert-True "DONE_T* marker in UTF-16 log -> status done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"

  # ---------- 3b. no-BOM UTF-16LE log ----------
  $d = New-TestStateDir "utf16-nobom"
  $log = Join-Path $d "job.log"
  New-OldLogUtf16NoBom $log @("worker rc 0", "DONE_T1 no-bom")
  New-TestJob -StateDir $d -Id "t-1009" -LogFile $log
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1009"
  Assert-True "DONE_T* in UTF-16LE without BOM -> status done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"

  # ---------- 4. wrapper exit code 0 (sidecar) ----------
  $d = New-TestStateDir "exit-0"
  $log = Join-Path $d "job.log"
  $exitFile = Join-Path $d "t-1004.exit"
  New-OldLog $log @("no marker in this log")
  Set-Content -LiteralPath $exitFile -Value "0" -Encoding ASCII
  New-TestJob -StateDir $d -Id "t-1004" -LogFile $log -ExitFile $exitFile
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1004"
  Assert-True "exit 0 -> status done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  Assert-True "exit 0 -> note records exit code" ($j.note -match "exit 0") "note=$($j.note)"

  # ---------- 5. abnormal exit / no marker -> LOST ----------
  $d = New-TestStateDir "exit-7"
  $log = Join-Path $d "job.log"
  $exitFile = Join-Path $d "t-1005.exit"
  New-OldLog $log @("started", "working")
  Set-Content -LiteralPath $exitFile -Value "7" -Encoding ASCII
  New-TestJob -StateDir $d -Id "t-1005" -LogFile $log -ExitFile $exitFile
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1005"
  Assert-True "exit 7 + no marker -> status LOST" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"
  Assert-True "exit 7 + no marker -> watch exit 2" ($w.ExitCode -eq 2) "watchExit=$($w.ExitCode)"

  # no exit file + negated marker -> LOST
  $d = New-TestStateDir "no-marker"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("started", "NOT DONE yet")
  New-TestJob -StateDir $d -Id "t-1006" -LogFile $log
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1006"
  Assert-True "no DONE (NOT DONE) -> status LOST" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"

  # ---------- 5b. negation variants and over-wide DONE_T* -> LOST ----------
  $d = New-TestStateDir "marker-negatives"
  $cases = @(
    @{ id = "t-1101"; line = "NOT  DONE" },
    @{ id = "t-1102"; line = "Not DONE" },
    @{ id = "t-1103"; line = "NOT YET DONE" },
    @{ id = "t-1104"; line = "DONE_TIMEOUT" },
    @{ id = "t-1105"; line = "DONE_T1_FAILED" }
  )
  foreach ($c in $cases) {
    $log = Join-Path $d "$($c.id).log"
    New-OldLog $log @("started", $c.line)
    New-TestJob -StateDir $d -Id $c.id -LogFile $log
  }
  $w = Invoke-Watch $d
  $lostCount = 0
  foreach ($c in $cases) {
    if ((Get-TestJob $d $c.id).status -eq "lost") { $lostCount++ }
  }
  Assert-True "negated/over-wide markers -> all LOST" ($lostCount -eq $cases.Count) "lost=$lostCount/$($cases.Count) out=$($w.Output)"
  Assert-True "negated/over-wide markers -> watch exit 2" ($w.ExitCode -eq 2) "watchExit=$($w.ExitCode)"

  # ---------- 5c. negation words away from marker must NOT block completion ----------
  $d = New-TestStateDir "negation-positives"
  $log = Join-Path $d "t-1106.log"
  New-OldLog $log @("no errors, DONE_T1")
  New-TestJob -StateDir $d -Id "t-1106" -LogFile $log
  $log = Join-Path $d "t-1107.log"
  New-OldLog $log @("No failures; DONE_T1")
  New-TestJob -StateDir $d -Id "t-1107" -LogFile $log
  $w = Invoke-Watch $d
  $j1 = Get-TestJob $d "t-1106"
  $j2 = Get-TestJob $d "t-1107"
  Assert-True "negation away from marker -> done (no errors, DONE_T1)" ($j1.status -eq "done") "status=$($j1.status) out=$($w.Output)"
  Assert-True "negation away from marker -> done (No failures; DONE_T1)" ($j2.status -eq "done") "status=$($j2.status) out=$($w.Output)"
  Assert-True "negation-away positives -> watch exit 0" ($w.ExitCode -eq 0) "watchExit=$($w.ExitCode)"

  # ---------- 6. already done job is untouched ----------
  $d = New-TestStateDir "already-done"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("DONE_T1")
  New-TestJob -StateDir $d -Id "t-1007" -Status "done" -LogFile $log -Note "manual: accepted"
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1007"
  Assert-True "already done -> status/note untouched" ($j.status -eq "done" -and $j.note -eq "manual: accepted") "status=$($j.status) note=$($j.note)"
  Assert-True "already done -> watch exit 0" ($w.ExitCode -eq 0) "watchExit=$($w.ExitCode)"

  # ---------- 6b. previously misreported LOST + DONE marker -> recovered to done ----------
  $d = New-TestStateDir "lost-recovery"
  $log = Join-Path $d "job.log"
  New-OldLog $log @("DONE_T2 2026-01-01T00:00:00+00:00")
  New-TestJob -StateDir $d -Id "t-1008" -Status "lost" -LogFile $log -Note "watchdog: old false alarm"
  $w = Invoke-Watch $d
  $j = Get-TestJob $d "t-1008"
  Assert-True "lost record with DONE -> recovered to done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  Assert-True "lost record with DONE -> no alert (watch exit 0)" ($w.ExitCode -eq 0) "watchExit=$($w.ExitCode)"

  # ---------- 6c. watch -Json carries autoDone + alerts ----------
  $d = New-TestStateDir "json-shape"
  $log = Join-Path $d "done.log"
  New-OldLog $log @("DONE")
  New-TestJob -StateDir $d -Id "t-1201" -LogFile $log
  $log2 = Join-Path $d "lost.log"
  New-OldLog $log2 @("still running")
  New-TestJob -StateDir $d -Id "t-1202" -LogFile $log2
  $w = Invoke-Watch $d
  $obj = $w.Output | ConvertFrom-Json
  $autoIds = @($obj.autoDone | ForEach-Object { $_.id })
  $alertIds = @($obj.alerts | ForEach-Object { $_.id })
  Assert-True "watch -Json autoDone contains auto-completed id" ($autoIds -contains "t-1201") "autoDone=$($autoIds -join ',') out=$($w.Output)"
  Assert-True "watch -Json alerts contains LOST id" ($alertIds -contains "t-1202") "alerts=$($alertIds -join ',') out=$($w.Output)"
  Assert-True "watch -Json exits 2 when alerts exist" ($w.ExitCode -eq 2) "watchExit=$($w.ExitCode)"

  # ---------- 7. register wrapper exit 0 end-to-end ----------
  $d = New-TestStateDir "register-exit-0"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "wrapper-exit0", "-Command", "cmd /c exit 0")
  $id = Get-RegisteredId $r.Output
  Assert-True "register exit-0 wrapper launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "register wrapper writes exit code 0 sidecar" ($code -eq 0) "sidecar=$code"
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "register wrapper exit 0 -> auto done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 8. register wrapper abnormal exit end-to-end -> LOST ----------
  $d = New-TestStateDir "register-exit-7"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "wrapper-exit7", "-Command", "cmd /c exit 7")
  $id = Get-RegisteredId $r.Output
  Assert-True "register exit-7 wrapper launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "register wrapper writes nonzero exit sidecar" ($code -eq 7) "sidecar=$code"
    $j = Get-TestJob $d $id
    $null = Wait-ProcessGone -ProcId ([int]$j.pid)
    # age the job past the grace window so watch reaches LOST deterministically
    $null = Set-JobAged $d $id
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "register wrapper exit 7 + no DONE -> LOST (not done)" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 9. PowerShell-level exit 0 -> done ----------
  $d = New-TestStateDir "register-ps-exit-0"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "ps-exit0", "-Command", "exit 0")
  $id = Get-RegisteredId $r.Output
  Assert-True "register PowerShell exit 0 launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "PowerShell exit 0 -> sidecar 0" ($code -eq 0) "sidecar=$code"
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "PowerShell exit 0 -> auto done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 10. PowerShell-level exit 7 must NOT become done ----------
  $d = New-TestStateDir "register-ps-exit-7"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "ps-exit7", "-Command", "exit 7")
  $id = Get-RegisteredId $r.Output
  Assert-True "register PowerShell exit 7 launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "PowerShell exit 7 -> sidecar 7 (not 0)" ($code -eq 7) "sidecar=$code"
    $j = Get-TestJob $d $id
    $null = Wait-ProcessGone -ProcId ([int]$j.pid)
    $null = Set-JobAged $d $id
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "PowerShell exit 7 -> LOST (not done)" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 11. native exit 0 followed by throw must NOT become done ----------
  $d = New-TestStateDir "register-throw"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "throw-after-0", "-Command", "cmd /c exit 0; throw 'boom'")
  $id = Get-RegisteredId $r.Output
  Assert-True "register throw wrapper launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "cmd exit 0 + throw -> nonzero sidecar" ($null -ne $code -and $code -ne 0) "sidecar=$code"
    $j = Get-TestJob $d $id
    $null = Wait-ProcessGone -ProcId ([int]$j.pid)
    $null = Set-JobAged $d $id
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "cmd exit 0 + throw -> LOST (not done)" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 12. non-terminating PowerShell error must NOT become done ----------
  $d = New-TestStateDir "register-getitem-error"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "getitem-error", "-Command", "Get-Item C:\nope")
  $id = Get-RegisteredId $r.Output
  Assert-True "register Get-Item error launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "Get-Item error -> nonzero sidecar" ($null -ne $code -and $code -ne 0) "sidecar=$code"
    $j = Get-TestJob $d $id
    $null = Wait-ProcessGone -ProcId ([int]$j.pid)
    $null = Set-JobAged $d $id
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "Get-Item error -> LOST (not done)" ($j.status -eq "lost") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 13. native exit 0 then non-terminating error must NOT become done ----------
  $d = New-TestStateDir "register-cmd-getitem-error"
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "cmd-getitem-error", "-Command", "cmd /c exit 0; Get-Item C:\nope")
  $id = Get-RegisteredId $r.Output
  Assert-True "register cmd+Get-Item error launched" ($r.ExitCode -eq 0 -and $id) "exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "cmd exit 0 + Get-Item error -> nonzero sidecar" ($null -ne $code -and $code -ne 0) "sidecar=$code"
    $j = Get-TestJob $d $id
    $null = Wait-ProcessGone -ProcId ([int]$j.pid)
    $null = Set-JobAged $d $id
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "cmd exit 0 + Get-Item error -> LOST (not done)" ($j.status -eq "lost") "status=$($j.Status) out=$($w.Output)"
  }

  # ---------- 14. 5K long command via child .ps1 + -File ----------
  $d = New-TestStateDir "register-long-5k"
  $pad5k = ('a' * 5000) -join ''
  $cmd5k = '$pad = ''' + $pad5k + '''; exit 0'
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "long-5k", "-Command", $cmd5k)
  $id = Get-RegisteredId $r.Output
  Assert-True "5K command registered" ($r.ExitCode -eq 0 -and $id) "cmdLen=$($cmd5k.Length) exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "5K command -> sidecar 0" ($code -eq 0) "sidecar=$code"
    $child = Join-Path $d "$id.run.ps1"
    $childLen = if (Test-Path -LiteralPath $child) { (Get-Item -LiteralPath $child).Length } else { 0 }
    Assert-True "5K command child .ps1 written" ($childLen -gt 5000) "childLen=$childLen"
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "5K command -> auto done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  }

  # ---------- 15. 10K long command via child .ps1 + -File ----------
  $d = New-TestStateDir "register-long-10k"
  $pad10k = ('a' * 10000) -join ''
  $cmd10k = '$pad = ''' + $pad10k + '''; exit 0'
  $r = Invoke-Tasktrack @("register", "-StateDir", $d, "-Kind", "bash", "-Name", "long-10k", "-Command", $cmd10k)
  $id = Get-RegisteredId $r.Output
  Assert-True "10K command registered" ($r.ExitCode -eq 0 -and $id) "cmdLen=$($cmd10k.Length) exit=$($r.ExitCode) out=$($r.Output)"
  if ($id) {
    $code = Wait-ExitFile (Join-Path $d "$id.exit")
    Assert-True "10K command -> sidecar 0" ($code -eq 0) "sidecar=$code"
    $child = Join-Path $d "$id.run.ps1"
    $childLen = if (Test-Path -LiteralPath $child) { (Get-Item -LiteralPath $child).Length } else { 0 }
    Assert-True "10K command child .ps1 written" ($childLen -gt 10000) "childLen=$childLen"
    $w = Invoke-Watch $d
    $j = Get-TestJob $d $id
    Assert-True "10K command -> auto done" ($j.status -eq "done") "status=$($j.status) out=$($w.Output)"
  }
} finally {
  Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "PASS=$($script:passed) FAIL=$($script:failed)"
if ($script:failed -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED"
exit 0
