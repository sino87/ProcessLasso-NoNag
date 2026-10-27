Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Upstream.psm1') -Force
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
Assert ($release.Version -eq '18.4.0.48' -and $release.InstallerHash -eq $hash) 'Stable x64 selected instead of beta or x86'
Assert-Throws { Get-UpstreamRelease ($html.Replace('data-sha=','checksum=')) } 'Missing checksum refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('https://dl.bitsum.com/','https://example.com/')) } 'Unofficial download refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('pl-dl-body-stable','changed-layout')) } 'Unknown page layout refused'
$result=Get-StaticResult ([byte[]](0,1,2)) (Join-Path $PSScriptRoot '../src/NoNag.psm1')
Assert ($result.Status -eq 'review') 'Unknown executable cannot pass'
$data=New-Object byte[] 1000000
$data[0xE168C]=0x74; $data[0xE168D]=0x4D
[Array]::Copy([byte[]](0x0F,0x85,0xD9,0,0,0),0,$data,0xE4BF2,6)
$data[0xE4CD8]=0x75; $data[0xE4CD9]=0x38
$result=Get-StaticResult $data (Join-Path $PSScriptRoot '../src/NoNag.psm1')
Assert ($result.Status -eq 'review' -and @($result.Sites | Where-Object Matches).Count -eq 3) 'Matching offsets cannot approve an unknown hash'
$module=Import-Module (Join-Path $PSScriptRoot '../src/NoNag.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('NoNag-profile-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/profiles.json'))
    foreach ($bad in @($text.Replace('eb4d','eb00'),$text.Replace('"VmValidated": true','"VmValidated": "true"'),$text.Replace('"Offset": 927026','"Offset": 1'))) {
        [IO.File]::WriteAllText($temp,$bad)
        Assert-Throws { & $module { param($path) Read-NoNagProfiles $path } $temp } 'Malformed profile refused'
    }
} finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
exit 0
