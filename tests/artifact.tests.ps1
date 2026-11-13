<#
.SYNOPSIS
  AgentOS artifact 命令测试：固定根、目录结构、路径安全、只读 list、仓库不被污染。
.DESCRIPTION
  全部写入限制在 AGENTOS_HOME 沙箱内（<homebase>/devops/agentos/artifact-tests/<stamp>）。
  不触碰真实 data/agentos/hosts.json、ledger 或其他 worktree。
  exit 0 = 全部通过；exit 1 = 有失败
#>
[CmdletBinding()]
param(
    [switch]$KeepSandbox
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$aos = Join-Path $root 'bin\aos.ps1'
$artifact = Join-Path $root 'bin\artifact.ps1'

$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path $root -Parent }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$sandbox = Join-Path (Join-Path (Join-Path $homeBase 'devops\agentos') 'artifact-tests') $stamp
# 全程隔离：artifact 固定根落在 sandbox 内
$env:AGENTOS_HOME = $sandbox
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $sandbox 'devops\agentos\artifacts'))
Write-Output ('sandbox: ' + $sandbox)

function Get-RepoStatus {
    try {
        $out = (& git -C $root status --porcelain 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out.Trim()
    } catch {
        return $null
    }
}
$statusBefore = Get-RepoStatus

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Case, [string]$Status, [string]$Detail = '')
    $results.Add([pscustomobject]@{
            Case   = $Case
            Status = $Status
            Detail = $Detail
        })
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [scriptblock]$Run,
        [int]$ExpectExit = 0,
        [switch]$ExpectJson,
        [scriptblock]$Check
    )

    $out = ''
    $code = 0
    $err = ''
    try {
        $out = (& $Run 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $err = $_.Exception.Message
        $code = 99
    }

    $jsonOk = $true
    if ($ExpectJson -and -not $err -and $code -eq $ExpectExit) {
        try { $null = ($out | ConvertFrom-Json) } catch { $jsonOk = $false }
    }

    $checkOk = $true
    $checkDetail = ''
    if (-not $err -and $code -eq $ExpectExit -and $jsonOk -and $null -ne $Check) {
        try {
            $r = & $Check $out
            $isPair = ($r -is [System.Collections.IList]) -and ($r.Count -eq 2) -and ($r[0] -is [bool])
            if ($isPair) {
                $checkOk = [bool]$r[0]
                $checkDetail = [string]$r[1]
            } else {
                $checkOk = [bool]$r
            }
        } catch {
            $checkOk = $false
            $checkDetail = $_.Exception.Message
        }
    }

    $detailParts = @()
    if ($err) { $detailParts += $err }
    if (-not $jsonOk) { $detailParts += 'invalid JSON' }
    if ($checkDetail) { $detailParts += $checkDetail }
    if ($code -ne $ExpectExit) { $detailParts += ('exit=' + $code + ' want=' + $ExpectExit) }

    $pass = (-not $err) -and ($code -eq $ExpectExit) -and $jsonOk -and $checkOk
    Add-Result $Name $(if ($pass) { 'PASS' } else { 'FAIL' }) ($detailParts -join ' | ')
    return $out
}

function Test-Subdirs {
    param([string]$RunPath)
    return @(@('screenshots', 'html', 'reports', 'traces') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RunPath $_)) })
}

# --- 1. 空根 list：固定根正确，且只读不创建 ---
Invoke-TestCase 'artifact list on empty root returns fixed root without creating it (JSON)' {
    & $aos artifact list -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $rootFull = [IO.Path]::GetFullPath($artifactRoot).TrimEnd('\')
    $got = [IO.Path]::GetFullPath([string]$j.root).TrimEnd('\')
    $items = @($j.items)
    if (($j.ok -eq $true) -and ($j.count -eq 0) -and ($items.Count -eq 0) -and ($got -eq $rootFull) -and (-not (Test-Path -LiteralPath $artifactRoot))) {
        return $true
    }
    return @($false, ('ok=' + $j.ok + ' count=' + $j.count + ' root=' + $j.root + ' exists=' + (Test-Path -LiteralPath $artifactRoot)))
} | Out-Null

# --- 2. path 通过 aos：固定根 + 目录结构 ---
$runA = Join-Path $artifactRoot 'demo-repo\100\T1\run-a'
Invoke-TestCase 'artifact path via aos creates fixed root structure (JSON)' {
    & $aos artifact path -Repo 'demo-repo' -Issue '100' -Task 'T1' -RunId 'run-a' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $runFull = [IO.Path]::GetFullPath($runA).TrimEnd('\')
    $got = [IO.Path]::GetFullPath([string]$j.path).TrimEnd('\')
    $missing = @(Test-Subdirs $runA)
    if (($j.ok -eq $true) -and ($got -eq $runFull) -and (Test-Path -LiteralPath $runA) -and ($missing.Count -eq 0) -and ($j.created -eq $true)) {
        return $true
    }
    return @($false, ('path=' + $j.path + ' missing=' + ($missing -join ',')))
} | Out-Null

# --- 3. 直接调用 artifact.ps1，默认 run-id 为时间戳 ---
Invoke-TestCase 'artifact.ps1 direct call uses timestamp run id (JSON)' {
    & $artifact -Command path -Repo 'demo-repo' -Issue '100' -Task 'T2' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $runId = [string]$j.runId
    $dir = Join-Path (Join-Path $artifactRoot 'demo-repo\100\T2') $runId
    $missing = @(Test-Subdirs $dir)
    $ok = ($j.ok -eq $true) -and ($runId -match '^\d{8}-\d{6}$') -and (Test-Path -LiteralPath $dir) -and ($missing.Count -eq 0)
    if ($ok) { return $true }
    return @($false, ('runId=' + $runId + ' exists=' + (Test-Path -LiteralPath $dir) + ' missing=' + ($missing -join ',')))
} | Out-Null

# --- 3b. 重复 path 幂等：created=false，目录保留 ---
Invoke-TestCase 'artifact path reuses existing run dir with created=false (JSON)' {
    & $aos artifact path -Repo 'demo-repo' -Issue '100' -Task 'T1' -RunId 'run-a' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $missing = @(Test-Subdirs $runA)
    if (($j.ok -eq $true) -and ($j.created -eq $false) -and (Test-Path -LiteralPath $runA) -and ($missing.Count -eq 0)) {
        return $true
    }
    return @($false, ('created=' + $j.created + ' missing=' + ($missing -join ',')))
} | Out-Null

# --- 4. 非法名称 / 路径穿越一律拒绝（exit 1 + ok=false） ---
$badCases = @(
    @{ Name = 'repo traversal (..)'; Repo = '..'; Issue = '100'; Task = 'T1'; RunId = 'r1' },
    @{ Name = 'repo separator (a/b)'; Repo = 'a/b'; Issue = '100'; Task = 'T1'; RunId = 'r1' },
    @{ Name = 'issue traversal (../evil)'; Repo = 'demo-repo'; Issue = '../evil'; Task = 'T1'; RunId = 'r1' },
    @{ Name = 'issue absolute (C:\evil)'; Repo = 'demo-repo'; Issue = 'C:\evil'; Task = 'T1'; RunId = 'r1' },
    @{ Name = 'task separator (..\T1)'; Repo = 'demo-repo'; Issue = '100'; Task = '..\T1'; RunId = 'r1' },
    @{ Name = 'runid absolute (C:\evil)'; Repo = 'demo-repo'; Issue = '100'; Task = 'T1'; RunId = 'C:\evil' },
    @{ Name = 'runid trailing dot (bad.)'; Repo = 'demo-repo'; Issue = '100'; Task = 'T1'; RunId = 'bad.' },
    @{ Name = 'runid control character'; Repo = 'demo-repo'; Issue = '100'; Task = 'T1'; RunId = ('bad' + [char]1 + 'name') },
    @{ Name = 'task reserved device name (CON)'; Repo = 'demo-repo'; Issue = '100'; Task = 'CON'; RunId = 'r1' },
    @{ Name = 'runid overlong (>64 chars)'; Repo = 'demo-repo'; Issue = '100'; Task = 'T1'; RunId = ('a' * 65) }
)
foreach ($bc in $badCases) {
    $badRepo = [string]$bc.Repo
    $badIssue = [string]$bc.Issue
    $badTask = [string]$bc.Task
    $badRunId = [string]$bc.RunId
    Invoke-TestCase ('reject ' + $bc.Name) {
        & $artifact -Command path -Repo $badRepo -Issue $badIssue -Task $badTask -RunId $badRunId -Json
    } -ExpectExit 1 -ExpectJson -Check {
        param($text)
        $j = $text | ConvertFrom-Json
        if ($j.ok -eq $false) { return $true }
        return @($false, 'ok is not false')
    } | Out-Null
}

# --- 4b. aos 包装层同样拒绝非法参数 ---
Invoke-TestCase 'reject invalid run id via aos wrapper (JSON)' {
    & $aos artifact path -Repo 'demo-repo' -Issue '100' -Task 'T1' -RunId 'bad.' -Json
} -ExpectExit 1 -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    if ($j.ok -eq $false) { return $true }
    return @($false, 'ok is not false')
} | Out-Null

# --- 5. 非法调用后固定根下没有新增仓库目录 ---
$topDirs = @()
if (Test-Path -LiteralPath $artifactRoot) {
    $topDirs = @(Get-ChildItem -LiteralPath $artifactRoot -Directory | ForEach-Object { $_.Name } | Sort-Object)
}
$topOk = ($topDirs.Count -eq 1) -and ($topDirs[0] -eq 'demo-repo')
Add-Result 'invalid names leave artifact root untouched' $(if ($topOk) { 'PASS' } else { 'FAIL' }) ('top=' + ($topDirs -join ','))

# --- 5b. -Human 输出：path 只输出路径 ---
$humanRun = Join-Path $artifactRoot 'demo-repo\100\T3\human-run'
Invoke-TestCase 'artifact path -Human prints only the path' {
    & $aos artifact path -Repo 'demo-repo' -Issue '100' -Task 'T3' -RunId 'human-run' -Human
} -Check {
    param($text)
    $lines = @(($text -split '\r?\n') | Where-Object { $_.Trim().Length -gt 0 })
    $got = ''
    if ($lines.Count -eq 1) { $got = $lines[0].Trim() }
    $gotFull = ''
    if ($got) { $gotFull = [IO.Path]::GetFullPath($got) }
    $want = [IO.Path]::GetFullPath($humanRun)
    if (($lines.Count -eq 1) -and ($gotFull -eq $want) -and (Test-Path -LiteralPath $humanRun)) { return $true }
    return @($false, ('lines=' + $lines.Count + ' got=' + $got))
} | Out-Null

# --- 6. list 各层级（先放一个文件，验证文件数） ---
$shot = Join-Path (Join-Path $runA 'screenshots') 'shot-1.txt'
Set-Content -LiteralPath $shot -Value 'fixture' -Encoding UTF8

Invoke-TestCase 'artifact list -Repo -Issue shows task dirs with file counts (JSON)' {
    & $aos artifact list -Repo 'demo-repo' -Issue '100' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $items = @($j.items)
    $t1 = @($items | Where-Object { $_.name -eq 'T1' })
    $t2 = @($items | Where-Object { $_.name -eq 'T2' })
    if (($j.ok -eq $true) -and ($j.level -eq 'tasks') -and ($t1.Count -eq 1) -and ($t2.Count -eq 1) -and ([int]$t1[0].files -ge 1)) {
        return $true
    }
    return @($false, ('level=' + $j.level + ' count=' + $j.count))
} | Out-Null

Invoke-TestCase 'artifact list -Task shows run dirs with file counts (JSON)' {
    & $aos artifact list -Repo 'demo-repo' -Issue '100' -Task 'T1' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $items = @($j.items)
    $runHit = @($items | Where-Object { $_.name -eq 'run-a' })
    if (($j.ok -eq $true) -and ($j.level -eq 'runs') -and ($runHit.Count -eq 1) -and ([int]$runHit[0].files -ge 1)) {
        return $true
    }
    return @($false, ('level=' + $j.level + ' count=' + $j.count))
} | Out-Null

Invoke-TestCase 'artifact list without filter shows repo dirs (JSON)' {
    & $aos artifact list -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $items = @($j.items)
    $hit = @($items | Where-Object { $_.name -eq 'demo-repo' })
    if (($j.ok -eq $true) -and ($j.level -eq 'repos') -and ($hit.Count -eq 1) -and ([int]$hit[0].files -ge 1)) {
        return $true
    }
    return @($false, ('level=' + $j.level + ' count=' + $j.count))
} | Out-Null

# --- 7. list 对不存在的 repo 只读，不创建目录 ---
Invoke-TestCase 'artifact list does not create missing repo directories (JSON)' {
    & $aos artifact list -Repo 'ghost-repo' -Json
} -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    $ghost = Join-Path $artifactRoot 'ghost-repo'
    if (($j.ok -eq $true) -and ($j.count -eq 0) -and (-not (Test-Path -LiteralPath $ghost))) {
        return $true
    }
    return @($false, ('count=' + $j.count + ' created=' + (Test-Path -LiteralPath $ghost)))
} | Out-Null

# --- 7b. -Human list 输出表格 ---
Invoke-TestCase 'artifact list -Human prints run table' {
    & $aos artifact list -Repo 'demo-repo' -Issue '100' -Task 'T1' -Human
} -Check {
    param($text)
    if (($text -match 'run-a') -and ($text -match 'total=1')) { return $true }
    return @($false, 'missing run-a/total=1 in human output')
} | Out-Null

# --- 7c. list 显式拒绝 -RunId ---
Invoke-TestCase 'artifact list rejects -RunId (JSON)' {
    & $aos artifact list -Repo 'demo-repo' -Issue '100' -Task 'T1' -RunId 'run-a' -Json
} -ExpectExit 1 -ExpectJson -Check {
    param($text)
    $j = $text | ConvertFrom-Json
    if (($j.ok -eq $false) -and ([string]$j.error.code -eq 'unsupported-arg')) { return $true }
    return @($false, ('ok=' + $j.ok))
} | Out-Null

# --- 8. 仓库不被污染：git 状态不变、仓库内无 devops、生成物在沙箱固定根下 ---
$statusAfter = Get-RepoStatus
$gitSame = ($null -ne $statusBefore) -and ($null -ne $statusAfter) -and ($statusBefore -eq $statusAfter)
$noRepoDevops = -not (Test-Path -LiteralPath (Join-Path $root 'devops'))
$underRootOk = $false
try {
    $rootFull = [IO.Path]::GetFullPath($artifactRoot).TrimEnd('\') + '\'
    $underRootOk = ([IO.Path]::GetFullPath($runA)).StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
} catch {
    $underRootOk = $false
}
$repoOk = $gitSame -and $noRepoDevops -and $underRootOk
Add-Result 'repository is not polluted; artifacts stay under sandbox fixed root' $(if ($repoOk) { 'PASS' } else { 'FAIL' }) ('gitSame=' + $gitSame + ' noRepoDevops=' + $noRepoDevops + ' underRoot=' + $underRootOk)

$results | Format-Table Case, Status, Detail -AutoSize

$fail = @($results | Where-Object { $_.Status -eq 'FAIL' })
if ($fail.Count -gt 0) {
    Write-Output ''
    Write-Output '--- failure detail ---'
    foreach ($f in $fail) {
        Write-Output ('[' + $f.Case + '] ' + $f.Detail)
    }
}
Write-Output ''
Write-Output ("TOTAL {0}  PASS {1}  FAIL {2}" -f $results.Count, ($results.Count - $fail.Count), $fail.Count)

if (-not $KeepSandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'sandbox removed'
} else {
    Write-Output ('sandbox kept: ' + $sandbox)
}

if ($fail.Count -gt 0) { exit 1 }
exit 0
