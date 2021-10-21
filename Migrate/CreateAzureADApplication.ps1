#Requires -RunAsAdministrator

function ImportModules() {
    Write-Progress "Importing modules"

    # Ensure NuGet is installed
    Write-Progress "Ensuring NuGet is installed"
    Get-PackageProvider -Name "NuGet" -ForceBootstrap

    # Check if modules need to be installed
    Write-Progress "Checking if MSOnline module is installed"
    if (!(Get-Module -ListAvailable -Name MSOnline)) {
        Write-Progress "Installing MSOnline Module"
        Write-Host "Installing MSOnline Module..." -ForegroundColor DarkGreen
        Install-Module MSOnline -Confirm:$false -Force
    }

    Write-Progress "Importing MSOnline Module"
    Import-Module MSOnline

    Write-Progress "Checking if AzureAD module is installed"
    if (!(Get-Module -ListAvailable -Name AzureAD)) {
    Write-Progress "Installing AzureAD Module"
        Write-Host "Installing AzureAD Module..." -ForegroundColor DarkGreen
        Install-Module AzureAD -Confirm:$false -Force
    }

    Write-Progress "Importing AzureAD Module"
    Import-Module AzureAD

    Write-Progress "Checking if MSAL.PS module is installed"
    if (!(Get-Module -ListAvailable -Name MSAL.PS)) {
        Write-Progress "Installing MSAL.PS Module"
        Write-Host "Installing MSAL.PS Module..." -ForegroundColor DarkGreen
        Install-Module -Name MSAL.PS -RequiredVersion 4.2.1.3 -Confirm:$false -Force
    }

    Write-Progress "Importing MSAL.PS Module"
    Import-Module MSAL.PS
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



function CreateApplication($appNameProvided) {
    $appName = "CloudM Migrate"
    
    if (-not ([string]::IsNullOrWhiteSpace($appNameProvided))){
      $appName = $appNameProvided
    }
    $appHomePageUrl = "https://cloudm.co/"
    $appReplyURLs = @($appHomePageURL, "https://localhost")

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
}

function CreateCertificate($appId, $certFolder, $certName, $certPassword, $certStartDate, $certEndDate) {
    Write-Progress "Creating certificate"

    Write-Progress "Checking if certificate already exists"
    # Check if a non-expired certificate already exists
    if ($existingCredentials = Get-AzureADApplicationKeyCredential -ObjectId $appId) {
        foreach ($credential in $existingCredentials) {
            if (IsValidCertificate -certificate $credential) {
                Write-Progress "Valid certificate exists, removing it"
                Write-Host "Certificate already exists" -ForegroundColor Yellow
                Remove-AzureADApplicationKeyCredential -ObjectId $appId -KeyId $credential.KeyId
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
    $cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cer.Import("$certFolder\$certName.cer") 
    $bin = $cer.GetRawCertData()
    $base64Value = [System.Convert]::ToBase64String($bin)
    $bin = $cer.GetCertHash()
    $base64Thumbprint = [System.Convert]::ToBase64String($bin)
    New-AzureADApplicationKeyCredential -ObjectId $appId -CustomKeyIdentifier $base64Thumbprint  -Type AsymmetricX509Cert -Usage Verify -Value $base64Value -StartDate $certStartDate -EndDate $certEndDate
}

function IsValidCertificate($certificate) {
    if ($certificate.Type -ne "AsymmetricX509Cert") {
        return $false
    }

    $today = Get-Date
    $start = Get-Date $certificate.StartDate
    if ($start -gt $today) {
        return $false
    }

    $end = Get-Date $certificate.EndDate
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

function GenerateApplicationApiPermissions() {
    Write-Progress "Generating application api permissions"
    $requiredResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.RequiredResourceAccess]
	
    $sharepointAccess = GetSharepointApiPermissions
    $requiredResourceAccess.Add($sharepointAccess)

    $graphAccess = GetMicrosoftGraphApiPermissions
    $requiredResourceAccess.Add($graphAccess)

    $exchangeAccess = GetExchangeApiPermissions
    $requiredResourceAccess.Add($exchangeAccess)

    return $requiredResourceAccess;
}

function GetSharepointApiPermissions() {
    #Office 365 SharePoint Online app permissions
    $sharepointAppId = "00000003-0000-0ff1-ce00-000000000000"
    $roles = @(
        "678536fe-1083-478a-9c59-b99265e6b0d3",
        "741f803b-c850-494e-b5df-cde7c675a1ca"
    )

    return GenerateRequiredResourceAccess -resourceAppId $sharepointAppId -roles $roles
}


function GetMicrosoftGraphApiPermissions() {
    #OneNote app permissions
    $graphAppId = "00000003-0000-0000-c000-000000000000"
    $roles = @(
        "75359482-378d-4052-8f01-80520e7db3cd",
        "5b567255-7703-4780-807c-7be8301ae99b",
        "62a82d76-70ea-41e2-9197-370581804d09",
        "e2a3a72e-5f79-4c64-b1b1-878b674786c9",
        "3aeca27b-ee3a-4c2b-8ded-80376e2134a4",
        "9492366f-7969-46a4-8d15-ed1a20078fff",
        "df021288-bdef-4463-88db-98f22de89214",
        "913b9306-0ce1-42b8-9137-6a7df690a760",
        "35930dcf-aceb-4bd1-b99a-8ffed403c974",        
        "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
    )

    return GenerateRequiredResourceAccess -resourceAppId $graphAppId -roles $roles
}

function GetExchangeApiPermissions() {
    #Office 365 Exchange Online app permissions
    $exchangeAppId = "00000002-0000-0ff1-ce00-000000000000"
    $roles = @("dc890d15-9560-4a4c-9b7f-a736ec74ec40")

    return GenerateRequiredResourceAccess -resourceAppId $exchangeAppId -roles $roles
}


function GenerateRequiredResourceAccess($resourceAppId, $roles) {
    $requiredResourceAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
    $requiredResourceAccess.ResourceAppId = $resourceAppId
    $requiredResourceAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]

    #Add roles
    foreach ($role in $roles) {
        $resourceAccess = GenerateResourceAccess -resourceId $role -resourceType "Role"
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

function AssignApplicationPermissions($app, $servicePrincipalId) {
    Write-Progress "Assigning application permissions"
    foreach ($requiredResourcesAccess in $app.RequiredResourceAccess) {      
        $principal = Get-AzureADServicePrincipal -Filter "appid eq '$($requiredResourcesAccess.ResourceAppId)'"
        Write-Host "Assigning Application permissions for $($principal.displayName)" 
        $resources = GenerateApplicationApiPermissions | Where-Object {$_.ResourceAppId -eq $requiredResourcesAccess.ResourceAppId}
        foreach ($resource in $resources.ResourceAccess) {
            if ($resource.Type -match "Role") {
                try {
                    Write-Progress ("Assigning " + $resource.Id)
                    New-AzureADServiceAppRoleAssignment -ObjectId $servicePrincipalId -PrincipalId $servicePrincipalId -ResourceId $principal.ObjectId -Id $resource.Id
                } 
                catch [Microsoft.Open.AzureAD16.Client.ApiException] {
                    Write-Host "Role assignment already exists " $resource.Id -ForegroundColor Yello
                }            
            }
        }	   
    }
}

function TestConnection($tenantId, $clientId, $username, $certPath, $certPassword) {
    Write-Host "Testing application connection (this can take up to a few minutes)..." -ForegroundColor DarkGreen
    Start-Sleep -s 15
    $retrycount = 8
    do {
        try {
            Write-Progress "Generating graph api token"
            $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            $certificate.Import($certPath, $certPassword, 'DefaultKeySet')

            $MSGraphToken = Get-MsalToken -TenantId $tenantId -Scope 'https://graph.microsoft.com/.default' -ClientId $clientId -ClientCertificate $certificate
            
            Write-Progress "Requesting user from graph api"
            $url = "https://graph.microsoft.com/v1.0/users/" + $username
            $token = "bearer " + $MSGraphToken.AccessToken
            $response = Invoke-RestMethod -Uri $url -Headers @{'Authorization' = $token; 'User-Agent' = 'CloudMigrator-3.21+'}

            if ($response.userPrincipalName -ieq $username) {
                return $true
            }

            throw "Unexpected graph response (" + $response.userPrincipalName + ")"
        }
        catch {
            if ($retrycount -gt 0) {
                Write-Host "Could not connect to the Azure application. Retrying in 15 seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            }
            $retrycount --
        }
    }
    While ($retrycount -ge 0)

    Write-Progress "Timeout: Could not connect to azure"
    Write-Host "Could not connect to the Azure application. You may need to re-run this script if the below settings do not work for migrations." -ForegroundColor Red
    return $false
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

function CreateAppRegistration($username, $password, $certFolder, $certName, $certPassword, $userOutput, $skipMfaLoginError, $appName) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    # Validate directory
    CheckDirectory -path $certFolder

    # Generate dates
    Write-Progress "Generating certificate dates"
    $dateFormat = (Get-Culture).DateTimeFormat.ShortDatePattern
    $certStartDate = (Get-Date).ToString($dateFormat)
    $certEndDate = ([DateTime]::Now).AddYears(5).ToString($dateFormat)

    try {
        # Import/Install required modules
        ImportModules
        Write-Host "Imported Modules" -ForegroundColor DarkGreen

        # Connect to AzureAD
        $connection = CreateConnection -username $username -password $password -skipMfaLoginError $skipMfaLoginError
        Write-Host "Connected" -ForegroundColor DarkGreen

        if (!$certName) {
            $certName = $connection.TenantDomain
        }

        # Create Application
        $tenantId = (Get-AzureADTenantDetail).ObjectId
        $app = CreateApplication $appName
        $appObjectId = $app.ObjectId
        $appId = $app.AppId
        Write-Host "Registered app" $appId -ForegroundColor DarkGreen
	
        # Create certificate
        CreateCertificate -appId $appObjectId -certFolder $certFolder -certName $certName -certPassword $certPassword -certStartDate $certStartDate -certEndDate $certEndDate
        Write-Host "Certificate created" -ForegroundColor DarkGreen

        # Create Service principal
        $servicePrincipalId = CreateServicePrincipal -appId $appId -appObjectId $appObjectId -accountId $connection.Account.Id
        Write-Host "Service principal created" -ForegroundColor DarkGreen

        # Assign API permissions
        AssignApplicationPermissions -app $app -servicePrincipalId $servicePrincipalId
        Write-Host "Assigned application permissions" -ForegroundColor DarkGreen

        # Test Application connection
        $certPath = $certFolder + "\\" + $certName + ".pfx"
        $success = TestConnection -tenantId $tenantId -clientId $appId -username $connection.Account.Id -certPath $certPath -certPassword $certPassword

        # Return appid if user friendly output is disabled
        if (!$userOutput) {
            return $appId
        }

        # Display user friendly output
        $nl = [Environment]::NewLine
        $output = ($nl + $nl + "Client ID: " + $appId)
        $output += ($nl + "Certificate Path: " + $certPath)
        $output += ($nl + "Certificate Password: " + $certPassword)

        if ($success) {
            $output = $nl + $nl +"Azure AD application successfully registered." + $output
            Write-Host $output -ForegroundColor Green
        } else {
            $output = $nl + $nl +"Azure AD application registered but could not connect." + $output
            Write-Host $output -ForegroundColor Magenta
        }

    }
    catch [Microsoft.Open.Azure.AD.CommonLibrary.AadAuthenticationFailedException] {
        throw
    }
}

function CreateAzureAppRegistration() {
    $certPassword = Read-Host 'Enter Your Certificate Password:' 
    $location = (Get-Location).ToString()

    CreateAppRegistration -certFolder $location -certPassword $certPassword -userOutput $true
}
CreateAzureAppRegistration