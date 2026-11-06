[CmdletBinding()]
param()

$issues = @()
$warnings = @()

# Test DNS resolution
$dns = Resolve-DnsName "windowsupdate.microsoft.com" -ErrorAction SilentlyContinue
if (-not $dns) { $issues += "DNS lookup failed for windowsupdate.microsoft.com" }


# Test HTTPS connectivity to key endpoints
$endpoints = @(
    @{ Host = "windowsupdate.microsoft.com"; Port = 443 },
    @{ Host = "update.microsoft.com"; Port = 443 },
    @{ Host = "download.windowsupdate.com"; Port = 80 },
    @{ Host = "dl.delivery.mp.microsoft.com"; Port = 80 ; Optional = $true }
)

foreach ($ep in $endpoints) {
    $tc = Test-NetConnection -ComputerName $ep.Host -Port $ep.Port -WarningAction SilentlyContinue
    if (-not $tc.TcpTestSucceeded) {
        if ($ep.Optional) {
            $warnings += "Optional endpoint unreachable: $($ep.Host):$($ep.Port)"
            continue
        }
        $issues += "FAIL cannot reach $($ep.Host):$($ep.Port)"
    }
}

#Disk space check
try {
    $diskInfo = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'" |
    Select-Object DeviceID, @{n="Free Space (GB)"; e={[math]::Round($_.FreeSpace / 1GB, 2)}}, @{n="Size (GB)"; e={[math]::Round($_.Size/1GB, 2)}}
        
    if ($diskInfo."Free Space (GB)" -lt 20) {
        $issues += "Low Disk Space: ($($diskInfo.'Free Space (GB)'))"
    }
} catch {
    $issues += "Failed to retrieve disk information: $_"
}


#Check if there is a pending reboot 
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) {
    $issues += "Reboot pending (Component Based Servicing)"
}
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore) {
    $issues += "Reboot pending (Windows Update)"
}

if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) {
    $issues += "Reboot pending (pending file rename operations)"
}

#Check to see if services are stopped
$services = Get-Service -Name "wuauserv", "bits", "cryptsvc" | Where-Object {$_.Status -eq "Stopped"}

foreach ($service in $services) {
    $warnings +=  "$($service.Name) is stopped... starting"
    try {
        Start-Service -Name $service.Name -ErrorAction Stop
        $warnings += "Service $($service.Name) was stopped and has been restarted"
    } catch {
        $issues += "Service $($service.Name) is stopped and failed to restart: $_"
    }
} 

#Check trustedinstaller not disabled
if ((Get-Service -Name TrustedInstaller).StartType -eq "Disabled") {
    try {
        Set-Service -Name TrustedInstaller -StartupType Manual -ErrorAction Stop
    } catch {
        $issues += "Service TrustedInstaller is disabled and failed to update: $_"
    }
}

$finalResult = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Passed       = ($issues.Count -eq 0)
    Issues       = $issues
    Warnings     = $warnings
}
$finalResult | ConvertTo-Json -Compress
