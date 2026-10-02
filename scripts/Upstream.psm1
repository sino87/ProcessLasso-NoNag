Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UpstreamRelease([string]$Html) {
    $body = [regex]::Match($Html, '(?is)<tbody\b[^>]*\bid="pl-dl-body-stable"[^>]*>(.*?)</tbody>')
    $rows = [regex]::Matches($body.Groups[1].Value, '(?is)<tr\b[^>]*\bdata-arch="x64"[^>]*>(.*?)</tr>')
    if (-not $body.Success -or $rows.Count -ne 1) { throw 'Stable x64 release row unavailable.' }
    $row = $rows[0].Groups[1].Value
    $version = [regex]::Match($row, '<td>\s*(\d+\.\d+\.\d+\.\d+)\s*</td>')
    $hash = [regex]::Match($row, 'data-sha="([a-fA-F0-9]{64})"')
    $link = [regex]::Match($row, 'href="(https://dl\.bitsum\.com/files/processlassosetup64\.exe)"')
    if (-not $version.Success -or -not $hash.Success -or -not $link.Success) { throw 'Release metadata incomplete.' }
    @{ Version = $version.Groups[1].Value; InstallerHash = $hash.Groups[1].Value.ToLowerInvariant(); Url = $link.Groups[1].Value }
}

function Assert-BitsumSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'CN=Bitsum Technologies \(Bitsum LLC\)(?:,|$)') {
        throw 'Valid Bitsum signature required.'
    }
}

function Get-StaticResult([byte[]]$Data, [string]$ModulePath) {
    $module = Import-Module $ModulePath -Force -PassThru
    & $module {
        param($Data)
        $hash = Get-DataHash $Data
        $profile = Get-NoNagProfiles | Where-Object { $_.OriginalHash -eq $hash } | Select-Object -First 1
        $diagnostic = if ($profile) { $profile } else { Get-NoNagProfiles | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 }
        $sites = foreach ($patch in $diagnostic.Patches) {
            $site = @{ Offset = $patch.Offset; Expected = [BitConverter]::ToString($patch.Before).Replace('-', ' '); Length = $patch.Before.Length }
            $actual = 'Out of range'
            if ($Data.Length -ge $site.Offset + $site.Length) {
                $actual = [BitConverter]::ToString($Data, $site.Offset, $site.Length).Replace('-', ' ')
            }
            @{ Offset = ('0x{0:X}' -f $site.Offset); Expected = $site.Expected; Actual = $actual; Matches = $actual -ceq $site.Expected }
        }
        if (-not $profile) {
            return @{ Status = 'review'; Reason = 'Executable hash is not supported by the current patch. Offset matches are diagnostic only.'; ExecutableHash = $hash; Sites = @($sites) }
        }
        $patched = New-PatchedData $Data
        $changed = @(for ($i = 0; $i -lt $Data.Length; $i++) { if ($Data[$i] -ne $patched[$i]) { $i } })
        $expected = @(foreach ($patch in $profile.Patches) {
            for ($i = 0; $i -lt $patch.Before.Length; $i++) {
                if ($patch.Before[$i] -ne $patch.After[$i]) { $patch.Offset + $i }
            }
        })
        if (($changed -join ',') -cne ($expected -join ',')) { throw 'Unexpected patch changes.' }
        @{ Status = 'pass'; Reason = 'Registered executable and exact patch changes verified.'; ExecutableHash = $hash; Sites = @($sites) }
    } $Data
}

function Get-NotificationPlan($State, $Report) {
    $events = @()
    if ($Report.Status -eq 'error') {
        if ($State.LastError -cne $Report.ErrorKey) { $events += @{ Kind = 'error'; Key = $Report.ErrorKey } }
    } else {
        if ($State.LastError) { $events += @{ Kind = 'recovery'; Key = '' } }
        if ($Report.Status -eq 'review' -and $Report.ExecutableHash -notin $State.NotifiedHashes) {
            $events += @{ Kind = 'review'; Key = $Report.ExecutableHash }
        }
    }
    return ,$events
}

function Set-StaticReadme([string]$Text, [string]$Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Invalid version.' }
    $pattern = '(?m)^\| Automated (?:compatibility|static) check \|[^\r\n]*$'
    if ([regex]::Matches($Text, $pattern).Count -ne 1) { throw 'README check row unavailable.' }
    [regex]::Replace($Text, $pattern, "| Automated static check | Process Lasso $Version x64 |")
}

function Send-CheckNotification($State, $Event, [scriptblock]$Send) {
    & $Send | Out-Null
    switch ($Event.Kind) {
        'review' { $State.NotifiedHashes = @($State.NotifiedHashes) + $Event.Key }
        'error' { $State.LastError = $Event.Key }
        'recovery' { $State.LastError = '' }
    }
}

Export-ModuleMember -Function Get-UpstreamRelease, Assert-BitsumSignature, Get-StaticResult, Get-NotificationPlan, Set-StaticReadme, Send-CheckNotification
