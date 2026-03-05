# OOBE Autopilot Registration Script - Production Version
# Registers devices in Microsoft Intune Autopilot during SCCM OOBE
# Version: 3.3 - Replace WinForms form with HTA (mshta.exe/Trident) to bypass GDI cursor pipeline

param()

#region Configuration
$TenantId     = "YOUR_TENANT_ID"
$ClientId     = "YOUR_CLIENT_ID"
$ClientSecret = "YOUR_CLIENT_SECRET"
$logFile = "C:\Windows\Temp\AutopilotRegistration.log"
#endregion

#region Logging Function
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
    Write-Output $Message
}
#endregion

Write-Log "=== Autopilot Registration Started ==="
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
Write-Log "Running as: $($currentUser.Name)"

#region Network Connectivity
Write-Log "Checking network connectivity..."
$networkReady = $false
$maxWaitTime = 300
$waitTime = 0

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
    exit 1
}
#endregion

#region Device Information
$serialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber
Write-Log "Device Serial: $serialNumber"
#endregion

#region Initialize WinForms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
#endregion

#region Window Management (used for progress / result dialogs)
Add-Type @"
using System;
using System.Runtime.InteropServices;
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
#endregion

#region Agency Selection via HTA
# All previous Win32 cursor approaches (SetSystemCursor, SPI_SETCURSORS, WM_SETCURSOR
# WndProc override) confirmed the APIs succeed but the cursor sprite still does not
# render on physical Dell hardware during OOBE.  Diagnosis: the WinForms/GDI cursor
# pipeline does not drive the hardware cursor overlay on physical displays in this
# execution context.
#
# Fix: replace the WinForms interactive form with an HTA (HTML Application).
# mshta.exe hosts the Trident (IE) engine - a completely separate rendering stack
# from WinForms/GDI.  Cursor rendering in HTA is handled by the browser engine and
# works correctly on physical Dell hardware.
Write-Log "Preparing HTA agency selection dialog..."

$htaPath    = "C:\\Windows\\Temp\\AutopilotSelect.hta"
$resultPath = "C:\\Windows\\Temp\\AutopilotResult.txt"

@($htaPath, $resultPath) | Where-Object { Test-Path $_ } | Remove-Item -Force

$agencies = @(
    "OCIO","OCFO","OALJ","ARB","ASAM","ASP","BRB","CRC","DBC","SEC","SOL","OCIA",
    "OSHA","ETA","OASAM","HRC","ILAB","OPA","OSEC","VETS","ODEP","OMBUD","WB","BOC",
    "MSHA","EBSA","OFCCP","OWCP","OWECA","OWDLH","OWDCM","OWDAO","ECB","EMC",
    "OWDFE","OWDEE","WHD","TEST","OLMS"
) | Sort-Object

$optionsHtml = ($agencies | ForEach-Object {
    '<option value="' + $_ + '">' + $_ + '</option>'
}) -join "`n"
$optionsHtml += "`n" + '<option value="Other (Enter Below)">Other (Enter Below)</option>'

$htaContent = @"
<html>
<head>
<title>Microsoft Intune - Autopilot Device Registration</title>
<HTA:APPLICATION
  ID=`"objHTA`"
  APPLICATIONNAME=`"AutopilotRegister`"
  SCROLL=`"no`"
  SINGLEINSTANCE=`"yes`"
  MAXIMIZEBUTTON=`"no`"
  MINIMIZEBUTTON=`"no`"
  SHOWINTASKBAR=`"yes`"
/>
<style>
  *       { font-family:'Segoe UI',Arial,sans-serif; margin:0; padding:0; box-sizing:border-box; }
  body    { background:#F0F8FF; }
  #hdr    { background:#0078D4; color:#fff; padding:18px 25px; }
  #hdr h1 { font-size:20px; font-weight:bold; }
  #body   { padding:18px 35px 8px; }
  .serial { color:#0078D4; font-weight:bold; font-size:13px; margin-bottom:6px; }
  .sep    { border:none; border-top:2px solid #0078D4; margin:8px 0 12px; }
  label   { display:block; font-weight:bold; font-size:12px; margin-bottom:4px; color:#444; }
  select, input[type=text] { width:100%; padding:7px 10px; font-size:13px; border:1px solid #bbb; margin-bottom:12px; }
  input[type=text]:disabled { background:#f5f5f5; color:#999; }
  #footer { text-align:right; padding:5px 35px 18px; }
  button  { padding:9px 22px; font-size:13px; font-weight:bold; border-radius:2px; margin-left:8px; cursor:pointer; }
  #btnReg { background:#0078D4; color:#fff; border:none; }
  #btnCnl { background:#fff; color:#333; border:1px solid #bbb; }
</style>
<script language=`"VBScript`">
Dim sResultFile
sResultFile = `"$resultPath`"

Sub Window_OnLoad()
  window.resizeTo 520, 390
  Dim L, T
  L = Int((screen.availWidth  - 520) / 2)
  T = Int((screen.availHeight - 390) / 2)
  window.moveTo L, T
  document.getElementById(`"cboAgency`").focus()
End Sub

Sub cboAgency_onchange()
  If document.getElementById(`"cboAgency`").value = `"Other (Enter Below)`" Then
    document.getElementById(`"txtCustom`").disabled = False
    document.getElementById(`"txtCustom`").focus()
  Else
    document.getElementById(`"txtCustom`").disabled = True
    document.getElementById(`"txtCustom`").value = `"`"
  End If
End Sub

Sub WriteResult(ByVal txt)
  Dim fso, f
  Set fso = CreateObject(`"Scripting.FileSystemObject`")
  Set f   = fso.CreateTextFile(sResultFile, True)
  f.Write txt
  f.Close
End Sub

Sub btnReg_onclick()
  Dim agency
  If document.getElementById(`"cboAgency`").value = `"Other (Enter Below)`" Then
    agency = Trim(document.getElementById(`"txtCustom`").value)
    If agency = `"`" Then
      MsgBox `"You must enter an agency name.`", 48, `"Invalid Input`"
      Exit Sub
    End If
  Else
    agency = document.getElementById(`"cboAgency`").value
  End If
  WriteResult agency
  window.close()
End Sub

Sub btnCnl_onclick()
  WriteResult `"__CANCELLED__`"
  window.close()
End Sub
</script>
</head>
<body>
  <div id=`"hdr`">
    <h1>DOL Autopilot Pre-Provisioning</h1>
  </div>
  <div id=`"body`">
    <p class=`"serial`">Device Serial Number: $serialNumber</p>
    <p style=`"font-size:12px;color:#555;margin-bottom:6px;`">
      Initial Device Setup &amp;mdash; Agency Assignment Required<br>
      Type letter to jump &amp;nbsp;|&amp;nbsp; Alt+R = Register &amp;nbsp;|&amp;nbsp; Alt+C = Cancel
    </p>
    <hr class=`"sep`"/>
    <label for=`"cboAgency`">Select Your Agency:</label>
    <select id=`"cboAgency`" onchange=`"cboAgency_onchange()`" size=`"1`">
      $optionsHtml
    </select>
    <label for=`"txtCustom`">Enter Agency Name (if Other):</label>
    <input type=`"text`" id=`"txtCustom`" disabled=`"disabled`" maxlength=`"100`"/>
  </div>
  <div id=`"footer`">
    <button id=`"btnReg`" accesskey=`"r`" onclick=`"btnReg_onclick()`">Register Device</button>
    <button id=`"btnCnl`" accesskey=`"c`" onclick=`"btnCnl_onclick()`">Cancel</button>
  </div>
</body>
</html>
"@

[System.IO.File]::WriteAllText($htaPath, $htaContent, [System.Text.Encoding]::UTF8)
Write-Log "HTA written: $htaPath"

Write-Log "Launching HTA agency selection dialog (mshta.exe)..."
try { [System.Console]::Beep(800, 200) } catch { }
$proc = Start-Process -FilePath "mshta.exe" -ArgumentList "`"$htaPath`"" -PassThru
$proc.WaitForExit()
Write-Log "HTA dialog closed (exit code: $($proc.ExitCode))"

$groupTag = "DOL"
if (Test-Path $resultPath) {
    $raw = [System.IO.File]::ReadAllText($resultPath).Trim()
    if ($raw -eq "__CANCELLED__" -or [string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "Dialog cancelled - using default: DOL"
    } else {
        $groupTag = $raw
        Write-Log "Agency selected: $groupTag"
    }
} else {
    Write-Log "WARNING: No result file - using default: DOL"
}

@($htaPath, $resultPath) | Where-Object { Test-Path $_ } | Remove-Item -Force -ErrorAction SilentlyContinue
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
    exit 1
}
#endregion

#region Authenticate to Microsoft Graph
Write-Log "Authenticating to Graph API..."
$tokenBody = @{
    Grant_Type    = "client_credentials"
    Scope         = "https://graph.microsoft.com/.default"
    Client_Id     = $ClientId
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
    exit 1
}
#endregion

#region Register in Autopilot
Write-Log "Registering in Autopilot - Group Tag: $groupTag"
$autopilotBody = @{
    serialNumber       = $serialNumber
    hardwareIdentifier = $hash
    groupTag           = $groupTag
} | ConvertTo-Json

try {
    $response = Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities" `
        -Method POST -Body $autopilotBody -Headers $headers -ContentType "application/json" -ErrorAction Stop

    Write-Log "SUCCESS! Device registered in Autopilot"
    
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
