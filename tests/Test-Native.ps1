[CmdletBinding()]
param([string]$BuildDirectory = (Join-Path $PSScriptRoot '../build'), [string]$DllPath, [string[]]$ResourcePaths)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bin = Join-Path ([IO.Path]::GetFullPath($BuildDirectory)) 'tests/native/Release'
if (-not $DllPath) { $DllPath = Join-Path $BuildDirectory 'bin/Release/version.dll' }
if (-not $ResourcePaths) { $ResourcePaths = @(Join-Path $bin 'pl_rsrc_test.dll') }
$work = Join-Path ([IO.Path]::GetTempPath()) ('nonag-native-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($work)
try {
    foreach ($resource in $ResourcePaths) {
        foreach ($mode in @('baseline','enabled','other-host')) {
            $case = Join-Path $work ([Guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory((Join-Path $case 'external'))
            $name = if ($mode -eq 'other-host') { 'OtherHost.exe' } else { 'ProcessLasso.exe' }
            Copy-Item -LiteralPath (Join-Path $bin 'dialog_harness.exe') -Destination (Join-Path $case $name)
            Copy-Item -LiteralPath (Join-Path $bin 'dialog_fixture.dll') -Destination $case
            foreach ($destination in @('pl_rsrc_test.dll','unrelated_resources.dll','external/pl_rsrc_test.dll')) {
                Copy-Item -LiteralPath $resource -Destination (Join-Path $case $destination)
            }
            if ($mode -ne 'baseline') { Copy-Item -LiteralPath $DllPath -Destination (Join-Path $case 'version.dll') }
            $expect = if ($mode -eq 'enabled') { 'enabled' } else { 'disabled' }
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $case $name
            $start.Arguments = $expect + ' "' + (Join-Path $case 'pl_rsrc_test.dll') + '"'
            $start.WorkingDirectory = $case
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $process = [Diagnostics.Process]::Start($start)
            if (-not $process.WaitForExit(15000)) { $process.Kill(); throw "Dialog test timed out: $mode" }
            $log = $process.StandardOutput.ReadToEnd()
            if ($process.ExitCode -ne 0 -or $log -notmatch 'RESULT failures=0') { throw "Dialog test failed: $mode`n$log" }
            $process.Dispose()
            Write-Host "PASS $mode : $resource"
        }
    }
    Copy-Item -LiteralPath $DllPath -Destination (Join-Path $work 'version.dll')
    Copy-Item -LiteralPath (Join-Path $bin 'forwarding_test.exe') -Destination $work
    & (Join-Path $work 'forwarding_test.exe') $ResourcePaths[0]
    if ($LASTEXITCODE -ne 0) { throw "VERSION forwarding failed: $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
