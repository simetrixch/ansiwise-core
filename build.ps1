<#
.SYNOPSIS
  build.ps1 — prove this part locally, the way .github/workflows/checks.yml does.
  Bash twin: build.sh in this folder. The two are held to answering identically.

.DESCRIPTION
  THIS REPOSITORY BUILDS NOTHING. It is a passive part of ansiwise-cli: no binary, no release, no
  tag of its own. "Building" it therefore means proving it — resolving it, and running the gate
  that decides whether it is sound.

  WHY IT EXISTS BESIDE THE WORKFLOW. The workflow answers on a push, which is the right moment for
  a change somebody else will read. This is for the other times: a run you want NOW, without
  pushing, and with the whole output in front of you rather than folded into a page.
#>
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)

Write-Host 'build: resolving'
dart pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'build: the gate'
dart run tool/ci.dart
exit $LASTEXITCODE
