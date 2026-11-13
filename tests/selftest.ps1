<#
.SYNOPSIS
  AgentOS 自检套件：在隔离沙箱里跑通全部命令，断言退出码与 JSON 可解析性。
.DESCRIPTION
  不触碰任何真实仓库。沙箱位于 <homebase>/devops/agentos/selftest/（运行时可指向 %TEMP%）。
  policy 签名测试只用 sandbox 内自签名 PFX（不写证书库、不写用户目录）。
  no-Reap 测试在 sandbox 的 bin 副本上执行，不修改生产脚本、不使用生产测试 seam。
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
$sandboxLedger = Join-Path $sandbox 'ledger.jsonl'
$auditLedger = Join-Path $sandbox 'audit-ledger.jsonl'
# 全程隔离：子脚本默认 ledger / policy 文件都落在 sandbox
$env:AGENTOS_HOME = $sandbox
# fixture: 远端资源清单（让 room 用例不依赖真实 data/）
$fixtureData = Join-Path $sandbox 'data\agentos'
New-Item -ItemType Directory -Force -Path $fixtureData | Out-Null
$fixtureHosts = @{
    meta  = @{ updated = '2026-01-01'; note = 'selftest fixture (fake hosts, no real data)' }
    hosts = @{
        'demo-host' = @{
            hostname = '127.0.0.1'; user = 'nobody'; purpose = 'selftest'; tags = @('test'); policy = @('free'); gpu_count = 4;
            profile  = @{ os = 'ubuntu-22.04'; runtime = 'runtime-a'; gpu_model = 'FAKE-GPU'; gpu_count = 4; driver = 'fake-driver'; image = 'fake-image' }
        }
        'tag-host'    = @{ hostname = '127.0.0.2'; user = 'nobody'; purpose = 'selftest tag gpu'; tags = @('test', '2gpu'); policy = @('free') }
        'legacy-host' = @{ hostname = '127.0.0.3'; user = 'nobody'; purpose = 'selftest legacy lease'; tags = @('test', '2gpu'); policy = @('free') }
        'res-host'    = @{
            hostname = '127.0.0.4'; user = 'nobody'; purpose = 'selftest preflight'; tags = @('test'); policy = @('free'); gpu_count = 2;
            profile  = @{ os = 'centos-7'; runtime = 'runtime-a'; gpu_count = 2 }
        }
        'blank-host'  = @{ hostname = '127.0.0.5'; user = 'nobody'; purpose = 'selftest unknown profile'; tags = @('test'); policy = @('free') }
    }
}
$fixtureHosts | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixtureData 'hosts.json') -Encoding UTF8
# fixture: 空 project 目录（让 projects 用例不依赖真实 project/）
$fixtureProject = Join-Path $sandbox 'project'
New-Item -ItemType Directory -Force -Path $fixtureProject | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fixtureProject 'demo-repo') | Out-Null
# fixture: 嵌套 delivery + 一个 state-only 任务，供 projects/audit 递归发现
$fixtureDelivery = Join-Path $fixtureProject 'deliveries\demo-delivery'
$fixturePlans = Join-Path $fixtureDelivery '.agentos\plans'
New-Item -ItemType Directory -Force -Path $fixturePlans | Out-Null
$fixturePlan = Join-Path $fixturePlans 'PLAN-902.md'
$fixturePlanLines = @(
    '# PLAN-902 — audit fixture',
    '',
    '- issue: 902',
    ("- repo: " + $fixtureDelivery),
    '',
    '## Tasks',
    '',
    '| id | title | kind | deps | touches | resource | worktree | accept |',
    '|----|-------|------|------|---------|----------|----------|--------|',
    '| T1 | audit fixture task | read | - | - | none | - | state-only should be detected |'
)
$fixturePlanLines | Set-Content -LiteralPath $fixturePlan -Encoding UTF8
$fixtureState = @{ T1 = @{ status = 'done'; owner = 'selftest'; prev = 'running'; updated = '2026-01-01T00:00:00' } }
$fixtureState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fixturePlans 'PLAN-902.state.json') -Encoding UTF8
$fixtureLeases = Join-Path $sandbox 'leases'
New-Item -ItemType Directory -Force -Path $fixtureLeases | Out-Null
# fixture: sandbox 自签名 PFX（CertificateRequest 全程内存，EphemeralKeySet 加载；不写证书库）
$policyPfx = Join-Path $sandbox 'policy-test.pfx'
$policyPwd = 'selftest-pfx'
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=agentos-selftest', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    [IO.File]::WriteAllBytes($policyPfx, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $policyPwd))
} finally {
    $rsa.Dispose()
}
$policyPfx2 = Join-Path $sandbox 'policy-test-2.pfx'
$rsa2 = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $req2 = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=agentos-selftest-2', $rsa2,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert2 = $req2.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    [IO.File]::WriteAllBytes($policyPfx2, $cert2.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $policyPwd))
} finally {
    $rsa2.Dispose()
}
$env:AGENTOS_POLICY_PFX = $policyPfx
$env:AGENTOS_POLICY_PFX_PASSWORD = $policyPwd

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

function Get-LedgerEventsAt {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

$planFile = Join-Path $repo '.agentos\plans\PLAN-900.md'

# --- plan ---
Test-Case 'plan new (JSON)' { & $aos plan new -Issue 900 -Title 'selftest' -Repo $repo } -ExpectJson | Out-Null
Test-Case 'plan validate (JSON)' { & $aos plan validate -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan graph (JSON)' { & $aos plan graph -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan next (JSON)' { & $aos plan next -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan show (JSON)' { & $aos plan show -Plan $planFile } -ExpectJson | Out-Null
Test-Case 'plan state (JSON)' { & $aos plan state -Plan $planFile -Task T1 -Status ready -Owner selftest -NoLedger } -ExpectJson | Out-Null
Test-Case 'plan validate (Human)' { & $aos plan validate -Plan $planFile -Human } | Out-Null
Test-Case 'plan graph (Human)' { & $aos plan graph -Plan $planFile -Human } | Out-Null

$statePlanFile = Join-Path $repo '.agentos\plans\PLAN-903.md'
Test-Case 'plan new 903 (JSON)' { & $aos plan new -Issue 903 -Title 'state-ledger' -Repo $repo } -ExpectJson | Out-Null
Test-Case 'plan state writes ledger (JSON)' { & $aos plan state -Plan $statePlanFile -Task T1 -Status ready -Owner selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null

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

# --- track + signed policy ---
Test-Case 'track start without subagent must fail' { & $aos track start -Issue 900 -Task T1 -Owner selftest -Plan $planFile -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track start blocks unmet deps' { & $aos track start -Issue 900 -Task T2 -Owner selftest -Plan $planFile -Subagent 'worker-selftest' -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track start (JSON)' { & $aos track start -Issue 900 -Task T1 -Owner selftest -Plan $planFile -Subagent 'worker-selftest' -Ledger $sandboxLedger } -ExpectJson | Out-Null
# policy 已由上面的 start 自动签名激活；此处模拟 Master 绕过 track，用 plan state 把节点写成 done
Test-Case 'plan state bypass fixture (JSON)' { & $aos plan state -Plan $statePlanFile -Task T3 -Status done -Owner selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track review (JSON)' { & $aos track review -Issue 900 -Task T1 -Plan $planFile -Ledger $sandboxLedger } -ExpectJson | Out-Null
# reclaim 行为夹具：一个 clean safe candidate + 一个 dirty worktree；另加两条 policy 之前的 legacy 事件
$cleanWt = Join-Path $sandbox 'demo-repo-clean'
$dirtyWt = Join-Path $sandbox 'demo-repo-dirty'
& git -C $repo worktree add -q -b 'task/900-clean' $cleanWt HEAD 2>&1 | Out-Null
& git -C $repo worktree add -q -b 'task/900-dirty' $dirtyWt HEAD 2>&1 | Out-Null
'keep me' | Set-Content -LiteralPath (Join-Path $dirtyWt 'dirty.txt') -Encoding UTF8
'{"event":"start","issue":"900","task":"T3","owner":"selftest","ts":"2026-01-01T00:00:00","repo":"demo-repo"}' | Add-Content -LiteralPath $sandboxLedger -Encoding UTF8
'{"event":"start","issue":"900","task":"T99","owner":"selftest","ts":"2026-01-01T00:00:00","repo":"demo-repo"}' | Add-Content -LiteralPath $sandboxLedger -Encoding UTF8
Test-Case 'track close with mismatched -Issue must fail' { & $aos track close -Issue 999 -Task T1 -Plan $planFile -Ledger $sandboxLedger -SkipReclaim } -ExpectThrow | Out-Null
$closeOut = Test-Case 'track close (JSON)' { & $aos track close -Issue 900 -Task T1 -Plan $planFile -Ledger $sandboxLedger } -ExpectJson
# 模拟 state 写丢：ledger 已 close(done)，state 还停在 running；后续 start T2 不应需要 -Force
$planStatePath = [IO.Path]::ChangeExtension($planFile, '.state.json')
$staleState = Get-Content -LiteralPath $planStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$staleState.T1.status = 'running'
$staleState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planStatePath -Encoding UTF8
Test-Case 'track start with subagent=owner must fail' { & $aos track start -Issue 900 -Task T2 -Owner claude -Plan $planFile -Subagent 'claude' -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track start T2 (for handover)' { & $aos track start -Issue 900 -Task T2 -Owner claude -Plan $planFile -Subagent 'worker-selftest' -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track who (JSON)' { & $aos track who -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track handoff claude->codex (JSON)' { & $aos track handoff -Issue 900 -Task T2 -From claude -Owner codex -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track release codex (JSON)' { & $aos track release -Issue 900 -Task T2 -Owner codex -Note 'selftest' -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track claim dsh (JSON)' { & $aos track claim -Issue 900 -Task T2 -Owner dsh -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track block T2 (JSON)' { & $aos track block -Issue 900 -Task T2 -Owner dsh -Plan $planFile -Reason 'selftest' -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track close T2 (JSON)' { & $aos track close -Issue 900 -Task T2 -Owner dsh -Plan $planFile -Ledger $sandboxLedger -SkipReclaim } -ExpectJson | Out-Null

Test-Case 'track list (JSON)' { & $aos track list -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track lost (JSON)' { & $aos track lost -Ledger $sandboxLedger } -ExpectJson | Out-Null

# --- gc ---
Test-Case 'gc dryrun (JSON)' { & $bin\gc.ps1 -Ledger $sandboxLedger -ProjectRoot $fixtureProject -Human:$false } -AllowAttention -ExpectJson | Out-Null

Test-Case 'track start fixture for isolation' { & $aos track start -Issue 900 -Task T3 -Owner claude -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track claim without auth must fail' { & $aos track claim -Issue 900 -Task T3 -Owner intruder -Force -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track claim with auth succeeds' { & $aos track claim -Issue 900 -Task T3 -Owner intruder -Force -AuthorizedBy selftest -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'track close T3' { & $aos track close -Issue 900 -Task T3 -Owner intruder -Ledger $sandboxLedger } -ExpectJson | Out-Null

# --- session (bound to a tracked task; ledger-only) ---
$sessPlan = Join-Path $repo '.agentos\plans\PLAN-925.md'
Test-Case 'plan new 925 (session)' { & $aos plan new -Issue 925 -Title 'session' -Repo $repo } -ExpectJson | Out-Null
Test-Case 'session register before track start must fail' { & $aos session register -Issue 925 -Task T1 -Role worker -Ledger $sandboxLedger } -ExpectThrow | Out-Null
Test-Case 'track start 925 (JSON)' { & $aos track start -Issue 925 -Task T1 -Owner selftest -Plan $sessPlan -Subagent 'worker-selftest' -Ledger $sandboxLedger } -ExpectJson | Out-Null
$sessOut = Test-Case 'session register (JSON)' { & $aos session register -Issue 925 -Task T1 -Role worker -HostName 'demo-host' -Ledger $sandboxLedger } -ExpectJson
$sid = ''
try { $sid = [string](($sessOut | Out-String) | ConvertFrom-Json).session } catch { $sid = '' }
Test-Case 'session heartbeat (JSON)' { & $aos session heartbeat -Id $sid -Ledger $sandboxLedger } -ExpectJson | Out-Null
$sessListOut = Test-Case 'session list (JSON)' { & $aos session list -Ledger $sandboxLedger } -ExpectJson
Test-Case 'session close (JSON)' { & $aos session close -Id $sid -Ledger $sandboxLedger } -ExpectJson | Out-Null
Test-Case 'session close is idempotent (JSON)' { & $aos session close -Id $sid -Ledger $sandboxLedger } -ExpectJson | Out-Null
$sessListAfter = Test-Case 'session list excludes closed (JSON)' { & $aos session list -Ledger $sandboxLedger } -ExpectJson
Test-Case 'track close 925 (JSON)' { & $aos track close -Issue 925 -Task T1 -Owner selftest -Plan $sessPlan -Ledger $sandboxLedger -SkipReclaim } -ExpectJson | Out-Null

# --- projects: session/policy events must not be counted as tasks ---
$projRepo = Join-Path $sandbox 'projects-session-repo'
New-Item -ItemType Directory -Force -Path $projRepo | Out-Null
$projPlan = Join-Path $projRepo '.agentos\plans\PLAN-927.md'
$projLedger = Join-Path $sandbox 'projects-ledger.jsonl'
Test-Case 'plan new 927 (projects-session)' { & $aos plan new -Issue 927 -Title 'projects-session' -Repo $projRepo } -ExpectJson | Out-Null
Test-Case 'track start 927 (JSON)' { & $aos track start -Issue 927 -Task T1 -Owner selftest -Plan $projPlan -Subagent 'worker-selftest' -Ledger $projLedger } -ExpectJson | Out-Null
$projSessOut = Test-Case 'session register 927 (JSON)' { & $aos session register -Issue 927 -Task T1 -Role worker -HostName 'demo-host' -Ledger $projLedger } -ExpectJson
$projSid = ''
try { $projSid = [string](($projSessOut | Out-String) | ConvertFrom-Json).session } catch { $projSid = '' }
Test-Case 'track close 927 (JSON)' { & $aos track close -Issue 927 -Task T1 -Owner selftest -Plan $projPlan -Ledger $projLedger -SkipReclaim } -ExpectJson | Out-Null
Test-Case 'session heartbeat after task close (JSON)' { & $aos session heartbeat -Id $projSid -Ledger $projLedger } -ExpectJson | Out-Null
$projSessProjects = Test-Case 'projects ignores session/policy events (JSON)' { & $bin\projects.ps1 -Root $projRepo -Ledger $projLedger } -ExpectJson
$projSessCheck = 'FAIL'
try {
    $pp = ($projSessProjects | Out-String) | ConvertFrom-Json
    if ($pp.ok -eq $true -and $pp.summary.activeTasks -eq 0 -and $pp.summary.openTasks -eq 0 -and $pp.summary.ledgerOnly -eq 0) { $projSessCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'projects: closed task + session heartbeat => active=0/open=0'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $projSessCheck; Detail = '' })

# --- room ---
Test-Case 'room list (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson | Out-Null
Test-Case 'room list (Human)' { & $bin\room.ps1 -Command list -HomeBase $sandbox -Human } | Out-Null

# --- room: GPU 子租约（仅 fake hosts fixture，不读真实 data/） ---
$roomLeaseDir = Join-Path $sandbox 'devops\agentos\leases'
New-Item -ItemType Directory -Force -Path $roomLeaseDir | Out-Null
Test-Case 'room acquire without -Gpus must fail (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task R1 -Issue 940 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson | Out-Null
$roomAcq1 = Test-Case 'room acquire 1 gpu (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task R1 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$roomAcq2 = Test-Case 'room acquire 2 gpus (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task R2 -Issue 940 -Gpus 2 -HomeBase $sandbox } -ExpectJson
$roomAcq3 = Test-Case 'room acquire last gpu (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task R3 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$roomFull = Test-Case 'room acquire full host fails with alternatives (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task R4 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson
$roomListGpu = Test-Case 'room list GPU usage (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$roomTagAll = Test-Case 'room acquire -Gpus all from tag gpu_count (JSON)' { & $bin\room.ps1 -Command acquire tag-host -Task R5 -Issue 940 -Gpus all -HomeBase $sandbox } -ExpectJson
$roomTagFull = Test-Case 'room acquire fails after -Gpus all (JSON)' { & $bin\room.ps1 -Command acquire tag-host -Task R6 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson

$roomGpuCheck = 'FAIL'
try {
    $ra1 = ($roomAcq1 | Out-String) | ConvertFrom-Json
    $ra2 = ($roomAcq2 | Out-String) | ConvertFrom-Json
    $ra3 = ($roomAcq3 | Out-String) | ConvertFrom-Json
    $rf = ($roomFull | Out-String) | ConvertFrom-Json
    $rl = ($roomListGpu | Out-String) | ConvertFrom-Json
    $rt = ($roomTagAll | Out-String) | ConvertFrom-Json
    $rtf = ($roomTagFull | Out-String) | ConvertFrom-Json
    $demoRow = @($rl.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $altHit = @($rf.alternatives | Where-Object { $_.host -eq 'tag-host' -and $_.free -eq 2 })
    $ok = (@($ra1.gpus) -join ',') -eq '0'
    $ok = $ok -and (@($ra2.gpus) -join ',') -eq '1,2'
    $ok = $ok -and (@($ra3.gpus) -join ',') -eq '3'
    $ok = $ok -and $demoRow.gpus_used -eq 4 -and $demoRow.gpus_free -eq 0 -and @($demoRow.allocations).Count -eq 3
    $ok = $ok -and $rf.ok -eq $false -and $rf.used -eq 4 -and $rf.free -eq 0 -and $altHit.Count -eq 1
    $ok = $ok -and (@($rt.gpus) -join ',') -eq '0,1' -and $rtf.ok -eq $false
    if ($ok) { $roomGpuCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room GPU sublease: lowest free ids / capacity / alternatives / -Gpus all'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $roomGpuCheck; Detail = '' })

$roomRel = Test-Case 'room release v2 allocation (JSON)' { & $bin\room.ps1 -Command release demo-host -Task R2 -Issue 940 -HomeBase $sandbox } -ExpectJson
$roomRelMissing = Test-Case 'room release unknown task must fail (JSON)' { & $bin\room.ps1 -Command release demo-host -Task R2 -Issue 940 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson
$roomListAfterRel = Test-Case 'room list after release (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$roomReleaseCheck = 'FAIL'
try {
    $rr = ($roomRel | Out-String) | ConvertFrom-Json
    $rm = ($roomRelMissing | Out-String) | ConvertFrom-Json
    $rl2 = ($roomListAfterRel | Out-String) | ConvertFrom-Json
    $demo2 = @($rl2.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $tasks2 = @($demo2.allocations | ForEach-Object { $_.task })
    if ((($rr.gpus) -join ',') -eq '1,2' -and $rm.ok -eq $false -and $demo2.gpus_used -eq 2 -and $demo2.gpus_free -eq 2 -and ($tasks2 -join ',') -eq 'R1,R3') { $roomReleaseCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room release removes only matching allocation; unknown task rejected'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $roomReleaseCheck; Detail = '' })

$roomResAcq = Test-Case 'room acquire second host allocation (JSON)' { & $bin\room.ps1 -Command acquire res-host -Task R7 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$roomMultiList = Test-Case 'room list multi-host allocations (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$roomMultiCheck = 'FAIL'
try {
    $rs = ($roomResAcq | Out-String) | ConvertFrom-Json
    $ml = ($roomMultiList | Out-String) | ConvertFrom-Json
    $res = @($ml.hosts | Where-Object { $_.host -eq 'res-host' })[0]
    $demo3 = @($ml.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    if ((($rs.gpus) -join ',') -eq '0' -and $res.gpus_used -eq 1 -and $res.gpus_free -eq 1 -and $demo3.gpus_used -eq 2 -and $demo3.gpus_free -eq 2) { $roomMultiCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room allocations are per-host and non-overlapping'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $roomMultiCheck; Detail = '' })

# v1 legacy lease：整机读取 / acquire 拒绝 / release 兼容
@{
    schema_version = 1; host = 'legacy-host'; task = 'LEGACY-1'; issue = '941';
    agent_task = ''; note = 'legacy fixture'; acquired_at = '2026-01-01T00:00:00Z'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $roomLeaseDir 'legacy-host.json') -Encoding UTF8
$legacyList = Test-Case 'room list v1 legacy lease (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$legacyAcqFail = Test-Case 'room acquire on v1 legacy host must fail (JSON)' { & $bin\room.ps1 -Command acquire legacy-host -Task R8 -Issue 940 -Gpus 1 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson
$legacyRelWrong = Test-Case 'room release v1 wrong task must fail (JSON)' { & $bin\room.ps1 -Command release legacy-host -Task R8 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson
$legacyRel = Test-Case 'room release v1 legacy by task (JSON)' { & $bin\room.ps1 -Command release legacy-host -Task LEGACY-1 -HomeBase $sandbox } -ExpectJson
$legacyAfter = Test-Case 'room list after v1 release (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$legacyCheck = 'FAIL'
try {
    $ll = ($legacyList | Out-String) | ConvertFrom-Json
    $la = ($legacyAcqFail | Out-String) | ConvertFrom-Json
    $lw = ($legacyRelWrong | Out-String) | ConvertFrom-Json
    $lr = ($legacyRel | Out-String) | ConvertFrom-Json
    $lx = ($legacyAfter | Out-String) | ConvertFrom-Json
    $lh = @($ll.hosts | Where-Object { $_.host -eq 'legacy-host' })[0]
    $lhAfter = @($lx.hosts | Where-Object { $_.host -eq 'legacy-host' })[0]
    $legacyAlloc = @($lh.allocations)[0]
    if ($lh.lease_mode -eq 'legacy' -and $lh.gpus_used -eq 2 -and $lh.gpus_free -eq 0 -and $legacyAlloc.legacy -eq $true -and
        $la.ok -eq $false -and $lw.ok -eq $false -and $lr.released -eq 'LEGACY-1' -and
        $lhAfter.lease_mode -eq 'free' -and -not (Test-Path -LiteralPath (Join-Path $roomLeaseDir 'legacy-host.json'))) { $legacyCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room v1 legacy lease read/acquire/release compatibility'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $legacyCheck; Detail = '' })

$roomShow = Test-Case 'room show profile (JSON)' { & $bin\room.ps1 -Command show demo-host -HomeBase $sandbox } -ExpectJson
$roomShowBlank = Test-Case 'room show unknown profile stays UNKNOWN (JSON)' { & $bin\room.ps1 -Command show blank-host -HomeBase $sandbox } -ExpectJson
$roomShowCheck = 'FAIL'
try {
    $sh = ($roomShow | Out-String) | ConvertFrom-Json
    $sb = ($roomShowBlank | Out-String) | ConvertFrom-Json
    if ($sh.host.profile.os -eq 'ubuntu-22.04' -and $sh.host.profile.runtime -eq 'runtime-a' -and $sh.host.gpu_count -eq 4 -and
        $sb.host.profile.status -eq 'UNKNOWN' -and $sb.host.gpu_count -eq 0) { $roomShowCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room show profile fields; missing profile => UNKNOWN without blocking'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $roomShowCheck; Detail = '' })

# 释放 room 测试占用，后续 plan/track 用例需要干净容量
foreach ($rt in @('R1', 'R3')) { & $bin\room.ps1 -Command release demo-host -Task $rt -Issue 940 -HomeBase $sandbox 2>&1 | Out-Null }
& $bin\room.ps1 -Command release res-host -Task R7 -Issue 940 -HomeBase $sandbox 2>&1 | Out-Null
& $bin\room.ps1 -Command release tag-host -Task R5 -Issue 940 -HomeBase $sandbox 2>&1 | Out-Null

# --- plan: needs（gpus 硬 / env 软）与 GPU 容量 ---
$resRepo = Join-Path $sandbox 'resource-repo'
New-Item -ItemType Directory -Force -Path (Join-Path $resRepo '.agentos\plans') | Out-Null
$needsPlan = Join-Path $resRepo '.agentos\plans\PLAN-940.md'
@(
    '# PLAN-940 — resource needs fixture',
    '',
    '- issue: 940',
    '',
    '## Tasks',
    '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | gpu match | read | - | - | demo-host | - | ok | gpus=2;env.os=ubuntu-22.04;env.runtime=runtime-a |',
    '| T2 | env mismatch allowed | read | - | - | demo-host | - | ok | gpus=2;env.os=centos-7 |',
    '| T3 | auto host | read | - | - | auto | - | ok | gpus=1 |',
    '| T4 | no resource | read | - | - | none | - | ok | - |'
) | Set-Content -LiteralPath $needsPlan -Encoding UTF8
$needsValidate = Test-Case 'plan validate needs + env soft (JSON)' { & $aos plan validate -Plan $needsPlan } -ExpectJson
$needsGraph = Test-Case 'plan graph same-host gpu capacity (JSON)' { & $aos plan graph -Plan $needsPlan } -ExpectJson
$needsShow = Test-Case 'plan show parses needs (JSON)' { & $aos plan show -Plan $needsPlan } -ExpectJson
$needsCheck = 'FAIL'
try {
    $nv = ($needsValidate | Out-String) | ConvertFrom-Json
    $ng = ($needsGraph | Out-String) | ConvertFrom-Json
    $ns = ($needsShow | Out-String) | ConvertFrom-Json
    $t1 = @($ns.tasks | Where-Object { $_.id -eq 'T1' })[0]
    $t4 = @($ns.tasks | Where-Object { $_.id -eq 'T4' })[0]
    $waveTasks = (@($ng.Waves)[0].Tasks -join ',')
    if ($nv.ok -eq $true -and (@($nv.warnings) -join ' ') -match 'mismatch' -and (@($nv.warnings) -join ' ') -match '\[soft\]' -and
        @($ng.Waves).Count -eq 1 -and $waveTasks -match 'T1' -and $waveTasks -match 'T2' -and @($ng.ForcedSerial).Count -eq 0 -and
        $t1.GpuSpec -eq '2' -and $t1.EnvNeeds.os -eq 'ubuntu-22.04' -and $t4.HasGpus -eq $false) { $needsCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan needs: gpus parsed; env mismatch only warning; same-host capacity shares wave'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $needsCheck; Detail = '' })

$missingGpusPlan = Join-Path $resRepo '.agentos\plans\PLAN-941.md'
@(
    '# PLAN-941 — missing gpus fixture', '', '- issue: 941', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | missing gpus | read | - | - | demo-host | - | ok | env.os=ubuntu-22.04 |'
) | Set-Content -LiteralPath $missingGpusPlan -Encoding UTF8
$missingGpusOut = Test-Case 'plan validate 9-col resource without gpus fails (JSON)' { & $aos plan validate -Plan $missingGpusPlan } -ExpectExit 1 -ExpectJson
$missingGpusCheck = 'FAIL'
try {
    $mg = ($missingGpusOut | Out-String) | ConvertFrom-Json
    if ($mg.ok -eq $false -and (@($mg.errors) -join ' ') -match 'gpus') { $missingGpusCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan validate rejects 9-column resource without needs gpus'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $missingGpusCheck; Detail = '' })

$capacityPlan = Join-Path $resRepo '.agentos\plans\PLAN-942.md'
@(
    '# PLAN-942 — gpu capacity fixture', '', '- issue: 942', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | three | read | - | - | demo-host | - | ok | gpus=3 |',
    '| T2 | three | read | - | - | demo-host | - | ok | gpus=3 |'
) | Set-Content -LiteralPath $capacityPlan -Encoding UTF8
$capacityValidate = Test-Case 'plan validate same-host over-capacity serializes (JSON)' { & $aos plan validate -Plan $capacityPlan } -ExpectJson
$capacityGraph = Test-Case 'plan graph same-host over-capacity forced serial (JSON)' { & $aos plan graph -Plan $capacityPlan } -ExpectJson
$capacityCheck = 'FAIL'
try {
    $cv = ($capacityValidate | Out-String) | ConvertFrom-Json
    $cg = ($capacityGraph | Out-String) | ConvertFrom-Json
    $forced = @($cg.ForcedSerial)
    if ($cv.ok -eq $true -and @($cg.Waves).Count -eq 2 -and $forced.Count -eq 1 -and [string]$forced[0].Reason -match 'resource:demo-host:gpus') { $capacityCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan graph serializes same-host tasks when GPU total exceeds gpu_count'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $capacityCheck; Detail = '' })

$invalidGpusPlan = Join-Path $resRepo '.agentos\plans\PLAN-944.md'
@(
    '# PLAN-944 — invalid gpus fixture', '', '- issue: 944', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | bad gpus | read | - | - | demo-host | - | ok | gpus=0 |'
) | Set-Content -LiteralPath $invalidGpusPlan -Encoding UTF8
$invalidGpusOut = Test-Case 'plan validate rejects invalid needs gpus (JSON)' { & $aos plan validate -Plan $invalidGpusPlan } -ExpectExit 1 -ExpectJson
$invalidGpusCheck = 'FAIL'
try {
    $ig = ($invalidGpusOut | Out-String) | ConvertFrom-Json
    if ($ig.ok -eq $false -and (@($ig.errors) -join ' ') -match 'invalid needs gpus') { $invalidGpusCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan validate rejects gpus=0'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $invalidGpusCheck; Detail = '' })

$legacyPlanRes = Join-Path $resRepo '.agentos\plans\PLAN-945.md'
@(
    '# PLAN-945 — legacy resource fixture', '', '- issue: 945', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept |',
    '|----|-------|------|------|---------|----------|----------|--------|',
    '| T1 | legacy whole host | read | - | - | demo-host | - | ok |'
) | Set-Content -LiteralPath $legacyPlanRes -Encoding UTF8
$legacyPlanOut = Test-Case 'plan validate legacy 8-column resource is warning (JSON)' { & $aos plan validate -Plan $legacyPlanRes } -ExpectJson
$legacyPlanCheck = 'FAIL'
try {
    $lp = ($legacyPlanOut | Out-String) | ConvertFrom-Json
    if ($lp.ok -eq $true -and (@($lp.warnings) -join ' ') -match 'legacy 8-column resource') { $legacyPlanCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan validate treats 8-column resource as legacy whole host (warning only)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $legacyPlanCheck; Detail = '' })

# --- plan resources：GPU 不足 exit 2；env mismatch 不阻断 ---
$preflight = Test-Case 'plan resources sufficient + env mismatch warning (JSON)' { & $aos plan resources -Plan $needsPlan } -ExpectJson
$preflightCheck = 'FAIL'
try {
    $pf = ($preflight | Out-String) | ConvertFrom-Json
    $pt1 = @($pf.tasks | Where-Object { $_.id -eq 'T1' })[0]
    $pt2 = @($pf.tasks | Where-Object { $_.id -eq 'T2' })[0]
    $pt3 = @($pf.tasks | Where-Object { $_.id -eq 'T3' })[0]
    $pt4 = @($pf.tasks | Where-Object { $_.id -eq 'T4' })[0]
    if ($pf.ok -eq $true -and $pt1.env -eq 'match' -and $pt2.env -eq 'mismatch' -and $pt3.status -eq 'ok' -and $pt3.host -ne '-' -and $pt4.status -eq 'skip') { $preflightCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan resources: env mismatch does not block; auto host selected; per-task host/gpus/free/env'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $preflightCheck; Detail = '' })

$insufficientPlan = Join-Path $resRepo '.agentos\plans\PLAN-943.md'
@(
    '# PLAN-943 — insufficient gpu fixture', '', '- issue: 943', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | needs two | read | - | - | res-host | - | ok | gpus=2 |'
) | Set-Content -LiteralPath $insufficientPlan -Encoding UTF8
& $bin\room.ps1 -Command acquire res-host -Task OTHER -Issue 943 -Gpus 1 -HomeBase $sandbox 2>&1 | Out-Null
$insufficientOut = Test-Case 'plan resources GPU shortage exits 2 (JSON)' { & $aos plan resources -Plan $insufficientPlan } -ExpectExit 2 -ExpectJson
& $bin\room.ps1 -Command release res-host -Task OTHER -Issue 943 -HomeBase $sandbox 2>&1 | Out-Null
$insufficientCheck = 'FAIL'
try {
    $io = ($insufficientOut | Out-String) | ConvertFrom-Json
    $it = @($io.tasks)[0]
    $altHit2 = @($it.alternatives | Where-Object { $_.host -eq 'demo-host' -and $_.free -eq 4 })
    if ($io.ok -eq $false -and $it.status -eq 'insufficient' -and $altHit2.Count -eq 1 -and @($io.suggestions).Count -ge 1 -and (@($io.suggestions) -join ' ') -match 'reduce|use host|wait') { $insufficientCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan resources: GPU shortage exit 2 with host/reduce/wait suggestions'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $insufficientCheck; Detail = '' })

$unknownGpuPlan = Join-Path $resRepo '.agentos\plans\PLAN-947.md'
@(
    '# PLAN-947 — unknown gpu_count fixture', '', '- issue: 947', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | unknown capacity | read | - | - | blank-host | - | ok | gpus=1 |'
) | Set-Content -LiteralPath $unknownGpuPlan -Encoding UTF8
$unknownGpuOut = Test-Case 'plan resources unknown gpu_count is structured (JSON)' { & $aos plan resources -Plan $unknownGpuPlan } -ExpectExit 2 -ExpectJson
$unknownGpuCheck = 'FAIL'
try {
    $ug = ($unknownGpuOut | Out-String) | ConvertFrom-Json
    $ugt = @($ug.tasks)[0]
    if ($ug.ok -eq $false -and $ugt.status -eq 'unknown-gpu-count' -and (@($ug.errors) -join ' ') -match 'gpu_count unknown' -and (@($ug.suggestions) -join ' ') -match 'gpu_count') { $unknownGpuCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'plan resources unknown gpu_count returns structured error, no null reference'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $unknownGpuCheck; Detail = '' })

$auditResPlan = Join-Path $resRepo '.agentos\plans\PLAN-948.md'
@(
    '# PLAN-948 — audit resource fixture', '', '- issue: 948', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | env warning | read | - | - | demo-host | - | ok | gpus=1;env.os=centos-7 |'
) | Set-Content -LiteralPath $auditResPlan -Encoding UTF8
$overlapLeaseDir = Join-Path $sandbox 'gpu-overlap-leases'
New-Item -ItemType Directory -Force -Path $overlapLeaseDir | Out-Null
@{
    schema_version = 2; host = 'demo-host'; updated_at = '2026-01-01T00:00:00Z';
    allocations = @(
        @{ task = 'OV1'; issue = '948'; agent_task = ''; gpus = @(0); acquired_at = '2026-01-01T00:00:00Z'; note = '' },
        @{ task = 'OV2'; issue = '948'; agent_task = ''; gpus = @(0, 1); acquired_at = '2026-01-01T00:00:01Z'; note = '' }
    )
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $overlapLeaseDir 'demo-host.json') -Encoding UTF8
$auditResLedger = Join-Path $sandbox 'audit-resource-ledger.jsonl'
$auditResOut = Test-Case 'audit GPU overlap + env warning (JSON)' { & $bin\audit.ps1 -Plan $auditResPlan -Ledger $auditResLedger -LeaseDir $overlapLeaseDir -HostsFile (Join-Path $fixtureData 'hosts.json') } -ExpectExit 2 -ExpectJson
$auditResCheck = 'FAIL'
try {
    $ar = ($auditResOut | Out-String) | ConvertFrom-Json
    $gpuHits = @($ar.findings | Where-Object { $_.kind -eq 'gpu-overlap' -and $_.severity -eq 'error' })
    $envHits = @($ar.findings | Where-Object { $_.kind -eq 'env-mismatch' -and $_.severity -eq 'warning' })
    if ($gpuHits.Count -ge 1 -and $envHits.Count -ge 1 -and [int]$ar.summary.gpuErrors -ge 1 -and [int]$ar.summary.envWarnings -ge 1 -and [int]$ar.resourceSummary.gpuErrors -ge 1) { $auditResCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit reports GPU overlap as error and env mismatch as warning'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $auditResCheck; Detail = '' })

# --- track: resource 门禁（GPU 硬 / env 软） ---
$trackResRepo = Join-Path $sandbox 'track-resource-repo'
New-Item -ItemType Directory -Force -Path (Join-Path $trackResRepo '.agentos\plans') | Out-Null
$trackResPlan = Join-Path $trackResRepo '.agentos\plans\PLAN-950.md'
@(
    '# PLAN-950 — track resource gate fixture', '', '- issue: 950', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | env mismatch ok | read | - | - | demo-host | - | ok | gpus=1;env.os=centos-7 |',
    '| T2 | needs two | read | - | - | demo-host | - | ok | gpus=2;env.os=ubuntu-22.04 |'
) | Set-Content -LiteralPath $trackResPlan -Encoding UTF8
$resourceLedger = Join-Path $sandbox 'resource-ledger.jsonl'
Test-Case 'track start without allocation must fail' { & $aos track start -Issue 950 -Task T1 -Owner selftest -Plan $trackResPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectThrow | Out-Null
$noLeaseMsg = ''
try { & $aos track start -Issue 950 -Task T1 -Owner selftest -Plan $trackResPlan -Subagent 'worker-selftest' -Ledger $resourceLedger 2>&1 | Out-Null } catch { $noLeaseMsg = $_.Exception.Message }
$results.Add([pscustomobject]@{ Case = 'track start rejection names aos room acquire and alternatives'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $(if ($noLeaseMsg -match 'aos room acquire' -and $noLeaseMsg -match 'Alternatives') { 'PASS' } else { 'FAIL' }); Detail = '' })

& $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 950 -Gpus 1 -HomeBase $sandbox 2>&1 | Out-Null
$trackT1Out = Test-Case 'track start with allocation + env mismatch warning (JSON)' { & $aos track start -Issue 950 -Task T1 -Owner selftest -Plan $trackResPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectJson
$trackT1Check = 'FAIL'
try {
    $st1 = ($trackT1Out | Out-String) | ConvertFrom-Json
    if ($st1.resource.Checked -eq $true -and $st1.resource.Host -eq 'demo-host' -and $st1.resource.Env -eq 'mismatch' -and @($st1.resource.Warnings).Count -ge 1) { $trackT1Check = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'track start passes with matching allocation; env mismatch is warning only'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $trackT1Check; Detail = '' })

& $bin\room.ps1 -Command acquire demo-host -Task T2 -Issue 950 -Gpus 1 -HomeBase $sandbox 2>&1 | Out-Null
Test-Case 'track start rejects insufficient gpu allocation' { & $aos track start -Issue 950 -Task T2 -Owner selftest -Plan $trackResPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectThrow | Out-Null
& $bin\room.ps1 -Command release demo-host -Task T2 -Issue 950 -HomeBase $sandbox 2>&1 | Out-Null
& $bin\room.ps1 -Command acquire demo-host -Task T2 -Issue 950 -Gpus 2 -HomeBase $sandbox 2>&1 | Out-Null
$trackT2Out = Test-Case 'track start with matching 2-gpu allocation (JSON)' { & $aos track start -Issue 950 -Task T2 -Owner selftest -Plan $trackResPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectJson
$trackT2Check = 'FAIL'
try {
    $st2 = ($trackT2Out | Out-String) | ConvertFrom-Json
    if ($st2.resource.Checked -eq $true -and @($st2.resource.Gpus).Count -eq 2 -and $st2.resource.Env -eq 'match') { $trackT2Check = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'track start accepts allocation with enough GPUs'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $trackT2Check; Detail = '' })

& $aos track close -Issue 950 -Task T1 -Owner selftest -Plan $trackResPlan -Ledger $resourceLedger -SkipReclaim 2>&1 | Out-Null
& $aos track close -Issue 950 -Task T2 -Owner selftest -Plan $trackResPlan -Ledger $resourceLedger -SkipReclaim 2>&1 | Out-Null
& $bin\room.ps1 -Command release demo-host -Task T1 -Issue 950 -HomeBase $sandbox 2>&1 | Out-Null
& $bin\room.ps1 -Command release demo-host -Task T2 -Issue 950 -HomeBase $sandbox 2>&1 | Out-Null

# issue identity：同 host 同 task T1、不同 issue 100/200 必须各自独立 allocation
$issueRepo = Join-Path $sandbox 'issue-identity-repo'
New-Item -ItemType Directory -Force -Path (Join-Path $issueRepo '.agentos\plans') | Out-Null
foreach ($iid in @(100, 200)) {
    @(
        "# PLAN-$iid — issue identity fixture", '', "- issue: $iid", '', '## Tasks', '',
        '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
        '|----|-------|------|------|---------|----------|----------|--------|-------|',
        '| T1 | same task different issue | read | - | - | demo-host | - | ok | gpus=1 |'
    ) | Set-Content -LiteralPath (Join-Path $issueRepo ".agentos\plans\PLAN-$iid.md") -Encoding UTF8
}
$issuePlan100 = Join-Path $issueRepo '.agentos\plans\PLAN-100.md'
$issuePlan200 = Join-Path $issueRepo '.agentos\plans\PLAN-200.md'
$issueAcq100 = Test-Case 'room acquire T1 issue 100 (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 100 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$issueAcq100Again = Test-Case 'room acquire T1 issue 100 is idempotent (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 100 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$issueAcq200 = Test-Case 'room acquire same task issue 200 gets separate gpu (JSON)' { & $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 200 -Gpus 1 -HomeBase $sandbox } -ExpectJson
$issueList = Test-Case 'room list same task different issues (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$issueTrack100 = Test-Case 'track start issue 100 uses own allocation (JSON)' { & $aos track start -Issue 100 -Task T1 -Owner selftest -Plan $issuePlan100 -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectJson
$issueTrack200 = Test-Case 'track start issue 200 uses own allocation (JSON)' { & $aos track start -Issue 200 -Task T1 -Owner selftest -Plan $issuePlan200 -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectJson
$issueRelNoIssue = Test-Case 'room release without issue rejected for issue-scoped task (JSON)' { & $bin\room.ps1 -Command release demo-host -Task T1 -HomeBase $sandbox } -ExpectExit 1 -ExpectJson
$issueRel200 = Test-Case 'room release T1 issue 200 only (JSON)' { & $bin\room.ps1 -Command release demo-host -Task T1 -Issue 200 -HomeBase $sandbox } -ExpectJson
$issueList200 = Test-Case 'room list after release issue 200 (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$issueRel100 = Test-Case 'room release T1 issue 100 only (JSON)' { & $bin\room.ps1 -Command release demo-host -Task T1 -Issue 100 -HomeBase $sandbox } -ExpectJson
$issueList100 = Test-Case 'room list after release issue 100 (JSON)' { & $bin\room.ps1 -Command list -HomeBase $sandbox } -ExpectJson
$issueIdentityCheck = 'FAIL'
try {
    $ia1 = ($issueAcq100 | Out-String) | ConvertFrom-Json
    $iar = ($issueAcq100Again | Out-String) | ConvertFrom-Json
    $ia2 = ($issueAcq200 | Out-String) | ConvertFrom-Json
    $il = ($issueList | Out-String) | ConvertFrom-Json
    $demoIssue = @($il.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $allocRows = @($demoIssue.allocations | Where-Object { $_.task -eq 'T1' })
    $issueIds = @($allocRows | ForEach-Object { [string]$_.issue } | Sort-Object)
    $gpuIds = @()
    foreach ($ar in $allocRows) { $gpuIds += @($ar.gpus) }
    $st100 = ($issueTrack100 | Out-String) | ConvertFrom-Json
    $st200 = ($issueTrack200 | Out-String) | ConvertFrom-Json
    $noIssue = ($issueRelNoIssue | Out-String) | ConvertFrom-Json
    $r200 = ($issueRel200 | Out-String) | ConvertFrom-Json
    $after200 = ($issueList200 | Out-String) | ConvertFrom-Json
    $r100 = ($issueRel100 | Out-String) | ConvertFrom-Json
    $after100 = ($issueList100 | Out-String) | ConvertFrom-Json
    $demo200 = @($after200.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $demo100 = @($after100.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $alloc200 = @($demo200.allocations | Where-Object { $_.task -eq 'T1' })
    $ok = [string]$ia1.issue -eq '100' -and [string]$ia2.issue -eq '200'
    $ok = $ok -and ((@($ia1.gpus) -join ',') -ne (@($ia2.gpus) -join ','))
    $ok = $ok -and [string]$iar.issue -eq '100' -and ((@($iar.gpus) -join ',') -eq (@($ia1.gpus) -join ','))
    $ok = $ok -and $allocRows.Count -eq 2 -and ($issueIds -join ',') -eq '100,200' -and $gpuIds.Count -eq 2
    $ok = $ok -and $st100.resource.Host -eq 'demo-host' -and $st200.resource.Host -eq 'demo-host'
    $ok = $ok -and @($st100.resource.Gpus).Count -eq 1 -and @($st200.resource.Gpus).Count -eq 1
    $ok = $ok -and $noIssue.ok -eq $false
    $ok = $ok -and $r200.ok -eq $true -and [string]$r200.issue -eq '200' -and $alloc200.Count -eq 1 -and [string]$alloc200[0].issue -eq '100'
    $ok = $ok -and $r100.ok -eq $true -and [string]$r100.issue -eq '100' -and $demo100.lease_mode -eq 'free' -and @($demo100.allocations).Count -eq 0
    if ($ok) { $issueIdentityCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'room issue identity: same task different issues get separate GPUs; release only matching task+issue'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $issueIdentityCheck; Detail = '' })
& $aos track close -Issue 100 -Task T1 -Owner selftest -Plan $issuePlan100 -Ledger $resourceLedger -SkipReclaim 2>&1 | Out-Null
& $aos track close -Issue 200 -Task T1 -Owner selftest -Plan $issuePlan200 -Ledger $resourceLedger -SkipReclaim 2>&1 | Out-Null

# track gpus=all：必须整机 allocation（GPU 硬约束）
$allPlan = Join-Path $trackResRepo '.agentos\plans\PLAN-951.md'
@(
    '# PLAN-951 — gpus all fixture', '', '- issue: 951', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | whole host | read | - | - | demo-host | - | ok | gpus=all |'
) | Set-Content -LiteralPath $allPlan -Encoding UTF8
& $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 951 -Gpus 1 -HomeBase $sandbox 2>&1 | Out-Null
Test-Case 'track start gpus=all rejects partial allocation' { & $aos track start -Issue 951 -Task T1 -Owner selftest -Plan $allPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectThrow | Out-Null
& $bin\room.ps1 -Command release demo-host -Task T1 -Issue 951 -HomeBase $sandbox 2>&1 | Out-Null
& $bin\room.ps1 -Command acquire demo-host -Task T1 -Issue 951 -Gpus all -HomeBase $sandbox 2>&1 | Out-Null
$trackAllOut = Test-Case 'track start gpus=all accepts whole-host allocation (JSON)' { & $aos track start -Issue 951 -Task T1 -Owner selftest -Plan $allPlan -Subagent 'worker-selftest' -Ledger $resourceLedger } -ExpectJson
$trackAllCheck = 'FAIL'
try {
    $sa = ($trackAllOut | Out-String) | ConvertFrom-Json
    if ($sa.resource.Checked -eq $true -and @($sa.resource.Gpus).Count -eq 4 -and $sa.resource.WholeHost -eq $false) { $trackAllCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'track start gpus=all requires whole-host allocation'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $trackAllCheck; Detail = '' })
& $aos track close -Issue 951 -Task T1 -Owner selftest -Plan $allPlan -Ledger $resourceLedger -SkipReclaim 2>&1 | Out-Null
& $bin\room.ps1 -Command release demo-host -Task T1 -Issue 951 -HomeBase $sandbox 2>&1 | Out-Null

# snapshot：resources 含 allocation/GPU 使用；env mismatch 只进 envWarnings（soft）
$snapResPlan = Join-Path $resRepo '.agentos\plans\PLAN-946.md'
@(
    '# PLAN-946 — snapshot resource fixture', '', '- issue: 946', '', '## Tasks', '',
    '| id | title | kind | deps | touches | resource | worktree | accept | needs |',
    '|----|-------|------|------|---------|----------|----------|--------|-------|',
    '| T1 | snapshot env warning | read | - | - | demo-host | - | ok | gpus=1;env.os=centos-7 |'
) | Set-Content -LiteralPath $snapResPlan -Encoding UTF8
& $bin\room.ps1 -Command acquire demo-host -Task SNAP -Issue 946 -Gpus 1 -HomeBase $sandbox 2>&1 | Out-Null
$snapResOut = Test-Case 'snapshot resources + envWarnings (JSON)' { & $bin\snapshot.ps1 -Repo $repo -Plan $snapResPlan } -ExpectJson -AllowAttention
& $bin\room.ps1 -Command release demo-host -Task SNAP -Issue 946 -HomeBase $sandbox 2>&1 | Out-Null
$snapResCheck = 'FAIL'
try {
    $sr = ($snapResOut | Out-String) | ConvertFrom-Json
    $demoSnap = @($sr.resources.hosts | Where-Object { $_.host -eq 'demo-host' })[0]
    $ew = @($sr.resources.envWarnings)
    if ([int]$sr.resources.gpus_used -ge 1 -and @($demoSnap.allocations).Count -ge 1 -and $ew.Count -ge 1 -and [string]$ew[0].status -eq 'mismatch' -and ((@($sr.attention) -join ' ') -notmatch 'env')) { $snapResCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'snapshot resources include GPU allocations; env warnings are soft'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $snapResCheck; Detail = '' })

# --- hygiene ---
Test-Case 'hygiene (JSON)' { & $bin\hygiene.ps1 } -AllowAttention -ExpectJson | Out-Null
Test-Case 'hygiene (Human)' { & $bin\hygiene.ps1 -Human } -AllowAttention | Out-Null

# --- projects ---
$projectsOut = Test-Case 'projects overview (JSON)' { & $bin\projects.ps1 -Root $fixtureProject } -AllowAttention -ExpectJson
Test-Case 'projects overview (Human)' { & $bin\projects.ps1 -Root $fixtureProject -Human } -AllowAttention | Out-Null

# --- audit (lease fixtures always injected) ---
Test-Case 'audit init policy (fixture, JSON)' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -PfxPath $policyPfx -PfxPassword $policyPwd -Root $fixtureProject -Ledger $auditLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson | Out-Null
$auditOut = Test-Case 'audit state-only (JSON)' { & $bin\audit.ps1 -Root $fixtureProject -Ledger $auditLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
Test-Case 'audit backfill (JSON)' { & $bin\audit.ps1 -Root $fixtureProject -Ledger $auditLedger -LeaseDir $fixtureLeases -Backfill } -ExpectJson | Out-Null
Test-Case 'audit clean after backfill (JSON)' { & $bin\audit.ps1 -Root $fixtureProject -Ledger $auditLedger -LeaseDir $fixtureLeases } -ExpectJson | Out-Null
$subagentAuditOut = Test-Case 'audit detects subagent-missing (JSON)' { & $bin\audit.ps1 -Plan $statePlanFile -Ledger $sandboxLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson

# --- audit: default current-directory root + audit-history classification ---
$auditRootsHome = Join-Path $sandbox 'audit-roots-home'
$auditRootsAgentos = Join-Path $auditRootsHome 'agentos'
$auditRootsPlans = Join-Path $auditRootsAgentos '.agentos\plans'
New-Item -ItemType Directory -Force -Path $auditRootsPlans | Out-Null
$auditRootsPlan = Join-Path $auditRootsPlans 'PLAN-930.md'
@(
    '# PLAN-930 — audit roots fixture',
    '',
    '- issue: 930',
    '',
    '## Tasks',
    '',
    '| id | title | kind | deps | touches | resource | worktree | accept |',
    '|----|-------|------|------|---------|----------|----------|--------|',
    '| T1 | audit roots task | read | - | - | none | - | scanned via default agentos root |'
) | Set-Content -LiteralPath $auditRootsPlan -Encoding UTF8
@{ T1 = @{ status = 'done'; owner = 'selftest'; prev = 'running'; updated = '2026-01-01T00:00:00' } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $auditRootsPlans 'PLAN-930.state.json') -Encoding UTF8
$auditRootsLedger = Join-Path $sandbox 'audit-roots-ledger.jsonl'
'{"event":"start","issue":"930","task":"T1","owner":"selftest","subagent":"worker-selftest","ts":"2026-01-01T00:00:00","repo":"agentos"}' | Add-Content -LiteralPath $auditRootsLedger -Encoding UTF8
'{"event":"close","issue":"930","task":"T1","owner":"selftest","ts":"2026-01-01T00:00:01","repo":"agentos"}' | Add-Content -LiteralPath $auditRootsLedger -Encoding UTF8
Test-Case 'audit roots/history fixture init policy (JSON)' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -PfxPath $policyPfx -PfxPassword $policyPwd -Root $auditRootsAgentos -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson | Out-Null

$savedAgentosHome = $env:AGENTOS_HOME
$env:AGENTOS_HOME = $auditRootsHome
$auditRootsOut = Test-Case 'audit default root is current directory (JSON)' {
    Push-Location $auditRootsAgentos
    try { & $bin\audit.ps1 -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } finally { Pop-Location }
} -ExpectJson
$env:AGENTOS_HOME = $savedAgentosHome

$auditRootsCheck = 'FAIL'
try {
    $ar = ($auditRootsOut | Out-String) | ConvertFrom-Json
    $agentosRootPath = (Resolve-Path -LiteralPath $auditRootsAgentos).Path
    if ((@($ar.roots) -contains $agentosRootPath) -and $ar.summary.plans -ge 1 -and $ar.summary.unplannedLedger -eq 0 -and
        (@($ar.unplannedLedgerIssues) -notcontains '930') -and $ar.summary.errors -eq 0) { $auditRootsCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit default root scans current directory plans'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $auditRootsCheck; Detail = '' })

$auditRootsHistory = Join-Path $auditRootsHome 'data\agentos\audit-history.json'
New-Item -ItemType Directory -Force -Path (Split-Path $auditRootsHistory -Parent) | Out-Null
@{ schema_version = 1; entries = @(@{ key = '999|T1'; reason = 'selftest historical task' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $auditRootsHistory -Encoding UTF8
'{"event":"close","issue":"999","task":"T1","owner":"selftest","ts":"2026-01-01T00:00:02","repo":"demo"}' | Add-Content -LiteralPath $auditRootsLedger -Encoding UTF8
$env:AGENTOS_HOME = $auditRootsHome
$historyOut = Test-Case 'audit history key is warning-only (JSON)' { & $bin\audit.ps1 -Root $auditRootsAgentos -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } -ExpectJson
$env:AGENTOS_HOME = $savedAgentosHome

$historyCheck = 'FAIL'
try {
    $hr = ($historyOut | Out-String) | ConvertFrom-Json
    $histFindings = @($hr.findings | Where-Object { $_.kind -eq 'unplanned-history' -and $_.issue -eq '999' -and $_.severity -eq 'warning' })
    if ($hr.summary.unplannedHistorical -eq 1 -and $hr.summary.unplannedLedger -eq 0 -and $hr.summary.errors -eq 0 -and $histFindings.Count -eq 1) { $historyCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit historical ledger key is counted separately, not an error'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $historyCheck; Detail = '' })

'{"event":"close","issue":"998","task":"T1","owner":"selftest","ts":"2026-01-01T00:00:03","repo":"demo"}' | Add-Content -LiteralPath $auditRootsLedger -Encoding UTF8
$env:AGENTOS_HOME = $auditRootsHome
$unplannedOut = Test-Case 'audit unlisted task stays unplanned (JSON)' { & $bin\audit.ps1 -Root $auditRootsAgentos -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } -ExpectJson
$env:AGENTOS_HOME = $savedAgentosHome

$unplannedCheck = 'FAIL'
try {
    $ur = ($unplannedOut | Out-String) | ConvertFrom-Json
    $issues = @($ur.unplannedLedgerIssues)
    if ($ur.summary.unplannedHistorical -eq 1 -and $ur.summary.unplannedLedger -eq 1 -and $ur.summary.errors -eq 0 -and
        ($issues -contains '998') -and ($issues -notcontains '999')) { $unplannedCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit task outside history and PLAN remains unplanned-ledger'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $unplannedCheck; Detail = '' })

Remove-Item -LiteralPath $auditRootsHistory -Force
$env:AGENTOS_HOME = $auditRootsHome
$missingHistoryOut = Test-Case 'audit missing history file is empty (JSON)' { & $bin\audit.ps1 -Root $auditRootsAgentos -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } -ExpectJson
$env:AGENTOS_HOME = $savedAgentosHome

$missingHistoryCheck = 'FAIL'
try {
    $mr = ($missingHistoryOut | Out-String) | ConvertFrom-Json
    if ($mr.summary.unplannedHistorical -eq 0 -and $mr.summary.unplannedLedger -eq 2 -and $mr.summary.errors -eq 0) { $missingHistoryCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit missing history file does not fail or waive'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $missingHistoryCheck; Detail = '' })

# 反静默豁免：issue 已有 PLAN 时，即使 issue|task 在历史清单中，也必须报 ledger-only（不能降级为 unplanned-history）。
'{"event":"close","issue":"930","task":"T2","owner":"selftest","ts":"2026-01-01T00:00:04","repo":"agentos"}' | Add-Content -LiteralPath $auditRootsLedger -Encoding UTF8
@{ schema_version = 1; entries = @(@{ key = '930|T2'; reason = 'selftest overlap: plan exists but task row missing' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $auditRootsHistory -Encoding UTF8
$env:AGENTOS_HOME = $auditRootsHome
$overlapOut = Test-Case 'audit history cannot waive ledger-only when issue has PLAN (JSON)' { & $bin\audit.ps1 -Root $auditRootsAgentos -Ledger $auditRootsLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
$env:AGENTOS_HOME = $savedAgentosHome

$overlapCheck = 'FAIL'
try {
    $ov = ($overlapOut | Out-String) | ConvertFrom-Json
    $agentosRootPath = (Resolve-Path -LiteralPath $auditRootsAgentos).Path
    $ledgerOnlyHits = @($ov.findings | Where-Object { $_.kind -eq 'ledger-only' -and $_.issue -eq '930' -and $_.task -eq 'T2' })
    $historyHits = @($ov.findings | Where-Object { $_.kind -eq 'unplanned-history' -and $_.issue -eq '930' -and $_.task -eq 'T2' })
    if ((@($ov.roots) -contains $agentosRootPath) -and $ov.summary.plans -ge 1 -and
        $ov.summary.ledgerOnly -eq 1 -and $ov.summary.unplannedHistorical -eq 0 -and
        $ov.summary.unplannedLedger -eq 2 -and $ov.summary.errors -eq 1 -and $ov.ok -eq $false -and
        $ledgerOnlyHits.Count -eq 1 -and $historyHits.Count -eq 0) { $overlapCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit PLAN issue precedence beats history: ledger-only stays an error'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $overlapCheck; Detail = '' })
Remove-Item -LiteralPath $auditRootsHistory -Force

$badHistory = Join-Path $sandbox 'audit-history-bad.json'
'{"schema_version":1,"entries":[' | Set-Content -LiteralPath $badHistory -Encoding UTF8
Test-Case 'audit invalid history JSON must fail' { & $bin\audit.ps1 -Root (Join-Path $auditRootsHome 'project') -Ledger $auditRootsLedger -HistoryFile $badHistory -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

$badHistorySchema = Join-Path $sandbox 'audit-history-bad-schema.json'
'{"schema_version":2,"entries":[]}' | Set-Content -LiteralPath $badHistorySchema -Encoding UTF8
Test-Case 'audit history schema_version != 1 must fail' { & $bin\audit.ps1 -Root (Join-Path $auditRootsHome 'project') -Ledger $auditRootsLedger -HistoryFile $badHistorySchema -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

$badHistoryNoEntries = Join-Path $sandbox 'audit-history-no-entries.json'
'{"schema_version":1}' | Set-Content -LiteralPath $badHistoryNoEntries -Encoding UTF8
Test-Case 'audit history missing entries must fail' { & $bin\audit.ps1 -Root (Join-Path $auditRootsHome 'project') -Ledger $auditRootsLedger -HistoryFile $badHistoryNoEntries -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

$badHistoryEmpty = Join-Path $sandbox 'audit-history-empty.json'
New-Item -ItemType File -Force -Path $badHistoryEmpty | Out-Null
Test-Case 'audit history empty file must fail' { & $bin\audit.ps1 -Root (Join-Path $auditRootsHome 'project') -Ledger $auditRootsLedger -HistoryFile $badHistoryEmpty -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

$badHistoryNoKey = Join-Path $sandbox 'audit-history-no-key.json'
'{"schema_version":1,"entries":[{"reason":"missing key"}]}' | Set-Content -LiteralPath $badHistoryNoKey -Encoding UTF8
Test-Case 'audit history entry without key must fail' { & $bin\audit.ps1 -Root (Join-Path $auditRootsHome 'project') -Ledger $auditRootsLedger -HistoryFile $badHistoryNoKey -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

# --- snapshot / doctor ---
$snapOut = Test-Case 'snapshot (JSON)' { & $bin\snapshot.ps1 -Repo $repo -Plan $planFile } -ExpectJson -AllowAttention
Test-Case 'snapshot (Human)' { & $bin\snapshot.ps1 -Repo $repo -Human } -AllowAttention | Out-Null
Test-Case 'doctor' { & $aos doctor } -AllowAttention -ExpectJson | Out-Null
Test-Case 'version' { & $aos version } | Out-Null

# --- 断言 snapshot 关键字段 ---
$snapCheck = 'FAIL'
try {
    $s = ($snapOut | Out-String) | ConvertFrom-Json
    if ($s.ok -eq $true -and $s.repo.issueSource -eq 'local' -and $null -ne $s.worktrees -and $null -ne $s.schedule -and $null -ne $s.sessions) { $snapCheck = 'PASS' }
} catch { $snapCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'snapshot fields (issueSource/worktrees/schedule/sessions)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $snapCheck; Detail = '' })

$projCheck = 'FAIL'
try {
    $p = ($projectsOut | Out-String) | ConvertFrom-Json
    if ($p.summary.withPlans -ge 1 -and @($p.repos | Where-Object { $_.name -eq 'demo-delivery' }).Count -eq 1) { $projCheck = 'PASS' }
} catch { $projCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'projects recursive discovery (demo-delivery)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $projCheck; Detail = '' })

$auditCheck = 'FAIL'
try {
    $a = ($auditOut | Out-String) | ConvertFrom-Json
    if ($a.summary.stateOnly -ge 1) { $auditCheck = 'PASS' }
} catch { $auditCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'audit detects state-only'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $auditCheck; Detail = '' })

$stateLedgerCheck = 'FAIL'
try {
    $events = @(Get-LedgerEventsAt $sandboxLedger)
    if (@($events | Where-Object { $_.issue -eq '903' -and $_.event -eq 'state' }).Count -ge 1) { $stateLedgerCheck = 'PASS' }
} catch { $stateLedgerCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'plan state writes ledger (issue 903)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $stateLedgerCheck; Detail = '' })

$subagentLedgerCheck = 'FAIL'
try {
    $events = @(Get-LedgerEventsAt $sandboxLedger)
    $starts = @($events | Where-Object { $_.issue -eq '900' -and $_.task -eq 'T1' -and $_.event -eq 'start' })
    if ($starts.Count -ge 1 -and $starts[$starts.Count - 1].subagent -eq 'worker-selftest') { $subagentLedgerCheck = 'PASS' }
} catch { $subagentLedgerCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'track start records subagent in ledger'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $subagentLedgerCheck; Detail = '' })

$subagentAuditCheck = 'FAIL'
try {
    $sa = ($subagentAuditOut | Out-String) | ConvertFrom-Json
    if ($sa.summary.subagentMissing -ge 1 -and @($sa.findings | Where-Object { $_.kind -eq 'subagent-missing' }).Count -ge 1) { $subagentAuditCheck = 'PASS' }
} catch { $subagentAuditCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'audit flags plan state bypass (subagent-missing)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $subagentAuditCheck; Detail = '' })

$reconcileCheck = 'FAIL'
try {
    $st = Get-Content -LiteralPath $planStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.T1.status -eq 'done' -and $st.T2.status -eq 'done') { $reconcileCheck = 'PASS' }
} catch { $reconcileCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'track close reconciles stale state to ledger'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $reconcileCheck; Detail = '' })

$reclaimCheck = 'FAIL'
try {
    $c = ($closeOut | Out-String) | ConvertFrom-Json
    $att = (@($c.attention) -join ' | ')
    $dirtyFile = Join-Path $dirtyWt 'dirty.txt'
    $cleanIntact = Test-Path -LiteralPath $cleanWt
    $dirtyIntact = Test-Path -LiteralPath $dirtyWt
    $fileIntact = (Test-Path -LiteralPath $dirtyFile) -and ((Get-Content -LiteralPath $dirtyFile -Raw -Encoding UTF8).Trim() -eq 'keep me')
    $allInvoked = ($c.reclaim.audit.invoked -eq $true) -and ($c.reclaim.worktrees.invoked -eq $true) -and ($c.reclaim.hygiene.invoked -eq $true)
    if ($c.reclaim.mode -eq 'read-only' -and $c.reclaim.destructiveApplied -eq $false -and
        $c.reclaim.worktrees.dryRun -eq $true -and $c.reclaim.hygiene.dryRun -eq $true -and
        $allInvoked -and $c.reclaim.worktrees.candidates -ge 1 -and $c.reclaim.worktrees.dirty -ge 1 -and
        $cleanIntact -and $dirtyIntact -and $fileIntact -and
        $att -match 'audit' -and $att -match 'stale' -and $att -match 'dirty' -and $att -match 'safe candidates') { $reclaimCheck = 'PASS' }
} catch { $reclaimCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'track close reclaim is read-only and keeps dirty/clean worktrees'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $reclaimCheck; Detail = '' })

$legacyCheck = 'FAIL'
try {
    $c = ($closeOut | Out-String) | ConvertFrom-Json
    if ($c.reclaim.audit.subagentMissing -eq 0 -and $c.reclaim.audit.subagentWaived -ge 1 -and $c.reclaim.audit.policy.mode -eq 'active') { $legacyCheck = 'PASS' }
} catch { $legacyCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'audit waives pre-policy subagent gaps (no forged start)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $legacyCheck; Detail = '' })

$policyCheck = 'FAIL'
try {
    $policyPath = Join-Path $sandbox 'subagent-policy.json'
    if (Test-Path -LiteralPath $policyPath) {
        $pj = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pj.since -and $pj.thumbprint) { $policyCheck = 'PASS' }
    }
} catch { $policyCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'track start activates signed subagent policy file'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $policyCheck; Detail = '' })

$signedCheck = 'FAIL'
try {
    $events = @(Get-LedgerEventsAt $sandboxLedger)
    $pe = @($events | Where-Object { $_.event -eq 'policy' })
    if ($pe.Count -ge 1 -and $pe[0].sig.alg -eq 'RS256' -and $pe[0].sig.thumbprint -and $pe[0].sig.value -and $pe[0].sig.cert) { $signedCheck = 'PASS' }
} catch { $signedCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'policy events carry PFX signature + thumbprint'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $signedCheck; Detail = '' })

$sessCheck = 'FAIL'
try {
    $sl = ($sessListOut | Out-String) | ConvertFrom-Json
    $sa = ($sessListAfter | Out-String) | ConvertFrom-Json
    $hit = @($sl.items | Where-Object { $_.id -eq $sid -and $_.issue -eq '925' -and $_.task -eq 'T1' -and $_.host -eq 'demo-host' })
    if ($sid -and $hit.Count -ge 1 -and $sl.count -ge 1 -and $sa.count -eq 0) { $sessCheck = 'PASS' }
} catch { $sessCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'session binds task/host; close removes from open list'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $sessCheck; Detail = '' })

$sessLedgerCheck = 'FAIL'
try {
    $events = @(Get-LedgerEventsAt $sandboxLedger)
    if (@($events | Where-Object { $_.event -eq 'session-register' -and $_.session -eq $sid }).Count -ge 1 -and
        @($events | Where-Object { $_.event -eq 'session-heartbeat' -and $_.session -eq $sid }).Count -ge 1 -and
        @($events | Where-Object { $_.event -eq 'session-close' -and $_.session -eq $sid }).Count -ge 1) { $sessLedgerCheck = 'PASS' }
} catch { $sessLedgerCheck = 'FAIL' }
$results.Add([pscustomobject]@{ Case = 'session events live only in unified ledger'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $sessLedgerCheck; Detail = '' })

Write-Output ''
# --- P1-1 policy / legacy close / no-policy behavior ---
$noPolicyRepo = Join-Path $sandbox 'no-policy-repo'
New-Item -ItemType Directory -Force -Path $noPolicyRepo | Out-Null
& $aos plan new -Issue 920 -Title 'no-policy' -Repo $noPolicyRepo 2>&1 | Out-Null
$noPolicyPlan = Join-Path $noPolicyRepo '.agentos\plans\PLAN-920.md'
$noPolicyLedger = Join-Path $sandbox 'no-policy-ledger.jsonl'
& $aos plan state -Plan $noPolicyPlan -Task T1 -Status done -Owner selftest -Ledger $noPolicyLedger 2>&1 | Out-Null
$noPolicyOut = Test-Case 'audit no policy is not silently waived (JSON)' { & $bin\audit.ps1 -Plan $noPolicyPlan -Ledger $noPolicyLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
$savedPfx = $env:AGENTOS_POLICY_PFX
$savedPwd = $env:AGENTOS_POLICY_PFX_PASSWORD
$env:AGENTOS_POLICY_PFX = ''
$env:AGENTOS_POLICY_PFX_PASSWORD = ''
Test-Case 'audit -InitPolicy without PFX must fail' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -Plan $noPolicyPlan -Ledger $noPolicyLedger } -ExpectThrow | Out-Null
Test-Case 'audit -InitPolicy future must fail' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -SubagentSince '2999-01-01T00:00:00' -PfxPath $policyPfx -PfxPassword $policyPwd -Plan $noPolicyPlan -Ledger $noPolicyLedger } -ExpectThrow | Out-Null
Test-Case 'audit override without -AuthorizedBy must fail' { & $bin\audit.ps1 -SubagentSince '2000-01-01T00:00:00' -PfxPath $policyPfx -PfxPassword $policyPwd -Plan $noPolicyPlan -Ledger $noPolicyLedger } -ExpectThrow | Out-Null
$env:AGENTOS_POLICY_PFX = $savedPfx
$env:AGENTOS_POLICY_PFX_PASSWORD = $savedPwd
$overrideOut = Test-Case 'audit override with authorization (JSON)' { & $bin\audit.ps1 -SubagentSince '2000-01-01T00:00:00' -AuthorizedBy selftest -PfxPath $policyPfx -PfxPassword $policyPwd -Plan $noPolicyPlan -Ledger $noPolicyLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
Start-Sleep -Seconds 1
$initOut = Test-Case 'audit -InitPolicy explicit waiver (JSON)' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -PfxPath $policyPfx -PfxPassword $policyPwd -Plan $noPolicyPlan -Ledger $noPolicyLedger -LeaseDir $fixtureLeases } -ExpectJson

$noPolicyCheck = 'FAIL'
try {
    $np = ($noPolicyOut | Out-String) | ConvertFrom-Json
    if ($np.subagentPolicy.mode -eq 'missing' -and $np.summary.subagentMissing -ge 1 -and $np.summary.errors -ge 2 -and @($np.findings | Where-Object { $_.kind -eq 'policy-missing' }).Count -ge 1) { $noPolicyCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'no policy is not silently waived'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $noPolicyCheck; Detail = '' })

$overrideCheck = 'FAIL'
try {
    $events = @(Get-LedgerEventsAt $noPolicyLedger)
    $ev = @($events | Where-Object { $_.event -eq 'policy' -and $_.source -eq 'audit-override' -and $_.authorizedBy -eq 'selftest' -and $_.sig.value })
    if ($ev.Count -ge 1) { $overrideCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'policy override is authorized, signed and ledger-traced'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $overrideCheck; Detail = '' })

$initCheck = 'FAIL'
try {
    $io = ($initOut | Out-String) | ConvertFrom-Json
    if ($io.subagentPolicy.mode -eq 'active' -and $io.summary.subagentWaived -ge 1 -and $io.summary.subagentMissing -eq 0) { $initCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'explicit init waives legacy boundary visibly'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $initCheck; Detail = '' })

$legacyPlan = Join-Path $repo '.agentos\plans\PLAN-921.md'
& $aos plan new -Issue 921 -Title 'legacy-close' -Repo $repo 2>&1 | Out-Null
'{"event":"start","issue":"921","task":"T1","owner":"selftest","ts":"2026-01-01T00:00:00","repo":"demo-repo"}' | Add-Content -LiteralPath $sandboxLedger -Encoding UTF8
$legacyCloseOut = Test-Case 'track close legacy task (JSON)' { & $aos track close -Issue 921 -Task T1 -Owner selftest -Plan $legacyPlan -Ledger $sandboxLedger -SkipReclaim } -ExpectJson
$legacyCloseCheck = 'FAIL'
try {
    $lc = ($legacyCloseOut | Out-String) | ConvertFrom-Json
    if ($lc.subagentStatus -eq 'legacy' -and $lc.subagentMissing -eq $false -and ((@($lc.attention) -join ' ') -notmatch 'no start event with -Subagent')) { $legacyCloseCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'legacy close does not report false subagentMissing'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $legacyCloseCheck; Detail = '' })

# --- round-3 security tests: raw / tampered / wrong-key policy ---
$forgedRepo = Join-Path $sandbox 'forged-repo'
New-Item -ItemType Directory -Force -Path $forgedRepo | Out-Null
& $aos plan new -Issue 922 -Title 'forged' -Repo $forgedRepo 2>&1 | Out-Null
$forgedPlan = Join-Path $forgedRepo '.agentos\plans\PLAN-922.md'
$forgedLedger = Join-Path $sandbox 'forged-ledger.jsonl'
& $aos plan state -Plan $forgedPlan -Task T1 -Status done -Owner selftest -Ledger $forgedLedger 2>&1 | Out-Null
'{"event":"policy","issue":"","task":"","since":"2000-01-01T00:00:00","source":"forged","authorizedBy":"","ts":"2026-01-01T00:00:00"}' | Add-Content -LiteralPath $forgedLedger -Encoding UTF8
$forgedOut = Test-Case 'forged raw (unsigned) policy rejected (JSON)' { & $bin\audit.ps1 -Plan $forgedPlan -Ledger $forgedLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
$forgedCheck = 'FAIL'
try { $fo = ($forgedOut | Out-String) | ConvertFrom-Json; if ($fo.subagentPolicy.mode -eq 'invalid' -and $fo.summary.subagentWaived -eq 0 -and $fo.summary.subagentMissing -ge 1 -and @($fo.findings | Where-Object { $_.kind -eq 'policy-invalid' }).Count -ge 1) { $forgedCheck = 'PASS' } } catch { }
$results.Add([pscustomobject]@{ Case = 'forged raw policy cannot waive gaps'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $forgedCheck; Detail = '' })

# tampered signature: valid policy event with mutated since (retains old signature)
$tamperLedger = Join-Path $sandbox 'tamper-ledger.jsonl'
Test-Case 'audit init tamper fixture (JSON)' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -PfxPath $policyPfx -PfxPassword $policyPwd -Plan $forgedPlan -Ledger $tamperLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson | Out-Null
$tamperEvents = @(Get-LedgerEventsAt $tamperLedger)
$tamperPolicy = @($tamperEvents | Where-Object { $_.event -eq 'policy' })[0]
if ($tamperPolicy) {
    $tamperPolicy.since = '2000-01-01T00:00:00'
    ($tamperPolicy | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $tamperLedger -Encoding UTF8
}
$tamperOut = Test-Case 'tampered signed policy rejected (JSON)' { & $bin\audit.ps1 -Plan $forgedPlan -Ledger $tamperLedger -LeaseDir $fixtureLeases } -AllowAttention -ExpectJson
$tamperCheck = 'FAIL'
try { $to = ($tamperOut | Out-String) | ConvertFrom-Json; if ($to.subagentPolicy.mode -eq 'invalid' -and $to.subagentPolicy.error -match 'signature') { $tamperCheck = 'PASS' } } catch { }
$results.Add([pscustomobject]@{ Case = 'tampered policy signature cannot waive gaps'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $tamperCheck; Detail = '' })

Test-Case 'policy key mismatch refused' { & $bin\audit.ps1 -InitPolicy -AuthorizedBy selftest -PfxPath $policyPfx2 -PfxPassword $policyPwd -Plan $forgedPlan -Ledger $sandboxLedger -LeaseDir $fixtureLeases } -ExpectThrow | Out-Null

& $aos plan new -Issue 923 -Title 'tamper' -Repo $repo 2>&1 | Out-Null
$tamperRepoLedger = Join-Path $sandbox 'tamper-repo-ledger.jsonl'
'{"event":"policy","issue":"","task":"","since":"2999-01-01T00:00:00","source":"track-start","authorizedBy":"attacker","ts":"2026-01-01T00:00:00"}' | Add-Content -LiteralPath $tamperRepoLedger -Encoding UTF8
Test-Case 'track start refuses unsigned/future policy' { & $aos track start -Issue 923 -Task T1 -Owner selftest -Plan (Join-Path $repo '.agentos\plans\PLAN-923.md') -Subagent 'worker-selftest' -Ledger $tamperRepoLedger } -ExpectThrow | Out-Null

# --- cross-layer: lease vs open agent tasks (warnings only) ---
$crossLeases = Join-Path $sandbox 'cross-leases'
New-Item -ItemType Directory -Force -Path $crossLeases | Out-Null
@{
    schema_version = 2; host = 'demo-host'; updated_at = '2026-01-01T00:00:00Z';
    allocations = @(@{ task = 'T9'; issue = '940'; agent_task = 'nobody'; gpus = @(0); acquired_at = '2026-01-01T00:00:00Z'; note = '' })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $crossLeases 'demo-host.json') -Encoding UTF8
$crossOut = Test-Case 'audit cross-layer stale lease is warning (JSON)' { & $bin\audit.ps1 -Plan $noPolicyPlan -Ledger $noPolicyLedger -LeaseDir $crossLeases } -AllowAttention -ExpectJson
$crossCheck = 'FAIL'
try {
    $xo = ($crossOut | Out-String) | ConvertFrom-Json
    if ($xo.crossLayer.errors -eq 0 -and @($xo.crossLayer.findings | Where-Object { $_.kind -eq 'lease-stale' }).Count -ge 1) { $crossCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit cross-layer flags lease without open task'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $crossCheck; Detail = '' })

# open agent task older than grace with no matching lease -> agent-task-no-lease warning
$noLeaseRepo = Join-Path $sandbox 'no-lease-repo'
New-Item -ItemType Directory -Force -Path $noLeaseRepo | Out-Null
& $aos plan new -Issue 941 -Title 'no-lease' -Repo $noLeaseRepo 2>&1 | Out-Null
$noLeasePlan = Join-Path $noLeaseRepo '.agentos\plans\PLAN-941.md'
$noLeaseLedger = Join-Path $sandbox 'no-lease-ledger.jsonl'
& $aos track start -Issue 941 -Task T1 -Owner selftest -Plan $noLeasePlan -Subagent 'worker-selftest' -Ledger $noLeaseLedger 2>&1 | Out-Null
$noLeaseOut = Test-Case 'audit cross-layer open task without lease is warning (JSON)' { & $bin\audit.ps1 -Plan $noLeasePlan -Ledger $noLeaseLedger -LeaseDir $crossLeases -CrossLayerGraceMinutes 0 } -AllowAttention -ExpectJson
$noLeaseCheck = 'FAIL'
try {
    $nl = ($noLeaseOut | Out-String) | ConvertFrom-Json
    if ($nl.crossLayer.errors -eq 0 -and @($nl.crossLayer.findings | Where-Object { $_.kind -eq 'agent-task-no-lease' }).Count -ge 1) { $noLeaseCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'audit cross-layer flags open task without lease'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $noLeaseCheck; Detail = '' })
# --- public release surface: version / doctor / install dry-run / layout ---
$versionOut = Test-Case 'version is 0.2.0' { & $aos version }
$versionCheck = 'FAIL'
try {
    if ((($versionOut | Out-String).Trim() -eq 'agentos 0.2.0')) { $versionCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'version reports 0.2.0'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $versionCheck; Detail = '' })

$doctorCheck = 'FAIL'
try {
    $docOut = & $aos doctor 2>&1 | Out-String
    $docJson = $docOut | ConvertFrom-Json
    $internalWord = 'driver' + 'core'
    $badChecks = @($docJson.checks | Where-Object { (($_.Group + '/' + $_.Item) -match $internalWord) -or ($_.Item -match 'harness adapters') })
    if ($docJson.agentos -eq '0.2.0' -and @($docJson.checks).Count -eq 9 -and $badChecks.Count -eq 0) { $doctorCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'doctor checks public layout only and reports 0.2.0'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $doctorCheck; Detail = '' })

$layoutBad = @('driver' + 'core', '.agentos', 'data', 'devops')
$layoutPresent = @($layoutBad | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) })
$layoutCheck = if ($layoutPresent.Count -eq 0) { 'PASS' } else { 'FAIL present=' + ($layoutPresent -join ',') }
$results.Add([pscustomobject]@{ Case = 'public tree excludes internal data / driver directories'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $layoutCheck; Detail = '' })

$installOut = Test-Case 'install.ps1 dry-run installs only agentos skill' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') -Target claude -NoRules -NoPath -DryRun
}
$installCheck = 'FAIL'
try {
    $it = ($installOut | Out-String)
    $extraA = 'dev' + 'center-workflow'
    $extraB = 'skill' + '-creator'
    if ($it -match 'agentos' -and $it -match 'DRY-RUN' -and $it -notmatch $extraA -and $it -notmatch $extraB) { $installCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'install.ps1 dry-run lists only the agentos skill'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $installCheck; Detail = '' })

# --- close no-Reap via sandbox bin copy (no production seam, no production mutation) ---
$noReapPlan = Join-Path $repo '.agentos\plans\PLAN-924.md'
& $aos plan new -Issue 924 -Title 'close-no-reap' -Repo $repo 2>&1 | Out-Null
& $aos track start -Issue 924 -Task T1 -Owner selftest -Plan $noReapPlan -Subagent 'worker-selftest' -Ledger $sandboxLedger 2>&1 | Out-Null
$binCopy = Join-Path $sandbox 'bin-copy'
New-Item -ItemType Directory -Force -Path $binCopy | Out-Null
Copy-Item -Path (Join-Path $bin '*') -Destination $binCopy -Recurse -Force
$reapLog = Join-Path $sandbox 'hygiene-reap.log'
$fixture = $null
$fixturePid = 0
$fixtureAlive = $false
$closeNoReapOut = ''
try {
    $fixture = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
    $fixturePid = [int]$fixture.Id
    Start-Sleep -Milliseconds 600
    $wrapper = @'
param([switch]$Reap)
"$Reap" | Add-Content -LiteralPath '__LOG__' -Encoding UTF8
if ($Reap) { Stop-Process -Id __PID__ -Force -ErrorAction SilentlyContinue }
Write-Output '{"ok":true,"dryRun":true,"leaked":0,"attention":[]}'
exit 0
'@.Replace('__LOG__', $reapLog).Replace('__PID__', [string]$fixturePid)
    Set-Content -LiteralPath (Join-Path $binCopy 'hygiene.ps1') -Value $wrapper -Encoding UTF8
    $closeNoReapOut = Test-Case 'track close no-Reap (sandbox copy, JSON)' { & (Join-Path $binCopy 'track.ps1') -Command close -Issue 924 -Task T1 -Owner selftest -Plan $noReapPlan -Ledger $sandboxLedger } -ExpectJson
    $fixtureAlive = [bool](Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)
} finally {
    if ($fixturePid -gt 0 -and (Get-Process -Id $fixturePid -ErrorAction SilentlyContinue)) { Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue }
}
$noReapCheck = 'FAIL'
try {
    $c = ($closeNoReapOut | Out-String) | ConvertFrom-Json
    $log = if (Test-Path -LiteralPath $reapLog) { Get-Content -LiteralPath $reapLog -Raw -Encoding UTF8 } else { '' }
    $dirtyFile = Join-Path $dirtyWt 'dirty.txt'
    $dirtyOk = (Test-Path -LiteralPath $dirtyWt) -and (Test-Path -LiteralPath $dirtyFile) -and ((Get-Content -LiteralPath $dirtyFile -Raw -Encoding UTF8).Trim() -eq 'keep me')
    if ($fixtureAlive -and ($log -match 'False') -and ($log -notmatch 'True') -and ($c.reclaim.destructiveApplied -eq $false) -and ($c.reclaim.hygiene.dryRun -eq $true) -and $dirtyOk) { $noReapCheck = 'PASS' }
} catch { }
$results.Add([pscustomobject]@{ Case = 'track close does not call hygiene -Reap (sandbox, dirty kept)'; Exit = 0; Want = 0; Json = 'ok'; Ms = 0; Status = $noReapCheck; Detail = '' })

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
    if (Test-Path -LiteralPath $cleanWt) { & git -C $repo worktree remove --force $cleanWt 2>&1 | Out-Null }
    if (Test-Path -LiteralPath $dirtyWt) { & git -C $repo worktree remove --force $dirtyWt 2>&1 | Out-Null }
    & git -C $repo branch -D 'task/900-clean' 'task/900-dirty' 2>&1 | Out-Null
    & git -C $repo worktree prune 2>&1 | Out-Null
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'sandbox removed'
} else {
    Write-Output ("sandbox kept: " + $sandbox)
}

if ($fail.Count -gt 0) { exit 1 }
exit 0
