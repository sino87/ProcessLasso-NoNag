Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\NoNag.psm1') -Force
$folder = Join-Path ([IO.Path]::GetTempPath()) ("NoNag-exit-'test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $folder
$probe = Join-Path $folder 'worker test.ps1'
$installation = "C:\Test Folder\User's Process Lasso"
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    foreach ($action in @('Enable','Disable')) {
        foreach ($code in @(0,1,10,11)) {
            $body = 'param($Action,$Installation)' + "`r`n"
            $body += 'if ($Action -ne ''' + $action + ''' -or $Installation -ne ''' + $installation.Replace("'", "''") + ''') { exit 99 }' + "`r`n"
            $body += "exit $code"
            [IO.File]::WriteAllText($probe, $body)
            $encoded = New-NoNagWorkerCommand -ScriptPath $probe -Action $action -Installation $installation
            & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded
            if ($LASTEXITCODE -ne $code) { throw "Expected $action exit $code, received $LASTEXITCODE" }
            Write-Host "PASS $action exit code $code and quoted paths"
        }
    }
    [IO.File]::WriteAllText($probe, 'throw ''Worker failed before returning a result.''')
    $encoded = New-NoNagWorkerCommand -ScriptPath $probe -Action Enable -Installation $installation
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $shell
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    try { if ($process.ExitCode -ne 1) { throw 'Unhandled worker failure must return exit code 1.' } }
    finally { $process.Dispose() }
    Write-Host 'PASS Unhandled worker failure'
    Write-Host '9 worker tests passed.'
} finally {
    if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) }
    [IO.Directory]::Delete($folder)
}
exit 0
