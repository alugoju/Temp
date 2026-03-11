# Detect-GroupTag-DEN.ps1
# Intune Proactive Remediation - Detection Script
# Group Tag : DEN
# Registry  : HKLM:\SOFTWARE\Contoso\Autopilot  (Value: GroupTag)
#
# Exit 0 = Compliant   (group tag is correct – no remediation needed)
# Exit 1 = Non-compliant (group tag missing or wrong – trigger remediation)

$RegistryPath  = "HKLM:\SOFTWARE\Contoso\Autopilot"
$RegistryValue = "GroupTag"
$ExpectedTag   = "DEN"

try {
    $current = Get-ItemProperty -Path $RegistryPath -Name $RegistryValue -ErrorAction Stop
    if ($current.$RegistryValue -eq $ExpectedTag) {
        Write-Output "Compliant: GroupTag is '$ExpectedTag'"
        exit 0
    }
    Write-Output "Non-compliant: GroupTag is '$($current.$RegistryValue)', expected '$ExpectedTag'"
    exit 1
} catch {
    Write-Output "Non-compliant: Registry key or value not found. $_"
    exit 1
}
