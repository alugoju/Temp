#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Microsoft Company Portal offline during Autopilot pre-provisioning.
.DESCRIPTION
    Designed to run under IME/SYSTEM context as an Intune Win32 app.
    Uses multi-fallback path resolution to reliably locate bundled files.

    Path resolution order:
      1. $PSScriptRoot                        (PS 3.0+, most reliable)
      2. Split-Path $MyInvocation.MyCommand.Definition  (may be empty under IME)
      3. Split-Path $MyInvocation.MyCommand.Path        (may be empty under IME)
      4. Recursive scan of all known IME staging roots  (nuclear fallback)

    Install order:
      1. Each dependency .Appx  (Add-AppxPackage, skip if already present)
      2. Main .AppxBundle       (Add-AppxProvisionedPackage -> Add-AppxPackage fallback)

    PsExec test:
      psexec.exe -s -i powershell.exe -ExecutionPolicy Bypass \
        -File "C:\path\to\Install-CompanyPortal.ps1"

.NOTES
    Version : 2.0
    Context : IME/SYSTEM, Autopilot pre-provisioning (White Glove)
    Exit  0 : Success
    Exit  1 : Failure
#>

[CmdletBinding()]
param()

#region ---------------------------------------------------------------- Logging
$LogDir  = 'C:\Windows\Logs\IntuneApps'
$LogFile = Join-Path $LogDir 'CompanyPortalInstall.log'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    try {
        $null = New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
    Write-Output $line
}
#endregion

#region --------------------------------------------------------------- Header
Write-Log '================================================================'
Write-Log '  Install-CompanyPortal.ps1  v2.0  (IME/SYSTEM Context Safe)'
Write-Log '================================================================'
Write-Log "Start time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Computer        : $env:COMPUTERNAME"
Write-Log "Log file        : $LogFile"

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
Write-Log "Running as      : $($identity.Name)"
Write-Log "Is SYSTEM       : $($identity.IsSystem)"
Write-Log "PS Version      : $($PSVersionTable.PSVersion)"
Write-Log "PS Edition      : $($PSVersionTable.PSEdition)"
Write-Log "OS Version      : $([System.Environment]::OSVersion.VersionString)"
Write-Log "Session ID      : $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"
Write-Log "PID             : $([System.Diagnostics.Process]::GetCurrentProcess().Id)"
Write-Log "env:TEMP        : $env:TEMP"
Write-Log "env:SystemRoot  : $env:SystemRoot"
#endregion

#region -------------------------------------------------------- Path Resolution
Write-Log ''
Write-Log '--- Path Resolution ---'

# Expected file names
$AppxBundleName  = 'Microsoft.CompanyPortal_11.2.1753.0.AppxBundle'
$DependencyNames = @(
    'Microsoft.NET.Native.Framework.2.2.Appx',
    'Microsoft.NET.Native.Runtime.2.2.Appx',
    'Microsoft.Services.Store.Engagement_10.0.Appx',
    'Microsoft.UI.Xaml.2.7.Appx',
    'Microsoft.VCLibs.140.00.Appx'
)

$ScriptDir = $null

# Helper: test if a candidate directory contains the AppxBundle
function Test-CandidateDir {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path $Dir -ErrorAction SilentlyContinue)) { return $false }
    return (Test-Path (Join-Path $Dir $AppxBundleName) -ErrorAction SilentlyContinue)
}

# ---- Method 1: $PSScriptRoot -----------------------------------------------
Write-Log "Method 1 | PSScriptRoot = '$PSScriptRoot'"
if (Test-CandidateDir $PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
    Write-Log 'Method 1 | SUCCESS'
} else {
    Write-Log 'Method 1 | Bundle not found here (PSScriptRoot empty or bundle absent)'
}

# ---- Method 2: $MyInvocation.MyCommand.Definition --------------------------
if (-not $ScriptDir) {
    $def = $MyInvocation.MyCommand.Definition
    Write-Log "Method 2 | MyCommand.Definition = '$def'"
    if (-not [string]::IsNullOrWhiteSpace($def)) {
        $candidate = Split-Path -Parent $def -ErrorAction SilentlyContinue
        Write-Log "Method 2 | Resolved dir = '$candidate'"
        if (Test-CandidateDir $candidate) {
            $ScriptDir = $candidate
            Write-Log 'Method 2 | SUCCESS'
        } else {
            Write-Log 'Method 2 | Bundle not found in resolved dir'
        }
    } else {
        Write-Log 'Method 2 | Empty (expected under IME/SYSTEM when invoked non-interactively)'
    }
}

# ---- Method 3: $MyInvocation.MyCommand.Path --------------------------------
if (-not $ScriptDir) {
    $cmdPath = $MyInvocation.MyCommand.Path
    Write-Log "Method 3 | MyCommand.Path = '$cmdPath'"
    if (-not [string]::IsNullOrWhiteSpace($cmdPath)) {
        $candidate = Split-Path -Parent $cmdPath -ErrorAction SilentlyContinue
        Write-Log "Method 3 | Resolved dir = '$candidate'"
        if (Test-CandidateDir $candidate) {
            $ScriptDir = $candidate
            Write-Log 'Method 3 | SUCCESS'
        } else {
            Write-Log 'Method 3 | Bundle not found in resolved dir'
        }
    } else {
        Write-Log 'Method 3 | Empty'
    }
}

# ---- Method 4: Scan all known IME staging roots ----------------------------
if (-not $ScriptDir) {
    Write-Log 'Method 4 | Scanning known IME staging/cache paths...'

    # IME extracts Win32 app content to GUIDed subdirs under these roots.
    # The list is ordered from most-likely to least-likely to reduce scan time.
    $imeStagingRoots = @(
        'C:\Program Files (x86)\Microsoft Intune Management Extension\Content\Staging',
        'C:\Windows\IMECache',
        'C:\ProgramData\Microsoft\IntuneManagementExtension\Cache',
        'C:\Windows\ccmcache',             # SCCM cache (belt-and-suspenders)
        'C:\Windows\Temp',
        'C:\Windows\SysWOW64\config\systemprofile\AppData\Local\Temp',
        'C:\Windows\System32\config\systemprofile\AppData\Local\Temp',
        $env:TEMP,
        $env:TMP
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in $imeStagingRoots) {
        Write-Log "Method 4 | Checking root: '$root'"
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) {
            Write-Log 'Method 4 |   Root does not exist, skip'
            continue
        }
        try {
            # Depth 4 covers: <root>\<GUID>\<optional-subfolder>\<file>
            $hit = Get-ChildItem -Path $root -Filter $AppxBundleName `
                       -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) {
                $ScriptDir = $hit.DirectoryName
                Write-Log "Method 4 | SUCCESS: found at '$($hit.FullName)'"
                break
            } else {
                Write-Log "Method 4 |   Bundle not found under '$root'"
            }
        } catch {
            Write-Log "Method 4 |   Error scanning '$root': $($_.Exception.Message)"
        }
    }
}

# ---- Final verdict ---------------------------------------------------------
if (-not $ScriptDir) {
    Write-Log ''
    Write-Log 'ERROR: All path resolution methods exhausted.'
    Write-Log "       '$AppxBundleName' was not found anywhere."
    Write-Log '       Possible causes:'
    Write-Log '         - IME has not yet staged the Win32 app content'
    Write-Log '         - .intunewin was built from the wrong source folder'
    Write-Log '         - Staging path falls outside the known list'
    Write-Log 'Exiting with code 1.'
    exit 1
}

Write-Log ''
Write-Log "Resolved working directory: '$ScriptDir'"
#endregion

#region ------------------------------------------------------ File Verification
Write-Log ''
Write-Log '--- File Verification ---'

$AppxBundlePath = Join-Path $ScriptDir $AppxBundleName
Write-Log "AppxBundle : $AppxBundlePath"
if (-not (Test-Path $AppxBundlePath)) {
    Write-Log 'ERROR: AppxBundle missing after path resolution succeeded — filesystem race?'
    exit 1
}
$bundleMB = [math]::Round((Get-Item $AppxBundlePath).Length / 1MB, 2)
Write-Log "           OK  ($bundleMB MB)"

$DependencyPaths = [System.Collections.Generic.List[string]]::new()
$missingDeps     = [System.Collections.Generic.List[string]]::new()

foreach ($dep in $DependencyNames) {
    $depPath = Join-Path $ScriptDir $dep
    if (Test-Path $depPath) {
        $depKB = [math]::Round((Get-Item $depPath).Length / 1KB, 1)
        Write-Log "Dependency : $dep   OK  ($depKB KB)"
        $DependencyPaths.Add($depPath)
    } else {
        Write-Log "Dependency : $dep   MISSING"
        $missingDeps.Add($dep)
    }
}

Write-Log ''
Write-Log "Bundle found    : 1 / 1"
Write-Log "Deps found      : $($DependencyPaths.Count) / $($DependencyNames.Count)"

if ($missingDeps.Count -gt 0) {
    Write-Log 'WARN: Missing dependencies — install may still succeed if they are'
    Write-Log '      already registered in the Windows AppX store.'
    Write-Log "      Missing: $($missingDeps -join ', ')"
}
#endregion

#region ------------------------------------------------------ Pre-Install Check
Write-Log ''
Write-Log '--- Pre-Install Check ---'

$targetVersion   = [version]'11.2.1753.0'
$existingPackage = Get-AppxPackage -AllUsers -Name 'Microsoft.CompanyPortal' -ErrorAction SilentlyContinue

if ($existingPackage) {
    $installedVer = [version]$existingPackage.Version
    Write-Log "Company Portal installed : YES"
    Write-Log "  Package full name : $($existingPackage.PackageFullName)"
    Write-Log "  Installed version : $installedVer"
    Write-Log "  Target version    : $targetVersion"
    Write-Log "  Install location  : $($existingPackage.InstallLocation)"

    if ($installedVer -ge $targetVersion) {
        Write-Log 'Installed version >= target. Nothing to do. Exiting 0.'
        exit 0
    }
    Write-Log 'Installed version < target. Proceeding with upgrade.'
} else {
    Write-Log 'Company Portal installed : NO — proceeding with fresh install'
}
#endregion

#region ------------------------------------------------- Install Dependencies
Write-Log ''
Write-Log '--- Installing Dependencies ---'

foreach ($depPath in $DependencyPaths) {
    $depLeaf = Split-Path $depPath -Leaf
    Write-Log "Installing : $depLeaf"
    Write-Log "  Full path: $depPath"
    try {
        Add-AppxPackage -Path $depPath -ForceApplicationShutdown -ErrorAction Stop
        Write-Log "  Result   : OK"
    } catch {
        $msg = $_.Exception.Message
        # 0x80073D06 = ERROR_PACKAGES_IN_USE / version already present — non-fatal
        if ($msg -match '0x80073D06' -or $msg -match 'already installed' -or
            $msg -match 'higher version' -or $msg -match 'equally') {
            Write-Log "  Result   : SKIP (already installed at same/higher version — non-fatal)"
        } else {
            Write-Log "  Result   : WARN — $msg"
            Write-Log '  Continuing; install may still succeed if dep already registered'
        }
    }
}
#endregion

#region ------------------------------------------ Install Company Portal Bundle
Write-Log ''
Write-Log '--- Installing Company Portal AppxBundle ---'
Write-Log "Bundle       : $AppxBundlePath"
Write-Log "Dep count    : $($DependencyPaths.Count)"
$DependencyPaths | ForEach-Object { Write-Log "  Dep path : $_" }

$installSuccess = $false

# Primary method: Add-AppxProvisionedPackage
# Provisions the app for ALL users — correct for Autopilot pre-provisioning
# so every user who signs in gets Company Portal without a per-user install.
Write-Log ''
Write-Log 'Trying Add-AppxProvisionedPackage (all-user provisioning)...'
try {
    $provResult = Add-AppxProvisionedPackage \
        -Online \
        -PackagePath $AppxBundlePath \
        -DependencyPackagePath $DependencyPaths \
        -SkipLicense \
        -ErrorAction Stop

    Write-Log 'Add-AppxProvisionedPackage : SUCCESS'
    Write-Log "  Online         : $($provResult.Online)"
    Write-Log "  PackagePath    : $($provResult.PackagePath)"
    $installSuccess = $true
} catch {
    $provErr = $_.Exception.Message
    Write-Log "Add-AppxProvisionedPackage : FAILED"
    Write-Log "  Error          : $provErr"
}

# Fallback method: Add-AppxPackage -AllUsers
if (-not $installSuccess) {
    Write-Log ''
    Write-Log 'Trying Add-AppxPackage -AllUsers (fallback)...'
    try {
        $addParams = @{
            Path                    = $AppxBundlePath
            ForceApplicationShutdown = $true
            ForceUpdateFromAnyVersion = $true
            ErrorAction             = 'Stop'
        }
        if ($DependencyPaths.Count -gt 0) {
            $addParams['DependencyPath'] = $DependencyPaths
        }
        Add-AppxPackage @addParams
        Write-Log 'Add-AppxPackage : SUCCESS'
        $installSuccess = $true
    } catch {
        $pkgErr = $_.Exception.Message
        Write-Log "Add-AppxPackage : FAILED"
        Write-Log "  Error         : $pkgErr"
    }
}

if (-not $installSuccess) {
    Write-Log ''
    Write-Log 'ERROR: All install methods failed. See errors above.'
    Write-Log 'Exiting with code 1.'
    exit 1
}
#endregion

#region ------------------------------------------------ Post-Install Verification
Write-Log ''
Write-Log '--- Post-Install Verification ---'
Write-Log 'Waiting 5 seconds for AppX subsystem to register the package...'
Start-Sleep -Seconds 5

$verifyApp = Get-AppxPackage -AllUsers -Name 'Microsoft.CompanyPortal' -ErrorAction SilentlyContinue
if ($verifyApp) {
    Write-Log 'VERIFIED: Company Portal found via Get-AppxPackage -AllUsers'
    Write-Log "  Package full name : $($verifyApp.PackageFullName)"
    Write-Log "  Version           : $($verifyApp.Version)"
    Write-Log "  Install location  : $($verifyApp.InstallLocation)"
    Write-Log "  User contexts     : $($verifyApp.PackageUserInformation.Count)"
} else {
    # Provisioned packages may not show in Get-AppxPackage until a user logs in;
    # check the provisioned package list before declaring failure.
    Write-Log 'Not found in Get-AppxPackage -AllUsers — checking provisioned packages...'
    $provPkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -eq 'Microsoft.CompanyPortal' }
    if ($provPkg) {
        Write-Log 'VERIFIED: Company Portal found in provisioned package list (staged for new users)'
        Write-Log "  DisplayName  : $($provPkg.DisplayName)"
        Write-Log "  Version      : $($provPkg.Version)"
        Write-Log "  PackageName  : $($provPkg.PackageName)"
    } else {
        Write-Log 'ERROR: Company Portal not found in Get-AppxPackage -AllUsers'
        Write-Log '       nor in Get-AppxProvisionedPackage -Online.'
        Write-Log 'Exiting with code 1.'
        exit 1
    }
}
#endregion

Write-Log ''
Write-Log '================================================================'
Write-Log '  Install-CompanyPortal.ps1 COMPLETED SUCCESSFULLY'
Write-Log "  End time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log '================================================================'
exit 0
