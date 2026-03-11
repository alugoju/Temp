# Remediate-GroupTag-CLT.ps1
# Intune Proactive Remediation - Remediation Script
# Group Tag : CLT
# Registry  : HKLM:\SOFTWARE\Contoso\Autopilot  (Value: GroupTag)
#
# Exit 0 = Remediation succeeded
# Exit 1 = Remediation failed

$RegistryPath  = "HKLM:\SOFTWARE\Contoso\Autopilot"
$RegistryValue = "GroupTag"
$DesiredTag    = "CLT"

try {
    # Ensure the registry key path exists
    if (-not (Test-Path -Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    # Write / overwrite the GroupTag value
    Set-ItemProperty -Path $RegistryPath -Name $RegistryValue -Value $DesiredTag -Type String -Force

    # Verify the write succeeded
    $written = (Get-ItemProperty -Path $RegistryPath -Name $RegistryValue).$RegistryValue
    if ($written -eq $DesiredTag) {
        Write-Output "Remediation succeeded: GroupTag set to '$DesiredTag'"
        exit 0
    }
    Write-Output "Remediation failed: value after write is '$written'"
    exit 1
} catch {
    Write-Output "Remediation failed: $_"
    exit 1
}
