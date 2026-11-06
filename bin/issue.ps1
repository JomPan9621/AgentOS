<#
.SYNOPSIS
  AgentOS issue 源解析：GitHub / GitLab / 本地兜底。
.DESCRIPTION
  规则：GitHub 仓库必须走 issue；GitLab 走 API；其余或无远端时落到
  <repo>\.agentos\issues\ISSUE-<id>.md 作为本地兜底。
  凭据只从 -Token 参数或 GITLAB_TOKEN / GH_TOKEN 环境变量读取，绝不入库。
#>
[CmdletBinding()]
param(
    [ValidateSet('detect', 'new', 'show', 'list')]
    [string]$Command = 'detect',
    [string]$Repo = '',
    [string]$Id = '',
    [string]$Title = '',
    [string]$Body = '',
    [string]$Token = '',
    [switch]$Human,
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoPath = if ($Repo) { (Resolve-Path -LiteralPath $Repo).Path } else { (Get-Location).Path }
$machine = -not $Human
if ($machine) { $machine = $true }

function Write-Json {
    param($Obj, [int]$Depth = 5)
    $Obj | ConvertTo-Json -Depth $Depth
}

function Get-Remote {
    try { return [string](& git -C $RepoPath remote get-url origin 2>$null) } catch { return '' }
}

function Get-Source {
    param([string]$Remote)
    if ([string]::IsNullOrWhiteSpace($Remote)) { return 'local' }
    if ($Remote -match 'github\.com') { return 'github' }
    $hosts = $env:AGENTOS_GITLAB_HOSTS
    if ($hosts) {
        foreach ($h in ($hosts -split ',')) {
            if ($h.Trim() -and $Remote -match [regex]::Escape($h.Trim())) { return 'gitlab' }
        }
    }
    if ($Remote -match 'gitlab') { return 'gitlab' }
    return 'local'
}

function Get-LocalIssuePath { param([string]$I) Join-Path $RepoPath (".agentos\issues\ISSUE-{0}.md" -f $I) }

function Get-GitLabBase {
    param([string]$Remote)
    if ($Remote -match '^(?:https?://)?(?<host>[^/:]+)[/:](?<path>.+?)(?:\.git)?$') {
        return @{ Host = $Matches['host']; Path = $Matches['path'] }
    }
    return $null
}

function Invoke-Dispatch {
switch ($Command) {
    'detect' {
        $remote = Get-Remote
        $src = Get-Source $remote
        if ($machine) {
            [pscustomobject]@{
                ok          = $true
                repo        = $RepoPath
                remote      = $remote
                source      = $src
                mustUseIssue = ($src -eq 'github')
                policy      = $(switch ($src) { 'github' { 'MUST use GitHub issue' } 'gitlab' { 'use GitLab issue API' } default { 'local fallback' } })
            } | ConvertTo-Json -Depth 4
            return
        }
        Write-Output ("repo    : " + $RepoPath)
        Write-Output ("remote  : " + $(if ($remote) { $remote } else { '(none)' }))
        Write-Output ("source  : " + $src)
        switch ($src) {
            'github' { Write-Output 'policy  : MUST use GitHub issue (gh cli or api)' }
            'gitlab' { Write-Output 'policy  : use GitLab issue API (token via -Token or GITLAB_TOKEN)' }
            default { Write-Output 'policy  : local fallback -> .agentos\issues\ISSUE-<id>.md' }
        }
    }
    'new' {
        if (-not $Id) { throw '-Id is required' }
        $remote = Get-Remote
        $src = Get-Source $remote
        if ($src -eq 'local') {
            $p = Get-LocalIssuePath $Id
            New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
            if (Test-Path -LiteralPath $p) { throw "issue exists: $p" }
            $lines = @()
            $lines += "# ISSUE-$Id - $Title"
            $lines += ''
            $lines += ('- id      : ' + $Id)
            $lines += ('- created : ' + (Get-Date -Format 'yyyy-MM-dd'))
            $lines += ('- repo    : ' + $RepoPath)
            $lines += '- status  : open'
            $lines += ''
            $lines += '## 背景'
            $lines += ''
            $lines += $Body
            $lines += ''
            $lines += '## 验收'
            $lines += ''
            $lines += '- [ ] '
            $lines | Set-Content -LiteralPath $p -Encoding UTF8
            if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'local'; id = $Id; created = $p }) ; return }
            Write-Output "source=local"
            Write-Output "created=$p"
            return
        }
        if ($src -eq 'github') {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh cli not found; GitHub repo requires issue creation via gh' }
            $args = @('issue', 'create', '--repo', $remote, '--title', $Title)
            if ($Body) { $args += @('--body', $Body) }
            $out = & gh @args 2>&1
            if ($LASTEXITCODE -ne 0) { throw ("gh failed: " + ($out -join '; ')) }
            if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'github'; output = ($out -join ' | ') }) ; return }
            Write-Output "source=github"
            Write-Output ($out -join '')
            return
        }
        if ($src -eq 'gitlab') {
            $tok = if ($Token) { $Token } else { $env:GITLAB_TOKEN }
            if (-not $tok) { throw 'GitLab issue needs -Token or GITLAB_TOKEN env' }
            $info = Get-GitLabBase $remote
            $proj = [uri]::EscapeDataString($info.Path)
            $uri = "https://$($info.Host)/api/v4/projects/$proj/issues"
            $payload = @{ title = $Title; description = $Body } | ConvertTo-Json -Compress
            $hdr = @{ 'PRIVATE-TOKEN' = $tok }
            $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $hdr -Body $payload -ContentType 'application/json'
            if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'gitlab'; iid = $resp.iid; url = $resp.web_url }) ; return }
            Write-Output "source=gitlab"
            Write-Output ("iid=" + $resp.iid)
            Write-Output ("url=" + $resp.web_url)
            return
        }
    }
    'show' {
        if (-not $Id) { throw '-Id is required' }
        $remote = Get-Remote
        $src = Get-Source $remote
        if ($src -eq 'local') {
            $p = Get-LocalIssuePath $Id
            if (-not (Test-Path -LiteralPath $p)) { throw "local issue not found: $p" }
            if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'local'; id = $Id; path = $p; content = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }) ; return }
            Get-Content -LiteralPath $p -Encoding UTF8
            return
        }
        if ($src -eq 'github') {
            & gh issue view $Id --repo $remote 2>&1
            return
        }
        $tok = if ($Token) { $Token } else { $env:GITLAB_TOKEN }
        if (-not $tok) { throw 'GitLab read needs -Token or GITLAB_TOKEN env' }
        $info = Get-GitLabBase $remote
        $proj = [uri]::EscapeDataString($info.Path)
        $uri = "https://$($info.Host)/api/v4/projects/$proj/issues/$Id"
        $r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'PRIVATE-TOKEN' = $tok }
        Write-Output ("#" + $r.iid + " " + $r.title)
        Write-Output $r.description
    }
    'list' {
        $remote = Get-Remote
        $src = Get-Source $remote
        if ($src -eq 'local') {
            $dir = Join-Path $RepoPath '.agentos\issues'
            if (-not (Test-Path -LiteralPath $dir)) { if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'local'; items = @() }) } else { Write-Output 'no local issues' } ; return }
            if ($machine) { Write-Json ([pscustomobject]@{ ok = $true; source = 'local'; items = @(Get-ChildItem -LiteralPath $dir -Filter 'ISSUE-*.md' | ForEach-Object { $_.Name }) }) ; return }
            Get-ChildItem -LiteralPath $dir -Filter 'ISSUE-*.md' | ForEach-Object { $_.Name }
            return
        }
        if ($src -eq 'github') { & gh issue list --repo $remote 2>&1; return }
        $tok = if ($Token) { $Token } else { $env:GITLAB_TOKEN }
        if (-not $tok) { throw 'GitLab list needs -Token or GITLAB_TOKEN env' }
        $info = Get-GitLabBase $remote
        $proj = [uri]::EscapeDataString($info.Path)
        $uri = "https://$($info.Host)/api/v4/projects/$proj/issues?state=opened"
        $r = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'PRIVATE-TOKEN' = $tok }
        foreach ($x in $r) { Write-Output ("#{0} {1}" -f $x.iid, $x.title) }
    }
}
}

Invoke-Dispatch
exit 0
