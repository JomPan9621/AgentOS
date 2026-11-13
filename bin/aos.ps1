<#
.SYNOPSIS
  AgentOS 统一入口：Claude Code / Codex / DSH 三工具共用同一套执行框架。
.DESCRIPTION
  默认输出 JSON（AI-native）；人类可读渲染走 -Human。
  退出码：0 成功 / 1 错误 / 2 需治理。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'wt', 'issue', 'track', 'session', 'snapshot', 'projects', 'room', 'hygiene', 'artifact', 'gc', 'audit', 'doctor', 'version', 'help')]
    [string]$Command = 'help',
    [switch]$Human,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$bin = $PSScriptRoot

function Show-Help {
    Write-Output 'AgentOS - unified agent execution framework'
    Write-Output ''
    Write-Output 'usage: aos <command> [args...]'
    Write-Output ''
    Write-Output '  snapshot  one-call JSON state for agents (exit 2 = needs attention)
  projects  cross-repo overview: plans / active / worktrees / issue source
  room      remote resources: list / check / acquire / release machine leases
  hygiene   harness process hygiene: detect leaked helper processes, report machine pressure'
    Write-Output '  artifact  generated files home: path | list  (fixed under <homebase>\devops\agentos\artifacts)'
    Write-Output '  plan      new | validate | graph | next | state | show'
    Write-Output '  wt        list | new | status | prune'
    Write-Output '  issue     detect | new | show | list'
    Write-Output '  track     start | review | close | block | abandon | claim | release | handoff | who | list | lost'
    Write-Output '            close -Plan auto-reconciles state/ledger and runs read-only audit / wt prune / hygiene'
    Write-Output '            -SkipReclaim is for tests/batch close only; destructive -Apply/-Reap is never automatic'
    Write-Output '  session   register | heartbeat | close | list  (harness presence; bound to a tracked task; ledger-only)'
    Write-Output '  audit     PLAN / state / ledger / lease reconciliation; -Backfill restores provable gaps'
    Write-Output '            -InitPolicy requires -PfxPath/-PfxPassword; policy events are PFX-signed and append-only'
    Write-Output '  gc        lifecycle reclaim: ledger compaction + closed-plan archive (dry-run by default)'
    Write-Output '  doctor    unification self-check across the three agents'
    Write-Output '  version'
    Write-Output ''
    Write-Output 'typical flow:'
    Write-Output '  aos snapshot -Repo <path>'
    Write-Output '  aos issue detect -Repo <path>'
    Write-Output '  aos plan new -Issue 271 -Title "..." -Repo <path>'
    Write-Output '  aos plan validate -Plan <file>'
    Write-Output '  aos plan graph -Plan <file>'
    Write-Output '  aos wt new -Issue 271 -Slug attn-fence -Repo <path>'
    Write-Output '  aos track start -Issue 271 -Task T1 -Owner codex -Plan <file> -Subagent <label>'
    Write-Output '  aos track close -Issue 271 -Task T1 -Plan <file>   # auto reconcile + read-only checks'
    Write-Output '  aos session register -Issue 271 -Task T1 -Role worker -Host <machine>'
    Write-Output '  aos session heartbeat -Id <sid>'
    Write-Output '  aos session close -Id <sid>'
    Write-Output '  aos track who                                   # who holds what, what is claimable'
    Write-Output '  aos track claim -Issue 271 -Task T1 -Owner dsh   # take over another harness task'
    Write-Output '  aos wt prune            # dry-run inventory'
}

function ConvertTo-Args {
    param([string[]]$Items)

    $named = @{}
    $pos = @()
    $i = 0
    while ($i -lt $Items.Count) {
        $a = $Items[$i]
        if ($a -match '^--?(?<k>[A-Za-z][A-Za-z0-9]*)$') {
            $k = $Matches['k']
            $hasValue = ($i + 1 -lt $Items.Count) -and -not ($Items[$i + 1] -match '^--?[A-Za-z]')
            if ($hasValue) {
                $named[$k] = $Items[$i + 1]
                $i += 2
            } else {
                $named[$k] = $true
                $i += 1
            }
            continue
        }
        $pos += $a
        $i += 1
    }
    return [pscustomobject]@{ Named = $named; Positional = $pos }
}

function Invoke-Sub {
    param([string]$ScriptName)

    $child = Join-Path $bin $ScriptName
    $clean = @($Rest | Where-Object { $null -ne $_ -and "$_" -ne '' })
    $parsed = ConvertTo-Args $clean

    if ($parsed.Positional.Count -eq 0) {
        $named0 = $parsed.Named
        if ($Human) { $named0['Human'] = $true }
        & $child @named0
        $c0 = $LASTEXITCODE
        if ($null -ne $c0 -and $c0 -ne 0) { exit $c0 }
        return
    }

    $sub = $parsed.Positional[0]
    $named = $parsed.Named
    if ($Human) { $named['Human'] = $true }
    # 位置参数 1..n 透传给子脚本（例如 "aos room acquire <host>" 的 host）
    if ($parsed.Positional.Count -gt 1) {
        $restPos = @($parsed.Positional[1..($parsed.Positional.Count - 1)])
        & $child -Command $sub @restPos @named
    } else {
        & $child -Command $sub @named
    }
    $code = $LASTEXITCODE
    if ($null -ne $code -and $code -ne 0) { exit $code }
}

function Invoke-Doctor {
    param([switch]$HumanOut)

    $home_ = [Environment]::GetFolderPath('UserProfile')
    $rows = [System.Collections.Generic.List[object]]::new()

    $need = @('plan.ps1', 'wt.ps1', 'issue.ps1', 'track.ps1', 'session.ps1', 'snapshot.ps1', 'projects.ps1', 'room.ps1', 'hygiene.ps1', 'artifact.ps1', 'gc.ps1', 'audit.ps1', 'ledger.ps1')
    $missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bin $_)) })
    $detail = if ($missing.Count -gt 0) { 'missing ' + ($missing -join ',') } else { ('{0}/{0} present' -f $need.Count) }
    $rows.Add([pscustomobject]@{ Group = 'scripts'; Item = 'bin'; Ok = ($missing.Count -eq 0); Detail = $detail })

    $repoSkill = Join-Path $bin '..\skills\agentos\SKILL.md'
    $repoHash = ''
    if (Test-Path -LiteralPath $repoSkill) {
        $repoHash = (Get-FileHash -LiteralPath $repoSkill -Algorithm MD5).Hash
    }

    $agents = @(
        @{ Name = 'claude'; Skill = (Join-Path $home_ '.claude\skills\agentos'); Rules = (Join-Path $home_ '.claude\CLAUDE.md') },
        @{ Name = 'codex';  Skill = (Join-Path $home_ '.codex\skills\agentos');  Rules = (Join-Path $home_ '.codex\AGENTS.md') },
        @{ Name = 'dsh';    Skill = (Join-Path $home_ '.dsh\skills\agentos');    Rules = (Join-Path $home_ '.dsh\AGENTS.md') }
    )

    foreach ($a in $agents) {
        $sk = Join-Path $a.Skill 'SKILL.md'
        $skillOk = $false
        $skillDetail = 'missing'
        if (Test-Path -LiteralPath $sk) {
            $h = (Get-FileHash -LiteralPath $sk -Algorithm MD5).Hash
            if ($h -eq $repoHash -and $repoHash -ne '') {
                $skillOk = $true
                $skillDetail = 'match'
            } else {
                $skillDetail = 'differs from repo'
            }
        }
        $rows.Add([pscustomobject]@{ Group = 'skill'; Item = $a.Name; Ok = $skillOk; Detail = $skillDetail })

        $rulesOk = $false
        $rulesDetail = 'missing'
        if (Test-Path -LiteralPath $a.Rules) {
            $t = [System.IO.File]::ReadAllText($a.Rules, [System.Text.Encoding]::UTF8)
            if ($t.Contains('agentos managed (global)')) {
                $rulesOk = $true
                $rulesDetail = 'block present'
            } else {
                $rulesDetail = 'block absent'
            }
        }
        $rows.Add([pscustomobject]@{ Group = 'rules'; Item = $a.Name; Ok = $rulesOk; Detail = $rulesDetail })
    }

    $binDir = Join-Path $home_ '.agentos\bin'
    $shim = Join-Path $binDir 'aos.cmd'
    $shimOk = Test-Path -LiteralPath $shim
    $shimDetail = if ($shimOk) { $shim } else { 'missing' }
    $rows.Add([pscustomobject]@{ Group = 'path'; Item = 'shim'; Ok = $shimOk; Detail = $shimDetail })

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = $false
    if ($userPath) { $onPath = (($userPath -split ';') -contains $binDir) }
    $pathDetail = if ($onPath) { 'present' } else { 'absent' }
    $rows.Add([pscustomobject]@{ Group = 'path'; Item = 'user PATH'; Ok = $onPath; Detail = $pathDetail })

    $failed = @($rows | Where-Object { -not $_.Ok })
    $scriptsOk = ($missing.Count -eq 0)

    if ($HumanOut) {
        $rows | Format-Table Group, Item, Ok, Detail -AutoSize
        Write-Output ''
        if ($scriptsOk -and $failed.Count -eq 0) {
            Write-Output 'doctor: three agents unified on AgentOS'
        } elseif ($scriptsOk) {
            Write-Output ('doctor: ' + $failed.Count + ' item(s) not ready (run install.ps1)')
        } else {
            Write-Output 'doctor: scripts missing'
        }
    } else {
        $payload = [pscustomobject]@{
            ok      = ($scriptsOk -and $failed.Count -eq 0)
            agentos = '0.3.0'
            checks  = @($rows)
            failed  = @($failed | ForEach-Object { $_.Group + '/' + $_.Item })
        }
        $payload | ConvertTo-Json -Depth 6
    }

    if (-not $scriptsOk) { exit 1 }
    if ($failed.Count -gt 0) { exit 2 }
    exit 0
}

$humanOut = $Human -or (@($Rest) -contains '-Human')

switch ($Command) {
    'plan' { Invoke-Sub 'plan.ps1' }
    'wt' { Invoke-Sub 'wt.ps1' }
    'issue' { Invoke-Sub 'issue.ps1' }
    'track' { Invoke-Sub 'track.ps1' }
    'session' { Invoke-Sub 'session.ps1' }
    'snapshot' { Invoke-Sub 'snapshot.ps1' }
    'projects' { Invoke-Sub 'projects.ps1' }
    'hygiene' { Invoke-Sub 'hygiene.ps1' }
    'artifact' { Invoke-Sub 'artifact.ps1' }
    'room' { Invoke-Sub 'room.ps1' }
    'gc' { Invoke-Sub 'gc.ps1' }
    'audit' { Invoke-Sub 'audit.ps1' }
    'doctor' { Invoke-Doctor -HumanOut:$humanOut }
    'version' { Write-Output 'agentos 0.3.0'; exit 0 }
    default { Show-Help; exit 0 }
}
