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

function CreateInteractiveConnection($azureEnvironment) {
    Write-Host "Connecting to MgGraph using an Interactive login"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
    $neededScopes = "offline_access openid profile Application.ReadWrite.All Organization.Read.All Directory.Read.All RoleManagement.Read.Directory AppRoleAssignment.ReadWrite.All";
    Connect-MgGraph -Environment $ae -Scope $neededScopes  -ErrorAction Stop
}

function CreateConnection($token, $azureEnvironment) {
    Write-Progress "Connecting to MgGraph using an Access token"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'Global' }
        2 { 'China' }
        3 { 'USGov' }
        4 { 'USGovDoD' }
    }
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    Connect-MgGraph -Environment $ae -AccessToken $secureToken -ErrorAction Stop
}

function CreateApplication($appNameProvided, $redirectUris) {
    $appName = "CloudM Migrate Delegated"
    if (-not ([string]::IsNullOrWhiteSpace($appNameProvided))) {
        $appName = $appNameProvided
    }
    $appHomePageUrl = "https://cloudm.io/"
    $requiredResourceAccess = GenerateDelegatedApplicationApiPermissions
    $alwaysOnUI = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication
    $alwaysOnUI.DisplayName = $appName
    $alwaysOnUI.Web.ImplicitGrantSettings.EnableIdTokenIssuance = $true
    $alwaysOnUI.Web.RedirectUris = @('{0}/api/OfficeExport/callback' -f $redirectUris), ('{0}/api/OfficeImport/callback' -f $redirectUris)
    $alwaysOnUI.Web.HomePageUrl = $appHomePageUrl
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    $alwaysOnUI.SignInAudience = "AzureADMyOrg"
    $alwaysOnUI.Info.PrivacyStatementUrl = "https://www.cloudm.io/legal/privacy-policy"
    $alwaysOnUI.Info.TermsOfServiceUrl = "https://www.cloudm.io/legal/terms-conditions"
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
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
    return $app
}

function GenerateDelegatedApplicationApiPermissions() {
    Write-Progress "Generating Delegated API permissions"
    $requiredResourceAccess = @{
        ResourceAppId  = "00000003-0000-0000-c000-000000000000";
        ResourceAccess = @(
            @{
                #Chat.ReadWrite
                Id   = "9ff7295e-131b-4d94-90e1-69fde507ac11";
                Type = "Scope"
            },
            @{
                #ChannelMessage.Send
                Id   = "ebf0f66e-9fb1-49e4-a278-222f76911cf4";
                Type = "Scope"
            },
            @{
                #User.Read
                Id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d";
                Type = "Scope"
            },
            @{
                #offline 
                Id   = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182";
                Type = "Scope"
            }
        )
    }
    return $requiredResourceAccess;
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return $resourceAccess
}


function CreateAppDelegatedRegistration([parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$redirectUris, [parameter(mandatory)][String]$azureEnvironment, $token) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $internal = $token;
    $dateFormat = (Get-Culture).DateTimeFormat.ShortDatePattern
    $certEndDate = ([DateTime]::Now).AddYears(5).ToString($dateFormat)
    $passwordCred = @{
        displayName = 'Migrate'
        endDateTime = $certEndDate
    }
    try {
        # Import/Install required modules
        Write-Host "Import Modules" -ForegroundColor DarkGreen
        # Ensure NuGet is installed
        Write-Progress "Ensuring NuGet is installed"
        Get-PackageProvider -Name "NuGet" -ForceBootstrap | Out-Null
        ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement -requiredVersion 2.10.0
        ImportModules -moduleName Microsoft.Graph.Applications -requiredVersion 2.10.0
        Write-Host "Modules imported" -ForegroundColor DarkGreen

        if (!$internal) {
            CreateInteractiveConnection -azureEnvironment $azureEnvironment
        }
        else {
            CreateConnection -token $token -azureEnvironment $azureEnvironment
        }

        Write-Host "Connected to Microsoft Graph" -ForegroundColor DarkGreen

        # Create Application
        $app = CreateApplication $appName -redirectUris $redirectUris
        $appClientId = $app.AppId
        $appId = $app.Id
        Write-Host "App created successfully" -ForegroundColor DarkGreen

        $passwordCred = @{
            displayName = 'CloudM Secret'
            endDateTime = (Get-Date).AddMonths(6)
        }
     

        if ($app.passwordcredentials.count -eq 0) {
            $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
            write-host "Application password created" -foregroundcolor darkgreen
        }
        else
        { #Client Secret already exists. We need to delete it and generate a new one.
            foreach ($key in $app.PasswordCredentials) {
                Remove-MgApplicationPassword -ApplicationId $appId -KeyId $key.KeyId
                Write-Host "Application password removed successfully" -ForegroundColor DarkGreen
            }
            $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
            write-host "Application password created: " $appsecret -foregroundcolor darkgreen
        }
        
        if ($internal) {
            return $appClientId + "|" + $appsecret.SecretText
        }
        # Display user friendly output
        $nl = [Environment]::NewLine
        $output = ($nl + $nl + "Delegated Permissions Client ID: " + $appClientId)
        $output += ($nl + "Delegated Permissions Client Secret: " + $appsecret.SecretText)
       
        $output = $nl + $nl + "Azure AD Delegated application successfully registered." + $output
        Write-Host $output -ForegroundColor Green
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


function CreateAzureAppRegistration() {
    $appName = Read-Host 'Enter the application Name'
    $redirectUris = Read-Host "Enter the redirect URI`nIf using CloudM Migrate Hosted, enter the URL of https://migrate.cloudm.io`nIf using CloudM Migrate Self Hosted, enter the URL of your CloudM Migrate Self Hosted instance eg https://cloudm.local"
    $azureEnvironment = Read-Host "Enter the number that corresponds to your Cloud Deployment`n`n0 Global`n1 China`n2 US Gov `n3 US GovDoD"
    Read-Host "$($nl)$($nl)You are using the interactive mode. You will be prompted by a window to connect to Graph via your Global Admin Credentails. Please enter to continue"
    CreateAppDelegatedRegistration -appName $appName -redirectUris $redirectUris -azureEnvironment $azureEnvironment
}

CreateAzureAppRegistration
