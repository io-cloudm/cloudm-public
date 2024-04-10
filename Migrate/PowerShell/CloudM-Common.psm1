function GenerateRequiredResourceAccess($resourceAppId, $roles) {
    $requiredResourceAccess = New-Object PowerShell.Cmdlets.Resources.MSGraph.Models.ApiV10.MicrosoftGraphRequiredResourceAccess
    $requiredResourceAccess.ResourceAppId = $resourceAppId
    $requiredResourceAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    #Add roles
    foreach ($role in $roles) {
        $resourceAccess = GenerateResourceAccess -resourceId $role -resourceType "Role"
        $requiredResourceAccess.ResourceAccess.Add($resourceAccess)
    }

    return $requiredResourceAccess
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return [Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]$resourceAccess
}

function GenerateRequiredResourceAccess($resourceAppId, $roles) {
    $requiredResourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $requiredResourceAccess.ResourceAppId = $resourceAppId
    $requiredResourceAccessList = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    #Add roles
    foreach ($role in $roles) {
        $resourceAccess = GenerateResourceAccess -resourceId $role -resourceType "Role"
        $requiredResourceAccessList.Add($resourceAccess)
    }
    $requiredResourceAccess.ResourceAccess = $requiredResourceAccessList
    return $requiredResourceAccess
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return $resourceAccess
}

function GenerateApplicationApiPermissions([bool]$limitedScope) {
    Write-Progress "Generating application api permissions"
    
    $requiredResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    $sharepointAccess = GetSharepointApiPermissions -limitedScope $limitedScope
    $requiredResourceAccess.Add($sharepointAccess)

    $graphAccess = GetMicrosoftGraphApiPermissions -limitedScope $limitedScope
    $requiredResourceAccess.Add($graphAccess)

    $exchangeAccess = GetExchangeApiPermissions
    $requiredResourceAccess.Add($exchangeAccess)

    return $requiredResourceAccess;
}

function GetMicrosoftGraphApiPermissions([bool]$limitedScope) {
    $graphAppId = "00000003-0000-0000-c000-000000000000"
    [string[]]$roles = GetMicrosoftGraphPermissionsRoles -limitedScope $limitedScope
    return GenerateRequiredResourceAccess -resourceAppId $graphAppId -roles $roles
}

