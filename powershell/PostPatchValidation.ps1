[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [datetime]$patchStartTime
)

#get last reboot time
$currentBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime

#check for Windows Update faluire events
$updateEvents = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; ID=20,25,31; StartTime = $patchStartTime } -ErrorAction SilentlyContinue
if ($updateEvents) {
    foreach ($winEvent in $updateEvents) {
        $issues += "Update event $($event.Id) at $($event.TimeCreated): $($event.Message)"
    }
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

#check services health
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

$finalResult = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    CurrentBootTime = $currentBootTime
    Passed       = ($issues.Count -eq 0)
    Issues       = $issues

}
$finalResult | ConvertTo-Json -Compress



