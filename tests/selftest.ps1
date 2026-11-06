<#
.SYNOPSIS
  AgentOS 自检套件：在隔离沙箱里跑通全部命令，断言退出码与 JSON 可解析性。
.DESCRIPTION
  不触碰任何真实仓库。沙箱位于 devops/agentos/selftest/。
  exit 0 = 全部通过；exit 1 = 有失败
#>
[CmdletBinding()]
param(
    [switch]$KeepSandbox
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $root 'bin'
$aos = Join-Path $bin 'aos.ps1'

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path $root -Parent }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sandbox = Join-Path (Join-Path $homeBase 'devops\agentos\selftest') $stamp
$repo = Join-Path $sandbox 'demo-repo'

New-Item -ItemType Directory -Force -Path $repo | Out-Null
& git -C $repo init -q 2>&1 | Out-Null
& git -C $repo config user.name 'agentos-selftest' 2>&1 | Out-Null
& git -C $repo config user.email 'selftest@localhost' 2>&1 | Out-Null
'# sandbox' | Set-Content -LiteralPath (Join-Path $repo 'README.md') -Encoding UTF8
& git -C $repo add -A 2>&1 | Out-Null
& git -C $repo commit -qm 'init' 2>&1 | Out-Null
& git -C $repo branch -M master 2>&1 | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Run,
        [int]$ExpectExit = 0,
        [switch]$ExpectJson,
        [switch]$AllowAttention,
        [switch]$ExpectThrow
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = ''
    $code = 0
    $err = ''
    $threw = $false
    try {
        $out = (& $Run 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch {
        $err = $_.Exception.Message
        $code = 99
        $threw = $true
    }
    $sw.Stop()
    $jsonOk = $true
    if ($ExpectJson -and -not $err) {
        try { $null = ($out | ConvertFrom-Json) } catch { $jsonOk = $false }
    }
    $exitOk = ($code -eq $ExpectExit) -or ($AllowAttention -and $code -eq 2)
    if ($ExpectThrow) { $pass = $threw }
    else { $pass = $exitOk -and $jsonOk -and -not $err }
    $results.Add([pscustomobject]@{
            Case   = $Name
            Exit   = $code
            Want   = $ExpectExit
            Json   = $(if ($ExpectJson) { if ($jsonOk) { 'ok' } else { 'BAD' } } else { '-' })
            Ms     = $sw.ElapsedMilliseconds
            Status = $(if ($pass) { 'PASS' } else { 'FAIL' })
            Detail = $err
        })
    return $out
}

$planFile = Join-Path $repo '.agentos\plans\PLAN-900.md'

# --- plan ---
Test-Case 'plan new (JSON)' { & $aos plan new -Issue 900 -Title 'selftest' -Repo $repo } -ExpectJson | Out-Null
Test-Case 'plan validate (JSON)' { & $aos plan validate -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan graph (JSON)' { & $aos plan graph -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan next (JSON)' { & $aos plan next -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan show (JSON)' { & $aos plan show -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan state (JSON)' { & $aos plan state -Plan $planFile -Task T1 -Status running -Owner selftest } -ExpectJson | Out-Null
Test-Case 'plan validate (Human)' { & $aos plan validate -Plan $planFile -Human } | Out-Null
Test-Case 'plan graph (Human)' { & $aos plan graph -Plan $planFile -Human } | Out-Null

# --- issue ---
Test-Case 'issue detect (JSON)' { & $aos issue detect -Repo $repo } -ExpectJson | Out-Null
Test-Case 'issue new local (JSON)' { & $aos issue new -Id 900 -Title 'selftest issue' -Repo $repo } -ExpectJson | Out-Null
Test-Case 'issue show local (JSON)' { & $aos issue show -Id 900 -Repo $repo } -ExpectJson | Out-Null
Test-Case 'issue list local (JSON)' { & $aos issue list -Repo $repo } -ExpectJson | Out-Null
Test-Case 'issue detect (Human)' { & $aos issue detect -Repo $repo -Human } | Out-Null

# --- wt ---
Test-Case 'wt status (JSON)' { & $aos wt status -Repo $repo } -ExpectJson | Out-Null
Test-Case 'wt list (JSON)' { & $aos wt list -Repo $repo } -ExpectJson | Out-Null
Test-Case 'wt prune dryrun (JSON)' { & $aos wt prune -Repo $repo } -ExpectJson | Out-Null
Test-Case 'wt status (Human)' { & $aos wt status -Repo $repo -Human } | Out-Null

# --- track ---
$sandboxLedger = Join-Path $sandbox 'ledger.jsonl'
Test-Case 'track start (JSON)' { & $aos track start -Issue 900 -Task T1 -Owner selftest -Plan $planFile -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track review (JSON)' { & $aos track review -Issue 900 -Task T1 -Plan $planFile -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track close (JSON)' { & $aos track close -Issue 900 -Task T1 -Plan $planFile -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track start T2 (for handover)' { & $aos track start -Issue 900 -Task T2 -Owner claude -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track who (JSON)' { & $aos track who -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track handoff claude->codex (JSON)' { & $aos track handoff -Issue 900 -Task T2 -From claude -Owner codex -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track release codex (JSON)' { & $aos track release -Issue 900 -Task T2 -Owner codex -Note 'selftest' -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track claim dsh (JSON)' { & $aos track claim -Issue 900 -Task T2 -Owner dsh -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track close T2 (JSON)' { & $aos track close -Issue 900 -Task T2 -Owner dsh -Ledger $sandboxLedger } -ExpectJson | Out-Null

Test-Case 'track list (JSON)' { & $aos track list -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track lost (JSON)' { & $aos track lost -Ledger $sandboxLedger } -ExpectJson | Out-Null

# --- gc ---
Test-Case 'gc dryrun (JSON)' { & $bin\gc.ps1 -Ledger $sandboxLedger -Human:$false } -AllowAttention -ExpectJson | Out-Null

Test-Case 'track start fixture for isolation' { & $aos track start -Issue 900 -Task T3 -Owner claude -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track claim without auth must fail' { & $aos track claim -Issue 900 -Task T3 -Owner intruder -Force -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track claim with auth succeeds' { & $aos track claim -Issue 900 -Task T3 -Owner intruder -Force -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track close T3' { & $aos track close -Issue 900 -Task T3 -Owner intruder -Ledger $sandboxLedger } -ExpectJson | Out-Null

# --- room ---
Test-Case 'room list (JSON)' { & $bin\room.ps1 -Command list } -ExpectJson | Out-Null
Test-Case 'room list (Human)' { & $bin\room.ps1 -Command list -Human } | Out-Null

# --- hygiene ---
Test-Case 'hygiene (JSON)' { & $bin\hygiene.ps1 } -AllowAttention -ExpectJson | Out-Null
Test-Case 'hygiene (Human)' { & $bin\hygiene.ps1 -Human } -AllowAttention | Out-Null

# --- projects ---
Test-Case 'projects overview (JSON)' { & $aos projects } -AllowAttention -ExpectJson | Out-Null
Test-Case 'projects overview (Human)' { & $aos projects -Human } -AllowAttention | Out-Null

# --- snapshot / doctor ---
$snapOut = Test-Case 'snapshot (JSON)' { & $bin\snapshot.ps1 -Repo $repo -Plan $planFile } -ExpectJson -AllowAttention
Test-Case 'snapshot (Human)' { & $bin\snapshot.ps1 -Repo $repo -Human } -AllowAttention | Out-Null
Test-Case 'doctor' { & $aos doctor } -AllowAttention -ExpectJson | Out-Null
Test-Case 'version' { & $aos version } | Out-Null

# --- 断言 snapshot 关键字段 ---
$snapCheck = 'FAIL'
try {
    $s = ($snapOut | Out-String) | ConvertFrom-Json
    if ($s.ok -eq $true -and $s.repo.issueSource -eq 'local' -and $null -ne $s.worktrees -and $null -ne $s.schedule) { $snapCheck = 'PASS' }
} catch { $snapCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'snapshot fields (issueSource/worktrees/schedule)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $snapCheck; Detail = '' })

Write-Output ''
$results | Format-Table Case, Status, Exit, Want, Json, Ms, Detail -AutoSize

$fail = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($fail.Count -gt 0) {
    Write-Output ''
    Write-Output '--- failure detail ---'
    foreach ($f in $fail) {
        Write-Output ("[" + $f.Case + "] exit=" + $f.Exit + " want=" + $f.Want + " json=" + $f.Json)
        if ($f.Detail) { Write-Output ("   " + $f.Detail) }
    }
}
Write-Output ''
Write-Output ("TOTAL {0}  PASS {1}  FAIL {2}" -f $results.Count, ($results.Count - $fail.Count), $fail.Count)

if (-not $KeepSandbox) {
    & git -C $repo worktree prune 2>&1 | Out-Null
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'sandbox removed'
} else {
    Write-Output ("sandbox kept: " + $sandbox)
}

if ($fail.Count -gt 0) { exit 1 }
exit 0
