param 
(  
  [Parameter(Mandatory=$false)]  
  [object] $WebhookData  
)  

$ErrorActionPreference = "Stop"

Connect-AzAccount -Identity 

$notificationPayload = ConvertFrom-Json -InputObject $WebhookData.RequestBody   
$maintenanceRunId = $notificationPayload[0].data.CorrelationId
$runId = $maintenanceRunId.Split("/")[8] + "_" + $maintenanceRunId.Split("/")[-1]
$resourceSubscriptionIds = $notificationPayload[0].data.ResourceSubscriptionIds
function Stop-MaintenanceRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        [string]$Reason = "pre-check failed"
    )

    Write-Warning "Cancelling maintenance run: $Reason"
    $body = '{"properties": {"status": "Cancel"}}'

    $response = Invoke-AzRestMethod -Path "$($RunId)?api-version=2023-09-01-preview" `
        -Payload $body -Method PUT

    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        Write-Warning "Cancel request FAILED with status $($response.StatusCode): $($response.Content)"
    } else {
        Write-Output "Cancel request returned status: $($response.StatusCode)"
    }
}

if ($resourceSubscriptionIds.Count -eq 0) {
    Write-Output "Resource subscriptions are not present."
    return
}

try {
    $ctx = New-AzStorageContext -StorageAccountName "azurepatchlabstoracc0896" -UseConnectedAccount
    $tmp = Join-Path $env:TEMP 'PrePatchCheck.ps1'
    Get-AzStorageBlobContent -Container "lab-scripts" -Blob "lab-preblob" -Destination $tmp `
    -Context $ctx -Force 
    $preCheckScript = Get-Content -Path $tmp -Raw

    $query = @"
    maintenanceresources  
    | where type =~ 'microsoft.maintenance/applyupdates' 
    | where properties.correlationId =~ '$($maintenanceRunId)' 
    | where id has '/providers/microsoft.compute/virtualmachines/' 
    | project id, resourceId = tostring(properties.resourceId) 
    | order by id asc 
"@ 
    Write-Output "Querying ARG to get machine details [MaintenanceRunId=$maintenanceRunId][ResourceSubscriptionIdsCount=$($resourceSubscriptionIds.Count)]" 
    $targetMachines = Search-AzGraph -Query $query -Subscription $resourceSubscriptionIds
} catch {
    Stop-MaintenanceRun -RunId $maintenanceRunId -Reason $_.Exception.Message
    return
}

if (!$targetMachines) {
    Write-Warning "No machines found."
    return
}

$passedVMs = @() 
$failedVMs = @()

foreach ($machine in $targetMachines) {
    $checkData = $null
    $vmId = $machine.resourceId
    $split = $vmId -split "/"
    $rg = $split[4]
    $vmName = $split[8]

    Write-Output "Running script on $vmName..."

    try {
        $preCheckResult = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName `
        -CommandId 'RunPowerShellScript' -ScriptString $preCheckScript

        $checkData = ($preCheckResult.Value[0].Message) | ConvertFrom-Json

    } catch {
        $failedVMs += "$vmName : pre-check could not run: $($_.Exception.Message)"
        continue
    }

    if ($null -eq $checkData) {
        $failedVMs += "$vmName : pre-check returned no usable result"
    }
    elseif ($checkData.Passed -eq $true) {
        $passedVms += [PSCustomObject]@{ ResourceGroup = $rg; VMName = $vmName }
    } else {
        $failedVMs += "$vmName : $($checkData.Issues -join '; ')" 
    }
}

if ($failedVMs.Count -gt 0) {
    foreach ($f in $failedVMs) { Write-Warning $f } 
    Stop-MaintenanceRun -RunId $maintenanceRunId -Reason "VM pre-check failures"
    return
} 

foreach ($vmInfo in $passedVMs) {
    $rg = $vmInfo.ResourceGroup
    $vmName = $vmInfo.vmName
    Write-Output "$vmName passed pre-check - taking snapshot and proceeding"

    try {
        $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName 
        $snapshotConfig = New-AzSnapshotConfig -Location $vm.Location -CreateOption "Copy" -OsType "Windows" `
        -AccountType "Standard_LRS" -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id `
        -ErrorAction Stop
        $timestamp = Get-Date -Format 'ddMMyyyy-HHmmss'
        $snapshotName = "$($vmName)_AUM_OSDisk_$timestamp"
        New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $rg `
        -ErrorAction Stop
        Write-Output "Snapshot $snapshotName created successfully"
    } catch {
        Write-Warning "Snapshot creation failed for $vmName : $_"
    }
}