<#
.SYNOPSIS
  worktree 兼容转发器：旧调用路径 -> AgentOS 唯一实现。
.DESCRIPTION
  唯一实现是 <agentos>\bin\wt.ps1。本文件不维护第二份实现，只把参数原样转发：
  旧参数 -RepoRoot 映射到 -Repo；未指定仓库时由 bin/wt.ps1 按当前目录推导。
  保留它只为让历史调用与文档引用不断链。
#>
[CmdletBinding()]
param(
    [ValidateSet('list', 'new', 'status', 'prune')]
    [string]$Command = 'list',
    [string]$Repo = '',
    [string]$RepoRoot = '',
    [string]$Issue = '',
    [string]$Slug = '',
    [string]$Base = 'master',
    [string]$TargetRef = 'refs/remotes/origin/master',
    [int]$Limit = 8,
    [switch]$Apply,
    [switch]$Force,
    [switch]$IncludeIgnored,
    [switch]$Human,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

# drivercore/worktree -> agentos 根（不写死盘符/homebase 路径）
$agentosRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$impl = Join-Path $agentosRoot 'bin\wt.ps1'
if (-not (Test-Path -LiteralPath $impl)) {
    throw "AgentOS worktree 实现缺失: $impl（请先安装/更新 agentos 仓库）"
}

$target = if ($Repo) { $Repo } elseif ($RepoRoot) { $RepoRoot } else { '' }
$forward = @{
    Command        = $Command
    Base           = $Base
    TargetRef      = $TargetRef
    Limit          = $Limit
    Apply          = [bool]$Apply
    Force          = [bool]$Force
    IncludeIgnored = [bool]$IncludeIgnored
    Human          = [bool]$Human
    Json           = [bool]$Json
}
if ($target) { $forward['Repo'] = $target }
if ($Issue) { $forward['Issue'] = $Issue }
if ($Slug) { $forward['Slug'] = $Slug }

& $impl @forward
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
exit 0
