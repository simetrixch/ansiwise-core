<#
.SYNOPSIS
  check.ps1 — every check of this repository, run here, in one command.
  Bash twin: check.sh beside this file. The two are held to answering identically.

.DESCRIPTION
  WHO RUNS IT. A person on Windows runs it while working, to get the same answer without pushing.
  The push hook (.githooks/pre-push) is bash and runs check.sh, because a git hook is started as a
  shell script on every platform.

  THE STEPS ARE NAMED. The run stops at the first red step. Its last line is then
  `check: FAIL — <step>`, where <step> is the command that was red. A run where every step is
  green ends with `check: OK — every check green`.

  A MISSING TOOL IS A RED STEP, NEVER A SKIPPED ONE. A skipped step prints nothing, and a run that
  prints nothing about a check reads like a run in which that check passed.

  THE DART VERSION IS NOT READ HERE. tool/gate/pins.dart names the one Dart SDK the checks of this
  repository are true against, and tool/ci.dart refuses every other one, printing the version it
  found and the version it expected. Reading that pin here as well would make this file a second
  carrier of it, and a second carrier drifts.
#>
$ErrorActionPreference = 'Stop'

# The exit code of dart is read below, by hand, so that a red step ends with the verdict line this
# file promises. Left at $true, PowerShell turns a non-zero exit code into a terminating error and
# the verdict line is never reached.
$PSNativeCommandUseErrorActionPreference = $false

# The verdict lines carry an em dash, and both twins have to print it as the same characters.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

Set-Location (Split-Path -Parent $PSScriptRoot)

function Stop-Check {
  param([Parameter(Mandatory)] [string] $Step)
  Write-Host "check: FAIL — $Step"
  exit 1
}

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
  Write-Host 'dart is not on PATH. Every check of this repository is a Dart program, so none of them can start.'
  Stop-Check 'dart pub get'
}

Write-Host 'check: dart pub get'
dart pub get
if ($LASTEXITCODE -ne 0) { Stop-Check 'dart pub get' }

Write-Host 'check: dart run tool/ci.dart'
dart run tool/ci.dart
if ($LASTEXITCODE -ne 0) { Stop-Check 'dart run tool/ci.dart' }

Write-Host 'check: OK — every check green'
