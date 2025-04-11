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
    if ($secureCertificatePassword) {
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
    $requireProxy = Read-Host "$($nl)Do you need to connect to Microsoft Graph via a proxy? (yes/no)"
    if($requireProxy -eq "yes") {
        if (Connect-MgWithProxy) {
            Write-Host "Proxy connection successful." -ForegroundColor Green
        } else {
            Write-Host "Proxy connection failed. Exiting script." -ForegroundColor Red
            return
        }
    }
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
    Read-Host "$($nl)$($nl)You are using the interactive mode. You will be prompted by a window to connect to Graph via your Global Admin Credentails. Press enter to continue"
    if ($limitedScope -eq $true) {
        CreateAppRegistration -certificateFolder "$($location)" -certificatePassword $certificatePassword -appName "$($appName)" -azureEnvironment $azureEnvironment -limitedScope
    }
    else {
        CreateAppRegistration -certificateFolder "$($location)" -certificatePassword $certificatePassword -appName "$($appName)" -azureEnvironment $azureEnvironment
    }
}

function Connect-MgWithProxy {
    [CmdletBinding()]
    param ()

    Write-Host "`n=== Microsoft Graph Proxy Connector ===`n" -ForegroundColor Cyan
       
    $proxyServer = Read-Host "Enter Proxy Server (e.g., http://your.proxy.server)"
    $proxyPort = Read-Host "Enter Proxy Port (e.g., 8080)"
    $useAuth = Read-Host "Does your proxy require authentication? (yes/no)"

    $proxyUri = "${proxyServer}:${proxyPort}"
    $proxy = New-Object System.Net.WebProxy($proxyUri, $true)

    if ($useAuth -eq "yes") {
        $proxyUser = Read-Host "Enter Proxy Username"
        $proxyPass = Read-Host "Enter Proxy Password" -AsSecureString
        $proxy.Credentials = New-Object System.Net.NetworkCredential($proxyUser, $proxyPass)
    }

    [System.Net.WebRequest]::DefaultWebProxy = $proxy
    $env:http_proxy = $proxyUri
    $env:https_proxy = $proxyUri

    Write-Host "`nTesting proxy connection to Microsoft Graph..." -ForegroundColor Cyan

    try {
        $testResponse = Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/$metadata" -Proxy $proxyUri -UseBasicParsing -TimeoutSec 10
        if ($testResponse.StatusCode -eq 200) {
            Write-Host "Proxy test successful. Microsoft Graph is reachable." -ForegroundColor Green
            return $true
        } else {
            Write-Host "Unexpected response code: $($testResponse.StatusCode)" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "Proxy test failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}


CreateAzureAppRegistration


# SIG # Begin signature block
# MIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBP6Cf4Vy5TsXh6
# mAAI3oH1bysf7Uf+BO8nke7Li3wYmKCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCK
# Qc9vAbjutKlUMA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2JhbFNpZ24g
# Um9vdCBDQSAtIFIzMRMwEQYDVQQKEwpHbG9iYWxTaWduMRMwEQYDVQQDEwpHbG9i
# YWxTaWduMB4XDTIwMDcyODAwMDAwMFoXDTI5MDMxODAwMDAwMFowUzELMAkGA1UE
# BhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2Jh
# bFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAti3FMN166KuQPQNysDpLmRZhsuX/pWcdNxzlfuyTg6qE9aND
# m5hFirhjV12bAIgEJen4aJJLgthLyUoD86h/ao+KYSe9oUTQ/fU/IsKjT5GNswWy
# KIKRXftZiAULlwbCmPgspzMk7lA6QczwoLB7HU3SqFg4lunf+RuRu4sQLNLHQx2i
# CXShgK975jMKDFlrjrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWhb71hEHREspgH4nSr
# /2jcbCY+6R/l4ASHrTDTDI0DfFW4FnBcJHggJetnZ4iruk40mGtwEd44ytS+ocCc
# 4d8eAgHYO+FnQ4S2z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/WsHet3DUZHc86/vZWV
# 7Z0riBD++ljop1fhs8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA/NLDA/CMDNJF1i7n
# j5ie5gTuQm5nfkIWcWLnBPlgxmShtpyBIU4rxm1olIbGmXRzZzF6kfLUjHlufKa7
# fkZvTcWFEivPmiJECKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6RdktpFGQmKmgBzfE
# ZRqqHGsWd/enl+w/GTCZbzH76kCy59LE+snQ8FB2dFn6jW0XMr746X4D9OeHdZrU
# SpEshQMTAitCgPKJajbPyEygzp74y42tFqfT3tWbGKfGkjrxgmPxLg4kZN8CAwEA
# AaOCAXcwggFzMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzAP
# BgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQu86WOzAf
# BgNVHSMEGDAWgBSP8Et/qC5FJK5NUPpjmove4t0bvDB6BggrBgEFBQcBAQRuMGww
# LQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL3Jvb3RyMzA7
# BggrBgEFBQcwAoYvaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQv
# cm9vdC1yMy5jcnQwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2NybC5nbG9iYWxz
# aWduLmNvbS9yb290LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUdIAAwNDAyBggrBgEF
# BQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wDQYJ
# KoZIhvcNAQEMBQADggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9e1ozbg1nDnti2eEY
# XLC9E10dI645UHY3qkT9XwEjWYZWTMytvGQTFDCkIKjgP+icctx+89gMI7qoLao8
# 9uyfhzEHZfU5p1GCdeHyL5f20eFlloNk/qEdUfu1JJv10ndpvIUsXPpYd9Gup7EL
# 4tZ3u6m0NEqpbz308w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XUnZiM02FLL8Mofnre
# kw60faAKbZLEtGY/fadY7qz37MMIAas4/AocqcWXsojICQIZ9lyaGvFNbDDUswar
# AGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggboMIIE0KADAgECAhB3
# vQ4Ft1kLth1HYVMeP3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkw
# FwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENv
# ZGUgU2lnbmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAw
# MDBaMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIw
# MAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAy
# MDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj
# /SBerjgSi8os1P9B2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlM
# g7BKRFAEeIQQaqTWlpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRV
# X5YLEeWatSyyEc8lG31RK5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV
# 0xHK5s2zBZzIU+tS13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEz
# IHXMsdXtHQcZxOsmd/KrbReTSam35sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMk
# oog28vmfvpMusgafJsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq
# 7rfYrWGlr3A2onmO3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult
# 5a/dm2tjIF2OfjuyQ9hiOpTlzbSYszcZJBJyc6sEsAnchebUIgTvQCodLm3HadNu
# twFsDeCXpxbmJouI9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYy
# AjIwfLWTyCH9PIjmaWP47nXJi8Kr77o6/elev7YR8b7wPcoyPm593g9+m5XEEofn
# GrhO7izB36Fl6CSDySrC/blTAgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYw
# EwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4E
# FgQUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0
# Q9lWULvOljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8v
# b2NzcC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUH
# MAKGOmh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWdu
# aW5ncm9vdHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9i
# YWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJ
# KwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24u
# Y29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJ
# yTm6t6E5iS8Yn6vW6x1L6JR8DQdomxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbV
# YQLFY4/UovG2XiULd5bpzXFAM4gp7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQt
# pFg6bBNJ+KUVChSWhbFqaDQlQq+WVvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSX
# hndGKj0jfShziq7vKxuav2xTpxSePIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6
# bs+XYXvfcXo6ymP31TBENzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nO
# ZNm9/Lws80lWAMgSK8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOH
# X5OKSBoRHeU3hZ8uZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dq
# cYC/lt5yA9jYIivzJxZPOOhRQAyuku++PX33gMZMNleElaeEFUgwDlInCI2Oor0i
# xxnJpsoOqHo222q6YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7
# qWPLd0jV+mL8JOAEek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72
# f1LiSY25EXIMiEQmM2YBRN/kMw4h3mKJSAfa9TCCB88wggW3oAMCAQICDErzema3
# QWMQLxMLNTANBgkqhkiG9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQ
# R2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVW
# IENvZGVTaWduaW5nIENBIDIwMjAwHhcNMjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0
# MTE2WjCCAQ4xHTAbBgNVBA8MFFByaXZhdGUgT3JnYW5pemF0aW9uMREwDwYDVQQF
# EwgxMzMzNzM0MzETMBEGCysGAQQBgjc8AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZ
# BgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZ
# MBcGA1UECRMQMTcgTWFyYmxlIFN0cmVldDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3
# YXJlIExpbWl0ZWQxIDAeBgNVBAMTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScw
# JQYJKoZIhvcNAQkBFhhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCeChOiRjYdi7nE+/2zkusEYtLvYDDAgSTi
# G5qyauIreUULuW52PgP6b6SEcwMZf90BaYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/
# qdHwn9wjaI60cenb8e981VXrSHOFlTRnLFv2BEpiqtH0as26jTyt8oa1o6rd/4JI
# 5JngV1TohKwCpl5GxrOv9cDZvRqlBx4uJhU945FQ2wiB8SW9wIeGYDmMHxKX/YXk
# lSm88LnxNznd1BRanPl0VbkJq/UF0FfzN913qu/PxmE5gpak+QQr3JPYtCPQTZPH
# MAN6waMngJnw9TwlNUGEhxvt371Y2FxovdUZyDLuRKxUq7cKexhb2JeL6rWi4J8k
# Sxh54GfLwRAjLWUW6gt8E4Yd/62xP77AodWSvgGMeGM5P5fBQi3Be39abAou4fS3
# qWAEcaWy1qn7p0FxALrplQIyLw6Jnz7d0zzJKJE7hQcEfbqVJZzugxhB7GBfo7Vc
# KDLEJfcwl8RwmsiU4QQGrXUz1wcq+Fy6l+4Km+9f5roKK4dNFETf5srRH5bVvsu6
# wenIXB3elE+loXqkqWhrtuY+bxHoZ1wW1W6FNCh0a9eacSpqBccPahqghnuH19MJ
# 0ky7RAAOwsCiStl53YPocpf+4KYnx8nCDFJqU5TDK59Pav0u1EGv59Lo02AcSEw/
# 6knEVqOqkQIDAQABo4IB2zCCAdcwDgYDVR0PAQH/BAQDAgeAMIGfBggrBgEFBQcB
# AQSBkjCBjzBMBggrBgEFBQcwAoZAaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNv
# bS9jYWNlcnQvZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNydDA/BggrBgEFBQcw
# AYYzaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWdu
# Y2EyMDIwMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0
# dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkG
# A1UdEwQCMAAwRwYDVR0fBEAwPjA8oDqgOIY2aHR0cDovL2NybC5nbG9iYWxzaWdu
# LmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1h
# dHQubWNraW5zdHJ5QGNsb3VkbS5pbzATBgNVHSUEDDAKBggrBgEFBQcDAzAfBgNV
# HSMEGDAWgBQlndD8WQmGY8Xs87ETO1ccA5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6l
# Dmu5FlhyUaFHWawwDQYJKoZIhvcNAQELBQADggIBAMriJ8rqBFu9wWqoGWGotCk5
# rCrEXXfdRRM3jAqhwt+qWy/2nVrl892cPNQe4WeoagqZ1a0c7SRPijwMsmiadfvq
# +iOKe+qIuw2vR/bMpyq7J8GZoIrGD65tde5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+
# iUHv0+rm5LbLxlTftv02Ri6VzIUMg9O4FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB
# /LMWO9dTf5P1WtzcFMBShgSxQrQ5Li4lw4SKpburQecVnB6f7OW70Rfu4CiUVkeo
# R8jL4rUeRaSrR3Pj5tWkmVOpMAcdEjChHmh7gaeJNdOsfv8yUXML4zgSuJTsDR69
# 0NGHEcDcPwgAxTatLmuRCSTuH6tD/gG4ES38Q1mz7joDNkpR79/IzKfYHl30fxHj
# qJbf3cuDy+mK1qd13fvMpR9S69sb8bPdJDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj
# /dIkOT7d5n4CBpubKb6jjQtNIGeDSNcev6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5
# bAKwkllhra6kTj1rKTZEjZCRkaBpcOT3jCijqkG5ir7IZ7IObprSue4CKYjE0Nzc
# o1IuJrDjwM/2cBhLxs7XKKtKHvuX/ze8ygvJIdNTd+9wcwumekJJGFrqJgLPWr3H
# CtF4JiuAnFz7LYjLEr3nMYIDFTCCAxECAQEwbDBcMQswCQYDVQQGEwJCRTEZMBcG
# A1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0Mg
# UjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjACDErzema3QWMQLxMLNTANBglghkgB
# ZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEE
# AYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJ
# BDEiBCCViNJC5JiuLe/Aw6k4ZMW15VMFJokMmLIcYIW2Kyg3dzANBgkqhkiG9w0B
# AQEFAASCAgABg1HGHxb+L0DI9/kM+KD+ZY1AjTf6LiRy+6Mod9kA4iG+UV5z3cez
# IpjzQSmjoUp0ms1/+Kz+a7eXCisjxNTqOuLtlhBukYC88AnC3RXKEVd1KDGfjKIF
# ZFgoWqkaWqqUIjjg0E+n/WcywbB/VouBvuHubasGEMTA63OsQSYycsO6XEtYhIwA
# PeOFG1qns9CPenNDo7x+2phw89lsoObzdp2+14Htq+hlrPfuYatYlVAawUH4sjfr
# nskCxnevtPmODkjzdqQPtPnyV6kDRIEi6GKS/20deUCw7p+2teq9AWcFo6fcw5Yo
# 6vwsFnlq48FoqBJwhGAaNAqatixau/qZwSrIjiTkxiQEMJlOHZwqpyVp5cfjjqVE
# HADS49Ak3XwEFXYvo9rnt5pmcq7CN7zSKqLRxvUMN52Qre3x71JJN0o4s/8rxR7W
# 9yEqQwDFmLskMoF6xtnJm21xEGDFW2AQt1Kr05BC0itZq8K5YlEithZG+t/n3r0s
# kOAlcxl/zNZt6lTKfPq5VQP6NIKXoOB05Ab2ybmAf7qXjZwwxQbG8ZvvJ4YJTj8j
# XTGs0uHgCq9n6hiNiuHE4gq21uCTRzixBIEVM2Oofgrd3+zzGU46kzC3X1cjs1Zw
# G3zfGSKOhMDgZH3d48oWHwJfKDzdT9Xe/JsXezQbNQ1f4vOj/RTd9g==
# SIG # End signature block
