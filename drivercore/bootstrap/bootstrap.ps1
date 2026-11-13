<#
.SYNOPSIS
  AgentOS bootstrap（Windows）：在任意机器上复现 drivercore 驱动面。
.DESCRIPTION
  唯一安装实现仍是仓库根 install.ps1；本脚本只做前置检查、homebase 入口模板发布与安装调用，
  不复制第二套 skill 安装逻辑，也不创建第二份规则正文。

  默认 homebase = AgentOS 仓库的父目录（<homebase>\agentos）；可用 -HomeBase 覆盖。
  -DryRun 只打印计划：不写用户主目录、不写 homebase、不改 PATH、不注册计划任务。
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\bootstrap\bootstrap.ps1 -DryRun
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File drivercore\bootstrap\bootstrap.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$HomeBase = '',
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoInstall
)
$ErrorActionPreference = 'Stop'

$AgentOSRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $HomeBase) {
    if ($env:AGENTOS_HOME) { $HomeBase = $env:AGENTOS_HOME }
    else { $HomeBase = Split-Path $AgentOSRoot -Parent }
}
$HomeBase = [IO.Path]::GetFullPath($HomeBase)
$installer = Join-Path $AgentOSRoot 'install.ps1'

Write-Host "=== AgentOS bootstrap (drivercore) ==="
Write-Host "agentos:  $AgentOSRoot"
Write-Host "homebase: $HomeBase"
if ($DryRun) { Write-Host "[dry-run] 只打印计划，不执行任何写入" }

# --- 0. 前置检查：git + 至少一个 harness CLI（AgentOS 不分发工具链） ---
$gitOk = [bool](Get-Command git -ErrorAction SilentlyContinue)
$harness = @(@('claude', 'codex', 'dsh') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
$missing = @()
if (-not $gitOk) { $missing += 'git' }
if ($harness.Count -eq 0) { $missing += 'claude|codex|dsh' }
if ($missing.Count -gt 0) {
    $msg = "缺少前置工具: $($missing -join ', ')"
    if ($DryRun) { Write-Host "[warn] $msg（dry-run 继续）" }
    else { throw $msg }
} else {
    Write-Host "[ok] git 与 harness CLI 就绪（$($harness -join ' / ')）"
}

if (-not (Test-Path -LiteralPath $installer)) {
    throw "AgentOS 安装入口缺失: $installer"
}
$coreSkill = Join-Path $AgentOSRoot 'skills\agentos\SKILL.md'
if (-not (Test-Path -LiteralPath $coreSkill)) { throw "核心 skill 缺失: $coreSkill" }
# 公开版只安装 skills/agentos；drivercore\skills 是可选扩展目录，缺失不影响安装。

# --- 1. 全局安装：委托 install.ps1（skill + 规则块 + PATH） ---
if ($NoInstall) {
    Write-Host "[skip] 全局安装（-NoInstall）"
} elseif ($DryRun) {
    $forceArg = if ($Force) { ' -Force' } else { '' }
    Write-Host "[dry-run] 将执行: $installer -Target all$forceArg"
} else {
    Write-Host "[..] 调用 install.ps1 -Target all"
    & $installer -Target all -Force:$Force
    $rc = $LASTEXITCODE
    if ($null -ne $rc -and $rc -ne 0) { throw "install.ps1 返回 $rc" }
    Write-Host "[ok] AgentOS 全局安装完成（Claude / Codex / DSH）"
}

# --- 2. homebase 入口模板：AGENTS.md（唯一正文入口）+ CLAUDE.md（Claude 入口壳） ---
# 模板已脱敏：只含占位符与规则骨架，不含真实主机 / 凭据 / 业务数据。
$templates = @(
    @{ Src = 'drivercore\harness\AGENTS.template.md'; Dst = 'AGENTS.md' },
    @{ Src = 'drivercore\harness\CLAUDE.template.md'; Dst = 'CLAUDE.md' }
)
foreach ($t in $templates) {
    $srcPath = Join-Path $AgentOSRoot $t.Src
    $dst = Join-Path $HomeBase $t.Dst
    if (-not (Test-Path -LiteralPath $srcPath)) { throw "模板缺失: $srcPath" }
    if ((Test-Path -LiteralPath $dst) -and -not $Force) {
        Write-Host "[skip] $($t.Dst) 已存在（-Force 覆盖）: $dst"
        continue
    }
    if ($DryRun) {
        Write-Host "[dry-run] 将生成: $dst (template: $srcPath)"
        continue
    }
    $content = Get-Content -LiteralPath $srcPath -Raw -Encoding UTF8
    $content = $content.Replace('{{HOMEBASE}}', $HomeBase)
    $tmp = Join-Path $HomeBase ("$($t.Dst).$PID-$(Get-Random -Maximum 99999).tmp")
    try {
        [IO.File]::WriteAllText($tmp, $content, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $dst -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "[ok] homebase $($t.Dst) 已生成: $dst"
}

# --- 3. 数据层：只建空目录，真实机器清单由用户放入（永不入 git） ---
$dataDir = Join-Path $HomeBase 'data'
if (Test-Path -LiteralPath $dataDir) {
    Write-Host "[ok] 数据层已存在: $dataDir"
} elseif ($DryRun) {
    Write-Host "[dry-run] 将创建数据层目录: $dataDir"
} else {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    Write-Host "[warn] 数据层目录已创建: $dataDir —— 请放入真实机器清单等（永不入 git）"
}

# --- 4. 旧版迁移检测：完整正文的旧 CLAUDE.md（无 @AGENTS.md 入口） ---
$claudePath = Join-Path $HomeBase 'CLAUDE.md'
if ((Test-Path -LiteralPath $claudePath) -and -not (Select-String -LiteralPath $claudePath -Pattern '@AGENTS\.md' -Quiet)) {
    Write-Host "[warn] 检测到旧版 CLAUDE.md（无 @AGENTS.md 入口）；请人工比对后再用 -Force 替换。" -ForegroundColor Yellow
}

Write-Host "=== AgentOS bootstrap 完成 ==="
