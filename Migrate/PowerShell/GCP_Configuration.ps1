#Requires -RunAsAdministrator

<#
  .SYNOPSIS
  Performs GCP Project, Service Account and API configuration for CloudM Migrate.

  .DESCRIPTION
  The GCP_Configuration.ps1 script creates or sets a GCP Project as default, creates a service account and key, adds the service account as roles/owner on the project
  and enables the GCP APIs based on the scope passed to the script.

  .PARAMETER ProjectId
  Specifies the project id in GCP. ProjectId must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.

  .PARAMETER ServiceAccountId
  Specifies the service account id to create in the GCP project. ServiceAccountId must be between 6 and 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.

  .PARAMETER Scope
  Specifies the scopes required for the ClouM Migrate. Scope must be one of 'All', 'Standard', 'SourceLimited', 'DestinationLimited','Vault', 'Spaces' or 'Storage'.

  .PARAMETER KeyType
  Specifies a the type of key to generate. Must be one of 'P12' or 'JSON'. P12 is used as a default
  
  .PARAMETER OutputPath
  Specifies a path to output the script log and service account key to. If not provided C:\CloudM\GCPConfig is used as a default
    
  .INPUTS
  None. You cannot pipe objects to GCP_Configuration.ps1.

  .OUTPUTS
  None. GCP_Configuration.ps1 does not generate any output.

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Standard P12

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Vault JSON

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Standard JSON C:\TestConfig
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$false, HelpMessage="ProjectId must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen")]
    [Alias("P")]
    [ValidatePattern("(?!.*-$)^[a-z][a-z0-9\-]{5,29}$")]
    [ValidateLength(6,30)]
    [String]
    $ProjectId,

    [Parameter(Mandatory=$true, Position=1, ValueFromPipeline=$false, HelpMessage="ServiceAccountId must be between 6 and 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen")]
    [Alias("SA")]
    [ValidatePattern("(?!.*-$)^[a-z][a-z0-9\-]{5,29}$")]
    [ValidateLength(6,30)]
    [String]
    $ServiceAccountId,

    [Parameter(Mandatory=$true, Position=2, ValueFromPipeline=$false, HelpMessage="Scope must be one of 'All', 'Standard', 'SourceLimited', 'DestinationLimited', 'Vault', 'Spaces' or 'Storage'")]
    [Alias("S")]
    [ValidateSet("All", "Standard", "SourceLimited", "DestinationLimited", "Vault", "Spaces", "Storage")]
    [String]
    $Scope = "Standard",

    [Parameter(Mandatory=$true, Position=3, ValueFromPipeline=$false, HelpMessage="Key type must be one of 'P12' or 'JSON'")]
    [Alias("K")]
    [ValidateSet("P12", "JSON")]
    [String]
    $KeyType = "P12",

    [Parameter(Mandatory=$false, Position=4, ValueFromPipeline=$false, HelpMessage="Output Path for the key and log e.g. C:\CloudM\GCPConfig")]
    [Alias("O")]
    [String]
    $OutputPath = "C:\CloudM\GCPConfig"   
)

$ErrorActionPreference = 'Stop'

Function Write-Log([string]$LogPath, [string]$Message, [bool]$Highlight=$false)
{
    [string]$Date = Get-Date -Format G

    ("[$($Date)] - " + $Message) | Out-File -FilePath $LogPath -Append

	if (!($NonInteractive)) {

        if($Highlight)
        {
            Write-Host $Message -BackgroundColor Yellow -ForegroundColor Black
        }
        else
        {
		    Write-Host $Message
        }
	}
}

# Ensure that GoogleCloud module is installed
Function Install-Dependencies([string]$LogPath)
{
    Write-Log $LogPath "Ensuring GoogleCloud module..."
        
    Import-Module GoogleCloud    

    try {
        # Test to see if gcloud init has been run
        $CurrentProject = gcloud config get project
    }
    catch
    {
		$ErrorMessage = $_
		Write-Log $LogPath $ErrorMessage
		
        Throw "Google Cloud SDK has not been initialised or your account does not have the required permissions"
    }
    
    if($CurrentProject) {

        Write-Log $LogPath "Google Cloud SDK has been initialised, Current Project: '$CurrentProject'"
    }
    else
    {
        Throw "Google Cloud SDK has not been initialised"
    }
}

Function Get-Service-Account([string]$ProjectId, [string]$ServiceAccountId)
{
    Return "$($ServiceAccountId)@$($ProjectId).iam.gserviceaccount.com"
}

Function Build-Scopes-List([string]$Scope = "Standard") 
{
    $BaseScopes = @(
    "https://www.googleapis.com/auth/gmail.settings.basic",
    "https://www.googleapis.com/auth/gmail.settings.sharing",        
    "https://sites.google.com/feeds/",
    "https://www.google.com/m8/feeds",
    "https://www.googleapis.com/auth/admin.directory.group",
    "https://www.googleapis.com/auth/admin.directory.user",
    "https://www.googleapis.com/auth/admin.directory.resource.calendar",
    "https://www.googleapis.com/auth/apps.groups.migration",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/drive.appdata",
    "https://www.googleapis.com/auth/email.migration",
    "https://www.googleapis.com/auth/tasks",
    "https://www.googleapis.com/auth/contacts",
    "https://www.googleapis.com/auth/contacts.other.readonly",
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/directory.readonly",
    "https://www.googleapis.com/auth/user.addresses.read",
    "https://www.googleapis.com/auth/user.birthday.read",
    "https://www.googleapis.com/auth/user.emails.read",
    "https://www.googleapis.com/auth/user.gender.read",
    "https://www.googleapis.com/auth/user.organization.read",
    "https://www.googleapis.com/auth/user.phonenumbers.read",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/forms"
    )

    $SourceLimitedScopes = @(
    "https://www.googleapis.com/auth/gmail.labels",
    "https://www.googleapis.com/auth/gmail.readonly"
    )

    $DestinationLimitedScopes = @(
    "https://www.googleapis.com/auth/gmail.labels",
    "https://www.googleapis.com/auth/gmail.insert"
    )

    $StandardScopes = @(
    "https://mail.google.com/"
    )
    
    $VaultScopes = @(
    "https://www.googleapis.com/auth/ediscovery",
    "https://www.googleapis.com/auth/ediscovery.readonly",
    "https://www.googleapis.com/auth/devstorage.read_write"
    )

    #confim these - do we need bot?
    $SpacesScopes = @(
        "https://www.googleapis.com/auth/chat.spaces",
        "https://www.googleapis.com/auth/chat.memberships",
        "https://www.googleapis.com/auth/chat.memberships.app",
        "https://www.googleapis.com/auth/chat.messages",
        "https://www.googleapis.com/auth/chat.import",
        "https://www.googleapis.com/auth/chat.bot"
    )

    $CombinedScopes = @()

    Switch($Scope) 
    {
        "Standard" { $CombinedScopes= $BaseScopes + $StandardScopes}
        "SourceLimited" { $CombinedScopes= $BaseScopes + $SourceLimitedScopes }
        "DestinationLimited" { $CombinedScopes= $BaseScopes + $DestinationLimitedScopes }
        "Vault" { $CombinedScopes= $BaseScopes + $VaultScopes + $StandardScopes}
        "Spaces" { $CombinedScopes = $BaseScopes + $SpacesScopes + $StandardScopes}
        "Storage" { $CombinedScopes= $BaseScopes + $StandardScopes}
        "All" { $CombinedScopes= $BaseScopes + $VaultScopes + $SpacesScopes + $StandardScopes}
        default { $CombinedScopes= $BaseScopes + $VaultScopes + $SpacesScopes + $StandardScopes}
    }

    Return $CombinedScopes
}

Function Build-API-List([string]$Scope = "Standard") 
{
    $BaseApis = @(
    "admin.googleapis.com",
    "contacts.googleapis.com",
    "drive.googleapis.com",
    "gmail.googleapis.com",
    "calendar-json.googleapis.com",
    "groupsmigration.googleapis.com",
    "tasks.googleapis.com",
    "people.googleapis.com",
    "forms.googleapis.com"
    )
    
    $CloudStorageApis = @(
    "storage-api.googleapis.com",
    "storage-component.googleapis.com",
    "storage.googleapis.com"
    )

    $VaultApis = @(
    "vault.googleapis.com"
    )

    $SpacesApis = @(
    "chat.googleapis.com"
    )
    
    $CombinedApis = @()

    Switch($Scope) 
    {
        "Standard" { $CombinedApis = $BaseApis }
        "SourceLimited" { $CombinedApis = $BaseApis }
        "DestinationLimited" { $CombinedApis = $BaseApis }
        "Vault" { $CombinedApis = $BaseApis + $VaultApis + $CloudStorageApis }
        "Spaces" { $CombinedApis = $BaseApis + $SpacesApis + $CloudStorageApis }
        "Storage" { $CombinedApis = $BaseApis + $CloudStorageApis }
        "All" { $CombinedApis = $BaseApis + $VaultApis + $SpacesApis + $CloudStorageApis }
        default { $CombinedApis = $BaseApis + $VaultApis + $SpacesApis + $CloudStorageApis }
    }

    Return $CombinedApis
}

Function Configure-Apis ([string]$LogPath, [string]$ProjectId, [string]$Scope = "Standard")
{
    $Apis = Build-API-List $Scope

    $ServicesEnabled =  gcloud services list --enabled --format="value(name)"

    if($LastExitCode -ne 0) { Throw "Failed to List Enabled APIs" }

    Foreach ($Api in $Apis) {

        $IsEnabledApiName = $false

        Foreach ($ServiceName in $ServicesEnabled) {

            if($ServiceName.EndsWith($Api)) {

                $IsEnabledApiName = $true
                break
            }
        }        

        if(!$IsEnabledApiName) {

            Write-Log $LogPath "Enabling Api: '$Api'"

            try {

                $Operation = gcloud services enable $Api --no-user-output-enabled                
            }
            catch
            {
                Throw "Failed to Enable API: '$Api'"
            }

            if($LastExitCode -ne 0) { Throw "Failed to Enable API: '$Api'" }

            Write-Log $LogPath "Enabled Api: '$Api'"
        }
        else {

            Write-Log $LogPath "Api: '$Api' already Enabled"
        }        
    }
}

Function Configure-ServiceAccount-Key ([string]$LogPath, [string]$ProjectId, [string]$ServiceAccountId, [string]$OutputPath, [string]$KeyType)
{
    $ServiceAccountKeyPath = ""

    $ServiceAccountEmail = Get-Service-Account $ProjectId $ServiceAccountId
        
    Write-Log $LogPath "Creating Service Account Key for: '$ServiceAccountId'"

    Try {

        $LowerKeyType = $KeyType.ToLower()

        $ServiceAccountKeyPath = "$($OutputPath)\$($ServiceAccountId)_key.$($LowerKeyType)"

        gcloud iam service-accounts keys create $ServiceAccountKeyPath --iam-account=$ServiceAccountEmail --key-file-type=$LowerKeyType --no-user-output-enabled        
    }
    catch
    {
        Throw "Failed to Create Service Account Key: '$ServiceAccountId', $_"
    } 

    if($LastExitCode -ne 0) { Throw "Failed to Create Service Account Key: '$ServiceAccountId'" }

    Write-Log $LogPath "Created Service Account Key for: '$ServiceAccountId'"        

    Return $ServiceAccountKeyPath
}

Function Configure-ServiceAccount ([string]$LogPath, [string]$ProjectId, [string]$ServiceAccountId)
{
    $ServiceAccountClientId = ""

    $ServiceAccounts = gcloud iam service-accounts list --format="value(name)"

    if($LastExitCode -ne 0) { Throw "Failed to List Service Accounts" }

    $ServiceAccountExists = $false

    Foreach ($ServiceAccount in $ServiceAccounts) {

        $Index = $ServiceAccount.LastIndexOf('/')

        if($Index -gt -1) {
        
            $ExistingServiceAccountId = $ServiceAccount.Substring($Index+1) 

            if($ExistingServiceAccountId.StartsWith($ServiceAccountId)) {

                $ServiceAccountExists = $true
                break
            }
        }
    }

    if(!$ServiceAccountExists) {

        $ServiceAccountEmail = Get-Service-Account $ProjectId $ServiceAccountId

        Write-Log $LogPath "Creating Service Account: '$ServiceAccountId', this may take a few minutes"

        Try {            

            gcloud iam service-accounts create $ServiceAccountId --display-name="'$ServiceAccountId'" --project=$ProjectId --no-user-output-enabled
            
            Start-Sleep -Seconds 30      
        }
        catch
        {
            Throw "Failed to Create Service Account: '$ServiceAccountId', $_"
        }  

        if($LastExitCode -ne 0) { Throw "Failed to Create Service Account: '$ServiceAccountId'" }
            
        Write-Log $LogPath "Created Service Account: '$ServiceAccountId'"
                
        # Add Owner to Service Account
        $OwnerRole = "roles/owner"

        Write-Log $LogPath "Adding Role: '$OwnerRole' to Service Account: '$ServiceAccountId'"

        Try {

            gcloud projects add-iam-policy-binding $ProjectId --member="serviceAccount:$ServiceAccountEmail" --role="$OwnerRole" --no-user-output-enabled
        }
        catch
        {
            Throw "Failed to Add Role: '$role' to Service Account: '$ServiceAccountId', $_"
        }
        
        if($LastExitCode -ne 0) { Throw "Failed to Add Role: '$role' to Service Account: '$ServiceAccountId'" }   

        Write-Log $LogPath "Added Role: '$OwnerRole' to Service Account: '$ServiceAccountId'"

        Try {

            $RetrievedServiceAccount = gcloud iam service-accounts describe $ServiceAccountEmail --format="json" | ConvertFrom-Json

            if($RetrievedServiceAccount -ne $null) {

                $ServiceAccountClientId = $RetrievedServiceAccount.oauth2ClientId
            }
        }
        catch
        {
            Throw "Failed to Retrieve Service Account: '$ServiceAccountId', $_"
        } 

        if($LastExitCode -ne 0) { Throw "Failed to Retrieve Service Account: '$ServiceAccountId'" } 

        Return $ServiceAccountClientId
    }
    else {

        Write-Log $LogPath "Service Account: '$ServiceAccountId' already exists" 

        Throw "Service Account Already Exists: '$ServiceAccountId', Try again with another Account Id"
    }
}

Function Configure-Project ([string]$LogPath, [string]$ProjectId)
{
    $ProjectNumber = ""

    Write-Log $LogPath "Configuring Project: '$ProjectId'"

    $Projects = gcloud projects list --filter $ProjectId --format=json | ConvertFrom-Json

    if($LastExitCode -ne 0) { Throw "Failed to List Projects" }

    if($Projects.Length -eq 0) {

        Write-Log $LogPath "Creating Project: '$ProjectId', this may take a few minutes"

        try {
        
            gcloud projects create $ProjectId --set-as-default --no-user-output-enabled

            Start-Sleep -Seconds 30
        }
        catch
        {
            Throw "Failed to Create Project: '$ProjectId', $_"
        } 

        if($LastExitCode -ne 0) { Throw "Failed to Create Project: '$ProjectId'" }

        Write-Log $LogPath "Created Project: '$ProjectId'"

    }
    else {

        Write-Log $LogPath "Project: '$ProjectId' Already Exists"

        $CurrentProject = gcloud config get project
    
        if ($CurrentProject -ne $ProjectId) {

            Write-Log $LogPath "Switching to Project: '$ProjectId'"

            gcloud config set project $ProjectId --no-user-output-enabled

            Write-Log $LogPath "Switched to Project: '$ProjectId'"
        }
    }
    
    Try {

        $RetrievedProject = gcloud projects describe $ProjectId --format="json" | ConvertFrom-Json

        if($RetrievedProject -ne $null) {

            $ProjectNumber = $RetrievedProject.projectNumber
        }
    }
    catch
    {
        Throw "Failed to Configure Project: '$ProjectId', $_"
    } 

    if($LastExitCode -ne 0) { Throw "Failed to Configure Project: '$ProjectId'" } 
        
    Write-Log $LogPath "Configured Project: '$ProjectId'"

    Return $ProjectNumber
}

Function Create-OutputPath([string]$OutputPath)
{
    if(!(Test-Path -Path $OutputPath))
    {
        New-Item -ItemType "directory" -Path $OutputPath | Out-Null
    }
}

# Entry point for Script
Function Configure-GCP-For-Migrate ([string]$ProjectId, [string]$ServiceAccountId, [string]$Scope, [string]$KeyType, [string]$OutputPath = "C:\CloudM\GCPConfig")
{
    Create-OutputPath $OutputPath

    $LogPath = "$($OutputPath)\gcp_config.log"

    Write-Host ""
    Write-Log $LogPath "Configuring GCP for CloudM Migrate" $true
    Write-Host ""

    Install-Dependencies $LogPath
    
    # Project
    $ProjectNumber = Configure-Project $LogPath $ProjectId

    if($ProjectNumber) {

        # Service Account
        $ServiceAccountClientId = Configure-ServiceAccount $LogPath $ProjectId $ServiceAccountId
    
        if($ServiceAccountClientId) {

            $ServiceAccountEmail = Get-Service-Account $ProjectId $ServiceAccountId
    
            $ServiceAccountKeyPath = Configure-ServiceAccount-Key $LogPath $ProjectId $ServiceAccountId $OutputPath $KeyType

            # Enable APIs
            Configure-Apis $LogPath $ProjectId $Scope

            Write-Host ""
            Write-Host ""

            Write-Log $LogPath "Project, APIs and Service Account configured. Please use the following steps to complete the OAuth and Domain Wide Delegation configuration" $true

            Write-Host ""

            # Open Url at location for OAuth Consent Screen https://console.cloud.google.com/apis/credentials/consent?project=projectId

            Write-Log $LogPath "Step 1. Configure OAuth Consent" $true

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url: https://console.cloud.google.com/apis/credentials/consent?project=$ProjectId"
       
            Write-Host ""

            $ScopesToUse = Build-Scopes-List $Scope

            $ConcatenatedScopes = $ScopesToUse -join ','

            Write-Log $LogPath "Step 2. Configure Google Workspace Domain Wide Delegation using the following ClientId and Scopes:" $true
            Write-Host ""
            Write-Log $LogPath "ClientId: $ServiceAccountClientId"
            Write-Log $LogPath "Scopes: $ConcatenatedScopes"

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url : https://admin.google.com/ac/owl/domainwidedelegation?hl=en"
    
            Write-Host ""

            Write-Log $LogPath "Step 3. Service Account details for use in CloudM Migrate:" $true

            Write-Host ""
            Write-Log $LogPath "Email: $ServiceAccountEmail"
            Write-Log $LogPath "$KeyType Key: $ServiceAccountKeyPath"

            Write-Host ""

            Write-Log $LogPath "Configured GCP for CloudM Migrate" $true
        }
        else {

            Write-Log $LogPath "Failed Configuring GCP for CloudM Migrate" $true
        }
    }
    else {

        Write-Log $LogPath "Failed Configuring GCP for CloudM Migrate" $true
    }
}

Configure-GCP-For-Migrate $ProjectId $ServiceAccountId $Scope $KeyType $OutputPath

# SIG # Begin signature block
# MIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCALhzRcg2FifmTA
# e/5aodXs6bPoH7tYEtN7VYMEnTLTf6CCFGUwggWiMIIEiqADAgECAhB4AxhCRXCK
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
# BDEiBCA7bjXGav9DhRFyk7qMQz12mnfplgeO2bPIl9rvvKrowDANBgkqhkiG9w0B
# AQEFAASCAgB4HO60/7HhTn7lPh8AnnTz0bgSGZSHRdofBQWKhcSmx2zNWofQaOIa
# /5JD/yubNoOjpOPEO2hhi2pAnCE3d19x0d1ti0X8zll2/6zCmrj8TqoKKBb9ig9x
# 9MTE5SRnb+mMKfy/oWLkkMAK1YpZZYAu3HpuPVGFfobq9dnuhvDMyCXbEpEyfWxd
# PB6E35J+FT57Xa67e5R2ZybPHF5dV7HYzjIvRGEHBXDFMNrcDz2dIyQrNe240ns9
# WIX4wKIcdKcz401RF4SvIxZcOM9alZWHqf2orju0IZ5MsHc2E+M8Ru6VZ37CgZuU
# WEg3sc2OgcjKo1TJehVlqbtY35utybsuOgnegxmVnlOuIc/HuAtkDhOIi2SJMgz3
# q1UnKgSg5oQt+/5f1KkGtYpNUZOZj/Pivt0yjLzHeW2ZtIfIjNGJSVZcb6syY71R
# 7p6Ykw3AT6jd4CZPezUOER0GCFw0c67iS3I48nv1//poO6suv2rWZfdvqZ3GMBxV
# XAkjLlgD957MsQAKlWIEPLe27x+2SnhzTjXcKjtBn1O60R0Djz9yGx6PKh7Rj1/z
# uhSLaYkh+UJhFAYt3HnXon1fQXOy7ap9ui3/jZkmZjhM514oqSaASROQmgB54qnt
# x+Kv2Q6B8Yhk9fmJ5wRXhtfUtU/XCxy0lbN2N62jfF8Aj5/lQDeotA==
# SIG # End signature block
