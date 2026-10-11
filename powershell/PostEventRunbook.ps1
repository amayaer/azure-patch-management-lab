param 
(  
  [Parameter(Mandatory=$false)]  
  [object] $WebhookData  
)  

Connect-AzAccount -Identity 

$ctx = New-AzStorageContext -StorageAccountName "azurepatchlabstoracc0896" -UseConnectedAccount
$tmp = Join-Path $env:TEMP 'PostPatchValidation.ps1'

Get-AzStorageBlobContent -Container "lab-scripts" -Blob "lab-postblob" -Destination $tmp -Context $ctx -Force 
$postCheckScript = Get-Content -Path $tmp -Raw

$notificationPayload = ConvertFrom-Json -InputObject $WebhookData.RequestBody   
$maintenanceRunId = $notificationPayload[0].data.CorrelationId
$runId = $maintenanceRunId.Split("/")[8] + "_" + $maintenanceRunId.Split("/")[-1]
$resourceSubscriptionIds = $notificationPayload[0].data.ResourceSubscriptionIds

if ($resourceSubscriptionIds.Count -eq 0) {
    Write-Warning "Resource subscriptions are not present."
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

$body = @{
    query         = $query
    subscriptions = @($resourceSubscriptionIds)
    options       = @{ resultFormat = 'objectArray' }
} | ConvertTo-Json -Depth 5

$resp = Invoke-AzRestMethod -Method POST `
    -Path "/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01" `
    -Payload $body

if ($resp.StatusCode -ne 200) {
    throw "Resource Graph query failed ($($resp.StatusCode)): $($resp.Content)"
}

$targetMachines = ($resp.Content | ConvertFrom-Json).data

foreach ($machine in $targetMachines) {
    $checkData = $null
    $vmId = $machine.resourceId
    $split = $vmId -split "/"
    $rg = $split[4]
    $vmName = $split[8]

    Write-Output "Running script on $vmName..."

    try {
        $postCheckResult = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName `
        -CommandId 'RunPowerShellScript' -ScriptString $postCheckScript `
        -Parameter @{ PatchRunStartTime = $windowStart.ToString('o')} `
        -ErrorAction Stop

        $checkData = ($postCheckResult.Value[0].Message) | ConvertFrom-Json
    } catch {
        Write-Warning "post-check could not run for $($vmName): $($_.Exception.Message)"
    }

    if ($null -eq $CheckData) {
        Write-Warning "$vmName has no post-check result - treat as failed"
    } elseif ($checkData.Passed -eq $false) {
        Write-Warning "$vmName failed post-patch validation: $($checkData.Issues -join '; ' ) - preserving snapshot"
    } else {
        Write-Output "$vmName passed post-patch validation."
    }
}