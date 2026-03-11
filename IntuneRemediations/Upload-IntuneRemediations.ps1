#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk-creates Intune Proactive Remediations (Health Scripts) via Microsoft
    Graph API and assigns each one to its matching Autopilot Dynamic Group.

.DESCRIPTION
    For every Group Tag in $GroupTags the script:
      1. Reads the matching detection + remediation .ps1 files from disk.
      2. Base64-encodes them (required by Graph).
      3. Creates a deviceHealthScript resource in Intune.
      4. Assigns the script to the Dynamic Device Group whose membership rule
         matches that group tag.

    Prerequisites
    -------------
    - App Registration with the following Graph API Application permissions
      (admin-consented):
        DeviceManagementConfiguration.ReadWrite.All
        Group.Read.All
    - $TenantId, $ClientId, $ClientSecret filled in below (or passed as params).
    - Detection + remediation scripts already generated in .\Scripts\

.PARAMETER TenantId
    Azure AD / Entra ID Tenant ID (GUID).

.PARAMETER ClientId
    App Registration (service principal) Client ID.

.PARAMETER ClientSecret
    App Registration Client Secret.

.PARAMETER GroupTags
    Array of group-tag strings.  Must match the filenames produced by
    Generate-IntuneScripts.ps1 and the displayName suffix of each Dynamic Group.

.PARAMETER DryRun
    When specified, prints what would be created without calling Graph.

.EXAMPLE
    .\Upload-IntuneRemediations.ps1 `
        -TenantId   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-secret-here"

.EXAMPLE
    .\Upload-IntuneRemediations.ps1 -DryRun
#>
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,

    [string[]] $GroupTags = @(
        "WHD", "ABC", "NYC", "DAL", "CHI", "LAX",
        "ATL", "DEN", "PHX", "SEA", "MIA", "BOS",
        "DFW", "SFO", "MSP", "DTW", "PHL", "CLT",
        "LAS", "EWR", "MDW", "PDX", "SLC", "STL",
        "HOU", "MSY", "SAT", "TPA", "BNA", "IND"
    ),

    # Dynamic group displayName pattern: "Autopilot-<TAG>"
    # e.g. the group for tag WHD is expected to be named "Autopilot-WHD"
    [string] $GroupNamePrefix = "Autopilot-",

    [string] $ScriptRoot = $PSScriptRoot,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helper: Get OAuth2 token ──────────────────────────────────────────────────
function Get-GraphToken {
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri    "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body   $body
    return $response.access_token
}

# ── Helper: Graph request wrapper ─────────────────────────────────────────────
function Invoke-Graph {
    param(
        [string] $Method,
        [string] $Uri,
        [object] $Body,
        [string] $Token
    )
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    return Invoke-RestMethod @params
}

# ── Helper: Lookup Dynamic Group ID by displayName ────────────────────────────
function Get-GroupId {
    param([string] $DisplayName, [string] $Token)
    $encoded = [uri]::EscapeDataString($DisplayName)
    $uri     = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$DisplayName'&`$select=id,displayName"
    $result  = Invoke-Graph -Method Get -Uri $uri -Token $Token
    if ($result.value.Count -eq 0) {
        Write-Warning "  Group '$DisplayName' not found in Azure AD – assignment skipped."
        return $null
    }
    return $result.value[0].id
}

# ── Main ─────────────────────────────────────────────────────────────────────
Write-Host "Authenticating to Microsoft Graph..." -ForegroundColor Cyan
$token = if (-not $DryRun) { Get-GraphToken } else { "DRY-RUN-TOKEN" }
Write-Host "OK`n"

$detectDir = Join-Path $ScriptRoot "Scripts\Detection"
$remediDir = Join-Path $ScriptRoot "Scripts\Remediation"

$created = 0
$failed  = 0

foreach ($tag in $GroupTags) {
    $tag = $tag.Trim().ToUpper()
    Write-Host "Processing tag: $tag" -ForegroundColor Cyan

    # ── Read & encode scripts ────────────────────────────────────────────────
    $detectFile = Join-Path $detectDir "Detect-GroupTag-$tag.ps1"
    $remediFile = Join-Path $remediDir "Remediate-GroupTag-$tag.ps1"

    if (-not (Test-Path $detectFile)) { Write-Warning "  Missing: $detectFile – skipping."; $failed++; continue }
    if (-not (Test-Path $remediFile)) { Write-Warning "  Missing: $remediFile – skipping."; $failed++; continue }

    $detectB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($detectFile))
    $remediB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($remediFile))

    # ── Build Proactive Remediation payload ──────────────────────────────────
    $healthScript = @{
        "@odata.type"               = "#microsoft.graph.deviceHealthScript"
        displayName                 = "Autopilot GroupTag - $tag"
        description                 = "Ensures the Autopilot GroupTag registry value is set to $tag."
        publisher                   = "IT Operations"
        runAs32Bit                  = $false
        runAsAccount                = "system"
        enforceSignatureCheck       = $false
        detectionScriptContent      = $detectB64
        remediationScriptContent    = $remediB64
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would create: '$($healthScript.displayName)'" -ForegroundColor Yellow
    } else {
        try {
            $created_script = Invoke-Graph `
                -Method Post `
                -Uri    "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts" `
                -Body   $healthScript `
                -Token  $token
            Write-Host "  Created script ID: $($created_script.id)"

            # ── Assign to Dynamic Group ──────────────────────────────────────
            $groupName = "$GroupNamePrefix$tag"
            $groupId   = Get-GroupId -DisplayName $groupName -Token $token

            if ($groupId) {
                $assignment = @{
                    deviceHealthScriptAssignments = @(
                        @{
                            target = @{
                                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                                groupId       = $groupId
                            }
                            runRemediationScript = $true
                            runSchedule = @{
                                "@odata.type" = "#microsoft.graph.deviceHealthScriptDailySchedule"
                                interval      = 1
                                useUtc        = $false
                                time          = "02:00:00.0000000"
                            }
                        }
                    )
                }
                Invoke-Graph `
                    -Method Post `
                    -Uri    "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$($created_script.id)/assign" `
                    -Body   $assignment `
                    -Token  $token | Out-Null
                Write-Host "  Assigned to group: $groupName ($groupId)" -ForegroundColor Green
            }
            $created++
        } catch {
            Write-Warning "  Failed to create/assign '$tag': $_"
            $failed++
        }
    }
}

Write-Host ""
Write-Host "Summary: $created created, $failed failed." -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })
