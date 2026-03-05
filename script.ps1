# OOBE Autopilot Registration Script - Production Version
# Registers devices in Microsoft Intune Autopilot during SCCM OOBE
# Version: 3.0 Final

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

#region Cursor and Window Management
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
    
    public const int IDC_ARROW = 32512;
    public const int IDC_HAND = 32649;
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

# Wait for input device drivers
Write-Log "Waiting 15 seconds for input device initialization..."
Start-Sleep -Seconds 15

# Load and set cursor graphic
Write-Log "Loading cursor graphic..."
$hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
[CursorHelper]::SetCursor($hCursor) | Out-Null
Write-Log "Cursor loaded: $hCursor"

# Ensure cursor visibility
for ($i = 0; $i -lt 15; $i++) {
    [CursorHelper]::ShowCursor($true) | Out-Null
}
Write-Log "Cursor visibility ensured"
#endregion

#region Create Form
Write-Log "Creating UI form..."

$form = New-Object System.Windows.Forms.Form
$form.Text = "Microsoft Intune - Autopilot Device Registration"
$form.Size = New-Object System.Drawing.Size(520, 420)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.Cursor = [System.Windows.Forms.Cursors]::Arrow

# Cursor maintenance timer
$cursorTimer = New-Object System.Windows.Forms.Timer
$cursorTimer.Interval = 200
$cursorTimer.Add_Tick({
    $hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
    [CursorHelper]::SetCursor($hCursor) | Out-Null
    [CursorHelper]::ShowCursor($true) | Out-Null
})

# Window activation on show
$form.Add_Shown({
    Start-Sleep -Milliseconds 200
    
    # Sound notification
    try { [System.Console]::Beep(800, 200) } catch { }
    
    $hwnd = $form.Handle
    
    # Force to foreground
    [WindowHelper]::ShowWindow($hwnd, [WindowHelper]::SW_RESTORE) | Out-Null
    [WindowHelper]::SetWindowPos($hwnd, [WindowHelper]::HWND_TOPMOST, 0, 0, 0, 0, 
        [WindowHelper]::SWP_NOMOVE -bor [WindowHelper]::SWP_NOSIZE -bor [WindowHelper]::SWP_SHOWWINDOW) | Out-Null
    [WindowHelper]::BringWindowToTop($hwnd) | Out-Null
    [WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
    [WindowHelper]::SetFocus($hwnd) | Out-Null
    
    # Load cursor and position
    $hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
    [CursorHelper]::SetCursor($hCursor) | Out-Null
    
    $centerX = $form.Left + ($form.Width / 2)
    $centerY = $form.Top + ($form.Height / 2)
    [CursorHelper]::SetCursorPos($centerX, $centerY) | Out-Null
    
    $agencyDropdown.Focus()
    $cursorTimer.Start()
    
    Write-Log "Form displayed and activated"
})

$form.Add_FormClosing({
    $cursorTimer.Stop()
    $cursorTimer.Dispose()
})

# Re-establish focus if clicked
$form.Add_Click({
    $hwnd = $form.Handle
    [WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
    [WindowHelper]::BringWindowToTop($hwnd) | Out-Null
    $hCursor = [CursorHelper]::LoadCursor([IntPtr]::Zero, [CursorHelper]::IDC_ARROW)
    [CursorHelper]::SetCursor($hCursor) | Out-Null
})
#endregion

#region Form Controls - Header
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(520, 70)
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(25, 15)
$titleLabel.Size = New-Object System.Drawing.Size(470, 35)
$titleLabel.Text = "DOL Autopilot Pre-Provisioning"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.BackColor = [System.Drawing.Color]::Transparent
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Location = New-Object System.Drawing.Point(25, 80)
$subtitleLabel.Size = New-Object System.Drawing.Size(470, 40)
$subtitleLabel.Text = "Initial Device Setup - Agency Assignment Required`nKeyboard: Type letter → Alt+R | Mouse: Click to select"
$subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($subtitleLabel)
#endregion

#region Form Controls - Serial Number
$serialLabel = New-Object System.Windows.Forms.Label
$serialLabel.Location = New-Object System.Drawing.Point(35, 125)
$serialLabel.Size = New-Object System.Drawing.Size(450, 30)
$serialLabel.Text = "Device Serial Number: $serialNumber"
$serialLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$serialLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$serialLabel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($serialLabel)

$separatorPanel = New-Object System.Windows.Forms.Panel
$separatorPanel.Location = New-Object System.Drawing.Point(35, 160)
$separatorPanel.Size = New-Object System.Drawing.Size(450, 2)
$separatorPanel.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$form.Controls.Add($separatorPanel)
#endregion

#region Form Controls - Agency Selection
$agencyLabel = New-Object System.Windows.Forms.Label
$agencyLabel.Location = New-Object System.Drawing.Point(35, 175)
$agencyLabel.Size = New-Object System.Drawing.Size(450, 25)
$agencyLabel.Text = "Select Your Agency: (Type first letter to jump)"
$agencyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$agencyLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$agencyLabel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($agencyLabel)

$agencyDropdown = New-Object System.Windows.Forms.ComboBox
$agencyDropdown.Location = New-Object System.Drawing.Point(35, 205)
$agencyDropdown.Size = New-Object System.Drawing.Size(450, 35)
$agencyDropdown.DropDownStyle = "DropDownList"
$agencyDropdown.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$agencyDropdown.Cursor = [System.Windows.Forms.Cursors]::Arrow

$agencies = @(
   "OCIO","OCFO","OALJ","ARB","ASAM","ASP","BRB","CRC","DBC","SEC","SOL","OCIA",
   "OSHA","ETA","OASAM","HRC","ILAB","OPA","OSEC","VETS","ODEP","OMBUD","WB","BOC",
   "MSHA","EBSA","OFCCP","OWCP","OWECA","OWDLH","OWDCM","OWDAO","ECB","EMC",
   "OWDFE","OWDEE","WHD","TEST","OLMS"
) | Sort-Object

$agencies += "Other (Enter Below)"
$agencies | ForEach-Object { $agencyDropdown.Items.Add($_) | Out-Null }
$agencyDropdown.SelectedIndex = 0
$form.Controls.Add($agencyDropdown)

$customLabel = New-Object System.Windows.Forms.Label
$customLabel.Location = New-Object System.Drawing.Point(35, 255)
$customLabel.Size = New-Object System.Drawing.Size(350, 25)
$customLabel.Text = "Enter Agency Name (if Other):"
$customLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($customLabel)

$customTextbox = New-Object System.Windows.Forms.TextBox
$customTextbox.Location = New-Object System.Drawing.Point(35, 285)
$customTextbox.Size = New-Object System.Drawing.Size(450, 35)
$customTextbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$customTextbox.Enabled = $false
$customTextbox.Cursor = [System.Windows.Forms.Cursors]::IBeam
$form.Controls.Add($customTextbox)

$agencyDropdown.Add_SelectedIndexChanged({
    if ($agencyDropdown.SelectedItem -eq "Other (Enter Below)") {
        $customTextbox.Enabled = $true
        $customTextbox.Focus()
    } else {
        $customTextbox.Enabled = $false
        $customTextbox.Text = ""
    }
})
#endregion

#region Form Controls - Buttons
$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = New-Object System.Drawing.Point(290, 340)
$okButton.Size = New-Object System.Drawing.Size(120, 40)
$okButton.Text = "&Register Device"
$okButton.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$okButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($okButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(420, 340)
$cancelButton.Size = New-Object System.Drawing.Size(80, 40)
$cancelButton.Text = "&Cancel"
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$cancelButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($cancelButton)

$form.CancelButton = $cancelButton
#endregion

#region Show Form
Write-Log "Displaying agency selection dialog..."
try {
    $result = $form.ShowDialog()
} catch {
    Write-Log "ERROR: Failed to display dialog: $_"
    $groupTag = "DOL"
    $result = [System.Windows.Forms.DialogResult]::OK
}

if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    if ($agencyDropdown.SelectedItem -eq "Other (Enter Below)") {
        if ([string]::IsNullOrWhiteSpace($customTextbox.Text)) {
            [System.Windows.Forms.MessageBox]::Show(
                "You must enter an agency name.",
                "Invalid Input",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            $form.Dispose()
            Write-Log "ERROR: No agency name entered"
            exit 1
        } else { 
            $groupTag = $customTextbox.Text.Trim()
        }
    } else { 
        $groupTag = $agencyDropdown.SelectedItem 
    }
} else {
    Write-Log "Dialog cancelled - using default: DOL"
    $groupTag = "DOL"
}

$form.Dispose()
Write-Log "Agency selected: $groupTag"
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
