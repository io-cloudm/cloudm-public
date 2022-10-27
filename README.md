
# Archive

PowerShell scripts for configuring Google Workspace and Google Cloud Platform access.

## Pre-requisites for running

1. gcloud sdk installed
2. gcloud sdk initialised → run “gcloud init”, then follow instructions
3. Account in GCP with permissions to create a project (resourcemanager.projects.create role) or owner on existing project
4. Ability to run powershell script as Administrator

## GCP_Storage_Configuration

[GCP_Storage_Configuration](Archive/PowerShell/GCP_Storage_Configuration.ps1) GCS storage bucket configuration

### Running the Script

#### Help

    Get-Help .\GCP_Storage_Configuration.ps1 -full

#### Run

    .\GCP_Storage_Configuration.ps1 project-id-here service-account-id-here region-here bucket-name-here key-name-here optional-path-here

### Output

**ProjectId** must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**ServiceAccountId** must be between 6 and 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**Region** must be one of 'us-central1', 'europe-west1'

**BucketName** must be adhere to the naming conventions outlined at '[https://cloud.google.com/storage/docs/naming-buckets'](https://cloud.google.com/storage/docs/naming-buckets' "https://cloud.google.com/storage/docs/naming-buckets'")

**KeyName (OPTIONAL)** must be between 6 and 30 letters, digits, hyphens or underscores. It must start with a lower case letter, followed by one or more alphanumerical characters that can be separated by hyphens or underscores. It cannot have a trailing hyphen or underscore.

**OutputPath** for Json key and log e.g. C:\\CloudM  
GCPConfig. Defaults to USERHOME  
GCPConfig

The script outputs the following:

-   Service Account Email Address    
-   Path to Service Account Json key    
-   Bucket Url    
-   KMs Key Path


## GCP_Vault_Configuration

[GCP_Vault_Configuration](Archive/PowerShell/GCP_Vault_Configuration.ps1) Google Workspace Vault configuration

### Running the Script

#### Help

    Get-Help .\GCP_Vault_Configuration.ps1 -full

#### Run

    .\GCP_Vault_Configuration.ps1 project-id-here service-account-id-here optional-path-here

### Output

**ProjectId** must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**ServiceAccountId** must be between 6 and 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**OutputPath** for Json key and log e.g. C:\\\\\\\\CloudM  
GCPConfig

The script outputs the following:

-   Links to follow to perform manual config in Admin consoles    
-   ClientID    
-   Scopes to use    
-   ServiceAccount Email    
-   Path to ServiceAccount Json key

---

# Migrate

## Pre-requisites for running

1. gcloud sdk installed
2. gcloud sdk initialised → run “gcloud init”, then follow instructions
3. Account in GCP with permissions to create a project (resourcemanager.projects.create role) or owner on existing project
4. Ability to run powershell script as Administrator

## GCP_Configuration

[GCP_Configuration](Migrate/PowerShell/GCP_Configuration.ps1) Google Workspace configuration

### Running the Script

#### Help

    Get-Help .\GCP_Configuration.ps1 -full

#### Run

    .\GCP_Configuration.ps1 project-id-here service-account-id-here scope-here key-type-here optional-path-here

### Output

**ProjectId** must be a unique string of 6 to 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**ServiceAccountId** must be between 6 and 30 lowercase letters, digits, or hyphens. It must start with a lower case letter, followed by one or more lower case alphanumerical characters that can be separated by hyphens. It cannot have a trailing hyphen

**Scope** must be one of 'Full', 'SourceLimited', 'DestinationLimited', 'Vault' or 'Storage'

**OutputPath** for key and log e.g. C:\CloudM_GCPConfig

The script outputs the following:

 - Links to follow to perform manual config in Admin consoles
 - ClientID       
 - Scopes to use      
 - ServiceAccount Email       
 - Path to ServiceAccount key
