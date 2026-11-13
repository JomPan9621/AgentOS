<#
.SYNOPSIS
  AgentOS 生成物收口：固定根路径生成与只读清单。
.DESCRIPTION
  固定根：<homebase>\devops\agentos\artifacts
  结构：<root>\<repo>\<issue>\<task>\<run-id>\
  子命令：path / list
  默认输出 JSON；-Human 输出人读。
  退出码：0 成功 / 1 参数或安全校验失败
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('path', 'list')]
    [string]$Command = 'path',
    [string]$Repo = '',
    [string]$Issue = '',
    [string]$Task = '',
    [string]$RunId = '',
    [string]$HomeBase = '',
    [switch]$Json,
    [switch]$Human
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$machine = (-not $Human) -or $Json

# --- 环境自适配：AGENTOS_HOME 优先，其次 agentos 仓库的上一级 ---
if ([string]::IsNullOrWhiteSpace($HomeBase)) {
    $HomeBase = $env:AGENTOS_HOME
    if ([string]::IsNullOrWhiteSpace($HomeBase)) {
        $HomeBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }
}
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $HomeBase 'devops\agentos\artifacts'))
$subdirNames = @('screenshots', 'html', 'reports', 'traces')

function Write-Err {
    param([string]$Code, [string]$Message)
    if ($machine) {
        [pscustomobject]@{
            ok    = $false
            error = [pscustomobject]@{ code = $Code; message = $Message }
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Output ('ERROR ' + $Message)
    }
    exit 1
}

# 单段名称安全校验：拒绝路径分隔符、绝对路径、..、Windows 非法字符与保留名。
function Test-Segment {
    param([string]$Value, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Value)) { throw ($Label + ' is required') }
    $v = $Value.Trim()
    if ($v.Length -eq 0) { throw ($Label + ' is empty') }
    if ($v.Length -gt 64) { throw ($Label + ' must be at most 64 characters') }
    if ($v -eq '.' -or $v -eq '..' -or $v.Contains('..')) { throw ($Label + ' must not contain ..') }
    if ($v -match '[\x00-\x1f]') { throw ($Label + ' contains control characters') }
    if ($v -match '[\\/:*?"<>|]') { throw ($Label + ' contains path separators or invalid characters') }
    if ([IO.Path]::IsPathRooted($v)) { throw ($Label + ' must not be an absolute path') }
    if ($v -match '[\. ]$') { throw ($Label + ' must not end with a dot or space') }
    if ($v -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw ($Label + ' is a reserved device name') }
    if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw ($Label + ' allows only letters, digits, dot, underscore and dash') }
    return $v
}

function Get-ChildDirs {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Get-FileCount {
    param([string]$Path)
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue).Count
}

try {
    switch ($Command) {
        'path' {
            if ([string]::IsNullOrWhiteSpace($Repo)) { Write-Err 'missing-arg' 'path requires -Repo' }
            if ([string]::IsNullOrWhiteSpace($Issue)) { Write-Err 'missing-arg' 'path requires -Issue' }
            if ([string]::IsNullOrWhiteSpace($Task)) { Write-Err 'missing-arg' 'path requires -Task' }

            $repoName = Test-Segment $Repo 'Repo'
            $issueName = Test-Segment $Issue 'Issue'
            $taskName = Test-Segment $Task 'Task'
            if ([string]::IsNullOrWhiteSpace($RunId)) {
                $RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
            }
            $runName = Test-Segment $RunId 'RunId'

            $target = $artifactRoot
            foreach ($seg in @($repoName, $issueName, $taskName, $runName)) {
                $target = Join-Path $target $seg
            }
            $target = [IO.Path]::GetFullPath($target)
            $prefix = $artifactRoot.TrimEnd('\') + '\'
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'resolved path escapes the artifact root'
            }

            $alreadyExists = Test-Path -LiteralPath $target
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            foreach ($sub in $subdirNames) {
                New-Item -ItemType Directory -Force -Path (Join-Path $target $sub) | Out-Null
            }

            $payload = [pscustomobject]@{
                ok      = $true
                root    = $artifactRoot
                repo    = $repoName
                issue   = $issueName
                task    = $taskName
                runId   = $runName
                path    = $target
                subdirs = $subdirNames
                created = (-not $alreadyExists)
            }
            if ($machine) { $payload | ConvertTo-Json -Depth 5 } else { Write-Output $target }
            exit 0
        }
        'list' {
            if (-not [string]::IsNullOrWhiteSpace($RunId)) {
                Write-Err 'unsupported-arg' 'list does not support -RunId'
            }
            if (-not [string]::IsNullOrWhiteSpace($Issue) -and [string]::IsNullOrWhiteSpace($Repo)) {
                Write-Err 'missing-arg' 'list requires -Repo when -Issue is used'
            }
            if (-not [string]::IsNullOrWhiteSpace($Task) -and [string]::IsNullOrWhiteSpace($Issue)) {
                Write-Err 'missing-arg' 'list requires -Issue when -Task is used'
            }

            $level = 'repos'
            $kind = 'repo'
            $scanDir = $artifactRoot
            $repoName = ''
            $issueName = ''
            $taskName = ''
            if (-not [string]::IsNullOrWhiteSpace($Repo)) {
                $repoName = Test-Segment $Repo 'Repo'
                $scanDir = Join-Path $scanDir $repoName
                $level = 'issues'
                $kind = 'issue'
            }
            if (-not [string]::IsNullOrWhiteSpace($Issue)) {
                $issueName = Test-Segment $Issue 'Issue'
                $scanDir = Join-Path $scanDir $issueName
                $level = 'tasks'
                $kind = 'task'
            }
            if (-not [string]::IsNullOrWhiteSpace($Task)) {
                $taskName = Test-Segment $Task 'Task'
                $scanDir = Join-Path $scanDir $taskName
                $level = 'runs'
                $kind = 'run'
            }

            $items = @()
            foreach ($d in (Get-ChildDirs $scanDir)) {
                $items += [pscustomobject]@{
                    kind  = $kind
                    name  = $d.Name
                    path  = $d.FullName
                    files = (Get-FileCount $d.FullName)
                }
            }

            $payload = [pscustomobject]@{
                ok    = $true
                root  = $artifactRoot
                level = $level
                repo  = $repoName
                issue = $issueName
                task  = $taskName
                count = $items.Count
                items = @($items)
            }
            if ($machine) {
                $payload | ConvertTo-Json -Depth 5
            } else {
                if ($items.Count -eq 0) {
                    Write-Output ('no entries under ' + $scanDir)
                } else {
                    $items | Format-Table name, files, path -AutoSize
                }
                Write-Output ('total=' + $items.Count)
            }
            exit 0
        }
    }
} catch {
    Write-Err 'invalid-argument' $_.Exception.Message
}
