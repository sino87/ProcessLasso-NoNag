[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BaselineDirectory, [Parameter(Mandatory=$true)][string]$TargetDirectory, [string]$PythonPath='python')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = Join-Path $root ('dist/historical-' + [guid]::NewGuid().ToString('N'))
$templates = Join-Path $output 'templates'
$null=New-Item -ItemType Directory -Force $templates
& $PythonPath (Join-Path $PSScriptRoot 'analyze_patch.py') template --exe (Join-Path $BaselineDirectory 'ProcessLasso.exe') --resources (Join-Path $BaselineDirectory 'pl_rsrc_english.dll') --output (Join-Path $templates 'baseline.json')
if ($LASTEXITCODE -ne 0) { throw 'Baseline extraction failed.' }
$reportPath=Join-Path $output 'analysis.json'
& $PythonPath (Join-Path $PSScriptRoot 'analyze_patch.py') analyze --exe (Join-Path $TargetDirectory 'ProcessLasso.exe') --resources (Join-Path $TargetDirectory 'pl_rsrc_english.dll') --templates $templates --output $reportPath
if ($LASTEXITCODE -ne 0) { throw 'Historical analysis failed.' }
$report=[IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
$known=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'src/profiles.json')))
$expected=$known | Where-Object { $_.OriginalHash -eq $report.Profile.OriginalHash }
if ($report.Status -ne 'candidate' -or -not $expected -or $expected.PatchedHash -cne $report.Profile.PatchedHash) { throw 'Historical candidate differs from verified patch.' }
& (Join-Path $PSScriptRoot 'Prepare-Candidate.ps1') -AnalysisPath $reportPath -ExecutablePath (Join-Path $TargetDirectory 'ProcessLasso.exe') -OutputDirectory $output
Write-Output "Historical gate passed: $output"
