Connect-AzAccount -Identity 
$subscriptionId = (Get-AzContext).Subscription.Id


$installQuery = @'
patchinstallationresources
| where type =~ 'microsoft.compute/virtualmachines/patchinstallationresults'
| extend vmId = tolower(tostring(split(tolower(id), '/patchinstallationresults/')[0]))
| extend vmName = tostring(split(vmId, '/')[-1])
| extend startTime = todatetime(properties.startDateTime)
| summarize arg_max(startTime, *) by vmId
| project vmId, vmName, startTime, installationStatus = tostring(properties.status),
        installed = toint(properties.installedPatchCount),
        failed = toint(properties.failedPatchCount),
        notSelected = toint(properties.notSelectedPatchCount)
'@

$assessQuery = @'
patchassessmentresources
| where type =~ 'microsoft.compute/virtualmachines/patchassessmentresults'
| extend vmId = tolower(tostring(split(tolower(id), '/patchassessmentresults/')[0]))
| extend assessTime = todatetime(properties.lastModifiedDateTime)
| summarize arg_max(assessTime, *) by vmId
| project vmId, assessTime, 
        assessmentstatus = tostring(properties.status),
        criticalPending = toint(properties.availablePatchCountByClassification.critical),
        securityPending = toint(properties.availablePatchCountByClassification.security)
'@

$joinQuery = @"
$installQuery
| join kind=leftouter (
$assessQuery
) on vmId
| project-away vmId, vmId1
"@

$body = @{
    subscriptions = @($subscriptionId)
    query         = $joinQuery
    options       = @{ resultFormat = 'objectArray' }
} | ConvertTo-Json -Depth 5

$response = Invoke-AzRestMethod -Method POST `
    -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
    -Payload $body

if ($response.StatusCode -ne 200) { throw "Resource Graph query failed: $($response.Content)" }

$result = ($response.Content | ConvertFrom-Json).data

if ($null -eq $result -or $result.Count -eq 0) {
    Write-Warning "No Resource Graph results returned. Skipping CSV upload."
} else {
    Write-Output $result

    $csvPath = Join-Path $env:TEMP "ResourceGraphResults.csv"
    $result | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $storageAccountName = "azurepatchlabstoracc0896"
    $containerName = "lab-report"
    $blobName = "complianceReport_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"

    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

    Set-AzStorageBlobContent -File $csvPath -Container $containerName -Blob $blobName -Context $storageContext -Force

    Write-Host "Successfully uploaded $blobName to $containerName"
}
