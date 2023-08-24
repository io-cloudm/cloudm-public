#Requires -RunAsAdministrator

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
	$neededScopes = "offline_access openid profile Application.ReadWrite.All Organization.Read.All Directory.Read.All RoleManagement.Read.Directory AppRoleAssignment.ReadWrite.All RoleManagement.ReadWrite.Directory";
	Connect-MgGraph -Environment $ae -Scope $neededScopes  -ErrorAction Stop
}

function CreateApplication($appNameProvided, [bool]$limitedScope) {
  if(!$appNameProvided){
    $appName = "CloudM Migrate"
  } 
  
    $appHomePageUrl = "https://cloudm.io/"
    $requiredResourceAccess = GenerateApplicationApiPermissions -limitedScope $limitedScope
    $alwaysOnUI = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication
    $alwaysOnUI.DisplayName = $appName
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

function GetSharepointApiPermissions([bool]$limitedScope) {
    #Office 365 SharePoint Online app permissions
    $sharepointAppId = "00000003-0000-0ff1-ce00-000000000000"
    $roles = GetSharepointPermissionsRoles -limitedScope $limitedScope
    return GenerateRequiredResourceAccess -resourceAppId $sharepointAppId -roles $roles
}


function GetMicrosoftGraphApiPermissions([bool]$limitedScope) {
    #OneNote app permissions
    $graphAppId = "00000003-0000-0000-c000-000000000000"
    $roles = GetMicrosoftGraphPermissionsRoles -limitedScope $limitedScope

    return GenerateRequiredResourceAccess -resourceAppId $graphAppId -roles $roles
}

function GetExchangeApiPermissions() {
    #Office 365 Exchange Online app permissions
    $exchangeAppId = "00000002-0000-0ff1-ce00-000000000000"
    $roles = GetExchangePermissionsRoles

    return GenerateRequiredResourceAccess -resourceAppId $exchangeAppId -roles $roles
}

function GetExchangePermissionsRoles() {
    $roles = @("dc890d15-9560-4a4c-9b7f-a736ec74ec40",
    "dc50a0fb-09a3-484d-be87-e023b12c6440")
    return $roles
}

function GetMicrosoftGraphPermissionsRoles([bool]$limitedScope) {
     $roles = @(
        "75359482-378d-4052-8f01-80520e7db3cd",
        "5b567255-7703-4780-807c-7be8301ae99b",
        "62a82d76-70ea-41e2-9197-370581804d09",
        "e2a3a72e-5f79-4c64-b1b1-878b674786c9",
        "3aeca27b-ee3a-4c2b-8ded-80376e2134a4",
        "df021288-bdef-4463-88db-98f22de89214",
        "913b9306-0ce1-42b8-9137-6a7df690a760",
        "35930dcf-aceb-4bd1-b99a-8ffed403c974",        
        "7ab1d382-f21e-4acd-a863-ba3e13f7da61",
        "294ce7c9-31ba-490a-ad7d-97a7d075e4ed",
        "dfb0dd15-61de-45b2-be36-d6a69fba3c79",
        "44e666d1-d276-445b-a5fc-8815eeb81d55"
    )
    switch($limitedScope){
        $true {$roles += "883ea226-0bf2-4a8f-9f9d-92c9162a727d"}
        $false {$roles +="9492366f-7969-46a4-8d15-ed1a20078fff"}
    }
    return $roles
}

function GetSharepointPermissionsRoles([bool]$limitedScope){
    $roles = @()
    switch($limitedScope){
        $true {$roles +="20d37865-089c-4dee-8c41-6967602d4ac8"}
        $false {$roles +="678536fe-1083-478a-9c59-b99265e6b0d3", "741f803b-c850-494e-b5df-cde7c675a1ca"}
    }
    return $roles
}



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
    return $resourceAccess
}

function CreateCertificate($appId, $certFolder, $certName, $certPassword, $certStartDate, $certEndDate) {
    Write-Progress "Creating certificate"
    
    $app = 	Get-MgApplication -Filter "AppId eq '$appId'"
    Write-Progress "Checking if certificate already exists"
    # Check if a non-expired certificate already exists
    $existingCredentials = (Get-MgApplication -Filter "AppId eq '$appId'").KeyCredentials
    if ($existingCredentials) {
        foreach ($credential in $existingCredentials) {
            if (IsValidCertificate -certificate $credential) {
                Write-Progress "Valid certificate exists, removing it"
                Write-Host "Certificate already exists" -ForegroundColor Yellow
                Update-MgApplication -ApplicationId $app.Id -KeyCredentials @{}
            }
        }
    }

    #Generate certificate
    if (CreateSelfSignedCertificate -certName $certName -startDate $certStartDate -endDate $certEndDate -forceCert $true) {
        ExportPFXFile -certFolder $certFolder -certName $certName -certPassword $certPassword
        RemoveCertsFromStore -certName $certName -store "my"
        RemoveCertsFromStore -certName $certName -store "ca"
    }
    # Upload a certificate if needed
    $certData = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("$certFolder\$certName.cer")
    $keyCreds = @{ 
        Type = "AsymmetricX509Cert";
        Usage = "Verify";
        key =  $certData.GetRawCertData();
    }
    Update-MgApplication -ApplicationId $app.Id -KeyCredentials $keyCreds
}

function IsValidCertificate($certificate) {
    if ($certificate.Type -ne "AsymmetricX509Cert") {
        return $false
    }

    $today = Get-Date
    $start = Get-Date $certificate.StartDateTime
    if ($start -gt $today) {
        return $false
    }

    $end = Get-Date $certificate.EndDateTime
    if ($end -lt $today) {
		
        return $false
    }

    return $true
}

function CreateSelfSignedCertificate($certName, $startDate, $endDate, $forceCert) {
    Write-Progress "Creating self signed certificate"
    
    #Remove existing certificates with the same common name from personal and root stores
    #Need to be very wary of this as could break something
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }

    RemoveCertsFromStore -certName $certName -store "my"
    RemoveCertsFromStore -certName $certName -store "ca"

    Write-Progress "Creating cert name"
    $name = new-object -com "X509Enrollment.CX500DistinguishedName.1"
    $name.Encode("CN=$certName", 0)

    Write-Progress "Generating cert key"
    $key = new-object -com "X509Enrollment.CX509PrivateKey.1"
    $key.ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
    $key.KeySpec = 1
    $key.Length = 2048 
    $key.SecurityDescriptor = "D:PAI(A;;0xd01f01ff;;;SY)(A;;0xd01f01ff;;;BA)(A;;0x80120089;;;NS)"
    $key.MachineContext = 1
    $key.ExportPolicy = 1 # This is required to allow the private key to be exported

    Write-Progress "Creating cert key"
    $key.Create()

    Write-Progress "Generating cert server auth oid"
    $serverauthoid = new-object -com "X509Enrollment.CObjectId.1"
    $serverauthoid.InitializeFromValue("1.3.6.1.5.5.7.3.1") # Server Authentication
    $ekuoids = new-object -com "X509Enrollment.CObjectIds.1"
    $ekuoids.add($serverauthoid)
    $ekuext = new-object -com "X509Enrollment.CX509ExtensionEnhancedKeyUsage.1"
    $ekuext.InitializeEncode($ekuoids)

    Write-Progress "Generating cert object"
    $cert = new-object -com "X509Enrollment.CX509CertificateRequestCertificate.1"
    $cert.InitializeFromPrivateKey(2, $key, "")
    $cert.Subject = $name
    $cert.Issuer = $cert.Subject
    $cert.NotBefore = $startDate
    $cert.NotAfter = $endDate
    $cert.X509Extensions.Add($ekuext)
    Write-Progress "Encoding cert"
    $cert.Encode()

    Write-Progress "Generating cert enrollment"
    $enrollment = new-object -com "X509Enrollment.CX509Enrollment.1"
    $enrollment.InitializeFromRequest($cert)
    $certdata = $enrollment.CreateRequest(0)
    Write-Progress "Installing enrollment"
    $enrollment.InstallResponse(2, $certdata, 0, "")
    return $true
}

function CheckDirectory($path) {
    Write-Progress ("Checking if directory exists: " + $path)
    if (!(Test-Path $path)) {
        throw "Directory does not exist " + $path
    }
    try {
        Write-Progress "Checking if new file can be created in directory"
        New-Item -Path $path -Name "permissioncheck" -ItemType "file"
    } catch {
        throw "User does not have access to directory " + $path
    } finally {
        try {
            Write-Progress "Removing permissioncheck file"
            Remove-Item -Path ($path + "\permissioncheck") -Force
        } catch {
            Write-Progress "Could not remove permissioncheck file. " $_.Exception.Message
            Write-Host "Could not remove permissioncheck file. " $_.Exception.Message
        }
    }
}

function ExportPFXFile($certFolder, $certName, $certPassword) {
    Write-Progress "Exporting PFX"
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }
    if ($certPassword) {
      $securePassword = ConvertTo-SecureString $certPassword -AsPlainText -Force
    } else {
      $securePassword = (new-object System.Security.SecureString)
    }
    Write-Progress "Finding cert from store"
    $cert = Get-ChildItem -Path Cert:\LocalMachine\my | where-object { $_.Subject -eq "CN=$certName" }
    
    Write-Progress "Generating pfx file"
    Export-PfxCertificate -Cert $cert -Password $securePassword -FilePath "$certFolder\$certName.pfx"
    Write-Progress "Generating cer file"
    Export-Certificate -Cert $cert -Type CERT -FilePath "$certFolder\$certName.cer"
}

function RemoveCertsFromStore($certName, $store) {
    Write-Progress "Removing certs from store" $store
    # Once the certificates have been been exported we can safely remove them from the store
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }
    $certs = Get-ChildItem -Path ("Cert:\LocalMachine\" + $store) | Where-Object { $_.Subject -eq "CN=$certName" }
    foreach ($c in $certs) {
        Write-Progress ("Removing cert " + $c.PSPath)
        remove-item $c.PSPath
    }
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

function GetOrCreateServicePrincipal($appId) {
    Write-Progress "Looking for existing service principal"
    $servicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$($appId)'"
    if (!$servicePrincipal) {
        Write-Progress "Adding new service principal"
        $servicePrincipal = New-MgServicePrincipal -AppId $appId
    }
    return $servicePrincipal.Id
}

function GetServicePrincipalIdByAppId($spAppId) {
    Write-Progress "Getting ServicePrincipal Id for $spAppId "
    $servicePrincipal= Get-MgServicePrincipal -Filter "AppId eq '$spAppId'"
    return $servicePrincipal.Id;
}


function GrantAppRoleAssignmentToServicePrincipal($appServicePrincipalId, $permissionServicePrincipalId, $roles) {
    
     #Grant Admin consent on each role
    foreach ($roleId in $roles) {
        try
        {
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appServicePrincipalId -PrincipalId  $appServicePrincipalId -ResourceId $permissionServicePrincipalId -AppRoleId $roleId -ErrorAction "stop" | Out-Null
        }
        catch
        {
            $stringException = Out-String -InputObject $_.Exception 
            if( $stringException -like "*token validation failure*" -or $stringException -like "*nsufficient privileges to complete the*" )
            {
               throw
            }
        }
    }
}

function CreateAppRegistration($token, $certFolder, $certName, $certPassword, $userOutput, $appName, $useInteractiveLogin, $azureEnvironment, [bool]$limitedScope, $mailGroupAlias) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    # Validate directory
    CheckDirectory -path $certFolder

     try {

        # Import/Install required modules
        Write-Host "Import Modules" -ForegroundColor DarkGreen
        # Ensure NuGet is installed
        Write-Progress "Ensuring NuGet is installed"
        Get-PackageProvider -Name "NuGet" -ForceBootstrap | Out-Null
        ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement
        ImportModules -moduleName Microsoft.Graph.Applications

        Write-Host "Modules imported" -ForegroundColor DarkGreen

        # Connect to Mg-Graph using a pre-generated access token
		if($useInteractiveLogin -eq 0)
		{
            CreateInteractiveConnection -azureEnvironment $azureEnvironment
		}
		else
		{
            CreateConnection -token $token  -azureEnvironment $azureEnvironment
		}
       
        Write-Host "Connected" -ForegroundColor DarkGreen

        # Create Application
        $tenantId = $connectionInfo.tenantId
        $app = CreateApplication $appName -limitedScope $limitedScope
        $appObjectId = $app.Id
        $appId = $app.AppId
        Write-Host "Registered app" $appId -ForegroundColor DarkGreen

        if (!$certName) {
            $certName = $appName + "-" + $app.PublisherDomain
        }

        # Create certificate
        # Generate dates
        Write-Progress "Generating certificate dates"
        $dateFormat = (Get-Culture).DateTimeFormat.ShortDatePattern
        $certStartDate = (Get-Date).ToString($dateFormat)
        $certEndDate = ([DateTime]::Now).AddYears(5).ToString($dateFormat)

        CreateCertificate -appId $appId -certFolder $certFolder -certName $certName -certPassword $certPassword -certStartDate $certStartDate -certEndDate $certEndDate
        Write-Host "Certificate created" -ForegroundColor DarkGreen

        # Create Service principal
        $servicePrincipalId = GetOrCreateServicePrincipal  -appId $appId 
        Write-Host "Service principal created" -ForegroundColor DarkGreen

        #Assign exchange online admin roll
        ApplyExchangeAdminRole -servicePrincipalId $servicePrincipalId
        Write-Progress "Exchange admin roll applied"
        $certPath = $certFolder + "\" + $certName + ".pfx"


        # ---------------------  GRANT ADMIN CONSENT ---------------------------------

        #Get the Permission ServicePrincipalId for Graph
        $spAppId = '00000003-0000-0000-c000-000000000000' #Graph API
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        $roles = GetMicrosoftGraphPermissionsRoles -limitedScope $limitedScope
        #Grant Admin consent to permissions for Graph APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles

        #Get the Permission ServicePrincipalId for Sharepoint
        $spAppId = '00000003-0000-0ff1-ce00-000000000000' #Sharepoint API
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        $roles = GetSharepointPermissionsRoles $limitedScope
        #Grant Admin consent to permissions for Sharepoint APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles

        #Get the Permission ServicePrincipalId for Exchange
        $spAppId = '00000002-0000-0ff1-ce00-000000000000' #Exchange
        $permissionServicePrincipalId = GetServicePrincipalIdByAppId -spAppId $spAppId
        $roles = GetExchangePermissionsRoles
        #Grant Admin consent to permissions for Exchange APIs
        GrantAppRoleAssignmentToServicePrincipal -appServicePrincipalId $servicePrincipalId -permissionServicePrincipalId $permissionServicePrincipalId -roles $roles

        #--------------------------- END GRANT ADMIN CONSENT -------------------------

        # Return appid if user friendly output is disabled
        if (!$userOutput) {
            return $appId
        }
        
        $policy
        if($limitedScope){
            $policy = ApplyLimitedMailPolicy -appId $appId -certPath $certPath -certPassword $certPassword -tenantName $app.PublisherDomain -appName $appName -mailGroupAlias $mailGroupAlias
        }

        # Display user friendly output
        $nl = [Environment]::NewLine
        $output = ($nl + $nl + "Client ID: " + $appId)
        $output += ($nl + "Certificate Path: " + $certPath)
        $output += ($nl + "Certificate Password: " + $certPassword)
        if($limitedScope){
            $output += ($nl + "Policy Created for: " + $policy.ScopeName + " with " + $policy.AccessRight)
        }
        $output = $nl + $nl +"Azure AD application registered." + $output
        Write-Host $output -ForegroundColor Green
        $output | Out-File -FilePath "$certFolder\$appName.txt"

    }
    catch{
        throw
    }
}

function CreateUpdateApplicationAccessPolicy($appId, $appName, $certPath, $tenantName, $mailGroupAlias){
    $AppPolicies = Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue
    if($AppPolicies){
        foreach ($policie in $AppPolicies)
        {
            if($policie.AppId -eq $appId){
                Write-Host "Removing Application Access Policy for: $appId" 
                Remove-ApplicationAccessPolicy -Identity $policie.Identity
            }
        }
    }
    Write-Host "Creating Policy for: $mailGroupAlias" 
    $policy = New-ApplicationAccessPolicy -AppId $appId -PolicyScopeGroupId $mailGroupAlias -AccessRight RestrictAccess  -Description “Restricted policy for App $appName ($appId)" 
    return $policy
}

function ApplyLimitedMailPolicy($appId, $appName, $certPath, $certPassword, $tenantName, $mailGroupAlias){
    Start-Sleep -Seconds 10
    if ($certPassword) {
        $securePassword = ConvertTo-SecureString $certPassword -AsPlainText -Force
        Connect-ExchangeOnline -CertificateFilePath $certPath -CertificatePassword $securePassword -AppId $appId  -Organization $tenantName -ShowBanner:$false
    }else{
        Connect-ExchangeOnline -CertificateFilePath $certPath -AppId $appId  -Organization $tenantName -ShowBanner:$false
    }

    
    if(!$mailGroupAlias){
        $mailGroupAlias = $appName 
    }

    $distributionGroup = GetCreateMailGroup -mailGroupAlias $mailGroupAlias
    $policy = CreateUpdateApplicationAccessPolicy -appId $appId -appName $appName -certPath $certPath -tenantName $tenantName -mailGroupAlias $distributionGroup.PrimarySmtpAddress
    return $policy
}

function GetCreateMailGroup($mailGroupAlias){
    $distributionGroup = Get-DistributionGroup -Identity $mailGroupAlias -ErrorAction SilentlyContinue
    if($distributionGroup){
        Write-Host "Found Group: " $distributionGroup.PrimarySmtpAddress
        return $distributionGroup;
    }else{
        Write-Host "Creating Distribution Group: $mailGroupAlias" 
        $distributionGroup = New-DistributionGroup -Name $mailGroupAlias -Alias $mailGroupAlias -Type security -Description “Restricted group for App $appName ($appId)" 
    }
    return $distributionGroup;
}

function ApplyExchangeAdminRole($servicePrincipalId) {
    Write-Progress "Applying exchange admin roll to application"
    try {
      $id = Get-MgServicePrincipalMemberOf -ServicePrincipalId $servicePrincipalId -ErrorAction SilentlyContinue
      if(!$id) {
        #Exchange Administrator
        $directoryRoleId = (Get-MgDirectoryRole -Filter "RoleTemplateId eq '29232cdf-9323-42fd-ade2-1d097af3e4de'").Id 
        New-MgDirectoryRoleMemberByRef -DirectoryRoleId $directoryRoleId  -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$servicePrincipalId"
      }
    } catch {
      Write-Host "Exchange admin already applied" -ForegroundColor Yellow
    }
}

function CreateAzureAppRegistration() {
    $certPassword = Read-Host 'Enter Your Certificate Password:' 
    $location = Read-Host 'Enter the file location to save certificate:'
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
    $limitedScopePrompt = Read-Host 'Type 0 for default scopes or 1 for limited scopes'
    $limitedScope = switch ($limitedScopePrompt) {
        '1'   { $true }
        '0'    { $false }
        default { 'neither yes nor no' }
    }
    try
    {
	    CreateAppRegistration -token $token -certFolder $location -certPassword $certPassword -userOutput $true  -appName $appName -useInteractiveLogin $interactiveLogin -azureEnvironment $azureEnvironment -limitedScope $limitedScope
    }
    finally
    {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
}

CreateAzureAppRegistration

