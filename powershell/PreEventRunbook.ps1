param 
(  
  [Parameter(Mandatory=$false)]  
  [object] $WebhookData  

)  

Connect-AzAccount -Identity 

$notificationPayload = ConvertFrom-Json -InputObject $WebhookData.RequestBody   
$maintenanceRunId = $notificationPayload[0].data.CorrelationId
$runId = $maintenanceRunId.Split("/")[8] + "_" + $maintenanceRunId.Split("/")[-1]
$resourceSubscriptionIds = $notificationPayload[0].data.ResourceSubscriptionIds

if ($resourceSubscriptionIds.Count -eq 0) {
    Write-Output "Resource subscriptions are not present."
    return
}
Write-Output "Querying ARG to get machine details [MaintenanceRunId=$maintenanceRunId][ResourceSubscriptionIdsCount=$($resourceSubscriptionIds.Count)]" 

$query = @" 
    maintenanceresources  
    | where type =~ 'microsoft.maintenance/applyupdates' 
    | where properties.correlationId =~ '$($maintenanceRunId)' 
    | where id has '/providers/microsoft.compute/virtualmachines/' 
    | project id, resourceId = tostring(properties.resourceId) 
    | order by id asc 
"@ 

$targetMachines = Search-AzGraph -Query $query -Subscription $resourceSubscriptionIds

foreach ($machine in $targetMachines) {
    Write-Output "Target Machine ID: $($machine.resourceId)"
    $vmId = $machine.resourceId
    $split = $vmId -split "/"
    $subscriptionId = $split[2]
    $rg = $split[4]
    $vmName = $split[8]

    Write-Output "Running script on $vmName..."

    $preCheckResult = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName `
        -CommandId 'RunPowerShellScript' -ScriptPath ".\PrePatchCheck.ps1"

    $checkData = ($preCheckResult.Value[0].Message) | ConvertFrom-Json

    if ($checkData.Passed -eq $false) {
        Write-Output "$vmName failed pre-check: $($checkData.Issues -join '; ' ) - cancelling"

        $payload = '{"properties": {"status": "Cancel"}}'

        Invoke-AzRestMethod -Path "$($maintenanceRunId)?api-version=2023-09-01-preview" -Payload $payload -Method PUT
    } else {
        Write-Output "$vmName passed pre-check - taking snapshot and proceeding"

        $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName

        try {
            snapshotConfig = New-AzSnapshotConfig -Location $vm.Location -CreateOption "Copy" -OsType "Windows" `
            -AccountType "Standard_LRS" -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id
            $timestamp = Get-Date -Format 'ddMMyyyy-HHmmss'
            $snapshotName = "$($vmName)_AUM_OSDisk_$timestamp"
            New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $rg
            Write-Output "Snapshot $snapshotName created successfully"
        } catch {
            Write-Output "Snapshot creation failed for $vmName : $_"

        }
    }
}
