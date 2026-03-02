#!/usr/bin/env pwsh
# Fresh Eyes - Independent Code Review runner (PowerShell)
# Usage: ./fresheyes.ps1 [--gpt|--claude|--provider PROVIDER] [--manual|--automatic] 'scope text'

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Exit-WithError {
    param(
        [string]$Message,
        [int]$Code = 1
    )
    Write-Stderr $Message
    exit $Code
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Parse-Args {
    param([string[]]$InputArgs)

    $provider = ""
    $mode = if ($env:FRESHEYES_MODE) { $env:FRESHEYES_MODE } else { "manual" }
    $scopeParts = [System.Collections.Generic.List[string]]::new()

    $i = 0
    while ($i -lt $InputArgs.Count) {
        $arg = $InputArgs[$i]
        switch ($arg) {
            "-h" {
                Write-Output "Usage: fresheyes.ps1 [--gpt|--claude|--provider PROVIDER] [--manual|--automatic|--mode MODE] [scope text]"
                exit 0
            }
            "--help" {
                Write-Output "Usage: fresheyes.ps1 [--gpt|--claude|--provider PROVIDER] [--manual|--automatic|--mode MODE] [scope text]"
                exit 0
            }
            "--gpt" {
                $provider = "gpt"
                $i++
            }
            "--claude" {
                $provider = "claude"
                $i++
            }
            "--provider" {
                if (($i + 1) -ge $InputArgs.Count) {
                    Exit-WithError "Error: --provider requires a value (gpt|claude)."
                }
                $provider = $InputArgs[$i + 1]
                $i += 2
            }
            "--mode" {
                if (($i + 1) -ge $InputArgs.Count) {
                    Exit-WithError "Error: --mode requires a value (manual|automatic)."
                }
                $mode = $InputArgs[$i + 1]
                $i += 2
            }
            "--manual" {
                $mode = "manual"
                $i++
            }
            "--automatic" {
                $mode = "automatic"
                $i++
            }
            "--" {
                for ($j = $i + 1; $j -lt $InputArgs.Count; $j++) {
                    [void]$scopeParts.Add($InputArgs[$j])
                }
                $i = $InputArgs.Count
            }
            default {
                [void]$scopeParts.Add($arg)
                $i++
            }
        }
    }

    if (-not $provider) {
        $provider = if ($env:FRESHEYES_PROVIDER) { $env:FRESHEYES_PROVIDER } else { "gpt" }
    }

    return @{
        provider   = $provider
        mode       = $mode
        scopeParts = $scopeParts
    }
}

function Invoke-CommandCapture {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )
    $output = & $Exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return @{
        output   = $output
        exitCode = $exitCode
    }
}

function Build-AutomaticSummary {
    param(
        [string]$OutputFile,
        [string]$ProviderLabel
    )

    $data = $null
    try {
        $data = Get-Content -Raw -LiteralPath $OutputFile | ConvertFrom-Json
    } catch {
        Exit-WithError "Fresh Eyes: unable to parse $ProviderLabel output. Commit blocked.`nError: $($_.Exception.Message)" 2
    }

    if (-not ($data.PSObject.Properties.Name -contains "approve_commit")) {
        Exit-WithError "Fresh Eyes: approve_commit missing from $ProviderLabel output. Commit blocked." 2
    }

    $issues = @()
    if ($null -ne $data.issues) {
        $issues = @($data.issues)
    }

    if ($data.approve_commit -eq $true) {
        Write-Output "Fresh Eyes: approved."
        if ($issues.Count -gt 0) {
            Write-Output "Notes:"
            foreach ($issue in $issues) {
                $severity = if ($issue.severity) { $issue.severity } else { "unspecified" }
                $file = if ($issue.file) { $issue.file } else { "unknown" }
                $line = $issue.line
                $loc = if ($null -ne $line -and $line -ne "") { "$file`:$line" } else { $file }
                $desc = [string]($issue.description)
                if ($desc.Trim()) {
                    Write-Output "- [$severity] $loc - $($desc.Trim())"
                } else {
                    Write-Output "- [$severity] $loc"
                }
            }
        }
        return 0
    }

    Write-Output "Fresh Eyes: commit not approved."
    if ($issues.Count -gt 0) {
        Write-Output "Issues found:"
        foreach ($issue in $issues) {
            $severity = if ($issue.severity) { $issue.severity } else { "unspecified" }
            $file = if ($issue.file) { $issue.file } else { "unknown" }
            $line = $issue.line
            $loc = if ($null -ne $line -and $line -ne "") { "$file`:$line" } else { $file }
            $desc = [string]($issue.description)
            if ($desc.Trim()) {
                Write-Output "- [$severity] $loc - $($desc.Trim())"
            } else {
                Write-Output "- [$severity] $loc"
            }
        }
    } else {
        Write-Output "No issues listed, but approval was denied."
    }
    return 1
}

$parsed = Parse-Args -InputArgs $args
$provider = [string]$parsed.provider
$mode = [string]$parsed.mode
$scopeParts = $parsed.scopeParts

$model = ""
$providerLabel = ""
switch ($provider) {
    "gpt" {
        $model = if ($env:FRESHEYES_MODEL) { $env:FRESHEYES_MODEL } else { "gpt-5.3-codex" }
        $providerLabel = "Codex"
    }
    "claude" {
        $model = if ($env:FRESHEYES_MODEL) { $env:FRESHEYES_MODEL } else { "opus" }
        $providerLabel = "Claude"
    }
    default {
        Exit-WithError "Error: Unknown provider '$provider'. Use gpt or claude."
    }
}

if ($provider -eq "gpt" -and -not (Test-Command "codex")) {
    Exit-WithError "Error: codex CLI not found.`nInstall it with: npm install -g @openai/codex"
}
if ($provider -eq "claude" -and -not (Test-Command "claude")) {
    Exit-WithError "Error: claude CLI not found.`nInstall it with: npm install -g @anthropic-ai/claude-code"
}

$scopeText = ""
if ($scopeParts.Count -gt 0) {
    $scopeText = [string]::Join(" ", $scopeParts.ToArray())
} else {
    if ($mode -eq "automatic") {
        $scopeText = "Review the staged changes using git diff --cached."
    } else {
        $scopeText = "Review the staged changes using git diff --cached. If nothing is staged, review the most recent commit using git show HEAD."
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$promptFile = ""
$schemaFile = ""
$reasoningEffort = ""
switch ($mode) {
    "manual" {
        $promptFile = Join-Path $scriptDir "fresheyes-prompt.md"
        $reasoningEffort = "xhigh"
    }
    "automatic" {
        $promptFile = Join-Path $scriptDir "fresheyes-automatic-prompt.md"
        $schemaFile = Join-Path $scriptDir "fresheyes-automatic-schema.json"
        $reasoningEffort = "medium"
    }
    default {
        Exit-WithError "Error: Unknown mode '$mode'. Use manual or automatic."
    }
}

if (-not (Test-Path -LiteralPath $promptFile)) {
    Exit-WithError "Error: Prompt file not found: $promptFile"
}
if ($mode -eq "automatic" -and -not (Test-Path -LiteralPath $schemaFile)) {
    Exit-WithError "Error: Schema file not found: $schemaFile"
}

$template = Get-Content -Raw -LiteralPath $promptFile
$prompt = $template.Replace("{{REVIEW_SCOPE}}", $scopeText)

$logDir = Join-Path ([System.IO.Path]::GetTempPath()) "fresheyes-logs"
[void](New-Item -ItemType Directory -Path $logDir -Force)
$logFile = Join-Path $logDir ("fresheyes-{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
$activeFile = Join-Path $logDir ".active"
Set-Content -LiteralPath $activeFile -Value $logFile

Write-Stderr "Fresh Eyes: review starting. This may take up to 30 minutes, please wait patiently."
Write-Stderr "To see the size of the response so far, invoke: $scriptDir/fresheyes-progress.ps1"

$claudeTools = "Bash(git diff:*,git show:*,git log:*,git status:*),Read,Glob,Grep"

if ($mode -eq "automatic") {
    $outputFile = Join-Path $logDir ("fresheyes-automatic-{0}-{1}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID)
    $stderrFile = "$logFile.stderr"

    if ($provider -eq "gpt") {
        $argsList = @(
            "exec",
            "--sandbox", "read-only",
            "--color", "never",
            "--model", $model,
            "-c", "features.shell_snapshot=false",
            "--output-schema", $schemaFile,
            "-o", $outputFile,
            "-c", "model_reasoning_effort=$reasoningEffort",
            $prompt
        )
        $result = Invoke-CommandCapture -Exe "codex" -Arguments $argsList
        $result.output | Tee-Object -FilePath $logFile | Out-Null
        if ($result.exitCode -ne 0) {
            Exit-WithError "Fresh Eyes: $providerLabel failed. Commit blocked.`nFull log: $logFile"
        }
    } else {
        $jsonSchema = Get-Content -Raw -LiteralPath $schemaFile
        $argsList = @(
            "-p",
            "--model", $model,
            "--output-format", "json",
            "--json-schema", $jsonSchema,
            "--allowedTools", $claudeTools,
            "--dangerously-skip-permissions",
            $prompt
        )
        $result = & claude @argsList 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $result | Set-Content -LiteralPath $logFile
        if ($exitCode -ne 0) {
            $stderrText = if (Test-Path -LiteralPath $stderrFile) { Get-Content -Raw -LiteralPath $stderrFile } else { "" }
            Exit-WithError "Fresh Eyes: $providerLabel failed. Commit blocked.`nFull log: $logFile`n$stderrText"
        }

        try {
            $envelope = Get-Content -Raw -LiteralPath $logFile | ConvertFrom-Json
            $inner = $null
            if ($envelope.PSObject.Properties.Name -contains "structured_output" -and $null -ne $envelope.structured_output) {
                $inner = $envelope.structured_output
            } elseif ($envelope.PSObject.Properties.Name -contains "result" -and $null -ne $envelope.result) {
                $inner = $envelope.result
            } else {
                $inner = $envelope
            }
            $inner | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outputFile
        } catch {
            Exit-WithError "Fresh Eyes: unable to parse $providerLabel JSON envelope. Commit blocked.`nFull log: $logFile"
        }
    }

    if (-not (Test-Path -LiteralPath $outputFile) -or ((Get-Item -LiteralPath $outputFile).Length -eq 0)) {
        Exit-WithError "Fresh Eyes: $providerLabel produced no output. Commit blocked.`nFull log: $logFile"
    }

    $status = Build-AutomaticSummary -OutputFile $outputFile -ProviderLabel $providerLabel
    Write-Output ""
    Write-Output "---"
    Write-Output "Full log: $logFile"
    exit $status
}

if ($provider -eq "gpt") {
    $argsList = @(
        "exec",
        "--sandbox", "read-only",
        "--color", "never",
        "--model", $model,
        "-c", "features.shell_snapshot=false",
        "-c", "model_reasoning_effort=$reasoningEffort",
        $prompt
    )
    $result = Invoke-CommandCapture -Exe "codex" -Arguments $argsList
    $result.output | Tee-Object -FilePath $logFile | Out-Null
    if ($result.exitCode -ne 0) {
        Exit-WithError "Fresh Eyes: $providerLabel failed. See log: $logFile"
    }

    $lines = Get-Content -LiteralPath $logFile
    $start = -1
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        if ($lines[$idx] -match '^## Files Examined') {
            $start = $idx
        }
    }
    if ($start -ge 0) {
        $lines[$start..($lines.Count - 1)] | Write-Output
    } else {
        $lines | Write-Output
    }
} else {
    $stderrFile = "$logFile.stderr"
    $argsList = @(
        "-p",
        "--model", $model,
        "--output-format", "text",
        "--allowedTools", $claudeTools,
        "--dangerously-skip-permissions",
        $prompt
    )
    $result = & claude @argsList 2> $stderrFile
    $exitCode = $LASTEXITCODE
    $result | Tee-Object -FilePath $logFile
    if ($exitCode -ne 0) {
        $stderrText = if (Test-Path -LiteralPath $stderrFile) { Get-Content -Raw -LiteralPath $stderrFile } else { "" }
        Exit-WithError "Fresh Eyes: $providerLabel failed. See log: $logFile`n$stderrText"
    }
}

Write-Output ""
Write-Output "---"
Write-Output "Full log: $logFile"
