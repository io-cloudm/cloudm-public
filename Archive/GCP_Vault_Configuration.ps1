#Requires -RunAsAdministrator

<#
  .SYNOPSIS
  Performs GCP Project, Service Account and API configuration for CloudM Migrate.

  .DESCRIPTION
  The GCP_Vault_Configuration.ps1 script creates or sets a GCP Project as default, creates a service account and json key, adds the service account as roles/owner on the project
  and enables the GCP APIs based on the scopes required for Google Vault export.

  .PARAMETER ProjectId
  Specifies the project id in GCP. ProjectId must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.

  .PARAMETER ServiceAccountId
  Specifies the service account id to create in the GCP project. ServiceAccountId must be between 6 and 30 lowercase letters, digits, or hyphens. 
  It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen.
    
  .PARAMETER OutputPath
  Specifies a path to output the script log and service account Json key to. If not provided C:\CloudM\GCPVaultConfig is used as a default
  
  .INPUTS
  None. You cannot pipe objects to GCP_Vault_Configuration.ps1.

  .OUTPUTS
  None. GCP_Vault_Configuration.ps1 does not generate any output.

  .EXAMPLE
  PS> .\GCP_Vault_Configuration.ps1 test-cloudm-io-migrate test-service-account-1

  .EXAMPLE
  PS> .\GCP_Vault_Configuration.ps1 test-cloudm-io-migrate test-service-account-1 C:\TestConfig
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
    
    [Parameter(Mandatory=$false, Position=2, ValueFromPipeline=$false, HelpMessage="Output Path for P12 key and log e.g. C:\CloudM\GCPVaultConfig")]
    [Alias("O")]
    [String]
    $OutputPath = "C:\CloudM\GCPVaultConfig"
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

Function Build-Scopes-List() 
{    
    $VaultScopes = @(
    "https://www.googleapis.com/auth/ediscovery",
    "https://www.googleapis.com/auth/ediscovery.readonly",
    "https://www.googleapis.com/auth/devstorage.read_write"
    )

    Return $VaultScopes
}

Function Build-API-List() 
{    
    $CloudStorageApis = @(
    "storage-api.googleapis.com",
    "storage-component.googleapis.com",
    "storage.googleapis.com"
    )

    $VaultApis = @(
    "vault.googleapis.com"
    )
    
    $CombinedApis = $VaultApis + $CloudStorageApis
    
    Return $CombinedApis
}

Function Configure-Apis ([string]$LogPath, [string]$ProjectId)
{
    $Apis = Build-API-List

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

        $KeyFileType = "json"

        $ServiceAccountKeyPath = "$($OutputPath)\$($ServiceAccountId)_key.$($KeyFileType)"

        gcloud iam service-accounts keys create $ServiceAccountKeyPath --iam-account=$ServiceAccountEmail --key-file-type=$KeyFileType --no-user-output-enabled        
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
Function Configure-GCP-For-Migrate ([string]$ProjectId, [string]$ServiceAccountId, [string]$OutputPath = "C:\CloudM\GCPVaultConfig")
{
    Create-OutputPath $OutputPath

    $LogPath = "$($OutputPath)\gcp_config.log"

    Write-Host ""
    Write-Log $LogPath "Configuring GCP for CloudM Archive Vault" $true
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
            Configure-Apis $LogPath $ProjectId

            Write-Host ""
            Write-Host ""

            Write-Log $LogPath "Project, APIs and Service Account configured. Please use the following steps to complete the OAuth and Domain Wide Delegation configuration" $true

            Write-Host ""
            
            # Open Url at Service Account to Enable Domain Wide Delegation
            Write-Log $LogPath "Step 1. Service Account Domain Wide Delegation" $true

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url: https://console.cloud.google.com/iam-admin/serviceaccounts/details/$ServiceAccountClientId;edit=true?project=$ProjectId"

            Write-Host ""
    

            $ScopesToUse = Build-Scopes-List

            $ConcatenatedScopes = $ScopesToUse -join ','

            Write-Log $LogPath "Step 2. Configure Google Workspace Domain Wide Delegation using the following ClientId and Scopes:" $true
            Write-Host ""
            Write-Log $LogPath "ClientId: $ServiceAccountClientId"
            Write-Log $LogPath "Scopes: $ConcatenatedScopes"

            Write-Host ""

            Write-Log $LogPath "To configure, use a browser and navigate to the following url : https://admin.google.com/ac/owl/domainwidedelegation?hl=en"
    
            Write-Host ""

            Write-Log $LogPath "Step 3. Service Account details for use in CloudM Archive Vault:" $true

            Write-Host ""
            Write-Log $LogPath "Email: $ServiceAccountEmail"
            Write-Log $LogPath "Json Key: $ServiceAccountKeyPath"

            Write-Host ""

            Write-Log $LogPath "Configured GCP for CloudM Archive Vault" $true
        }
        else {

            Write-Log $LogPath "Failed Configuring GCP for CloudM Archive Vault" $true
        }
    }
    else {

        Write-Log $LogPath "Failed Configuring GCP for CloudM Archive Vault" $true
    }
}

Configure-GCP-For-Migrate $ProjectId $ServiceAccountId $OutputPath
