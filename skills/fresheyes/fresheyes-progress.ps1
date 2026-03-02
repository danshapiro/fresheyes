#!/usr/bin/env pwsh
# fresheyes-progress.ps1 - Check if a fresheyes review is still producing output.
# Takes no arguments. Prints the line count of the active review's log.
# If this number is growing between calls, the review is not dead.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$logDir = Join-Path ([System.IO.Path]::GetTempPath()) "fresheyes-logs"
$activeFile = Join-Path $logDir ".active"

if (-not (Test-Path -LiteralPath $activeFile)) {
    Write-Output "0"
    exit 0
}

$logFile = (Get-Content -Raw -LiteralPath $activeFile).Trim()
if (-not $logFile -or -not (Test-Path -LiteralPath $logFile)) {
    Write-Output "0"
    exit 0
}

$lineCount = (Get-Content -LiteralPath $logFile | Measure-Object -Line).Lines
Write-Output $lineCount
