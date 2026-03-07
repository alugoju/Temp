# OOBE Autopilot Registration Script - Production Version
# Registers devices in Microsoft Intune Autopilot during SCCM/MDT OOBE
# Version: 4.1 - HTA agency selection with BOM-safe write ($env:TEMP + WriteAllBytes)
#
# Usage (ServiceUI.exe):
#   ServiceUI.exe -process:tsprogressui.exe
#     %windir%\System32\WindowsPowerShell\v1.0\powershell.exe
#     -WindowStyle Hidden -ExecutionPolicy Bypass
#     -File Import-Autopilotpopup.ps1
#
# Exit codes:
#   0  = Success (device registered, task sequence can continue)
#   1  = Failure (network timeout, auth failure, registration error, etc.)

param()

#region Configuration
$TenantId     = "YOUR_TENANT_ID"
$ClientId     = "YOUR_CLIENT_ID"
$ClientSecret = "YOUR_CLIENT_SECRET"

# Task Sequence variable name written after successful registration.
# Subsequent TS steps can read %OSDGroupTag% (SCCM) or use it in conditions.
$TSGroupTagVariable   = "OSDGroupTag"
$TSRegistrationStatus = "OSDAutopilotStatus"   # "Success" or "Failed_<reason>"
$logFile = "C:\Windows\Temp\AutopilotRegistration.log"
#endregion

#region Deployment Environment Detection
# -----------------------------------------------------------------------
# Both SCCM/MECM and MDT expose the Microsoft.SMS.TSEnvironment COM object.
# We attempt to bind to it to determine whether we are running inside a
# task sequence. If the COM object is unavailable the script still works
# but skips all TS-variable read/write operations.
#
# SCCM-specific variables (set only by SCCM/MECM):
#   _SMSTSAdvertID, _SMSTSMP, _SMSTSSiteCode, _SMSTSIsClientInstalled
#
# MDT-specific variables (set only by MDT):
#   DeployRoot, ResourceRoot, Phase, TaskSequenceID
# -----------------------------------------------------------------------

$script:tsEnv           = $null          # Microsoft.SMS.TSEnvironment COM object (or $null)
$script:deploymentEnv   = "Standalone"   # "SCCM", "MDT", or "Standalone"
$script:mdtLogPath      = $null          # MDT log directory (if in MDT)

function Initialize-DeploymentEnvironment {
    # --- Try to bind to the TS environment COM object ---
    try {
        $tsObj = New-Object -COMObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
        $script:tsEnv = $tsObj
        Write-Log "Task Sequence environment detected (Microsoft.SMS.TSEnvironment bound)"
    } catch {
        Write-Log "Not running inside a task sequence (COM bind failed: $($_.Exception.Message))"
        $script:deploymentEnv = "Standalone"
        return
    }

    # --- Distinguish SCCM/MECM from MDT ---
    # MDT sets 'DeployRoot'; SCCM/MECM sets '_SMSTSAdvertID' or '_SMSTSMP'.
    $deployRoot  = $null
    $smstsMP     = $null
    try { $deployRoot = $script:tsEnv.Value("DeployRoot") }   catch { }
    try { $smstsMP    = $script:tsEnv.Value("_SMSTSMP")   }   catch { }

    if (-not [string]::IsNullOrWhiteSpace($deployRoot)) {
        $script:deploymentEnv = "MDT"
        # MDT logs go to <DeployRoot>\SMSOSD\OSDLOGS or BDD.log in %TEMP%
        $mdtLogDir = Join-Path $deployRoot "SMSOSD\OSDLOGS"
        if (Test-Path $mdtLogDir -ErrorAction SilentlyContinue) {
            $script:mdtLogPath = $mdtLogDir
        } else {
            $script:mdtLogPath = $env:TEMP
        }
        Write-Log "MDT environment detected. DeployRoot: $deployRoot"
    } elseif (-not [string]::IsNullOrWhiteSpace($smstsMP)) {
        $script:deploymentEnv = "SCCM"
        Write-Log "SCCM/MECM environment detected. Management Point: $smstsMP"
    } else {
        # COM object bound but neither MDT nor SCCM markers found - treat as SCCM
        $script:deploymentEnv = "SCCM"
        Write-Log "Task sequence environment detected (type undetermined, treating as SCCM)"
    }
}

# Read a task sequence variable safely (returns $Default if not in a TS)
function Get-TSVariable {
    param([string]$Name, [string]$Default = "")
    if ($null -eq $script:tsEnv) { return $Default }
    try {
        $val = $script:tsEnv.Value($Name)
        return if ([string]::IsNullOrEmpty($val)) { $Default } else { $val }
    } catch {
        Write-Log "WARNING: Could not read TS variable '$Name': $($_.Exception.Message)"
        return $Default
    }
}

# Write a task sequence variable safely (no-op if not in a TS)
function Set-TSVariable {
    param([string]$Name, [string]$Value)
    if ($null -eq $script:tsEnv) {
        Write-Log "Skipping TS variable write (not in task sequence): $Name = $Value"
        return
    }
    try {
        $script:tsEnv.Value($Name) = $Value
        Write-Log "TS variable set: $Name = $Value"
    } catch {
        Write-Log "WARNING: Could not set TS variable '$Name': $($_.Exception.Message)"
    }
}
#endregion

#region Logging Function
# Writes to the local log file and, if in MDT, also appends to the MDT log.
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $Message"
    $line | Out-File -FilePath $logFile -Append
    Write-Output $Message

    # MDT supplemental log (BDD.log CMTrace format)
    if ($script:deploymentEnv -eq "MDT" -and $null -ne $script:mdtLogPath) {
        try {
            $mdtLine = "<![LOG[$Message]LOG]!><time=""$(Get-Date -Format 'HH:mm:ss.fff')"" date=""$(Get-Date -Format 'MM-dd-yyyy')"" component=""AutopilotRegistration"" context="""" type=""1"" thread="""" file="""">"
            $mdtLogFile = Join-Path $script:mdtLogPath "AutopilotRegistration.log"
            $mdtLine | Out-File -FilePath $mdtLogFile -Append -Encoding ASCII
        } catch { }
    }
}
#endregion

#region Initialise Environment
Write-Log "=== Autopilot Registration Started (v4.1 - HTA BOM-safe) ==="
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
Write-Log "Running as: $($currentUser.Name)"

# Bind to task sequence environment (sets $script:tsEnv and $script:deploymentEnv)
Initialize-DeploymentEnvironment
Write-Log "Deployment environment: $script:deploymentEnv"

# Read useful TS variables that may already be populated by the task sequence
$tsComputerName  = Get-TSVariable -Name "OSDComputerName"
$tsTaskSeqID     = Get-TSVariable -Name "TaskSequenceID"
$smstsLogPath    = Get-TSVariable -Name "_SMSTSLogPath"

if (-not [string]::IsNullOrEmpty($tsComputerName)) {
    Write-Log "TS OSDComputerName: $tsComputerName"
}
if (-not [string]::IsNullOrEmpty($tsTaskSeqID)) {
    Write-Log "TS TaskSequenceID: $tsTaskSeqID"
}
if (-not [string]::IsNullOrEmpty($smstsLogPath)) {
    # Redirect local log to the TS log path so all logs are collected by SCCM/MDT
    $logFile = Join-Path $smstsLogPath "AutopilotRegistration.log"
    Write-Log "Log redirected to TS log path: $logFile"
}
#endregion

#region Network Connectivity
Write-Log "Checking network connectivity..."
$networkReady = $false
$maxWaitTime  = 300
$waitTime     = 0

do {
    try {
        $testConnection = Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue
        if ($testConnection) {
            $networkReady = $true
            Write-Log "Network connectivity confirmed"
        } else {
            Write-Log "Waiting for network... ($waitTime seconds)"
            Start-Sleep -Seconds 10
            $waitTime += 10
        }
    } catch {
        Write-Log "Network test failed, retrying... ($waitTime seconds)"
        Start-Sleep -Seconds 10
        $waitTime += 10
    }
} while (-not $networkReady -and $waitTime -lt $maxWaitTime)

if (-not $networkReady) {
    Write-Log "ERROR: Network timeout after $maxWaitTime seconds"
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_NetworkTimeout"
    exit 1
}
#endregion

#region Device Information
$serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
Write-Log "Device Serial: $serialNumber"

# Use OSDComputerName from TS if available, otherwise use the actual hostname
$deviceName = if (-not [string]::IsNullOrEmpty($tsComputerName)) { $tsComputerName } else { $env:COMPUTERNAME }
Write-Log "Device Name: $deviceName"
#endregion

#region WinForms and Win32 Setup
# WinForms is initialised here for the progress/success/error dialogs shown after
# the HTA agency selection.  The CursorHelper/WindowHelper P/Invoke types are used
# in those dialogs' Add_Shown handlers to enforce cursor and focus.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CursorHelper {
    [DllImport("user32.dll")]
    public static extern int ShowCursor(bool bShow);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr LoadCursor(IntPtr hInstance, int lpCursorName);

    [DllImport("user32.dll")]
    public static extern IntPtr SetCursor(IntPtr hCursor);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern bool SetSystemCursor(IntPtr hcur, uint id);

    [DllImport("user32.dll")]
    public static extern IntPtr CopyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);

    public const int  IDC_ARROW        = 32512;
    public const uint OCR_NORMAL       = 32512;
    public const uint SPI_SETCURSORS   = 0x0057;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
}

public class WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public const int SW_RESTORE = 9;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;
}
"@

# Wait for input device drivers (Dell HID drivers finish enumeration ~10-15 s into OOBE)
Write-Log "Waiting 15 seconds for input device initialization..."
Start-Sleep -Seconds 15

# Apply cursor fix before any UI appears.
# These calls help the progress/result WinForms dialogs shown after the HTA dialog.
Write-Log "Applying cursor fix (SPI_SETCURSORS + SetSystemCursor + ShowCursor)..."
[CursorHelper]::SystemParametersInfo([CursorHelper]::SPI_SETCURSORS, 0, [IntPtr]::Zero, 0) | Out-Null
$hArrow = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
[CursorHelper]::SetSystemCursor([CursorHelper]::CopyIcon($hArrow), [CursorHelper]::OCR_NORMAL) | Out-Null
[CursorHelper]::SetCursor($hArrow) | Out-Null
$sc = [CursorHelper]::ShowCursor($true)
$scIter = 0
while ($sc -lt 0 -and $scIter -lt 32) { $sc = [CursorHelper]::ShowCursor($true); $scIter++ }
[CursorHelper]::mouse_event([CursorHelper]::MOUSEEVENTF_MOVE, 1, 0, 0, [IntPtr]::Zero)
[CursorHelper]::mouse_event([CursorHelper]::MOUSEEVENTF_MOVE, -1, 0, 0, [IntPtr]::Zero)
Write-Log "Cursor fix applied (ShowCursor counter=$sc after $scIter increments)"
#endregion

#region Agency Selection via HTA
# The agency selection UI is an HTA (mshta.exe / Trident engine).
# HTA cursor rendering is handled by the browser engine and works correctly on
# physical Dell hardware where WinForms/GDI cursor APIs fail silently.
#
# BOM-free write strategy - all three sources of BOM are eliminated:
#
#   SOURCE 1 - Script file encoding:
#     PowerShell here-strings are parsed from the .ps1 file.  If the .ps1 is
#     saved with a UTF-8 BOM by an editor, in rare PS 5.1 edge cases the BOM
#     character (U+FEFF) can appear as the first character of a string that
#     begins near the top of the file.  Eliminated here by building content
#     via List[string].Add() -- each string literal is a distinct token with
#     no file-position dependency.
#
#   SOURCE 2 - WriteAllText encoding preamble:
#     [System.Text.Encoding]::UTF8 returns a singleton whose GetPreamble()
#     returns {0xEF,0xBB,0xBF}; WriteAllText prepends those bytes.
#     Eliminated by using WriteAllBytes([Encoding]::ASCII.GetBytes()) which
#     takes a pre-encoded byte array -- no encoding object, no preamble logic.
#
#   SOURCE 3 - Corporate GP / AV file-write interception at C:\Windows\Temp:
#     Enterprise Group Policy or endpoint security (e.g. Symantec DLP,
#     CrowdStrike) can intercept writes to system directories and prepend
#     metadata / BOM bytes after the write returns.  All previous attempts
#     (Out-File ASCII, WriteAllText ASCII, WriteAllBytes ASCII) reported BOM
#     True because the write target was always C:\Windows\Temp.
#     Eliminated by writing to $env:TEMP, which under ServiceUI.exe (Session 1
#     context) resolves to the interactive user's profile temp folder
#     (e.g. C:\Users\<user>\AppData\Local\Temp) rather than C:\Windows\Temp.

Write-Log "Preparing HTA agency selection dialog..."
Write-Log "env:TEMP resolved to: $env:TEMP"

# Expand $env:TEMP to its full long path before use.
# On corporate machines with long usernames, $env:TEMP can resolve to a DOS 8.3
# short path (e.g. Z-ALUG~1.ENT instead of z-Alugoju-Narasimha.ENT).
# VBScript's FileSystemObject cannot write to paths containing tilde short names
# and silently fails - no result file is written and the HTA throws a Script Error.
# GetFullPath() resolves the drive-relative path; (Get-Item).FullName then expands
# any remaining 8.3 components to their full Unicode long path equivalents.
$tempLong   = (Get-Item -LiteralPath ([System.IO.Path]::GetFullPath($env:TEMP))).FullName
Write-Log "env:TEMP long path  : $tempLong"

# WHY THE HTA ENDS UP AT C:\Windows\Temp:
# When ServiceUI.exe does NOT successfully inherit the interactive user's environment
# (e.g. the TS step runs before a user session is fully established, or ServiceUI
# finds tsprogressui.exe in Session 0), the spawned PowerShell process keeps the
# SYSTEM account's environment where $env:TEMP = C:\Windows\Temp.
# In that case the enterprise filter driver intercepts mshta.exe's file read and
# injects BOM bytes (our write-time BOM check passes because ReadAllBytes also
# goes through the driver cache, but a fresh open by mshta.exe sees the modified
# file).
#
# FIX: if $env:TEMP resolved to the Windows system temp, fall back to
# C:\ProgramData\AutopilotTemp which is writable by SYSTEM, has a full long path,
# and is typically outside the GP/AV filter scope that targets Temp directories.
$systemTempCanon = (Get-Item -LiteralPath ([System.IO.Path]::GetFullPath("$env:SystemRoot\Temp"))).FullName
if ($tempLong -ieq $systemTempCanon) {
    Write-Log "WARNING: env:TEMP resolved to system temp ($tempLong) - filter driver interception likely."
    Write-Log "         Falling back to C:\ProgramData\AutopilotTemp to bypass GP/AV temp-dir filtering."
    $tempLong = Join-Path $env:ProgramData "AutopilotTemp"
    if (-not (Test-Path -LiteralPath $tempLong)) {
        New-Item -ItemType Directory -Path $tempLong -Force | Out-Null
    }
    Write-Log "Fallback path used : $tempLong"
}

$htaPath    = Join-Path $tempLong "AutopilotSelect.hta"
$resultPath = Join-Path $tempLong "AutopilotResult.txt"

Write-Log "HTA path    : $htaPath"
Write-Log "Result path : $resultPath"

# Clean up any artifacts from a previous run
@($htaPath, $resultPath) | Where-Object { Test-Path $_ } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Build sorted <option> list - all ASCII, no encoding concerns
$sortedAgencies = @(
    "OCIO","OCFO","OALJ","ARB","ASAM","ASP","BRB","CRC","DBC","SEC","SOL","OCIA",
    "OSHA","ETA","OASAM","HRC","ILAB","OPA","OSEC","VETS","ODEP","OMBUD","WB","BOC",
    "MSHA","EBSA","OFCCP","OWCP","OWECA","OWDLH","OWDCM","OWDAO","ECB","EMC",
    "OWDFE","OWDEE","WHD","TEST","OLMS"
) | Sort-Object
$sortedAgencies += "Other (Enter Below)"
$optionsHtml = ($sortedAgencies | ForEach-Object {
    '<option value="' + $_ + '">' + $_ + '</option>'
}) -join "`r`n"

# Build HTA content using List[string].Add() - one literal per Add() call.
# This avoids here-string dependency on the .ps1 file's byte-level encoding.
# Single-quoted PS strings are used throughout; variables injected via concatenation.
$L = [System.Collections.Generic.List[string]]::new()
$L.Add('<html>')
$L.Add('<head>')
$L.Add('<title>Microsoft Intune - Autopilot Device Registration</title>')
$L.Add('<HTA:APPLICATION')
$L.Add('  ID="objHTA"')
$L.Add('  APPLICATIONNAME="AutopilotRegister"')
$L.Add('  SCROLL="no"')
$L.Add('  SINGLEINSTANCE="yes"')
$L.Add('  MAXIMIZEBUTTON="no"')
$L.Add('  MINIMIZEBUTTON="no"')
$L.Add('  SHOWINTASKBAR="yes"')
$L.Add('/>')
$L.Add('<style>')
$L.Add('* { font-family:''Segoe UI'',Arial,sans-serif; margin:0; padding:0; box-sizing:border-box; }')
$L.Add('body { background:#F0F8FF; }')
$L.Add('#hdr { background:#0078D4; color:#fff; padding:18px 25px; }')
$L.Add('#hdr h1 { font-size:20px; font-weight:bold; }')
$L.Add('#bdy { padding:18px 35px 8px; }')
$L.Add('.serial { color:#0078D4; font-weight:bold; font-size:13px; margin-bottom:6px; }')
$L.Add('hr.sep { border:none; border-top:2px solid #0078D4; margin:8px 0 12px; }')
$L.Add('label { display:block; font-weight:bold; font-size:12px; margin-bottom:4px; color:#444; }')
$L.Add('select, input[type=text] { width:100%; padding:7px 10px; font-size:13px; border:1px solid #bbb; margin-bottom:12px; }')
$L.Add('input[disabled] { background:#f5f5f5; color:#999; }')
$L.Add('#footer { text-align:right; padding:5px 35px 18px; }')
$L.Add('button { padding:9px 22px; font-size:13px; font-weight:bold; margin-left:8px; cursor:pointer; }')
$L.Add('#btnReg { background:#0078D4; color:#fff; border:none; }')
$L.Add('#btnCnl { background:#fff; color:#333; border:1px solid #bbb; }')
$L.Add('</style>')
$L.Add('<script language="VBScript">')
$L.Add('Dim sResultFile')
$L.Add('sResultFile = "' + $resultPath + '"')   # $resultPath injected here - single backslashes, valid VBScript
$L.Add('')
$L.Add('Sub Window_OnLoad()')
$L.Add('  window.resizeTo 520, 400')
$L.Add('  window.moveTo Int((screen.availWidth - 520) / 2), Int((screen.availHeight - 400) / 2)')
$L.Add('  document.getElementById("cboAgency").focus()')
$L.Add('End Sub')
$L.Add('')
$L.Add('Sub cboAgency_onchange()')
$L.Add('  If document.getElementById("cboAgency").value = "Other (Enter Below)" Then')
$L.Add('    document.getElementById("txtCustom").disabled = False')
$L.Add('    document.getElementById("txtCustom").focus()')
$L.Add('  Else')
$L.Add('    document.getElementById("txtCustom").disabled = True')
$L.Add('    document.getElementById("txtCustom").value = ""')
$L.Add('  End If')
$L.Add('End Sub')
$L.Add('')
$L.Add('Sub WriteResult(ByVal txt)')
$L.Add('  Dim fso, f')
$L.Add('  Set fso = CreateObject("Scripting.FileSystemObject")')
$L.Add('  Set f = fso.CreateTextFile(sResultFile, True)')
$L.Add('  f.Write txt')
$L.Add('  f.Close')
$L.Add('End Sub')
$L.Add('')
$L.Add('Sub btnReg_onclick()')
$L.Add('  Dim agency')
$L.Add('  If document.getElementById("cboAgency").value = "Other (Enter Below)" Then')
$L.Add('    agency = Trim(document.getElementById("txtCustom").value)')
$L.Add('    If agency = "" Then')
$L.Add('      MsgBox "You must enter an agency name.", 48, "Invalid Input"')
$L.Add('      Exit Sub')
$L.Add('    End If')
$L.Add('  Else')
$L.Add('    agency = document.getElementById("cboAgency").value')
$L.Add('  End If')
$L.Add('  WriteResult agency')
$L.Add('  window.close()')
$L.Add('End Sub')
$L.Add('')
$L.Add('Sub btnCnl_onclick()')
$L.Add('  WriteResult "__CANCELLED__"')
$L.Add('  window.close()')
$L.Add('End Sub')
$L.Add('</script>')
$L.Add('</head>')
$L.Add('<body>')
$L.Add('<div id="hdr"><h1>DOL Autopilot Pre-Provisioning</h1></div>')
$L.Add('<div id="bdy">')
$L.Add('  <p class="serial">Device Serial Number: ' + $serialNumber + '</p>')
$L.Add('  <p style="font-size:12px;color:#555;margin-bottom:6px;">Initial Device Setup -- Agency Assignment Required<br>Type letter to jump | Alt+R = Register | Alt+C = Cancel</p>')
$L.Add('  <hr class="sep"/>')
$L.Add('  <label for="cboAgency">Select Your Agency:</label>')
$L.Add('  <select id="cboAgency" onchange="cboAgency_onchange()" size="1">')
$L.Add($optionsHtml)
$L.Add('  </select>')
$L.Add('  <label for="txtCustom">Enter Agency Name (if Other):</label>')
$L.Add('  <input type="text" id="txtCustom" disabled="disabled" maxlength="100"/>')
$L.Add('</div>')
$L.Add('<div id="footer">')
$L.Add('  <button id="btnReg" accesskey="r" onclick="btnReg_onclick()">Register Device</button>')
$L.Add('  <button id="btnCnl" accesskey="c" onclick="btnCnl_onclick()">Cancel</button>')
$L.Add('</div>')
$L.Add('</body>')
$L.Add('</html>')

# Join with CRLF (Windows line endings - correct for HTA/Trident)
$htaContent = [string]::Join("`r`n", $L)

# WriteAllBytes takes a raw byte[] with zero preamble logic.
# [Encoding]::ASCII.GetBytes() converts each char to its ASCII byte value;
# it produces no BOM bytes under any circumstances.
$htaBytes = [System.Text.Encoding]::ASCII.GetBytes($htaContent)
[System.IO.File]::WriteAllBytes($htaPath, $htaBytes)
Write-Log "HTA written: $($htaBytes.Length) bytes"

# Verify: read back first 3 bytes and confirm no UTF-8 BOM (0xEF 0xBB 0xBF).
# If this still shows True the write is being intercepted by GP/AV security
# software AFTER our call returns - a kernel-level filter driver behaviour.
$verifyBytes = [System.IO.File]::ReadAllBytes($htaPath)
$hasBom = ($verifyBytes.Length -ge 3 -and
           $verifyBytes[0] -eq 0xEF -and
           $verifyBytes[1] -eq 0xBB -and
           $verifyBytes[2] -eq 0xBF)
if ($hasBom) {
    Write-Log ("CRITICAL: HTA still has UTF-8 BOM after WriteAllBytes to `$env:TEMP ($env:TEMP). " +
               "First bytes: 0x{0:X2} 0x{1:X2} 0x{2:X2}. " +
               "A kernel-mode filter driver (GP/AV) is modifying the file after write. " +
               "Contact the endpoint security team to exclude this path." `
               -f $verifyBytes[0], $verifyBytes[1], $verifyBytes[2])
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_HTABOMInterception"
    exit 1
}
Write-Log "BOM verification: PASS (byte[0]=0x$($verifyBytes[0].ToString('X2')) -- no BOM)"

# -----------------------------------------------------------------------
# DIAGNOSTIC BLOCK - answers:
#   Q1. What path did we actually write to?  (already logged above as HTA path)
#   Q2. What is on lines 40 and 147 of the generated HTA?
#   Q3. Could backslashes in $resultPath corrupt the VBScript sResultFile line?
# -----------------------------------------------------------------------

# First 10 bytes as hex - confirms no BOM and shows actual file start
$hexDump = ($verifyBytes | Select-Object -First 10 |
            ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '
Write-Log "First 10 bytes (hex): $hexDump"

# Split on CRLF to get line array; report total and pinpoint error lines 40 and 147
# (Trident reports errors at the line number within the *file*, not within the script block)
$htaLineArray = $htaContent -split "`r`n"
Write-Log "HTA total lines: $($htaLineArray.Count)"
foreach ($diagLine in 40, 147) {
    if ($diagLine -le $htaLineArray.Count) {
        Write-Log ("HTA line {0,3}: {1}" -f $diagLine, $htaLineArray[$diagLine - 1])
    } else {
        Write-Log ("HTA line {0,3}: (beyond end - file has only {1} lines)" -f $diagLine, $htaLineArray.Count)
    }
}

# Q3 - Backslash answer: log the exact sResultFile assignment as it will appear in VBScript.
# VBScript does NOT use backslash as an escape character, so single backslashes are correct.
# Curly/smart quotes or non-ASCII chars in $resultPath would cause "Invalid character".
$vbsResultLine = 'sResultFile = "' + $resultPath + '"'
Write-Log "VBScript sResultFile line: $vbsResultLine"
$nonAscii = ($resultPath.ToCharArray() | Where-Object { [int]$_ -gt 127 })
if ($nonAscii) {
    Write-Log "WARNING: resultPath contains non-ASCII characters: $($nonAscii -join ',')"
} else {
    Write-Log "resultPath is pure ASCII - backslashes and path are valid for VBScript FSO"
}

# Write a plain-text debug copy of the HTA content so it can be inspected directly
# on the machine (open with Notepad to see exact content including any injected bytes)
$debugPath = Join-Path $tempLong "AutopilotSelect.debug.txt"
[System.IO.File]::WriteAllBytes($debugPath, $htaBytes)
Write-Log "Debug copy written: $debugPath  (identical bytes to the HTA - open in Notepad to inspect)"

# Launch HTA - mshta.exe is projected into Session 1 by ServiceUI.exe
Write-Log "Launching mshta.exe for agency selection..."
try { [System.Console]::Beep(800, 200) } catch { }

try {
    $htaProc = Start-Process -FilePath "mshta.exe" -ArgumentList "`"$htaPath`"" -PassThru -ErrorAction Stop
    $htaProc.WaitForExit()
    Write-Log "HTA dialog closed (mshta.exe exit code: $($htaProc.ExitCode))"
} catch {
    Write-Log "ERROR: Failed to launch mshta.exe: $_"
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_HTALaunch"
    exit 1
}

# Read agency selection written by VBScript WriteResult()
$groupTag = "DOL"
if (Test-Path $resultPath) {
    $raw = [System.IO.File]::ReadAllText($resultPath).Trim()
    if ($raw -eq "__CANCELLED__" -or [string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "Dialog cancelled - using default group tag: DOL"
    } else {
        $groupTag = $raw
        Write-Log "Agency selected: $groupTag"
    }
} else {
    Write-Log "WARNING: No result file at '$resultPath' - HTA closed without writing. Using default: DOL"
}

# Clean up HTA temp files
@($htaPath, $resultPath) | Where-Object { Test-Path $_ } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-Log "HTA temp files cleaned up"

# Write the selected group tag to the task sequence immediately after user confirms,
# so later TS steps can branch on it even if registration subsequently fails.
Set-TSVariable -Name $TSGroupTagVariable -Value $groupTag
Write-Log "TS variable '$TSGroupTagVariable' set to '$groupTag'"
#endregion

#region Progress Window
$progressForm = New-Object System.Windows.Forms.Form
$progressForm.Text = "Registering Device..."
$progressForm.Size = New-Object System.Drawing.Size(450, 150)
$progressForm.StartPosition = "CenterScreen"
$progressForm.FormBorderStyle = "FixedDialog"
$progressForm.MaximizeBox = $false
$progressForm.MinimizeBox = $false
$progressForm.TopMost = $true
$progressForm.ControlBox = $false
$progressForm.BackColor = [System.Drawing.Color]::White

$progressLabel = New-Object System.Windows.Forms.Label
$progressLabel.Location = New-Object System.Drawing.Point(20, 20)
$progressLabel.Size = New-Object System.Drawing.Size(410, 30)
$progressLabel.Text = "Collecting hardware information..."
$progressLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$progressLabel.TextAlign = "MiddleCenter"
$progressForm.Controls.Add($progressLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 60)
$progressBar.Size = New-Object System.Drawing.Size(410, 30)
$progressBar.Style = "Marquee"
$progressBar.MarqueeAnimationSpeed = 30
$progressForm.Controls.Add($progressBar)

$progressForm.Show()
[System.Windows.Forms.Application]::DoEvents()
#endregion

#region Collect Hardware Hash
Write-Log "Collecting hardware hash..."
try {
    $session = New-CimSession
    $devDetail = Get-CimInstance -CimSession $session `
        -Namespace root/cimv2/mdm/dmmap `
        -Class MDM_DevDetail_Ext01 `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    $hash = $devDetail.DeviceHardwareData
    $session | Remove-CimSession
    Write-Log "Hardware hash collected"

    $progressLabel.Text = "Authenticating with Microsoft Graph..."
    [System.Windows.Forms.Application]::DoEvents()
} catch {
    $progressForm.Close()
    $progressForm.Dispose()
    Write-Log "ERROR: Hardware hash collection failed: $_"
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_HardwareHash"
    exit 1
}
#endregion

#region Authenticate to Microsoft Graph
Write-Log "Authenticating to Graph API..."
$tokenBody = @{
    Grant_Type    = "client_credentials"
    Scope         = "https://graph.microsoft.com/.default"
    Client_Id     = $ClientId
    Client_Secret = $ClientSecret
}

try {
    $tokenResponse = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST -Body $tokenBody -ErrorAction Stop
    $headers = @{Authorization = "Bearer $($tokenResponse.access_token)"}
    Write-Log "Authentication successful"

    $progressLabel.Text = "Registering device in Autopilot..."
    [System.Windows.Forms.Application]::DoEvents()
} catch {
    $progressForm.Close()
    $progressForm.Dispose()
    Write-Log "ERROR: Authentication failed: $_"
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_AuthenticationError"
    exit 1
}
#endregion

#region Register in Autopilot
Write-Log "Registering in Autopilot - Group Tag: $groupTag"
$autopilotBody = @{
    serialNumber       = $serialNumber
    hardwareIdentifier = $hash
    groupTag           = $groupTag
} | ConvertTo-Json

try {
    $response = Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities" `
        -Method POST -Body $autopilotBody -Headers $headers -ContentType "application/json" -ErrorAction Stop

    Write-Log "SUCCESS! Device registered in Autopilot"

    # Write final confirmed values to the task sequence environment
    Set-TSVariable -Name $TSRegistrationStatus -Value "Success"
    Set-TSVariable -Name $TSGroupTagVariable   -Value $groupTag

    $progressLabel.Text = "Registration successful!"
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 1

    $progressForm.Close()
    $progressForm.Dispose()

    # Success beeps
    try {
        [System.Console]::Beep(1000, 150)
        Start-Sleep -Milliseconds 100
        [System.Console]::Beep(1200, 150)
    } catch { }

    # Success dialog
    $successForm = New-Object System.Windows.Forms.Form
    $successForm.Text = "Registration Complete"
    $successForm.Size = New-Object System.Drawing.Size(500, 240)
    $successForm.StartPosition = "CenterScreen"
    $successForm.FormBorderStyle = "FixedDialog"
    $successForm.MaximizeBox = $false
    $successForm.MinimizeBox = $false
    $successForm.TopMost = $true
    $successForm.BackColor = [System.Drawing.Color]::White

    $successForm.Add_Shown({
        Start-Sleep -Milliseconds 200
        $hwnd = $successForm.Handle
        [WindowHelper]::SetWindowPos($hwnd, [WindowHelper]::HWND_TOPMOST, 0, 0, 0, 0,
            [WindowHelper]::SWP_NOMOVE -bor [WindowHelper]::SWP_NOSIZE -bor [WindowHelper]::SWP_SHOWWINDOW) | Out-Null
        [WindowHelper]::BringWindowToTop($hwnd) | Out-Null
        [WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
        $hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
        [CursorHelper]::SetCursor($hCursor) | Out-Null
    })

    $iconPanel = New-Object System.Windows.Forms.Panel
    $iconPanel.Location = New-Object System.Drawing.Point(15, 20)
    $iconPanel.Size = New-Object System.Drawing.Size(40, 40)
    $iconPanel.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)

    $iconLabel = New-Object System.Windows.Forms.Label
    $iconLabel.Location = New-Object System.Drawing.Point(0, 0)
    $iconLabel.Size = New-Object System.Drawing.Size(40, 40)
    $iconLabel.Text = "i"
    $iconLabel.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $iconLabel.ForeColor = [System.Drawing.Color]::White
    $iconLabel.TextAlign = "MiddleCenter"
    $iconLabel.BackColor = [System.Drawing.Color]::Transparent
    $iconPanel.Controls.Add($iconLabel)
    $successForm.Controls.Add($iconPanel)

    $successMessage = New-Object System.Windows.Forms.Label
    $successMessage.Location = New-Object System.Drawing.Point(65, 20)
    $successMessage.Size = New-Object System.Drawing.Size(410, 130)
    $successMessage.Text = "Device: $serialNumber`n`nGroup Tag: $groupTag`n`nThe device has been successfully imported into Microsoft Intune Autopilot.`n`nWindows setup will continue."
    $successMessage.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $successForm.Controls.Add($successMessage)

    $successOK = New-Object System.Windows.Forms.Button
    $successOK.Location = New-Object System.Drawing.Point(200, 165)
    $successOK.Size = New-Object System.Drawing.Size(100, 35)
    $successOK.Text = "&OK"
    $successOK.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $successOK.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $successOK.ForeColor = [System.Drawing.Color]::White
    $successOK.FlatStyle = "Flat"
    $successOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $successOK.Cursor = [System.Windows.Forms.Cursors]::Hand
    $successForm.Controls.Add($successOK)
    $successForm.AcceptButton = $successOK

    $successForm.ShowDialog() | Out-Null
    $successForm.Dispose()

} catch {
    Write-Log "ERROR: Registration failed: $_"
    Set-TSVariable -Name $TSRegistrationStatus -Value "Failed_RegistrationError"

    $progressLabel.Text = "Registration failed!"
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 1

    $progressForm.Close()
    $progressForm.Dispose()

    # Error beeps
    try {
        [System.Console]::Beep(400, 300)
        Start-Sleep -Milliseconds 100
        [System.Console]::Beep(300, 300)
    } catch { }

    # Error dialog
    $errorForm = New-Object System.Windows.Forms.Form
    $errorForm.Text = "Registration Failed"
    $errorForm.Size = New-Object System.Drawing.Size(500, 240)
    $errorForm.StartPosition = "CenterScreen"
    $errorForm.FormBorderStyle = "FixedDialog"
    $errorForm.MaximizeBox = $false
    $errorForm.MinimizeBox = $false
    $errorForm.TopMost = $true
    $errorForm.BackColor = [System.Drawing.Color]::White

    $errorForm.Add_Shown({
        Start-Sleep -Milliseconds 200
        $hwnd = $errorForm.Handle
        [WindowHelper]::SetWindowPos($hwnd, [WindowHelper]::HWND_TOPMOST, 0, 0, 0, 0,
            [WindowHelper]::SWP_NOMOVE -bor [WindowHelper]::SWP_NOSIZE -bor [WindowHelper]::SWP_SHOWWINDOW) | Out-Null
        [WindowHelper]::BringWindowToTop($hwnd) | Out-Null
        [WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
        $hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
        [CursorHelper]::SetCursor($hCursor) | Out-Null
    })

    $iconPanel = New-Object System.Windows.Forms.Panel
    $iconPanel.Location = New-Object System.Drawing.Point(15, 20)
    $iconPanel.Size = New-Object System.Drawing.Size(40, 40)
    $iconPanel.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28)

    $iconLabel = New-Object System.Windows.Forms.Label
    $iconLabel.Location = New-Object System.Drawing.Point(0, 0)
    $iconLabel.Size = New-Object System.Drawing.Size(40, 40)
    $iconLabel.Text = "!"
    $iconLabel.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $iconLabel.ForeColor = [System.Drawing.Color]::White
    $iconLabel.TextAlign = "MiddleCenter"
    $iconLabel.BackColor = [System.Drawing.Color]::Transparent
    $iconPanel.Controls.Add($iconLabel)
    $errorForm.Controls.Add($iconPanel)

    $errorMessage = New-Object System.Windows.Forms.Label
    $errorMessage.Location = New-Object System.Drawing.Point(65, 20)
    $errorMessage.Size = New-Object System.Drawing.Size(410, 130)
    $errorMessage.Text = "Failed to import device into Intune Autopilot.`n`nError: $($_.Exception.Message)`n`nPlease contact IT support."
    $errorMessage.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $errorForm.Controls.Add($errorMessage)

    $errorOK = New-Object System.Windows.Forms.Button
    $errorOK.Location = New-Object System.Drawing.Point(200, 165)
    $errorOK.Size = New-Object System.Drawing.Size(100, 35)
    $errorOK.Text = "&OK"
    $errorOK.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $errorOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $errorOK.Cursor = [System.Windows.Forms.Cursors]::Hand
    $errorForm.Controls.Add($errorOK)
    $errorForm.AcceptButton = $errorOK

    $errorForm.ShowDialog() | Out-Null
    $errorForm.Dispose()

    exit 1
}
#endregion

Write-Log "=== Registration completed successfully ==="
# Exit 0 = success; task sequence step passes and continues to the next step
exit 0
