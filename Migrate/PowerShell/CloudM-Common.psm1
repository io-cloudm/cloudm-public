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

function GetSharepointApiPermissions([bool]$limitedScope) {
    $sharepointAppId = "00000003-0000-0ff1-ce00-000000000000"
    [string[]]$roles = GetSharepointPermissionsRoles -limitedScope $limitedScope
    return GenerateRequiredResourceAccess -resourceAppId $sharepointAppId -roles $roles
}

function GetMicrosoftGraphPermissionsRoles([bool]$limitedScope) {
    [string[]]$roles = @(
        #Teamwork.Migrate.All
        "dfb0dd15-61de-45b2-be36-d6a69fba3c79",
        #Tasks.ReadWrite.All
        "44e666d1-d276-445b-a5fc-8815eeb81d55"
        #User.Read.All
        "df021288-bdef-4463-88db-98f22de89214",
        #Place.Read.All
        "913b9306-0ce1-42b8-9137-6a7df690a760",
        #Group.ReadWrite.All
        "62a82d76-70ea-41e2-9197-370581804d09",
        #Files.Read.All
        "01d4889c-1287-42c6-ac1f-5d1e02578ef6",
        #Directory.Read.All
        "7ab1d382-f21e-4acd-a863-ba3e13f7da61",
        #Chat.ReadWrite.All
        "294ce7c9-31ba-490a-ad7d-97a7d075e4ed"
        #ChannelMember.ReadWrite.All,
        "35930dcf-aceb-4bd1-b99a-8ffed403c974"
        #Mail.ReadBasic
        "6be147d2-ea4f-4b5a-a3fa-3eab6f3c140a"
        #ChannelMessage.Read.All
        "7b2449af-6ccd-4f4d-9f78-e550c193f0d1"
    )
    switch ($limitedScope) {
        #Sites.Selected
        $true { $roles += "883ea226-0bf2-4a8f-9f9d-92c9162a727d" }
        #Sites.ReadWrite.All
        $false { $roles += "9492366f-7969-46a4-8d15-ed1a20078fff" }
    }
    return $roles
}

function GetSharepointPermissionsRoles([bool]$limitedScope) {
    [string[]]$roles = @()
    switch ($limitedScope) {
        #Sites.Selected
        $true { $roles += "20d37865-089c-4dee-8c41-6967602d4ac8" }
        $false {
            $roles += 
            #Sites.FullControl.All
            "678536fe-1083-478a-9c59-b99265e6b0d3", 
            #User.ReadWrite.All
            "741f803b-c850-494e-b5df-cde7c675a1ca" 
        }
    }
    return $roles
}

function GetExchangeApiPermissions() {
    $exchangeAppId = "00000002-0000-0ff1-ce00-000000000000"
    [string[]]$roles = GetExchangePermissionsRoles
    return GenerateRequiredResourceAccess -resourceAppId $exchangeAppId -roles $roles
}

function GetExchangePermissionsRoles() {
    [string[]]$roles = @(
        #full_access_as_app
        "dc890d15-9560-4a4c-9b7f-a736ec74ec40", 
        #Exchange.ManageAsApp
        "dc50a0fb-09a3-484d-be87-e023b12c6440")
    return $roles
}