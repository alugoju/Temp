# Simple PowerShell Script

# System Information
Write-Host "=== System Information ===" -ForegroundColor Cyan
Write-Host "Computer Name : $env:COMPUTERNAME"
Write-Host "User          : $env:USERNAME"
Write-Host "OS            : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Host "PowerShell    : $($PSVersionTable.PSVersion)"
Write-Host "Date/Time     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Disk Space
Write-Host "`n=== Disk Space ===" -ForegroundColor Cyan
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    $used = [math]::Round($_.Used / 1GB, 2)
    $free = [math]::Round($_.Free / 1GB, 2)
    Write-Host "$($_.Name): Used=${used}GB  Free=${free}GB"
}

# Top 5 processes by CPU
Write-Host "`n=== Top 5 Processes by CPU ===" -ForegroundColor Cyan
Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 |
    Format-Table Name, Id, @{N='CPU(s)';E={[math]::Round($_.CPU,2)}} -AutoSize

Write-Host "Done." -ForegroundColor Green
