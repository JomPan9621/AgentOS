<#
.SYNOPSIS
  注册/注销 AgentOS tasktrack 周期巡检计划任务（Windows）。
.DESCRIPTION
  逐机部署：clone/bootstrap 后需手动执行一次，周期巡检才会生效。
  实现固定为 drivercore/tasktrack/tasktrack.ps1；运行期状态仍在 <homebase>\devops\tasktrack。
  本脚本默认只写 wrapper / vbs 并注册计划任务；-DryRun 只打印计划，不写文件、不注册。

  任务名默认 agentos-tasktrack-watch，可用 -TaskName 覆盖。
  用法：
    注册: powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-watch-task.ps1
    预演: powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-watch-task.ps1 -DryRun
    注销: powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-watch-task.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$DryRun,
    [string]$HomeBase = '',
    [string]$TaskName = 'agentos-tasktrack-watch'
)
$ErrorActionPreference = 'Stop'

if (-not $HomeBase) {
    if ($env:AGENTOS_HOME) { $HomeBase = $env:AGENTOS_HOME }
    else {
        # drivercore/tasktrack -> agentos 根 -> homebase
        $agentosRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $HomeBase = Split-Path $agentosRoot -Parent
    }
}
$HomeBase = [IO.Path]::GetFullPath($HomeBase)

$script = Join-Path $PSScriptRoot 'tasktrack.ps1'
$watchDir = Join-Path $HomeBase 'devops\tasktrack'
$log = Join-Path $watchDir 'watch.log'
$wrapper = Join-Path $watchDir 'watch-task.cmd'
$hidden = Join-Path $watchDir 'watch-hidden.vbs'
$template = Join-Path $PSScriptRoot 'watch-hidden.vbs'

Write-Output 'AgentOS tasktrack watch install'
Write-Output "  task      : $TaskName"
Write-Output "  script    : $script"
Write-Output "  watch dir : $watchDir"
Write-Output "  log       : $log"
Write-Output "  wrapper   : $wrapper"
Write-Output "  hidden    : $hidden"

if (-not (Test-Path -LiteralPath $script)) { throw "tasktrack 实现缺失: $script" }
if (-not (Test-Path -LiteralPath $template)) { throw "watch-hidden.vbs 模板缺失: $template" }

if ($DryRun) {
    Write-Output 'DRY-RUN: 将生成 watch-task.cmd（cmd 包装 + 日志重定向）'
    Write-Output 'DRY-RUN: 将从模板生成 watch-hidden.vbs（隐藏启动）'
    Write-Output "DRY-RUN: 将注册计划任务 $TaskName（每 10 分钟执行 watch）"
    Write-Output 'DRY-RUN: 未写文件、未注册计划任务'
    exit 0
}

try {
    if ($Remove) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已注销计划任务: $TaskName"
        return
    }

    # 首次部署时父目录可能不存在；写入失败必须停止，不得注册指向缺失 wrapper 的任务
    New-Item -ItemType Directory -Force -Path $watchDir | Out-Null

    # cmd 包装负责日志重定向；cmd 按系统 ANSI 代码页读取本文件，故用 Default 编码写出。
    $wrapperText = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" watch >> `"$log`" 2>&1`r`n"
    [IO.File]::WriteAllText($wrapper, $wrapperText, [Text.Encoding]::Default)
    if (-not (Test-Path -LiteralPath $wrapper)) { throw "wrapper 写入失败: $wrapper" }

    # 计划任务由 wscript 隐藏启动 cmd：直接注册 .cmd 时会在桌面闪控制台窗口。
    # VBS 模板中的 __WATCH_TASK_CMD__ 由本脚本按机器路径替换；双引号按 VBScript 规则转义。
    $vbs = Get-Content -LiteralPath $template -Raw -Encoding UTF8
    if ($vbs -notmatch '__WATCH_TASK_CMD__') { throw "VBS 模板缺少 __WATCH_TASK_CMD__ 占位符: $template" }
    $vbsPath = $wrapper.Replace('"', '""')
    $vbs = $vbs.Replace('__WATCH_TASK_CMD__', $vbsPath)
    [IO.File]::WriteAllText($hidden, $vbs, [Text.Encoding]::Default)
    if (-not (Test-Path -LiteralPath $hidden)) { throw "hidden wrapper 写入失败: $hidden" }

    # 用 ScheduledTasks 模块注册：路径按对象传递，规避 schtasks /TR 的引号转义问题
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" `
        -Argument "//B //Nologo `"$hidden`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Force | Out-Null

    Write-Host "已注册计划任务: $TaskName"
    Write-Host "  执行: 每 10 分钟 -> $script watch"
    Write-Host "  日志: $log"
    Write-Host "注销请执行: 本脚本 -Remove"
} catch {
    Write-Host "操作失败: $_" -ForegroundColor Red
    exit 1
}
