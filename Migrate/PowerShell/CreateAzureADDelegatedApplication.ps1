﻿#Requires -RunAsAdministrator

function ImportModules($moduleName) {
    Write-Progress "Importing modules"
    #Install and Import Graph Module
    Write-Progress "Checking if $moduleName is installed"
    if (!(Get-Module -ListAvailable -Name $moduleName)) 
    {
        Write-Progress "Microsoft.Graph module is not installed."
        Write-Progress "Installing $moduleName Module"
        Write-Host "Installing $moduleName Module..." -ForegroundColor DarkGreen
        Install-Module $moduleName -RequiredVersion 2.0.0 -Confirm:$false -Force
        Write-Progress "$moduleName Module installed successfully."

    }
    else
    {
      
      #Check the version. We need Version 2.0.0 to be installed. If any other version (newer or older) is installed, we need to reinstall 2.0.0 
      #(No need to delete, a reinstall will upgrade to 2.0.0)
      #This is related to issue CMT-6388
      $stringVersion = (Get-InstalledModule $moduleName).Version.ToString()
      Write-Progress "$moduleName module is already installed with the version " 
      Write-Progress $stringVersion

      if(!($stringVersion -eq '2.0.0'))
      {
          Write-Host "Module version is different from 2.0.0. Installing the 2.0.0 version"
          Write-Host "Installing $moduleName 2.0.0 Module..." -ForegroundColor DarkGreen
          Install-Module $moduleName -RequiredVersion 2.0.0 -Confirm:$false -Force
          Write-Host "$moduleName Module installed successfully."
      }
      else
      {
          Write-Progress "$moduleName Module Version 2.0.0 is already installed."
      }
    }
    Write-Host "Importing $moduleName Module"

    Import-Module $moduleName -Scope Global -RequiredVersion 2.0.0
}

function CreateConnection($token, $azureEnvironment) {
    Write-Host "Connecting to MgGraph using an Access token"
	$ae = switch ( $azureEnvironment )
    {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
    Connect-MgGraph -Environment $ae -AccessToken $token -ErrorAction Stop
}

function CreateInteractiveConnection($azureEnvironment){
	Write-Host "Connecting to MgGraph using an Interactive login"
	$ae = switch ( $azureEnvironment )
    {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
	$neededScopes = "offline_access openid profile Application.ReadWrite.All Organization.Read.All Directory.Read.All RoleManagement.Read.Directory AppRoleAssignment.ReadWrite.All";
	Connect-MgGraph -Environment $ae -Scope $neededScopes  -ErrorAction Stop
}

function CreateApplication($appNameProvided, $redirectUris) {
    $appName = "CloudM Migrate Delegated"
    if (-not ([string]::IsNullOrWhiteSpace($appNameProvided))){
        $appName = $appNameProvided
    }
    $appHomePageUrl = "https://cloudm.io/"
    $requiredResourceAccess = GenerateDelegatedApplicationApiPermissions
    $alwaysOnUI = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication
    $alwaysOnUI.DisplayName = $appName
    $alwaysOnUI.Web.RedirectUris =  @('{0}/api/OfficeExport/callback' -f $redirectUris), ('{0}/api/OfficeImport/callback' -f $redirectUris)
    $alwaysOnUI.Web.HomePageUrl = $appHomePageUrl
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    $alwaysOnUI.SignInAudience = "AzureADMyOrg"
    $alwaysOnUI.Info.PrivacyStatementUrl = "https://www.cloudm.io/legal/privacy-policy"
    $alwaysOnUI.Info.TermsOfServiceUrl = "https://www.cloudm.io/legal/terms-conditions"
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    # Check if app has already been installed
    Write-Progress "Checking if app already exists"
    if ($app = 	Get-MgApplication -Filter "DisplayName eq '$($appName)'" -ErrorAction SilentlyContinue) {
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
    $requiredResourceAccess =  New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]
	
    $graphAccess = GetMicrosoftGraphApiPermissions
    $requiredResourceAccess.Add($graphAccess)

    return $requiredResourceAccess;
}

function GetMicrosoftGraphApiPermissions() {
    $graphAppId = "00000003-0000-0000-c000-000000000000"
    $scopes = @(
        "9ff7295e-131b-4d94-90e1-69fde507ac11"
    )
    return GenerateRequiredResourceAccess -resourceAppId $graphAppId -roles $scopes 
}

function GenerateRequiredResourceAccess($resourceAppId, $roles) {
    $requiredResourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess
    $requiredResourceAccess.ResourceAppId = $resourceAppId
    $requiredResourceAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess]

    #Add roles
    foreach ($role in $roles) {
        $resourceAccess = GenerateResourceAccess -resourceId $role -resourceType "Scope"
        $requiredResourceAccess.ResourceAccess = $resourceAccess
    }

    return $requiredResourceAccess
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return $resourceAccess
}


function CreateAppDelegatedRegistration($token, $userOutput, $appName, $redirectUris, $useInteractiveLogin, $azureEnvironment) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
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
	ImportModules -moduleName Microsoft.Graph.Applications
        Write-Host "Modules imported" -ForegroundColor DarkGreen

        if($useInteractiveLogin -eq 0)
        {
            CreateInteractiveConnection -azureEnvironment $azureEnvironment
        }
        else
        {
            CreateConnection -token $token  -azureEnvironment $azureEnvironment
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
     

       if($app.passwordcredentials.count -eq 0){
              $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
              write-host "Application password created" -foregroundcolor darkgreen
       }
       else
       #Client Secret already exists. We need to delete it and generate a new one.
       {
            foreach($key in $app.PasswordCredentials){
                Remove-MgApplicationPassword -ApplicationId $appId -KeyId $key.KeyId
                Write-Host "Application password removed successfully" -ForegroundColor DarkGreen
            }
            $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
            write-host "Application password created: " $appsecret -foregroundcolor darkgreen
       }
        
       if (!$userOutput) {
            return $appClientId + "|" + $appsecret.SecretText
       }
       # Display user friendly output
       $nl = [Environment]::NewLine
       $output = ($nl + $nl + "Delegated Permissions Client ID: " + $appClientId)
       $output += ($nl + "Delegated Permissions Client Secret: " + $appsecret.SecretText)
       
       $output = $nl + $nl +"Azure AD Delegated application successfully registered." + $output
       Write-Host $output -ForegroundColor Green
    }
    catch [Microsoft.Open.Azure.AD.CommonLibrary.AadAuthenticationFailedException] {
        throw
    }
}


function CreateAzureAppRegistration() {
	$appName = Read-Host 'Enter the application Name'
	$azureEnvironment = Read-Host "Enter the number that corresponds to your Cloud Deployment`n`n0 Global`n1 China`n2 US Gov `n3 US GovDoD"
	Write-Host 'Do you want to login to Graph interactively (recommended if you are running the script manually) or with a Graph token?'; 
	$interactiveLogin = Read-Host 'Type 0 for interactive login, 1 for a login with a Graph Token'
	$token = '';
	if($interactiveLogin -eq 1){
		$token = Read-Host 'Please enter the Graph Token'
	}
	else{
		Write-Host 'You are using the interactive mode. You will be prompted a window to connect to Graph via your Global Admin Credentails'
	}
    CreateAppDelegatedRegistration -token $token -userOutput $true -appName $appName -redirectUris "https://cloudm.local" -useInteractiveLogin $interactiveLogin -azureEnvironment $azureEnvironment
}

CreateAzureAppRegistration

