﻿#Requires -RunAsAdministrator

<#
  .SYNOPSIS
  Performs GCP Project, Service Account and API configuration for CloudM Migrate.

  .DESCRIPTION
  The GCP_Configuration.ps1 script creates or sets a GCP Project as default, creates a service account and p12 key, adds the service account as roles/owner on the project
  and enables the GCP APIs based on the scope passed to the script.

  .PARAMETER ProjectId
  Specifies the project id in GCP. ProjectId must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.

  .PARAMETER ServiceAccountId
  Specifies the service account id to create in the GCP project. ServiceAccountId must be between 6 and 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.

  .PARAMETER Scope
  Specifies the scopes required for the ClouM Migrate. Scope must be one of 'All', 'Standard', 'SourceLimited', 'DestinationLimited','Vault' or 'Storage'.
  
  .PARAMETER OutputPath
  Specifies a path to output the script log and service account p12 key to. If not provided C:\CloudM\GCPConfig is used as a default
  
  .INPUTS
  None. You cannot pipe objects to GCP_Configuration.ps1.

  .OUTPUTS
  None. GCP_Configuration.ps1 does not generate any output.

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Standard

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Vault

  .EXAMPLE
  PS> .\GCP_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 Standard C:\TestConfig
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

    [Parameter(Mandatory=$true, Position=2, ValueFromPipeline=$false, HelpMessage="Scope must be one of 'All', 'Standard', 'SourceLimited', 'DestinationLimited', 'Vault' or 'Storage'")]
    [Alias("S")]
    [ValidateSet("All", "Standard", "SourceLimited", "DestinationLimited", "Vault", "Storage")]
    [String]
    $Scope = "Standard",

    [Parameter(Mandatory=$false, Position=3, ValueFromPipeline=$false, HelpMessage="Output Path for P12 key and log e.g. C:\CloudM\GCPConfig")]
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
        $CurrentProject = gcloud config get-value project
    }
    catch
    {
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
    "https://www.googleapis.com/auth/userinfo.profile"
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

    $CombinedScopes = @()

    Switch($Scope) 
    {
        "Standard" { $CombinedScopes= $BaseScopes + $StandardScopes}
        "SourceLimited" { $CombinedScopes= $BaseScopes + $SourceLimitedScopes }
        "DestinationLimited" { $CombinedScopes= $BaseScopes + $DestinationLimitedScopes }
        "Vault" { $CombinedScopes= $BaseScopes + $VaultScopes + $StandardScopes}
        "Storage" { $CombinedScopes= $BaseScopes + $StandardScopes}
        "All" { $CombinedScopes= $BaseScopes + $VaultScopes + $StandardScopes}
        default { $CombinedScopes= $BaseScopes + $VaultScopes + $StandardScopes}
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
    "people.googleapis.com"
    )
    
    $CloudStorageApis = @(
    "storage-api.googleapis.com",
    "storage-component.googleapis.com",
    "storage.googleapis.com"
    )

    $VaultApis = @(
    "vault.googleapis.com"
    )
    
    $CombinedApis = @()

    Switch($Scope) 
    {
        "Standard" { $CombinedApis = $BaseApis}
        "SourceLimited" { $CombinedApis = $BaseApis }
        "DestinationLimited" { $CombinedApis = $BaseApis }
        "Vault" { $CombinedApis = $BaseApis + $VaultApis + $CloudStorageApis }
        "Storage" { $CombinedApis = $BaseApis + $CloudStorageApis }
        "All" { $CombinedApis = $BaseApis + $VaultApis + $CloudStorageApis }
        default { $CombinedApis = $BaseApis + $VaultApis + $CloudStorageApis }
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

Function Configure-ServiceAccount-Key ([string]$LogPath, [string]$ProjectId, [string]$ServiceAccountId, [string]$OutputPath)
{
    $ServiceAccountKeyPath = ""

    $ServiceAccountEmail = Get-Service-Account $ProjectId $ServiceAccountId
        
    Write-Log $LogPath "Creating Service Account Key for: '$ServiceAccountId'"

    Try {

        $ServiceAccountKeyPath = "$($OutputPath)\$($ServiceAccountId)_key.p12"

        gcloud iam service-accounts keys create $ServiceAccountKeyPath --iam-account=$ServiceAccountEmail --key-file-type=p12 --no-user-output-enabled        
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

        $CurrentProject = gcloud config get-value project
    
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
Function Configure-GCP-For-Migrate ([string]$ProjectId, [string]$ServiceAccountId, [string]$Scope, [string]$OutputPath = "C:\CloudM\GCPConfig")
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
    
            $ServiceAccountKeyPath = Configure-ServiceAccount-Key $LogPath $ProjectId $ServiceAccountId $OutputPath

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

            # Open Url at Service Account to Enable Domain Wide Delegation
            Write-Log $LogPath "Step 2. Service Account Domain Wide Delegation" $true

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url: https://console.cloud.google.com/iam-admin/serviceaccounts/details/$ServiceAccountClientId;edit=true?project=$ProjectId"

            Write-Host ""
    

            $ScopesToUse = Build-Scopes-List $Scope

            $ConcatenatedScopes = $ScopesToUse -join ','

            Write-Log $LogPath "Step 3. Configure Google Workspace Domain Wide Delegation using the following ClientId and Scopes:" $true
            Write-Host ""
            Write-Log $LogPath "ClientId: $ServiceAccountClientId"
            Write-Log $LogPath "Scopes: $ConcatenatedScopes"

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url : https://admin.google.com/ac/owl/domainwidedelegation?hl=en"
    
            Write-Host ""

            Write-Log $LogPath "Step 4. Service Account details for use in CloudM Migrate:" $true

            Write-Host ""
            Write-Log $LogPath "Email: $ServiceAccountEmail"
            Write-Log $LogPath "P12 Key: $ServiceAccountKeyPath"

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

Configure-GCP-For-Migrate $ProjectId $ServiceAccountId $Scope $OutputPath
