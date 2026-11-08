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
$maintenanceEvent = $notificationPayload[0]
$maintenanceRunId = $maintenanceevent.data.CorrelationId
$resourceSubscriptionIds = $maintenanceEvent.data.ResourceSubscriptionIds

$windowStart = ([datetime]$maintenanceEvent.data.StartDateTime).ToUniversalTime()

if ($maintenanceEvent.data.Status -ne "Succeeded") {
    throw "Maintenance run did not succeed. Status: $($maintenanceEvent.data.Status)"
}

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

if ($null -eq $targetMachines -or $targetMachines.Count -eq 0) {
    throw "No VMs were found for maintenance run: $maintenanceRunId"
}

Write-Output "Found $($targetMachines.Count) VM(s) for post-patch validation."

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

        $stdout = $postCheckResult.Value |
            Where-Object { $_.Code -like '*StdOut*' }

        $stderr = $postCheckResult.Value |
            Where-Object { $_.Code -like '*StdErr*' }

        $rawOutput = ($stdout.Message -join "`n")

        if ([string]::IsNullOrWhiteSpace($rawOutput)) {
            throw "Run Command returned empty standard output. Error: $($stderr.Message)"
        }

        $checkData = $rawOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Post-check failed for $vmName"
        Write-Warning "Error: $($_.Exception.Message)"
        $checkData = $null
    }

    if ($null -eq $CheckData) {
        Write-Warning "$vmName has no post-check result - treat as failed"
    } elseif ($checkData.Passed -eq $false) {
        $msg = "$vmName failed post-patch validation: $($checkData.Issues -join '; ' ) - preserving snapshot"
        Write-Output $msg
        Write-Warning $msg
    } elseif ($checkData.Passed -eq $true) {
        Write-Output "$vmName passed post-patch validation."
    } else {
        Write-Warning "$vmName returned an invalid compliance result - treat as failed"
    }
}