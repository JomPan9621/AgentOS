<#
.SYNOPSIS
  AgentOS worktree 槽位管理：list / new / status / prune。
.DESCRIPTION
  写型任务必须独占 worktree。本脚本是唯一的创建与回收入口。
  安全边界：只操作 <projectRoot> 下的 worktree，永不触碰主工作区。
#>
[CmdletBinding()]
param(
    [ValidateSet('list', 'new', 'status', 'prune')]
    [string]$Command = 'list',
    [string]$Repo = '',
    [string]$Issue = '',
    [string]$Slug = '',
    [string]$Base = 'master',
    [string]$TargetRef = 'refs/remotes/origin/master',
    [int]$Limit = 5,
    [switch]$Apply,
    [switch]$Force,
    [switch]$IncludeIgnored,
    [switch]$Human,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Repo) {
    $here = (Get-Location).Path
    $isRepo = $false
    try { $isRepo = ((& git --no-optional-locks -C $here rev-parse --is-inside-work-tree 2>$null) -eq 'true') } catch { $isRepo = $false }
    if (-not $isRepo) { throw '-Repo 必填：当前目录不是 git 仓库，请显式指定要治理的仓库路径' }
    $Repo = $here
}
$RepoRoot = (Resolve-Path -LiteralPath $Repo).Path
$projectRoot = (Resolve-Path -LiteralPath (Split-Path $RepoRoot -Parent)).Path
$repoName = Split-Path $RepoRoot -Leaf
$homeBase = $env:AGENTOS_HOME
if ([string]::IsNullOrWhiteSpace($homeBase)) { $homeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$machine = -not $Human
if ($machine) { $machine = $true }

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs, [switch]$AllowFailure)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @(& git --no-optional-locks -c "safe.directory=$Dir" -C $Dir @GitArgs 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0 -and -not $AllowFailure) { throw "git failed ($code): $($GitArgs -join ' ')" }
    return [pscustomobject]@{ Code = $code; Lines = @($out | ForEach-Object { [string]$_ }) }
}

function Test-UnderPath {
    param([string]$Path, [string]$Root)
    return $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-WorktreeEntries {
    $lines = (Invoke-Git $RepoRoot @('worktree', 'list', '--porcelain')).Lines
    $entries = @()
    $cur = $null
    foreach ($line in $lines) {
        if ($line -like 'worktree *') {
            if ($null -ne $cur) { $entries += [pscustomobject]$cur }
            $cur = [ordered]@{ Path = $line.Substring(9); Head = ''; Branch = '' }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -like 'HEAD *') { $cur.Head = $line.Substring(5) }
        elseif ($line -like 'branch refs/heads/*') { $cur.Branch = $line.Substring(18) }
        elseif ($line -eq 'detached') { $cur.Branch = '(detached)' }
    }
    if ($null -ne $cur) { $entries += [pscustomobject]$cur }
    return @($entries)
}

function Get-Report {
    $rootFull = (Resolve-Path -LiteralPath $RepoRoot).Path
    $rows = @()
    foreach ($e in (Get-WorktreeEntries)) {
        $p = (Resolve-Path -LiteralPath $e.Path).Path
        $st = @((Invoke-Git $p @('status', '--porcelain=v1', '--untracked-files=all', '--ignored=matching')).Lines)
        $tracked = @($st | Where-Object { $_ -notmatch '^\?\?' -and $_ -notmatch '^!!' }).Count
        $untracked = @($st | Where-Object { $_ -match '^\?\?' }).Count
        $ignored = @($st | Where-Object { $_ -match '^!!' }).Count
        $inTarget = (Invoke-Git $RepoRoot @('merge-base', '--is-ancestor', $e.Head, $TargetRef) -AllowFailure).Code -eq 0
        $safePath = ($p -ne $rootFull) -and (Test-UnderPath -Path $p -Root $projectRoot)
        $cleanStrict = ($tracked -eq 0 -and $untracked -eq 0 -and $ignored -eq 0)
        $cleanLoose = ($tracked -eq 0 -and $untracked -eq 0)
        $mergedOk = $inTarget -and $e.Branch -ne '(detached)'
        $cls = if (-not $safePath) { 'retain-root-or-outside' }
        elseif ($cleanStrict -and $mergedOk) { 'safe-delete-candidate' }
        elseif ($IncludeIgnored -and $cleanLoose -and $mergedOk) { 'safe-with-ignored' }
        elseif ($tracked -gt 0 -or $untracked -gt 0) { 'dirty-or-artifacts' }
        elseif (-not $mergedOk) { 'not-in-target-ref' }
        else { 'clean-with-ignored' }
        $rows += [pscustomobject]@{
            Path = $p; Branch = $e.Branch; Head = $e.Head.Substring(0, [Math]::Min(8, $e.Head.Length))
            Tracked = $tracked; Untracked = $untracked; Ignored = $ignored
            InTarget = $inTarget; Class = $cls
        }
    }
    return @($rows)
}

function Invoke-Dispatch {
switch ($Command) {
    'list' {
        $rows = @(Get-Report)
        if ($machine) {
            [pscustomobject]@{ ok = $true; repo = $RepoRoot; projectRoot = $projectRoot; total = $rows.Count; items = $rows } | ConvertTo-Json -Depth 6
            return
        }
        $rows | Sort-Object Class, Path | Format-Table -AutoSize
    }
    'status' {
        $rows = @(Get-Report)
        $active = @($rows | Where-Object { $_.Path -ne $RepoRoot })
        # 槽位只算 AgentOS 管理的 task/* 分支；历史遗留单独报告，不阻塞调度
        $managed = @($active | Where-Object { $_.Branch -like 'task/*' })
        $legacyCount = $active.Count - $managed.Count
        if ($machine) {
            [pscustomobject]@{
                ok          = $true
                repo        = $RepoRoot
                projectRoot = $projectRoot
                limit       = $Limit
                total       = $active.Count
                managed     = $managed.Count
                legacy      = $legacyCount
                overLimit   = ($managed.Count -gt $Limit)
                reclaimable = @($rows | Where-Object { $_.Class -eq 'safe-delete-candidate' }).Count
                dirty       = @($rows | Where-Object { $_.Class -eq 'dirty-or-artifacts' }).Count
                items       = $rows
            } | ConvertTo-Json -Depth 6
            return
        }
        $write = @($active | Where-Object { $_.Class -eq 'dirty-or-artifacts' -or $_.Class -eq 'not-in-target-ref' -or $_.Class -eq 'safe-delete-candidate' })
        Write-Output ("repo          : $RepoRoot")
        Write-Output ("projectRoot   : $projectRoot")
        Write-Output ("managed slots : {0} (limit {1})" -f $managed.Count, $Limit)
        Write-Output ("legacy trees  : {0}  (历史遗留，不计入槽位)" -f $legacyCount)
        Write-Output ("total trees   : {0}" -f $active.Count)
        Write-Output ("reclaimable   : {0}" -f @($rows | Where-Object { $_.Class -eq 'safe-delete-candidate' }).Count)
        Write-Output ("dirty         : {0}" -f @($rows | Where-Object { $_.Class -eq 'dirty-or-artifacts' }).Count)
        if ($managed.Count -gt $Limit) {
            Write-Output ("OVER LIMIT: managed {0} > {1}, must reclaim before creating new one" -f $managed.Count, $Limit)
            exit 2
        }
    }
    'new' {
        if (-not $Issue -or -not $Slug) { throw '-Issue and -Slug are required' }
        $active = @((Get-Report) | Where-Object { $_.Path -ne $RepoRoot })
        $managed = @($active | Where-Object { $_.Branch -like 'task/*' })
        if ($managed.Count -ge $Limit -and -not $Force) {
            throw "managed slot limit reached ($($managed.Count)/$Limit). run 'aos wt prune' or pass -Force"
        }
        $name = "$repoName-$Issue-$Slug"
        $path = Join-Path $projectRoot $name
        $branch = "task/$Issue-$Slug"
        if (Test-Path -LiteralPath $path) { throw "path exists: $path" }
        $exists = (Invoke-Git $RepoRoot @('show-ref', '--verify', '--quiet', "refs/heads/$branch") -AllowFailure).Code -eq 0
        if ($exists) { throw "branch exists: $branch" }
        $r = Invoke-Git $RepoRoot @('worktree', 'add', '-b', $branch, $path, $Base) -AllowFailure
        if ($r.Code -ne 0) { throw ("worktree add failed: " + ($r.Lines -join '; ')) }
        if ($machine) {
            [pscustomobject]@{ ok = $true; path = $path; branch = $branch; base = $Base; repo = $RepoRoot } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output "created=$path"
        Write-Output "branch=$branch"
        Write-Output "base=$Base"
    }
    'prune' {
        $rows = Get-Report
        $cand = @($rows | Where-Object { $_.Class -eq 'safe-delete-candidate' -or $_.Class -eq 'safe-with-ignored' })
        if ($machine) {
            [pscustomobject]@{ ok = $true; dryRun = (-not $Apply); candidates = @($cand); items = $rows } | ConvertTo-Json -Depth 6
            return
        }
        $rows | Sort-Object Class, Path | Format-Table -AutoSize
        if (-not $Apply) {
            Write-Output "DRY-RUN: $($cand.Count) safe-delete candidate(s). rerun with -Apply to remove only these."
            return
        }
        $logDir = Join-Path (Join-Path $homeBase 'devops\agentos\logs') ''
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $log = Join-Path $logDir ("prune-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $lines = @()
        foreach ($c in $cand) {
            $p = (Resolve-Path -LiteralPath $c.Path).Path
            if (-not (Test-UnderPath -Path $p -Root $projectRoot) -or $p -eq $RepoRoot) { throw "refuse: $p" }
            $r = Invoke-Git $RepoRoot @('worktree', 'remove', '--', $p) -AllowFailure
            if ($r.Code -ne 0 -or (Test-Path -LiteralPath $p)) { $lines += "FAILED $p"; continue }
            $bd = Invoke-Git $RepoRoot @('branch', '-d', $c.Branch) -AllowFailure
            $bs = if ($bd.Code -eq 0) { 'deleted' } else { 'retained' }
            $lines += "REMOVED $p branch=$($c.Branch) $bs"
            Write-Output $lines[-1]
        }
        if ($lines.Count -gt 0) { $lines | Set-Content -LiteralPath $log -Encoding UTF8; Write-Output "audit_log=$log" }
    }
}
}

if ((Invoke-Git $RepoRoot @('show-ref', '--verify', '--quiet', $TargetRef) -AllowFailure).Code -ne 0) {
    $TargetRef = 'HEAD'
}

Invoke-Dispatch
exit 0
