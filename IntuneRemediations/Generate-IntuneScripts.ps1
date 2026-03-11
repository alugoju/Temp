#Requires -Version 5.1
<#
.SYNOPSIS
    Generates Intune Proactive Remediation detection and remediation scripts for
    every Autopilot Group Tag in $GroupTags.

.DESCRIPTION
    Reads the two template files under .\Templates\ and stamps each Group Tag into
    a dedicated detection + remediation pair, written to:
        .\Scripts\Detection\Detect-GroupTag-<TAG>.ps1
        .\Scripts\Remediation\Remediate-GroupTag-<TAG>.ps1

    60 files total for 30 group tags.

.PARAMETER GroupTags
    Array of group-tag strings to generate scripts for.
    Edit the default value below to match your environment.

.PARAMETER OutputRoot
    Root folder that contains the Scripts\Detection and Scripts\Remediation
    sub-folders.  Defaults to the directory this script lives in.

.EXAMPLE
    .\Generate-IntuneScripts.ps1

.EXAMPLE
    .\Generate-IntuneScripts.ps1 -GroupTags @("WHD","ABC","NYC")
#>
param(
    [string[]] $GroupTags = @(
        # ---------- Add / remove / rename tags here ----------
        "WHD", "ABC", "NYC", "DAL", "CHI", "LAX",
        "ATL", "DEN", "PHX", "SEA", "MIA", "BOS",
        "DFW", "SFO", "MSP", "DTW", "PHL", "CLT",
        "LAS", "EWR", "MDW", "PDX", "SLC", "STL",
        "HOU", "MSY", "SAT", "TPA", "BNA", "IND"
        # -----------------------------------------------------
    ),

    [string] $OutputRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ────────────────────────────────────────────────────────────────────
$templateDir    = Join-Path $OutputRoot "Templates"
$detectTemplate = Join-Path $templateDir "Detect-GroupTag-Template.ps1"
$remediTemplate = Join-Path $templateDir "Remediate-GroupTag-Template.ps1"
$detectOut      = Join-Path $OutputRoot "Scripts\Detection"
$remediOut      = Join-Path $OutputRoot "Scripts\Remediation"

foreach ($dir in $detectOut, $remediOut) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ── Read templates ────────────────────────────────────────────────────────────
$detectTemplateContent = Get-Content -Raw -Path $detectTemplate
$remediTemplateContent = Get-Content -Raw -Path $remediTemplate

# ── Generate ──────────────────────────────────────────────────────────────────
$generated = 0
foreach ($tag in $GroupTags) {
    $tag = $tag.Trim().ToUpper()

    # Detection
    $detectContent = $detectTemplateContent -replace '\{\{GROUP_TAG\}\}', $tag
    $detectFile    = Join-Path $detectOut "Detect-GroupTag-$tag.ps1"
    Set-Content -Path $detectFile -Value $detectContent -Encoding UTF8
    Write-Host "  [+] $detectFile"

    # Remediation
    $remediContent = $remediTemplateContent -replace '\{\{GROUP_TAG\}\}', $tag
    $remediFile    = Join-Path $remediOut "Remediate-GroupTag-$tag.ps1"
    Set-Content -Path $remediFile -Value $remediContent -Encoding UTF8
    Write-Host "  [+] $remediFile"

    $generated += 2
}

Write-Host ""
Write-Host "Done. Generated $generated scripts ($($GroupTags.Count) group tags)." -ForegroundColor Green
