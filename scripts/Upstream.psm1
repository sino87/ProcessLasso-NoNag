Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CheckerRevision {
    $content = [Collections.Generic.List[byte]]::new()
    foreach ($name in @('check_compatibility.py', 'pe_image.py', 'compatibility-reference.json')) {
        $content.AddRange([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name)))
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($content.ToArray())).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

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

Export-ModuleMember -Function Get-CheckerRevision, Get-UpstreamRelease, Assert-BitsumSignature
