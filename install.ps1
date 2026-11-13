<#
.SYNOPSIS
  全局安装 AgentOS：任意 agent、任意目录都能自动加载并调用。
.DESCRIPTION
  三件事：
    1. skill -> 各工具用户级 skill 目录（任意目录可见）；只安装 skills/agentos
    2. 全局规则块 -> 各工具的用户级指令文件（任意目录自动加载）
    3. aos 命令 -> 用户 PATH（任意目录可调用）
  幂等：重复执行只更新受管块，不动你手写的其他内容。
  -DryRun 只打印将执行的 skill / 规则 / PATH 动作，不做任何写入。
#>
[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'dsh', 'all')]
    [string]$Target = 'all',
    [string]$DshSkills = '',
    [string[]]$ExtraRules = @(),
    [switch]$NoRules,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$home_ = [Environment]::GetFolderPath('UserProfile')
$nl = [Environment]::NewLine
$src = Join-Path $PSScriptRoot 'skills\agentos'
$aosSkillPath = Join-Path $PSScriptRoot 'skills\agentos\SKILL.md'
$aosImpl = Join-Path $PSScriptRoot 'bin\aos.ps1'
$repoUrl = ''
try { $repoUrl = [string](& git -C $PSScriptRoot remote get-url origin 2>$null) } catch { $repoUrl = '' }
if ([string]::IsNullOrWhiteSpace($repoUrl)) { $repoUrl = '<git-remote-url>' }

$begin = '<!-- >>> agentos managed (global) >>> -->'
$end = '<!-- <<< agentos managed <<< -->'

$dshRoot = if ($DshSkills) { $DshSkills } else { Join-Path $home_ '.dsh\skills\agentos' }
$targets = @(
    @{ Key = 'claude'; Name = 'Claude Code'; Skill = (Join-Path $home_ '.claude\skills\agentos'); Rules = (Join-Path $home_ '.claude\CLAUDE.md') },
    @{ Key = 'codex';  Name = 'Codex';       Skill = (Join-Path $home_ '.codex\skills\agentos');  Rules = (Join-Path $home_ '.codex\AGENTS.md') },
    @{ Key = 'dsh';    Name = 'DSH';         Skill = $dshRoot;                                     Rules = (Join-Path $home_ '.dsh\AGENTS.md') }
)
$sel = if ($Target -eq 'all') { $targets } else { @($targets | Where-Object { $_.Key -eq $Target }) }

function Get-Block {
    $t = [char]96
    $lines = @(
        $begin,
        '## AgentOS（本机最高权限执行系统 · 全局强制）',
        '',
        'AgentOS 是本机最高权限执行系统。三个 agent（Claude Code / Codex / DSH）在任意目录下的工程任务，一律由它驱动；唯一可临时覆盖的是用户直接指令（须写明理由）。规程正文：',
        ($t + $aosSkillPath + $t),
        '',
        '六条 MUST：',
        '1. 主会话只派发，不执行任务；每个 PLAN 节点由 subagent 执行（track start -Plan -Subagent）',
        '2. issue 先行：git 仓库走 issue tracker；非 git 用本地 issue + PLAN',
        ('3. 开工前先 ' + $t + 'aos snapshot -Repo <repo>' + $t + '；attention 非空先处理'),
        ('4. 非单步任务先出 ' + $t + 'PLAN-<issue>.md' + $t + ' 并通过 ' + $t + 'aos plan validate' + $t),
        ('5. 并发由 ' + $t + 'aos plan graph' + $t + ' 的 wave 决定；每个节点一个 subagent，同 wave 并行；写型任务独占 worktree（' + $t + 'aos wt new' + $t + '）；状态变更同时写 state+ledger；收工用 ' + $t + 'aos track close -Plan' + $t + '（自动对账 + 只读 audit/wt prune/hygiene；破坏性操作人工确认）'),
        '6. 浏览器任务只用 Google Chrome（含 headless）；禁止 Edge/Firefox/Safari/Brave/Chromium；Chrome 不可用则停止并报告',
        '',
        ('会话在场证明：' + $t + 'aos session register|heartbeat|close|list' + $t + '（绑定任务，只写统一 ledger）'),
        ('policy 签名：' + $t + 'aos audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>' + $t + '（生产初始化由 Master 执行；未签名 policy 一律拒绝）'),
        '',
        ('入口：' + $t + $aosImpl + $t + '（已装 aos 到 PATH）'),
        ('出处：' + $repoUrl),
        $end
    )
    return ($lines -join $nl)
}

function Set-ManagedBlock {
    param([string]$Path, [string]$Block)
    $dir = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $existing = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } else { '' }
    $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    if ([regex]::IsMatch($existing, $pattern)) {
        $updated = [regex]::Replace($existing, $pattern, $Block)
        $action = 'updated'
    } else {
        $updated = if ([string]::IsNullOrWhiteSpace($existing)) { $Block } else { $existing.TrimEnd() + $nl + $nl + $Block }
        $action = 'appended'
    }
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
    return $action
}

function Remove-ManagedBlock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $existing = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    if (-not [regex]::IsMatch($existing, $pattern)) { return 'no-block' }
    $updated = ([regex]::Replace($existing, $pattern, '')).TrimEnd() + $nl
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
    return 'removed'
}

function Install-SkillTree {
    param([string]$Name, [string]$Source, [string]$Destination)
    if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
        $n = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { return ('SKIP    skill ' + $Name + ' (exists; -Force to overwrite)') }
    }
    if ($DryRun) { return ('DRY     skill ' + $Name + ' -> ' + $Destination) }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Source.Length).TrimStart('\')
        $dst = Join-Path $Destination $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
    return ('OK      skill ' + $Name + ' -> ' + $Destination)
}

Write-Output 'AgentOS global install'
Write-Output ('  home   : ' + $home_)
Write-Output ('  source : ' + $src)
Write-Output ''

if ($Uninstall) {
    foreach ($t in $sel) {
        $removePaths = @($t.Skill)
        foreach ($p in $removePaths) {
            if (Test-Path -LiteralPath $p) {
                if ($DryRun) {
                    Write-Output ('  DRY     REMOVE ' + $p)
                } else {
                    Remove-Item -LiteralPath $p -Recurse -Force
                    Write-Output ('  REMOVED ' + $p)
                }
            }
        }
        if ($DryRun) {
            Write-Output ('  RULES   DRY remove-block ' + $t.Name)
        } else {
            Write-Output ('  RULES   ' + (Remove-ManagedBlock $t.Rules) + ' ' + $t.Name)
        }
    }
    exit 0
}

foreach ($t in $sel) {
    Write-Output ('  ' + (Install-SkillTree -Name 'agentos' -Source $src -Destination $t.Skill))
}

if ($DryRun) {
    Write-Output ''
    Write-Output 'DRY-RUN: no rules / PATH changes'
    exit 0
}

if (-not $NoRules) {
    Write-Output ''
    $block = Get-Block
    foreach ($t in $sel) {
        $a = Set-ManagedBlock -Path $t.Rules -Block $block
        Write-Output ('  RULES   ' + $a.PadRight(9) + $t.Name + ' -> ' + $t.Rules)
    }
    foreach ($extra in $ExtraRules) {
        if ([string]::IsNullOrWhiteSpace($extra)) { continue }
        $a = Set-ManagedBlock -Path $extra -Block $block
        Write-Output ('  RULES   ' + $a.PadRight(9) + 'extra -> ' + $extra)
    }
}

if (-not $NoPath) {
    Write-Output ''
    $binDir = Join-Path $home_ '.agentos\bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $shellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $shim = Join-Path $binDir 'aos.cmd'
    $shimLines = @('@echo off', ($shellExe + ' -NoProfile -ExecutionPolicy Bypass -File "' + $aosImpl + '" %*'))
    [System.IO.File]::WriteAllText($shim, ($shimLines -join $nl), (New-Object System.Text.ASCIIEncoding))
    Write-Output ('  OK      shim  -> ' + $shim + ' (' + $shellExe + ')')

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    if ($parts -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
        Write-Output ('  OK      PATH  -> appended ' + $binDir + ' (new shells only)')
    } else {
        Write-Output ('  SKIP    PATH  -> already present')
    }
}

Write-Output ''
Write-Output 'verify:'
Write-Output ('  ' + $aosImpl + ' doctor')
