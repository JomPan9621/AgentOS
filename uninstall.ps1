<#
.SYNOPSIS
  卸载 AgentOS 的全局挂载（skill / 全局规则块 / PATH）。
#>
[CmdletBinding()]
param(
    [ValidateSet('claude', 'codex', 'dsh', 'all')]
    [string]$Target = 'all',
    [string]$DshSkills = '',
    [switch]$KeepPath
)
$ErrorActionPreference = 'Stop'
$p = @{ Uninstall = $true; Target = $Target }
if ($DshSkills) { $p['DshSkills'] = $DshSkills }
& (Join-Path $PSScriptRoot 'install.ps1') @p
if (-not $KeepPath) {
    $binDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agentos\bin'
    $isWindowsHost = ([IO.Path]::DirectorySeparatorChar -eq [char]'\')
    if ($isWindowsHost) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -and (($userPath -split ';') -contains $binDir)) {
            [Environment]::SetEnvironmentVariable('Path', ((($userPath -split ';') | Where-Object { $_ -and $_.Trim() -ne $binDir }) -join ';'), 'User')
            Write-Output ('  PATH    removed ' + $binDir)
        }
    } else {
        $unixShim = Join-Path $binDir 'aos'
        if (Test-Path -LiteralPath $unixShim) {
            Remove-Item -LiteralPath $unixShim -Force
            Write-Output ('  SHIM    removed ' + $unixShim)
        }
        Write-Output ('  PATH    edit your shell profile to drop ' + $binDir)
    }
}
Write-Output 'done'
