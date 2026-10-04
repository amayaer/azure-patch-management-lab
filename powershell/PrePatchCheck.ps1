[CmdletBinding()]
param()

$issues = @()

# Test DNS resolution
try {
    Resolve-DnsName "windowsupdate.microsoft.com" -ErrorAction SilentlyContinue | Format-Table Name, IPAddress
} catch {
    $issues += "DNS $ep ($($_.Exception.Message))"
}

# Test HTTPS connectivity to key endpoints
$endpoints = @(
    "https://windowsupdate.microsoft.com",
    "https://update.microsoft.com",
    "https://download.windowsupdate.com",
    "https://dl.delivery.mp.microsoft.com"
)

foreach ($ep in $endpoints) {
    try {
        $response = Invoke-WebRequest -Uri $ep -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Output "OK $ep (Status: $($response.StatusCode))"
    }
    catch {
       $issues += "FAIL $ep ($($_.Exception.Message))"
    }
}

#disk space check
try {
    $diskInfo = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'" |
    Select-Object DeviceID, @{n="Free Space (GB)"; e={[math]::Round($_.FreeSpace / 1GB, 2)}}, @{n="Size (GB)"; e={[math]::Round($_.SizeGB/1GB, 2)}}
        
    if ($diskInfo."Free Space (GB)" -lt 20) {
        $issues += "Low Disk Space: ($($diskInfo.'Free Space (GB)'))"
    }
} catch {
    $issues += "Failed to retrieve disk information: $_"
}


#check if there is a pending reboot 
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) {
    $issues += "Reboot pending (Component Based Servicing)"
}
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore) {
    $issues += "Reboot pending (Windows Update)"
}

if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) {
    $issues += "Reboot pending (pending file rename operations)"
}

#check to see if services are stopped
$services = Get-Service -Name "wuauserv", "bits", "cryptsvc" | Where-Object {$_.Status -eq "Stopped"}

foreach ($service in $services) {
    Write-Verbose  "$($service.Name) is stopped... starting"
    try {
        Start-Service -Name $service.Name
        $issues += "Service $($service.Name) was stopped and has been restarted"
    } catch {
        $issues += "Service $($service.Name) is stopped and failed to restart: $_"
    }
} 

#check trustedinstaller not disabled
if ((Get-Service -Name TrustedInstaller).StartType -eq "Disabled") {
    try {
        Set-Service -Name TrustedInstaller -StartupType Manual
    } catch {
        $issues += "Service TrustedInstaller is disabled and failed to update: $_"
    }
}

#get last reboot time
$lastBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime

$finalResult = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Passed       = ($issues.Count -eq 0)
    Issues       = $issues
    LastBootTime = $lastBootTime
}
$finalResult | ConvertTo-Json -Compress
