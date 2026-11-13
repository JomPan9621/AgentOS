<#
.SYNOPSIS
  Shared ledger model for track / audit / session / policy.
.DESCRIPTION
  Single source of truth for parsing and appending <homebase>\devops\agentos\ledger.jsonl.
  Callers dot-source this file; do not duplicate the event state machine.

  Event families:
    - task    : start / review / close / block / abandon / claim / release / handoff / state
    - policy  : policy (append-only, PFX-signed; the ledger is authoritative, the json file is a cache)
    - session : session-register / session-heartbeat / session-close
  Task parsing ignores policy/session events; session parsing ignores task/policy events.
#>

function Get-LedgerField {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return '' }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

$script:SessionEvents = @('session-register', 'session-heartbeat', 'session-close')

function Test-LedgerSessionEvent {
    param([string]$Event)
    return ($script:SessionEvents -contains $Event)
}

function Read-LedgerEvents {
    param([string]$Path)
    $events = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $events }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        $ev = Get-LedgerField $e 'event'
        if ((Test-LedgerSessionEvent $ev) -or $ev -eq 'policy') { continue }
        $k = (Get-LedgerField $e 'issue') + '|' + (Get-LedgerField $e 'task')
        if ($k -eq '|') { continue }
        if (-not $events.ContainsKey($k)) { $events[$k] = [System.Collections.Generic.List[object]]::new() }
        $events[$k].Add($e)
    }
    return $events
}

function Read-LedgerSessionEvents {
    param([string]$Path)
    $list = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if (Test-LedgerSessionEvent (Get-LedgerField $e 'event')) { $list.Add($e) }
    }
    return @($list)
}

function Get-LedgerTaskInfo {
    param($Events)
    $info = [pscustomobject]@{
        Has = $false; Status = ''; Ts = ''; Owner = ''; Repo = ''; Subagent = ''; Wave = '';
        Held = $false; HasStart = $false; StartSubagent = '';
        HasExecution = $false; FirstExecutionTs = ''
    }
    if ($null -eq $Events) { return $info }
    foreach ($e in @($Events)) {
        $ev = Get-LedgerField $e 'event'
        $st = Get-LedgerField $e 'status'
        $ts = Get-LedgerField $e 'ts'
        $owner = Get-LedgerField $e 'owner'
        $subagent = Get-LedgerField $e 'subagent'
        $info.Has = $true
        if ($ts) { $info.Ts = $ts }
        if ($owner) { $info.Owner = $owner }
        $repo = Get-LedgerField $e 'repo'
        if ($repo) { $info.Repo = $repo }
        if ($subagent) { $info.Subagent = $subagent }
        $wave = Get-LedgerField $e 'wave'
        if ($wave) { $info.Wave = $wave }
        $execution = $false
        switch ($ev) {
            'close' { $info.Status = 'done'; $info.Held = $false; $execution = $true }
            'abandon' { $info.Status = 'abandoned'; $info.Held = $false }
            'state' {
                $info.Status = $st
                $info.Held = -not ($st -in @('done', 'abandoned', 'planned', 'ready'))
                if ($st -in @('running', 'review', 'done') -and (Get-LedgerField $e 'backfilled') -ne 'True') { $execution = $true }
            }
            'review' { $info.Status = 'review'; $info.Held = $true; $execution = $true }
            'start' {
                $info.Status = 'running'; $info.Held = $true
                $info.HasStart = $true
                if ($subagent) { $info.StartSubagent = $subagent }
                $execution = $true
            }
            'claim' { $info.Status = 'running'; $info.Held = $true; $execution = $true }
            'handoff' { $info.Status = 'running'; $info.Held = $true; $execution = $true }
            'block' { $info.Status = 'blocked'; $info.Held = $true }
            'release' { $info.Held = $false }
        }
        if ($execution) {
            $info.HasExecution = $true
            if (-not $info.FirstExecutionTs -and $ts) { $info.FirstExecutionTs = $ts }
        }
    }
    return $info
}

function Get-OpenLedgerTasks {
    param($Events)
    $open = @{}
    foreach ($k in $Events.Keys) {
        $info = Get-LedgerTaskInfo $Events[$k]
        if (-not $info.Has) { continue }
        if ($info.Status -in @('done', 'abandoned', 'planned', 'ready')) { continue }
        $parts = $k.Split('|')
        $open[$k] = [pscustomobject]@{
            issue = $parts[0]; task = $parts[1]
            owner = $info.Owner; ts = $info.Ts; repo = $info.Repo
            status = $info.Status; subagent = $info.Subagent; wave = $info.Wave
            held = $info.Held
        }
    }
    return $open
}

function Get-LedgerSessions {
    param([string]$Path)
    $map = [ordered]@{}
    foreach ($e in @(Read-LedgerSessionEvents -Path $Path)) {
        $ev = Get-LedgerField $e 'event'
        $id = Get-LedgerField $e 'session'
        if (-not $id) { continue }
        $ts = Get-LedgerField $e 'ts'
        switch ($ev) {
            'session-register' {
                $map[$id] = [pscustomobject]@{
                    id = $id; role = (Get-LedgerField $e 'role'); issue = (Get-LedgerField $e 'issue');
                    task = (Get-LedgerField $e 'task'); host = (Get-LedgerField $e 'host');
                    started = $ts; lastHeartbeat = $ts; closed = $false; closedTs = ''; note = (Get-LedgerField $e 'note')
                }
            }
            'session-heartbeat' {
                if ($map.Contains($id)) {
                    $map[$id].lastHeartbeat = $ts
                    if ((Get-LedgerField $e 'note')) { $map[$id].note = (Get-LedgerField $e 'note') }
                }
            }
            'session-close' {
                if ($map.Contains($id)) {
                    $map[$id].closed = $true
                    $map[$id].closedTs = $ts
                    if ((Get-LedgerField $e 'note')) { $map[$id].note = (Get-LedgerField $e 'note') }
                }
            }
        }
    }
    return @($map.Values)
}

function Add-LedgerRecord {
    param([string]$Path, [hashtable]$Event, [string]$Ts = '')
    $dir = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not $Event.ContainsKey('ts') -or [string]::IsNullOrWhiteSpace([string]$Event['ts'])) {
        $Event['ts'] = if ($Ts) { $Ts } else { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    }
    ($Event | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Get-LedgerPolicyPath {
    param([string]$LedgerPath)
    $dir = Split-Path $LedgerPath -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.' }
    $base = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileName($LedgerPath))
    $name = if ($base -eq 'ledger') { 'subagent-policy.json' } else { 'subagent-policy.' + $base + '.json' }
    return (Join-Path $dir $name)
}

function Test-PolicyTimestamp {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try { $null = [datetime]::ParseExact($Value, 'yyyy-MM-ddTHH:mm:ss', $null); return $true }
    catch { return $false }
}

function Read-LedgerPolicyEvents {
    param([string]$Path)
    $list = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ((Get-LedgerField $e 'event') -eq 'policy') { $list.Add($e) }
    }
    return @($list)
}

function Get-PolicyFileInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Since = ''; Source = ''; AuthorizedBy = ''; Thumbprint = ''; Status = 'missing' }
    }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $since = Get-LedgerField $j 'since'
        if (-not (Test-PolicyTimestamp $since)) {
            return [pscustomobject]@{ Exists = $true; Since = $since; Source = ''; AuthorizedBy = ''; Thumbprint = ''; Status = 'invalid' }
        }
        return [pscustomobject]@{
            Exists = $true; Since = $since
            Source = (Get-LedgerField $j 'source'); AuthorizedBy = (Get-LedgerField $j 'authorizedBy')
            Thumbprint = (Get-LedgerField $j 'thumbprint'); Status = 'ok'
        }
    } catch {
        return [pscustomobject]@{ Exists = $true; Since = ''; Source = ''; AuthorizedBy = ''; Thumbprint = ''; Status = 'invalid' }
    }
}

# --- policy signing (PFX + password) -----------------------------------------

function Resolve-PolicyPfx {
    param([string]$PfxPath = '', [string]$PfxPassword = '')
    if ([string]::IsNullOrWhiteSpace($PfxPath)) { $PfxPath = $env:AGENTOS_POLICY_PFX }
    if ([string]::IsNullOrWhiteSpace($PfxPassword)) { $PfxPassword = $env:AGENTOS_POLICY_PFX_PASSWORD }
    if ([string]::IsNullOrWhiteSpace($PfxPath)) { return $null }
    if (-not (Test-Path -LiteralPath $PfxPath)) { throw "policy PFX not found: $PfxPath" }
    return [pscustomobject]@{ Path = $PfxPath; Password = $PfxPassword }
}

function Open-PolicyCertificate {
    param([string]$PfxPath, [string]$PfxPassword)
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $PfxPassword, $flags)
    if (-not $cert.HasPrivateKey) { throw "policy PFX has no private key: $PfxPath" }
    return $cert
}

function Get-PolicyPayload {
    param($Event)
    return ('policy|{0}|{1}|{2}|{3}|{4}' -f (Get-LedgerField $Event 'ts'), (Get-LedgerField $Event 'since'), (Get-LedgerField $Event 'source'), (Get-LedgerField $Event 'authorizedBy'), (Get-LedgerField $Event 'note'))
}

function Add-PolicySignature {
    param([hashtable]$Event, [string]$PfxPath, [string]$PfxPassword)
    $key = Resolve-PolicyPfx -PfxPath $PfxPath -PfxPassword $PfxPassword
    if ($null -eq $key) { throw 'policy signing requires -PfxPath/-PfxPassword or AGENTOS_POLICY_PFX/AGENTOS_POLICY_PFX_PASSWORD' }
    $cert = Open-PolicyCertificate -PfxPath $key.Path -PfxPassword $key.Password
    # PS 5.1 does not surface .NET extension methods on instances; call the static class.
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($null -eq $rsa) { throw 'policy PFX key is not RSA' }
    $payload = Get-PolicyPayload ([pscustomobject]$Event)
    $sigBytes = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($payload), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $Event['sig'] = [ordered]@{
        alg        = 'RS256'
        thumbprint = $cert.Thumbprint
        cert       = [Convert]::ToBase64String($cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        value      = [Convert]::ToBase64String($sigBytes)
    }
    return $Event
}

function Test-PolicySignature {
    param($Event, [string]$PinnedThumbprint = '')
    $sigObj = $null
    if ($null -ne $Event -and $null -ne $Event.PSObject.Properties['sig']) { $sigObj = $Event.sig }
    if ($null -eq $sigObj) { return [pscustomobject]@{ Ok = $false; Reason = 'unsigned'; Thumbprint = '' } }
    $alg = Get-LedgerField $sigObj 'alg'
    $thumb = Get-LedgerField $sigObj 'thumbprint'
    $certB64 = Get-LedgerField $sigObj 'cert'
    $value = Get-LedgerField $sigObj 'value'
    if ($alg -ne 'RS256' -or [string]::IsNullOrWhiteSpace($thumb) -or [string]::IsNullOrWhiteSpace($certB64) -or [string]::IsNullOrWhiteSpace($value)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'signature-schema'; Thumbprint = $thumb }
    }
    if ($PinnedThumbprint -and $thumb -ne $PinnedThumbprint) {
        return [pscustomobject]@{ Ok = $false; Reason = 'key-mismatch'; Thumbprint = $thumb }
    }
    try {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($certB64))
        if ($cert.Thumbprint -ne $thumb) { return [pscustomobject]@{ Ok = $false; Reason = 'cert-thumbprint'; Thumbprint = $thumb } }
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        $payload = Get-PolicyPayload $Event
        $ok = $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($payload), [Convert]::FromBase64String($value), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return [pscustomobject]@{ Ok = [bool]$ok; Reason = $(if ($ok) { '' } else { 'signature-mismatch' }); Thumbprint = $thumb }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = ('signature-error: ' + $_.Exception.Message); Thumbprint = $thumb }
    }
}

function Get-SubagentPolicy {
    param([string]$LedgerPath)
    $file = Get-PolicyFileInfo -Path (Get-LedgerPolicyPath $LedgerPath)
    $events = @(Read-LedgerPolicyEvents -Path $LedgerPath)
    if ($events.Count -eq 0) {
        if ($file.Exists) {
            return [pscustomobject]@{
                Mode = 'orphan-file'; Since = ''; Source = ''; AuthorizedBy = ''; Thumbprint = '';
                FileStatus = $file.Status; FileSince = '';
                Error = 'policy file exists without a ledger policy event; run audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>'
            }
        }
        return [pscustomobject]@{
            Mode = 'missing'; Since = ''; Source = ''; AuthorizedBy = ''; Thumbprint = '';
            FileStatus = 'missing'; FileSince = '';
            Error = 'no signed subagent policy; run audit -InitPolicy -PfxPath <pfx> -PfxPassword <pwd> -AuthorizedBy <who>'
        }
    }

    # Every policy event must be signed, and every event must chain to the
    # thumbprint pinned by the first event. A raw/unsigned/forged event is invalid.
    $pinned = ''
    $sigError = ''
    foreach ($e in $events) {
        $thumb = ''
        if ($null -ne $e.PSObject.Properties['sig']) { $thumb = Get-LedgerField $e.sig 'thumbprint' }
        if ([string]::IsNullOrWhiteSpace($pinned) -and $thumb) { $pinned = $thumb }
        $chk = Test-PolicySignature -Event $e -PinnedThumbprint $pinned
        if (-not $chk.Ok) { $sigError = $chk.Reason; break }
    }

    $last = $events[$events.Count - 1]
    $since = Get-LedgerField $last 'since'
    $source = Get-LedgerField $last 'source'
    $authorizedBy = Get-LedgerField $last 'authorizedBy'
    $ts = Get-LedgerField $last 'ts'
    $allowedSources = @('track-start', 'audit-init', 'audit-override', 'env-override')
    if (-not (Test-PolicyTimestamp $since) -or -not (Test-PolicyTimestamp $ts) -or [string]::IsNullOrWhiteSpace($authorizedBy) -or ($allowedSources -notcontains $source)) {
        return [pscustomobject]@{ Mode = 'invalid'; Since = $since; Source = $source; AuthorizedBy = $authorizedBy; Thumbprint = $pinned; FileStatus = $file.Status; FileSince = $file.Since; Error = 'policy event failed authorization/schema validation' }
    }
    if ($sigError) {
        return [pscustomobject]@{ Mode = 'invalid'; Since = $since; Source = $source; AuthorizedBy = $authorizedBy; Thumbprint = $pinned; FileStatus = $file.Status; FileSince = $file.Since; Error = ('policy signature invalid: ' + $sigError) }
    }
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    if ($since -gt $now) {
        return [pscustomobject]@{ Mode = 'future'; Since = $since; Source = $source; AuthorizedBy = $authorizedBy; Thumbprint = $pinned; FileStatus = $file.Status; FileSince = $file.Since; Error = 'policy since is in the future' }
    }
    $fileStatus = $file.Status
    if (-not $file.Exists) { $fileStatus = 'missing' }
    elseif ($file.Status -eq 'ok' -and ($file.Since -ne $since -or $file.Thumbprint -ne $pinned)) { $fileStatus = 'mismatch' }
    return [pscustomobject]@{ Mode = 'active'; Since = $since; Source = $source; AuthorizedBy = $authorizedBy; Thumbprint = $pinned; FileStatus = $fileStatus; FileSince = $file.Since; Error = '' }
}

function Add-LedgerPolicyEvent {
    param(
        [string]$LedgerPath,
        [string]$Since = '',
        [string]$Source = 'track-start',
        [string]$AuthorizedBy = '',
        [string]$Note = '',
        [string]$PfxPath = '',
        [string]$PfxPassword = ''
    )
    if ([string]::IsNullOrWhiteSpace($Since)) { $Since = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    if (-not (Test-PolicyTimestamp $Since)) { throw "invalid policy since (expected yyyy-MM-ddTHH:mm:ss): $Since" }
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    if ($Since -gt $now) { throw "refuse future policy since: $Since" }
    if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) { throw 'policy change requires -AuthorizedBy <who>' }
    $event = @{
        ts = $now; event = 'policy'; issue = ''; task = ''; since = $Since; source = $Source;
        authorizedBy = $AuthorizedBy; note = $Note
    }
    $event = Add-PolicySignature -Event $event -PfxPath $PfxPath -PfxPassword $PfxPassword
    # Append-only key pin: once a policy exists, later events must use the same key.
    # Key rotation is intentionally out of scope (a new ledger / explicit migration is required).
    $existing = @(Read-LedgerPolicyEvents -Path $LedgerPath)
    if ($existing.Count -gt 0) {
        $pinned = ''
        foreach ($e in $existing) {
            if ($null -ne $e.PSObject.Properties['sig']) { $pinned = Get-LedgerField $e.sig 'thumbprint' }
            if ($pinned) { break }
        }
        if ($pinned -and $event['sig']['thumbprint'] -ne $pinned) {
            throw ('policy key mismatch: existing policy is pinned to thumbprint {0}; refusing key {1}' -f $pinned, $event['sig']['thumbprint'])
        }
    }
    $dir = Split-Path $LedgerPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-LedgerRecord -Path $LedgerPath -Event $event
    $cache = [ordered]@{
        since = $Since; updated = $now; source = $Source; authorizedBy = $AuthorizedBy;
        note = $Note; thumbprint = $event['sig']['thumbprint']
    }
    $cache | ConvertTo-Json | Set-Content -LiteralPath (Get-LedgerPolicyPath $LedgerPath) -Encoding UTF8
    return [pscustomobject]@{ Since = $Since; Source = $Source; AuthorizedBy = $AuthorizedBy; Thumbprint = $event['sig']['thumbprint'] }
}

function Get-SubagentGapStatus {
    param($Info, $Policy)
    if ($null -eq $Info -or -not $Info.HasExecution) { return 'ok' }
    if ($Info.HasStart -and $Info.StartSubagent) { return 'ok' }
    if ($null -ne $Policy -and $Policy.Mode -eq 'active' -and $Info.FirstExecutionTs -and $Info.FirstExecutionTs -lt $Policy.Since) { return 'legacy' }
    return 'missing'
}
