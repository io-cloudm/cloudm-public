#Requires -RunAsAdministrator

function ImportModules() {
    Write-Progress "Importing modules"

    # Ensure NuGet is installed
    Write-Progress "Ensuring NuGet is installed"
    Get-PackageProvider -Name "NuGet" -ForceBootstrap

    Write-Progress "Checking if AzureAD module is installed"
    if (!(Get-Module -ListAvailable -Name AzureAD)) {
    Write-Progress "Installing AzureAD Module"
        Write-Host "Installing AzureAD Module..." -ForegroundColor DarkGreen
        Install-Module AzureAD -Confirm:$false -Force
    }

    Write-Progress "Importing AzureAD Module"
    Import-Module AzureAD
}

function CreateConnection($username, $password, $skipMfaLoginError) {
    Write-Progress "Creating AzureAD Connection"
    if ($password) {
        Write-Progress "Creating credential from password"
        $credential = CreateCredential -username $username -password $password
    }
    
    try {
        if ($skipMfaLoginError) {
            Write-Progress "Connecting to AzureAD with Error stop"
            return Connect-AzureAd -Credential $credential -ErrorAction stop
        }
        else {
            Write-Progress "Connecting to AzureAD with Error continue"
            return Connect-AzureAd -Credential $credential
        }
    }
    catch [Microsoft.Open.Azure.AD.CommonLibrary.AadAuthenticationFailedException] {
        if ($skipMfaLoginError) {
            Write-Progress "Re-attempting to connect to AzureAD with manual login"
            return Connect-AzureAd
        }
        throw
    }
}

function CreateCredential($username, $password) {
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential -ArgumentList ($username, $securePassword)
}

function CreateApplication($appNameProvided, $redirectUris) {
    $appName = "CloudM Migrate Delegated"
    
    if (-not ([string]::IsNullOrWhiteSpace($appNameProvided))){
      $appName = $appNameProvided
    }
    $appHomePageUrl = "https://cloudm.co/"
    $appReplyURLs = @('{0}/api/OfficeExport/callback' -f $redirectUris), ('{0}/api/OfficeImport/callback' -f $redirectUris)

    # Check if app has already been installed
    Write-Progress "Checking if app already exists"
    $requiredResourceAccess = GenerateApplicationApiPermissions
    if ($app = Get-AzureADApplication -Filter "DisplayName eq '$($appName)'" -ErrorAction SilentlyContinue) {
        Write-Progress "App already exists"
        Write-Host "App already exists" -ForegroundColor Yellow
        $appURI = "api://" + $app.AppId
        Set-AzureADApplication -ObjectId $app.ObjectId -DisplayName $appName -Homepage $appHomePageUrl -IdentifierUris @($appURI) -ReplyUrls $appReplyURLs -RequiredResourceAccess $requiredResourceAccess 
        return $app
    }
    Write-Progress "Adding new Azure AD application"
    $app = New-AzureADApplication -DisplayName $appName -Homepage $appHomePageUrl -ReplyUrls $appReplyURLs -RequiredResourceAccess $requiredResourceAccess
    $appURI = "api://" + $app.AppId
    Set-AzureADApplication -ObjectId $app.ObjectId -IdentifierUri @($appURI)
    return $app
}

function GenerateApplicationApiPermissions() {
    Write-Progress "Generating application api permissions"
    $requiredResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.RequiredResourceAccess]
	
    $graphAccess = GetMicrosoftGraphApiPermissions
    $requiredResourceAccess.Add($graphAccess)

    return $requiredResourceAccess;
}

function GetMicrosoftGraphApiPermissions() {
    $graphAppId = "00000003-0000-0000-c000-000000000000"
    $scopes = @(
        "9ff7295e-131b-4d94-90e1-69fde507ac11"
    )
    return GenerateRequiredResourceAccess -resourceAppId $graphAppId -Scopes $scopes 
}

function GenerateRequiredResourceAccess($resourceAppId, $scopes) {
    $requiredResourceAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
    $requiredResourceAccess.ResourceAppId = $resourceAppId
    $requiredResourceAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]

    #Add scopes
    foreach ($scope in $scopes) {
        $resourceAccess = GenerateResourceAccess -resourceId $scope -resourceType "Scope"
        $requiredResourceAccess.ResourceAccess.Add($resourceAccess)
    }

    return $requiredResourceAccess
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Open.AzureAD.Model.ResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return $resourceAccess
}

function CreateServicePrincipal($appObjectId, $appId, $accountId) {
    Write-Progress "Looking for existing service principal"
    $servicePrincipal = Get-AzureADServicePrincipal -Filter "AppId eq '$($appId)'"
    if (!$servicePrincipal) {
        Write-Progress "Adding new service principal"
        $servicePrincipal = New-AzureADServicePrincipal -AppId $appId
    }
		
    Write-Progress "Getting application owner"
    $owner = Get-AzureADApplicationOwner -ObjectId $appObjectId -ErrorAction SilentlyContinue
    if (!$owner) {
        Write-Progress "Getting azure AD user"
        $admin = Get-AzureADUser -ObjectId $accountId
        Write-Progress "Adding application owner"
        Add-AzureADApplicationOwner -ObjectId $appObjectId -RefObjectId $admin.ObjectId  
    }
	
    return $servicePrincipal.ObjectId
}

function CreateAppDelegatedRegistration($username, $password, $userOutput, $skipMfaLoginError, $appName, $redirectUris) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $dateFormat = (Get-Culture).DateTimeFormat.ShortDatePattern
    $certEndDate = ([DateTime]::Now).AddYears(5).ToString($dateFormat)
    $passwordCred = @{
        displayName = 'Migrate'
        endDateTime = $certEndDate
    }
    try {
        # Import/Install required modules
        ImportModules
        Write-Host "Imported Modules" -ForegroundColor DarkGreen

        # Connect to AzureAD
        $connection = CreateConnection -username $username -password $password -skipMfaLoginError $skipMfaLoginError
        Write-Host "Connected" -ForegroundColor DarkGreen

        # Create Application
        $app = CreateApplication $appName -redirectUris $redirectUris
        $appObjectId = $app.ObjectId
        $appId = $app.AppId
        Write-Host "Registered app" $appId -ForegroundColor DarkGreen
        if($app.PasswordCredentials.Count -eq 0){
            $appsecret = New-AzureADApplicationPasswordCredential -ObjectId $appObjectId -CustomKeyIdentifier "Migrate" -StartDate $startDate -EndDate $endDate
            Write-Host "Application Password created" -ForegroundColor DarkGreen
        } else{
            foreach($key in $app.PasswordCredentials){
                Remove-AzureADApplicationPasswordCredential -ObjectId $appObjectId -KeyId $key.KeyId
                Write-Host "Removing Application Password" -ForegroundColor DarkGreen
            }
            $appsecret = New-AzureADApplicationPasswordCredential -ObjectId $appObjectId -CustomKeyIdentifier "Migrate" -StartDate $startDate -EndDate $endDate
            Write-Host "Application Password created" -ForegroundColor DarkGreen
        }
        # Create Service principal
        CreateServicePrincipal -appId $appId -appObjectId $appObjectId -accountId $connection.Account.Id
        Write-Host "Service principal created" -ForegroundColor DarkGreen

        # Return appid if user friendly output is disabled
        if (!$userOutput) {
            return $appId + "|" + $appsecret.Value
        }

        # Display user friendly output
        $nl = [Environment]::NewLine
        $output = ($nl + $nl + "Delegated Permissions Client ID: " + $appId)
        $output += ($nl + "Delegated Permissions Client ID Secret: " + $appsecret.Value)

        $output = $nl + $nl +"Azure AD Delegated application successfully registered." + $output
        Write-Host $output -ForegroundColor Green
    }
    catch [Microsoft.Open.Azure.AD.CommonLibrary.AadAuthenticationFailedException] {
        throw
    }
}

function CreateAzureAppRegistration {
 Param(
 [Parameter(Mandatory = $true, HelpMessage="Enter Your (HHTPS) Redirect Uri. Examples: CloudM Self Hosted https//:cloudm.local. CloudM Hosted CloudM Hosted https://migrate.cloudm.io:")]
 [ValidatePattern('^(www\.|https:\/\/)?[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(:[0-9]{1,5})?(\/.*)?$')]
 [string] $redirectUris
 )
    $location = (Get-Location).ToString()

    CreateAppDelegatedRegistration -certFolder $location -certPassword $certPassword -userOutput $true -redirectUris $redirectUris
}

CreateAzureAppRegistration

