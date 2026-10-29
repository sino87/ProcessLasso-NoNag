Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../scripts/Upstream.psm1') -Force -PassThru
function Assert($Condition,[string]$Name) { if (-not $Condition) { throw "FAIL $Name" }; Write-Output "PASS $Name" }
function Assert-Throws([scriptblock]$Action,[string]$Name) {
    $thrown=$false
    try { & $Action | Out-Null } catch { $thrown=$true }
    Assert $thrown $Name
}
$hash='a'*64
$html='<tbody id="pl-dl-body-beta"><tr data-arch="x64"><td>99.0.0.0</td></tr></tbody>'+
    '<tbody id="pl-dl-body-stable"><tr data-arch="x86"><td>1.0.0.0</td></tr><tr data-arch="x64"><td>18.4.0.48</td><span data-sha="'+$hash+'"></span><a href="https://dl.bitsum.com/files/processlassosetup64.exe">Download</a></tr></tbody>'
$release=Get-UpstreamRelease $html
Assert ($release.Version -eq '18.4.0.48' -and $release.InstallerHash -eq $hash) 'Stable x64 selected'
Assert-Throws { Get-UpstreamRelease ($html.Replace('data-sha=','checksum=')) } 'Missing checksum refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('https://dl.bitsum.com/','https://example.com/')) } 'Unofficial download refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('pl-dl-body-stable','changed-layout')) } 'Unknown page layout refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('</tbody>','<tr data-arch="x64"><td>2.0.0.0</td></tr></tbody>')) } 'Duplicate stable row refused'
foreach ($status in @('NotSigned','HashMismatch','UnknownError')) {
    & $module { param($s) $script:Status=$s; function script:Get-AuthenticodeSignature { [pscustomobject]@{Status=$script:Status;SignerCertificate=$null} } } $status
    Assert-Throws { Assert-BitsumSignature 'unused' } "Signature $status refused"
}
& $module { function script:Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Other publisher'}} } }
Assert-Throws { Assert-BitsumSignature 'unused' } 'Other publisher refused'
