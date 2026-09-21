# Cloudflare Hosts Sync for Windows PowerShell
#
# 从公开 GitHub raw 拉取 QNAP 已验证的 hosts-map.tsv，逐域名做真实 HTTPS
# 检测，只更新 Windows Hosts 的 CF-YX-WIN-SYNC Marker，不修改 OpenSurge。

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Status,
    [switch]$NoVerify,
    [string]$HostsFile,
    [string]$Repository,
    [string]$Branch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($DryRun -and $Status) {
    throw 'DryRun and Status cannot be used together.'
}

if (-not $HostsFile) {
    $HostsFile = if ($env:CLOUDFLARE_HOSTS_FILE) {
        $env:CLOUDFLARE_HOSTS_FILE
    } else {
        Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    }
}
if (-not $Repository) {
    $Repository = if ($env:CLOUDFLARE_HOSTS_REPO) { $env:CLOUDFLARE_HOSTS_REPO } else { 'zyk1172/cloudflare-hosts-sync' }
}
if (-not $Branch) {
    $Branch = if ($env:CLOUDFLARE_HOSTS_BRANCH) { $env:CLOUDFLARE_HOSTS_BRANCH } else { 'main' }
}

$BeginMarker = if ($env:CLOUDFLARE_HOSTS_BEGIN_MARKER) { $env:CLOUDFLARE_HOSTS_BEGIN_MARKER } else { '# CF-YX-WIN-SYNC-BEGIN' }
$EndMarker = if ($env:CLOUDFLARE_HOSTS_END_MARKER) { $env:CLOUDFLARE_HOSTS_END_MARKER } else { '# CF-YX-WIN-SYNC-END' }
$LegacyBeginMarker = if ($env:CLOUDFLARE_HOSTS_LEGACY_BEGIN_MARKER) { $env:CLOUDFLARE_HOSTS_LEGACY_BEGIN_MARKER } else { '# BEGIN PT-CLOUDFLARE-MANAGED' }
$LegacyEndMarker = if ($env:CLOUDFLARE_HOSTS_LEGACY_END_MARKER) { $env:CLOUDFLARE_HOSTS_LEGACY_END_MARKER } else { '# END PT-CLOUDFLARE-MANAGED' }
$FetchMode = if ($env:CLOUDFLARE_HOSTS_FETCH_MODE) { $env:CLOUDFLARE_HOSTS_FETCH_MODE } else { 'raw' }
$RawBaseUrl = if ($env:CLOUDFLARE_HOSTS_RAW_BASE_URL) {
    $env:CLOUDFLARE_HOSTS_RAW_BASE_URL.TrimEnd('/')
} else {
    "https://raw.githubusercontent.com/$Repository/$Branch"
}
$VerifyBeforeApply = if ($env:CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY) {
    $env:CLOUDFLARE_HOSTS_VERIFY_BEFORE_APPLY -ne 'false'
} else {
    $true
}
if ($NoVerify) {
    $VerifyBeforeApply = $false
}
$VerifyRetries = if ($env:CLOUDFLARE_HOSTS_VERIFY_RETRIES) { [int]$env:CLOUDFLARE_HOSTS_VERIFY_RETRIES } else { 1 }
$VerifyConnectTimeout = if ($env:CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT) { [int]$env:CLOUDFLARE_HOSTS_VERIFY_CONNECT_TIMEOUT } else { 4 }
$VerifyMaxTime = if ($env:CLOUDFLARE_HOSTS_VERIFY_MAX_TIME) { [int]$env:CLOUDFLARE_HOSTS_VERIFY_MAX_TIME } else { 8 }
$RejectHttpCodes = if ($env:CLOUDFLARE_HOSTS_REJECT_HTTP_CODES) {
    @($env:CLOUDFLARE_HOSTS_REJECT_HTTP_CODES -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    @('000', '403')
}

if ($FetchMode -notin @('raw', 'api', 'auto')) {
    throw 'CLOUDFLARE_HOSTS_FETCH_MODE must be raw, api or auto.'
}
if ($VerifyRetries -lt 1 -or $VerifyConnectTimeout -lt 1 -or $VerifyMaxTime -lt 1) {
    throw 'Verification retry and timeout values must be positive integers.'
}
if (-not (Test-Path -LiteralPath $HostsFile -PathType Leaf)) {
    throw "Hosts file not found: $HostsFile"
}

$Mode = if ($Status) { 'status' } elseif ($DryRun) { 'dry-run' } else { 'apply' }
$TempRoot = Join-Path $env:TEMP ("cloudflare-hosts-sync.{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$LockPath = Join-Path $env:TEMP 'cloudflare-hosts-sync.lock'
$LockStream = $null

function Get-RemoteText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $url = "$RawBaseUrl/$RelativePath"
    try {
        $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
        if ($FetchMode -eq 'api') {
            if (-not $gh) {
                throw 'CLOUDFLARE_HOSTS_FETCH_MODE=api requires gh.exe and GitHub authentication.'
            }
            $apiPath = "/repos/$Repository/contents/$RelativePath?ref=$Branch"
            return (& gh.exe api -H 'Accept: application/vnd.github.raw' $apiPath | Out-String).TrimEnd("`r", "`n")
        }
        if ($FetchMode -eq 'auto') {
            try {
                return (Invoke-WebRequest -UseBasicParsing -Uri $url -ErrorAction Stop).Content
            } catch {
                if (-not $gh) { throw }
            }
            $apiPath = "/repos/$Repository/contents/$RelativePath?ref=$Branch"
            return (& gh.exe api -H 'Accept: application/vnd.github.raw' $apiPath | Out-String).TrimEnd("`r", "`n")
        }
        return (Invoke-WebRequest -UseBasicParsing -Uri $url -ErrorAction Stop).Content
    } catch {
        throw "Cannot fetch $url : $($_.Exception.Message)"
    }
}

function Test-ExactDomain {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

function Test-ValidIp {
    param([string]$Value)
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) {
        return $false
    }
    $bytes = $address.GetAddressBytes()
    if ($bytes.Count -eq 4 -and $bytes[0] -eq 198 -and ($bytes[1] -eq 18 -or $bytes[1] -eq 19)) {
        return $false
    }
    return $true
}

function Get-MapRecords {
    param([Parameter(Mandatory = $true)][string]$MapText)

    $records = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $invalid = $false
    foreach ($line in ($MapText -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }
        $fields = $line -split "`t", -1
        if ($fields.Count -lt 10) {
            $invalid = $true
            continue
        }
        $domain = $fields[0].Trim().ToLowerInvariant()
        $ip = $fields[1].Trim()
        $group = $fields[2].Trim()
        $status = $fields[9].Trim()
        if (-not (Test-ExactDomain $domain) -or
            -not (Test-ValidIp $ip) -or
            $group -notin @('latency', 'bandwidth') -or
            $status -notin @('VERIFIED', 'RETAINED')) {
            $invalid = $true
            continue
        }
        if ($seen.ContainsKey($domain)) {
            continue
        }
        $seen[$domain] = $true
        $records.Add([pscustomobject]@{
            Domain = $domain
            Ip = $ip
            Group = $group
            Delay = $fields[3].Trim()
            Speed = $fields[4].Trim()
            Loss = $fields[5].Trim()
            Colo = $fields[6].Trim()
            VerifiedAt = $fields[7].Trim()
            SourceHttpCode = $fields[8].Trim()
            Status = $status
        })
    }
    if ($invalid) {
        throw 'hosts-map.tsv contains an invalid or unsupported record.'
    }
    return @($records | Sort-Object Domain)
}

function Test-MapRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$CurlPath,
        [Parameter(Mandatory = $true)][string]$ErrorFile
    )

    $resolveIp = $Record.Ip
    if ($resolveIp.Contains(':')) { $resolveIp = "[$resolveIp]" }
    $resolveSpec = '{0}:443:{1}' -f $Record.Domain, $resolveIp
    $curlArgs = @(
        '--noproxy', '*',
        '--silent', '--show-error',
        '--connect-timeout', [string]$VerifyConnectTimeout,
        '--max-time', [string]$VerifyMaxTime,
        '--resolve', $resolveSpec,
        '--output', 'NUL',
        '--write-out', '%{http_code}',
        "https://$($Record.Domain)/"
    )
    $output = (& $CurlPath @curlArgs 2> $ErrorFile | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    $httpCode = if ($output -match '^\d{3}$') { $output } else { '000' }
    if ($exitCode -ne 0 -or $httpCode -eq '000') {
        $reason = if (Test-Path -LiteralPath $ErrorFile) {
            (Get-Content -LiteralPath $ErrorFile -Raw).Trim()
        } else {
            'connection_or_tls_failure'
        }
        if (-not $reason) { $reason = 'connection_or_tls_failure' }
        if ($reason.Length -gt 180) { $reason = $reason.Substring(0, 180) }
        return [pscustomobject]@{ Success = $false; HttpCode = '000'; Reason = $reason }
    }
    if ($RejectHttpCodes -contains $httpCode) {
        return [pscustomobject]@{ Success = $false; HttpCode = $httpCode; Reason = 'rejected_http_code' }
    }
    return [pscustomobject]@{ Success = $true; HttpCode = $httpCode; Reason = 'http_response' }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    $mapText = Get-RemoteText -RelativePath 'hosts-map.tsv'
    $statusText = $null
    try { $statusText = Get-RemoteText -RelativePath 'status.json' } catch { $statusText = $null }
    $records = Get-MapRecords -MapText $mapText
    $explicitEmpty = $false
    if ($statusText) {
        try {
            $statusDoc = $statusText | ConvertFrom-Json
            if ([int]$statusDoc.schema -ge 2 -and [int]$statusDoc.domain_count -eq 0) {
                $explicitEmpty = $true
            }
        } catch {
            $explicitEmpty = $false
        }
    }
    if ($records.Count -eq 0 -and -not $explicitEmpty) {
        throw 'hosts-map.tsv has no valid mappings and status.json does not declare an explicit empty schema-2 map.'
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($Mode -ne 'status' -and $VerifyBeforeApply -and -not $curl) {
        throw 'curl.exe is required for per-domain HTTPS verification. Install/use Windows 10 or Windows 11 built-in curl.exe.'
    }
    $curlPath = $null
    if ($curl) {
        if ($curl.PSObject.Properties['Path']) {
            $curlPath = $curl.Path
        } elseif ($curl.PSObject.Properties['Source']) {
            $curlPath = $curl.Source
        } else {
            $curlPath = $curl.Definition
        }
    }

    try {
        $LockStream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw "Another Cloudflare Hosts Sync instance is running, or the lock cannot be opened: $LockPath"
    }

    $blockLines = New-Object 'System.Collections.Generic.List[string]'
    $verificationLines = New-Object 'System.Collections.Generic.List[string]'
    $passed = 0
    $rejected = 0
    $index = 0
    foreach ($record in $records) {
        $index++
        if ($Mode -eq 'status' -or -not $VerifyBeforeApply) {
            $blockLines.Add("$($record.Ip)`t$($record.Domain)")
            continue
        }
        $errorFile = Join-Path $TempRoot ("curl-{0}.err" -f $index)
        $result = $null
        for ($attempt = 1; $attempt -le $VerifyRetries; $attempt++) {
            $result = Test-MapRecord -Record $record -CurlPath $curlPath -ErrorFile $errorFile
            if ($result.Success -or $attempt -eq $VerifyRetries) { break }
            Start-Sleep -Seconds 1
        }
        if ($result.Success) {
            $passed++
            $verificationLines.Add("VERIFY $($record.Domain) $($record.Ip) HTTP=$($result.HttpCode) OK")
            $blockLines.Add("$($record.Ip)`t$($record.Domain)")
        } else {
            $rejected++
            $verificationLines.Add("VERIFY $($record.Domain) $($record.Ip) HTTP=$($result.HttpCode) FAIL $($result.Reason)")
        }
    }

    $blockLines = @($blockLines | Sort-Object { ($_ -split "`t", 2)[1] })
    if ($Mode -ne 'status' -and $blockLines.Count -eq 0 -and -not $explicitEmpty) {
        throw 'No mapping passed local HTTPS verification; existing Hosts was preserved.'
    }

    $encoding = [Text.Encoding]::Default
    $currentLines = @(Get-Content -LiteralPath $HostsFile -Encoding Default)
    $expectedLines = New-Object 'System.Collections.Generic.List[string]'
    $inside = $false
    $seenBegin = $false
    $seenEnd = $false
    $legacyInside = $false
    $legacySeenBegin = $false
    $legacySeenEnd = $false

    foreach ($line in $currentLines) {
        if ($line -ceq $BeginMarker) {
            if ($inside -or $seenBegin) { throw 'Existing Windows sync Marker is duplicated or malformed.' }
            $expectedLines.Add($BeginMarker)
            foreach ($blockLine in $blockLines) { $expectedLines.Add($blockLine) }
            $inside = $true
            $seenBegin = $true
            continue
        }
        if ($line -ceq $EndMarker) {
            if (-not $inside -or $seenEnd) { throw 'Existing Windows sync Marker is duplicated or malformed.' }
            $expectedLines.Add($EndMarker)
            $inside = $false
            $seenEnd = $true
            continue
        }
        if ($line -ceq $LegacyBeginMarker) {
            if ($legacyInside -or $legacySeenBegin) { throw 'Existing legacy PT Marker is duplicated or malformed.' }
            $legacyInside = $true
            $legacySeenBegin = $true
            continue
        }
        if ($line -ceq $LegacyEndMarker) {
            if (-not $legacyInside -or $legacySeenEnd) { throw 'Existing legacy PT Marker is duplicated or malformed.' }
            $legacyInside = $false
            $legacySeenEnd = $true
            continue
        }
        if ($legacyInside -or $inside) { continue }
        $expectedLines.Add($line)
    }
    if ($inside -or $legacyInside) {
        throw 'Existing Hosts contains an incomplete sync Marker; no change was made.'
    }
    if (-not $seenBegin) {
        $expectedLines.Add($BeginMarker)
        foreach ($blockLine in $blockLines) { $expectedLines.Add($blockLine) }
        $expectedLines.Add($EndMarker)
    } elseif (-not $seenEnd) {
        throw 'Existing Windows sync Marker is incomplete; no change was made.'
    }

    $currentText = [IO.File]::ReadAllText($HostsFile, $encoding)
    $newline = if ($currentText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $expectedText = [string]::Join($newline, $expectedLines)
    if ($currentText.EndsWith("`r`n") -or $currentText.EndsWith("`n")) {
        $expectedText += $newline
    }

    Write-Output "GitHub source: $RawBaseUrl/hosts-map.tsv"
    Write-Output "Accepted mappings: $($blockLines.Count)"
    if ($explicitEmpty) {
        Write-Output 'Remote map state: explicit empty mapping set (schema >= 2)'
    }
    Write-Output "Local Windows Marker: $(@($currentLines | Where-Object { $_ -ceq $BeginMarker }).Count)"
    Write-Output "Legacy PT Marker: $(@($currentLines | Where-Object { $_ -ceq $LegacyBeginMarker }).Count)"
    if ($Mode -ne 'status' -and $VerifyBeforeApply) {
        Write-Output "HTTPS verification: passed=$passed rejected=$rejected reject_http_codes=$($RejectHttpCodes -join ',')"
        if ($Mode -eq 'dry-run' -or $rejected -gt 0) {
            $verificationLines | ForEach-Object { Write-Output $_ }
        }
    }

    if ($Mode -eq 'status') {
        $statusLine = if ([StringComparer]::Ordinal.Equals($currentText, $expectedText)) { 'Hosts status: consistent' } else { 'Hosts status: drifted' }
        Write-Output $statusLine
        if ($statusText) { Write-Output $statusText }
        exit 0
    }

    if ($Mode -eq 'dry-run') {
        Write-Output '将写入的 Windows Marker 内容：'
        $start = $expectedLines.IndexOf($BeginMarker)
        $end = $expectedLines.IndexOf($EndMarker)
        if ($start -ge 0 -and $end -ge $start) {
            for ($i = $start; $i -le $end; $i++) { Write-Output $expectedLines[$i] }
        }
        $dryRunLine = if ([StringComparer]::Ordinal.Equals($currentText, $expectedText)) { '结果：无需修改 Hosts' } else { '结果：会修改 Windows Hosts（dry-run 未执行）' }
        Write-Output $dryRunLine
        exit 0
    }

    if ([StringComparer]::Ordinal.Equals($currentText, $expectedText)) {
        Write-Output 'No changes required.'
        exit 0
    }
    if (-not (Test-IsAdministrator)) {
        throw 'Updating Windows Hosts requires an elevated PowerShell. Run PowerShell as Administrator and execute this script again.'
    }

    $hostsDirectory = Split-Path -Parent $HostsFile
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$HostsFile.cloudflare-yx-sync-$timestamp"
    $tempPath = Join-Path $hostsDirectory ('.hosts.cloudflare-yx-sync.{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllText($tempPath, $expectedText, $encoding)
        [IO.File]::Replace($tempPath, $HostsFile, $backupPath, $true)
    } catch {
        throw "Windows Hosts update failed; the original file was not intentionally overwritten. Backup/temp may remain for inspection: $backupPath / $tempPath. $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output "Hosts updated from GitHub. Backup: $backupPath"
} finally {
    if ($LockStream) {
        $LockStream.Dispose()
    }
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
