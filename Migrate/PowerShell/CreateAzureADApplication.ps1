#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"
$EXHANGE_ROLE_TEMPLATE_ID = "29232cdf-9323-42fd-ade2-1d097af3e4de"
$MaximumFunctionCount = 8192
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
function ImportModules([parameter(mandatory)][String]$moduleName, 
    [parameter(mandatory)][String]$requiredVersion) {
    Write-Progress "Importing modules"
    #Install and Import Graph Module
    Write-Progress "Checking if $moduleName is installed"
    $installedModule = Get-InstalledModule $moduleName -ErrorAction SilentlyContinue
    if (!$installedModule) {
        Write-Progress "$moduleName module is not installed."
        Write-Progress "Installing $moduleName Module"
        Write-Host "Installing $moduleName Module..." -ForegroundColor Green
        Install-Module $moduleName -RequiredVersion $requiredVersion -Confirm:$false -Force
        Write-Progress "$moduleName Module installed successfully."

    }
    else {
        $stringVersion = (Get-InstalledModule $moduleName).Version.ToString()
        Write-Progress "$moduleName module is already installed with the version " 
        Write-Progress $stringVersion

        if (!($stringVersion -eq $requiredVersion)) {
            Write-Host "Module version is different from $requiredVersion. Installing the $requiredVersion version"
            Write-Host "Installing $moduleName $requiredVersion Module..." -ForegroundColor Green
            Install-Module $moduleName -RequiredVersion $requiredVersion -Confirm:$false -Force
            Write-Host "$moduleName Module installed successfully."
        }
        else {
            Write-Progress "$moduleName Module Version $requiredVersion is already installed." -Completed
        }
    }
    Write-Host "Importing $moduleName Module"

    Import-Module $moduleName -Scope Global -RequiredVersion $requiredVersion -ErrorAction SilentlyContinue
} 

function CreateConnection([parameter(mandatory)][String]$token, [parameter(mandatory)][int]$azureEnvironment) {
    Write-Progress "Connecting to MgGraph using an Access token"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'Global' }
        2 { 'China' }
        3 { 'USGov' }
        4 { 'USGovDoD' }
    }
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    Connect-MgGraph -Environment $ae -AccessToken $secureToken -NoWelcome -ErrorAction Stop
}

function CreateInteractiveConnection([parameter(mandatory)][int]$azureEnvironment) {
    Write-Host "Connecting to MgGraph using an Interactive login"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
    $neededScopes = @(
        "offline_access"
        "openid"
        "profile"
        "Application.ReadWrite.All"
        "Organization.Read.All"
        "Directory.Read.All"
        "RoleManagement.Read.Directory"
        "AppRoleAssignment.ReadWrite.All"
        "RoleManagement.ReadWrite.Directory"
    )
    Connect-MgGraph -Environment $ae -Scope $neededScopes -NoWelcome -ErrorAction Stop | Out-Null
}

function CreateConnection([parameter(mandatory)][string]$token, [parameter(mandatory)][int]$azureEnvironment) {
    Write-Progress "Connecting to MgGraph using an Access token"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    Connect-MgGraph -Environment $ae -AccessToken $secureToken -NoWelcome -ErrorAction Stop | Out-Null
}

function RemoveRequiredResourceAccess([parameter(mandatory)][string]$applicationId) {
    $appRequiredResourceAccess = @()
    $appRoleIds = @()
    $requiredResourceAccess = (Invoke-MgGraphRequest -Uri "v1.0/applications(appId='$($applicationId)')" -ErrorAction SilentlyContinue).RequiredResourceAccess 
    foreach ($rra in $requiredResourceAccess) {
        foreach ($resourceAccess in $rra.ResourceAccess) {
            $appRequiredResourceAccess += $resourceAccess.Id
        }
    }

    $appRoleAssignments = (Invoke-MgGraphRequest -Uri "v1.0/servicePrincipals(appId='$($applicationId)')/appRoleAssignments" -ErrorAction SilentlyContinue).Value

    foreach ($appRoleAssignment in $appRoleAssignments) {
        foreach ($a in $appRoleAssignment) {
            $appIdRole = $a.Get_Item("appRoleId")
            if (!$appRequiredResourceAccess.Contains($appIdRole)) {
                $appRoleIds += $a.Get_Item("Id")
                Write-Progress ("Adding AppIdRole to be removed: " + $appIdRole)
            }
        }
    }
     
    foreach ($appRoleAssignmentId in $appRoleIds) {
        Invoke-MgGraphRequest -Uri "v1.0/servicePrincipals(appId='$($applicationId)')/appRoleAssignments/$($appRoleAssignmentId)" -Method DELETE -ErrorAction SilentlyContinue
        Write-Progress ("Removed App Role Assignment Id:" + $appRoleAssignmentId)
    }
}

function CreateApplication([parameter(mandatory)][String]$appName, [parameter(mandatory)][System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]]$requiredResourceAccess) {
    $appHomePageUrl = "https://cloudm.io/"
    $alwaysOnUI = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication
    $alwaysOnUI.DisplayName = $appName
    $alwaysOnUI.Web.HomePageUrl = $appHomePageUrl
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    $alwaysOnUI.SignInAudience = "AzureADMyOrg"
    $alwaysOnUI.Info.PrivacyStatementUrl = "https://www.cloudm.io/legal/privacy-policy"
    $alwaysOnUI.Info.TermsOfServiceUrl = "https://www.cloudm.io/legal/terms-conditions"

    # Check if app has already been installed
    Write-Progress "Checking if app already exists"
    if ($app = Get-MgApplication -Filter "DisplayName eq '$($appName)'" -ErrorAction SilentlyContinue) {
        Write-Progress "App already exists"
        Write-Host "App already exists" -ForegroundColor Yellow
        $appURI = "api://" + $app.AppId
        $alwaysOnUI.IdentifierUris = $appURI
        Update-MgApplication -ApplicationId $app.Id -BodyParameter $alwaysOnUI
        return $app
    }
    Write-Progress "Adding new Azure AD application"
    $app = New-MgApplication -BodyParameter $alwaysOnUI
    $appURI = "api://" + $app.AppId
    Update-MgApplication -ApplicationId $app.Id -IdentifierUri @($appURI)
    return [Microsoft.Graph.PowerShell.Models.IMicrosoftGraphApplication]$app
}

#region Generate Permissions & Roles
function GetSharepointApiPermissions([bool]$limitedScope) {
    $sharepointAppId = "00000003-0000-0ff1-ce00-000000000000"
    [string[]]$roles = GetSharepointPermissionsRoles -limitedScope $limitedScope
    return GenerateRequiredResourceAccess -resourceAppId $sharepointAppId -roles $roles
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
#endregion

function GetOrCreateServicePrincipal([parameter(mandatory)][String]$appId) {
    Write-Progress "Looking for existing service principal"
    $servicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$($appId)'"
    if (!$servicePrincipal) {
        Write-Progress "Adding new service principal"
        $servicePrincipal = New-MgServicePrincipal -AppId $appId
    }
    return $servicePrincipal.Id
}

function GetServicePrincipalIdByAppId([parameter(mandatory)][String]$spAppId) {
    Write-Progress "Getting ServicePrincipal Id for $spAppId "
    $servicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$spAppId'"
    Write-Progress "Getting ServicePrincipal Id for $spAppId Conpleted" -Completed
    return $servicePrincipal.Id;
}

function GrantAppRoleAssignmentToServicePrincipal([parameter(mandatory)][String]$appServicePrincipalId, [parameter(mandatory)][String]$permissionServicePrincipalId, [string[]]$roles = $roles) {
    
    #Grant Admin consent on each role
    foreach ($roleId in $roles) {
        try {
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appServicePrincipalId -PrincipalId  $appServicePrincipalId -ResourceId $permissionServicePrincipalId -AppRoleId $roleId -ErrorAction "stop" | Out-Null
        }
        catch {
            $stringException = Out-String -InputObject $_.Exception 
            if ( $stringException -like "*token validation failure*" -or $stringException -like "*nsufficient privileges to complete the*" ) {
                throw
            }
        }
    }
}

function CreateAppRegistrationInternal ([parameter(mandatory)][String]$token, [parameter(mandatory)][String]$certificateFolder, [parameter(mandatory)][String]$azureEnvironment, [parameter(mandatory)][String]$certificatePassword, [parameter(mandatory)][String]$certificateName, $appName) {
    
    if (!$appName) {
        $appNameDefault = "CloudM Migrate"
    } 
    CreateAppRegistration -workFolder $certificateFolder -azureEnvironment $azureEnvironment -certificatePassword $certificatePassword -certificateName $certificateName -token $token -appName $appNameDefault
}

function CreateAppRegistration([parameter(mandatory)][String]$certificateFolder, [parameter(mandatory)][String]$azureEnvironment, [System.Management.Automation.SwitchParameter]$limitedScope, [String]$certificatePassword, [parameter(mandatory)][String]$appName, [String]$certificateName, [String]$token) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    try {
        Set-Location -Path $scriptPath
        $internal = $token;
        Write-Host "Import Modules" -ForegroundColor Green
        Import-CloudMModule -workFolder $scriptPath -moduleName "CloudM-Certificate" -internal $internal
        Import-CloudMModule -workFolder $scriptPath -moduleName "CloudM-Common" -internal $internal
        if ($limitedScope) {
            Import-CloudMModule -workFolder $scriptPath -moduleName "CloudM-Retry" -internal $internal
            Import-CloudMModule -workFolder $scriptPath -moduleName "CloudM-ProcessCsvs" -internal $internal
        }
        CheckDirectory -path $scriptPath
        if (!$internal) {
            $appName = CleanAppName -value $appName
            $appName = "CloudM-$($appName)"
        }

        $secureCertificatePassword = GetSecurePassword -password $certificatePassword


        # Ensure NuGet is installed
        Write-Progress "Ensuring NuGet is installed"
        Get-PackageProvider -Name "NuGet" -ForceBootstrap | Out-Null

        ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement -requiredVersion 2.10.0
        ImportModules -moduleName Microsoft.Graph.Applications -requiredVersion 2.10.0
        if ($limitedScope) {
            ImportModules -moduleName Microsoft.Graph.Files -requiredVersion 2.10.0
            ImportModules -moduleName Microsoft.Graph.Sites -requiredVersion 2.10.0
            ImportModules -moduleName Microsoft.Graph.Groups -requiredVersion 2.10.0
            ImportModules -moduleName Microsoft.Graph.Teams -requiredVersion 2.10.0
            ImportModules -moduleName ExchangeOnlineManagement -requiredVersion 3.2.0
        }
        if (!$internal) {
            CreateInteractiveConnection -azureEnvironment $azureEnvironment
        }
        else {
            CreateConnection -token $token -azureEnvironment $azureEnvironment
        }
           
        Write-Host "Connected" -ForegroundColor Green
        $requiredResourceAccess = GenerateApplicationApiPermissions -limitedScope $limitedScope
        # Create Application
        $app = CreateApplication $appName -requiredResourceAccess $requiredResourceAccess
        Write-Host "Registered app $($appName) - ($($app.AppId))"  -ForegroundColor Green
        if (!$certName) {
            $certName = $appName + "-" + $app.PublisherDomain
        }
        else {
            $certName = $certificateName
        }
        # Create certificate
        # Generate dates
        CreateUpdateCertificate -appId $app.AppId -workFolder $scriptPath -certName $certName -secureCertificatePassword $secureCertificatePassword -certStartDate $certStartDate -certEndDate $certEndDate | Out-Null
        
        Write-Host "Certificate created. $($appName) - ($($app.AppId))" -ForegroundColor Green

        # Create Service principal
        $servicePrincipalId = GetOrCreateServicePrincipal  -appId $app.AppId
        Write-Host "Service principal created. $($appName) - ($($app.AppId))" -ForegroundColor Green

        #Assign exchange online admin roll
        Write-Progress "Applying Application Roles"
        ApplyExchangeAdminRole -servicePrincipalId $servicePrincipalId
        $certPath = $scriptPath + "\" + $certName + ".pfx"
        Write-Host "Exchange admin roll applied. $($appName) - ($($app.AppId))" -ForegroundColor Green
        # ---------------------  GRANT ADMIN CONSENT ---------------------------------

        #Get the Permission ServicePrincipalId for Graph
        $spAppId = '00000003-0000-0000-c000-000000000000' #Graph API
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        [string[]]$roles = GetMicrosoftGraphPermissionsRoles -limitedScope $limitedScope
        #Grant Admin consent to permissions for Graph APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles

        #Get the Permission ServicePrincipalId for Sharepoint
        $spAppId = '00000003-0000-0ff1-ce00-000000000000' #Sharepoint API
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        [string[]]$roles = GetSharepointPermissionsRoles $limitedScope
        #Grant Admin consent to permissions for Sharepoint APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles

        #Get the Permission ServicePrincipalId for Exchange
        $spAppId = '00000002-0000-0ff1-ce00-000000000000' #Exchange
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        [string[]]$roles = GetExchangePermissionsRoles
        #Grant Admin consent to permissions for Exchange APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles
        Write-Progress "Applying Application Roles" -Completed
        #--------------------------- END GRANT ADMIN CONSENT -------------------------
        $policy = $null
        RemoveRequiredResourceAccess -applicationId $app.AppId
        if ($internal) {
            return $app.AppId + "|" + $certPath;
        }
        
        if ($limitedScope) {
            $mailGroupAlias = $appName 
            $policy = ApplyLimitedMailPolicy -AppId $app.AppId -CertPath $certPath -SecureCertificatePassword $secureCertificatePassword -TenantName $app.PublisherDomain -AppName $appName -MailGroupAlias $mailGroupAlias
        }
        $destinationPath = Join-Path -Path $certificateFolder -ChildPath "$($app.DisplayName) - $($app.PublisherDomain)"
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        $appCertPath = $destinationPath + "\" + $certName + ".pfx"
        OutPutFile -app $app -certPath $appCertPath -secureCertificatePassword $secureCertificatePassword -mailGroupAlias $mailGroupAlias -policy $policy -tenantId $tenantId
        MoveFiles -sourceFolder $scriptPath -appName $app.DisplayName -publisherDomain $app.PublisherDomain -destinationPath $destinationPath  -limitedScope $limitedScope
    }
    catch {
        Write-Host "The message was: $($_)" -ForegroundColor Red
        throw
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-MgGraph"
    }
}
function MoveFiles([parameter(mandatory)][String]$sourceFolder, [parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$publisherDomain, [bool]$limitedScope, [string]$destinationPath) {
    Get-ChildItem -File -Path $sourceFolder |
    ForEach-Object {
        if ($_.Name -match "^$($appName)") {
            Write-Host "Moving $($_.FullName) > ($($destinationPath))"
            Move-Item -Path $_.FullName -Destination $destinationPath -Force
        }
    }
} 

function Import-CloudMModule ([String]$workFolder, [String]$moduleName, $internal) {
    if ($internal) {
        return
    }
    Write-Host "Importing CloudM Module: $($moduleName)"
    $path = Join-Path -Path $workFolder -ChildPath "$($moduleName).psm1" 
    if (!(Test-Path -Path $path -PathType Leaf)) {
        throw (New-Object System.IO.FileNotFoundException("File not found: $($moduleName).psm1"))
    }
    else {
        Import-Module .\$($moduleName) -Force
    }
}

function CleanAppName([parameter(mandatory)][String]$value) {
    $Pattern = "[^a-zA-Z0-9\s]"
    return ($value -replace $Pattern -replace '(^\s+|\s+$)', ' ' -replace '\s+', '')
}

function OutPutFile([parameter(mandatory)][Microsoft.Graph.PowerShell.Models.IMicrosoftGraphApplication]$app, [parameter(mandatory)][String]$certPath, [String]$mailGroupAlias, [PSObject]$policy, [SecureString]$secureCertificatePassword, [string]$tenantId) {
    $nl = [Environment]::NewLine
    $output = ($nl + $nl + "Client ID: " + $app.AppId + ", App Name: " + $app.DisplayName)
    $output += ($nl + "Certificate Path: " + $certPath)
    if ($secureCertificatePasswor) {
        $output += ($nl + "Certificate Password: " + [System.Net.NetworkCredential]::new("", $secureCertificatePassword).Password)
    }
    if ($policy) {
        $output += ($nl + "Policy Created for: $($policy.ScopeName) with $($policy.AccessRight)")
    }
    if ($mailGroupAlias) {
        $output += ($nl + "Mail Group Alias: $($mailGroupAlias)")
    }
    if ($tenantId) {
        $output += ($nl + "Tenant Id: $(tenantId)")
    }
    $output = $nl + $nl + "Azure AD application registered. $($output)"
    Write-Host $output -ForegroundColor Green
    $output | Out-File -FilePath "$scriptPath\$($app.DisplayName)$($app.PublishName).txt"
}

function ApplyExchangeAdminRole($servicePrincipalId) {
    Write-Progress "Applying exchange admin roll to application"
    try {
        $id = Get-MgServicePrincipalMemberOf -ServicePrincipalId $servicePrincipalId -ErrorAction SilentlyContinue
        if (!$id) {
            $params = @{
                roleTemplateId = $EXHANGE_ROLE_TEMPLATE_ID
            }
            New-MgDirectoryRole -BodyParameter $params -ErrorAction SilentlyContinue
            #Exchange Administrator
            $directoryRoleId = (Get-MgDirectoryRole -Filter "RoleTemplateId eq '$($EXHANGE_ROLE_TEMPLATE_ID)'").Id 
            New-MgDirectoryRoleMemberByRef -DirectoryRoleId $directoryRoleId  -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$servicePrincipalId"
        }
    }
    catch {
        Write-Host "Exchange admin already applied" -ForegroundColor Yellow
    }
}
function GetSecurePassword ($password) {
    if ($password) {
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    }
    else {
        $securePassword = (new-object System.Security.SecureString)
    }
    return $securePassword
}

function CreateAzureAppRegistration() {
    $nl = [Environment]::NewLine
    Write-Host "(*) mark required fields"
    $certificatePassword = Read-Host "$($nl)Enter Your Certificate Password " 
    $location = Read-Host "$($nl)Enter the file location to save certificate * "
    $appName = Read-Host "$($nl)Enter the application Name * "
    $azureEnvironment = Read-Host "$($nl)Enter the number that corresponds to your Cloud Deployment`n`n0 Global`n1 China`n2 US Gov `n3 US GovDoD"
    $limitedScopePrompt = Read-Host "$($nl)Type 0 for default scopes or 1 for limited scopes "
    $limitedScope = switch ($limitedScopePrompt) {
        '1' { $true }
        '0' { $false }
        default { $false }
    }
    Read-Host "$($nl)$($nl)You are using the interactive mode. You will be prompted by a window to connect to Graph via your Global Admin Credentails. Please enter to continue"
    if ($limitedScope -eq $true) {
        CreateAppRegistration -certificateFolder "$($location)" -certificatePassword $certificatePassword -appName "$($appName)" -azureEnvironment $azureEnvironment -limitedScope
    }
    else {
        CreateAppRegistration -certificateFolder "$($location)" -certificatePassword $certificatePassword -appName "$($appName)" -azureEnvironment $azureEnvironment
    }
}

CreateAzureAppRegistration

