Connect-AzAccount -Identity 

$query = @"
    patchinstallationresources
    | where type =~ 'microsoft.maintenance/applyupdates' 
    | where properties.correlationId =~ '$($maintenanceRunId)' 
    | where id has '/providers/microsoft.compute/virtualmachines/' 
    | project id, resourceId = tostring(properties.resourceId) 
    | order by id asc 
"@ 

$result = Search-AzGraph -Query $query -Subscription $resourceSubscriptionIds

