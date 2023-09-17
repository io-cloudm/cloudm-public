$ErrorActionPreference = "Stop"
$MaximumFunctionCount = 8192
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

function ImportCloudMModules ([String]$WorkFolder, [bool]$limitedScope) {
    Set-Location -Path $workFolder
    ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement -requiredVersion 2.4.0
    ImportModules -moduleName Microsoft.Graph.Applications -requiredVersion 2.4.0
    if ($limitedScope) {
        ImportModules -moduleName Microsoft.Graph.Files -requiredVersion 2.4.0
        ImportModules -moduleName Microsoft.Graph.Sites -requiredVersion 2.4.0
        ImportModules -moduleName Microsoft.Graph.Groups -requiredVersion 2.4.0
        ImportModules -moduleName Microsoft.Graph.Teams -requiredVersion 2.4.0
        ImportModules -moduleName ExchangeOnlineManagement -requiredVersion 3.2.0
    }
    $retryPms1 = Join-Path -Path $WorkFolder -ChildPath "CloudM-Retry.psm1" 
    if (!(Test-Path -Path $retryPms1 -PathType Leaf)) {
        throw (New-Object System.IO.FileNotFoundException("File not found: $retryPms1", $retryPms1))
    }
    else {
        Import-Module .\CloudM-Retry -Force
    }
    if ($limitedScope) {
        $processEmailDrive = Join-Path -Path $WorkFolder -ChildPath "CloudM-ProcessCsvs.psm1" 
        if (!(Test-Path -Path $processEmailDrive -PathType Leaf)) {
            throw (New-Object System.IO.FileNotFoundException("File not found: $processEmailDrive", $processEmailDrive))
        }
        else {
            Import-Module .\CloudM-ProcessCsvs -Force
        }
    }
}

function MoveFiles([parameter(mandatory)][String]$sourceFolder, [parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$publisherDomain) {
    $destinationPath = Join-Path -Path $workFolder -ChildPath "$($appName) - $($publisherDomain)"
    $file = Join-Path -Path $workFolder -ChildPath "EmailDrive.csv" 
    if ((Test-Path -Path $file -PathType Leaf)) {
        $newFile = "$($destinationPath)\EmailDrive - $($publisherDomain) - $(Get-Date -UFormat %d-%m-%Y-%H.%M.%S).csv"
        Write-Host "Copying $($file) > $($newFile)"
        Copy-Item "$($file)" -Destination "$($newFile)"
        (Import-CSV $file -Header Email, ItemType | 
        Select-Object "Email", "ItemType" | 
        ConvertTo-Csv -NoTypeInformation | 
        Select-Object -Skip 1) -replace '"' | Set-Content $file
    }
    $file = Join-Path -Path $workFolder -ChildPath "SharePointSites.csv" 
    if ((Test-Path -Path $file -PathType Leaf)) {
        $newFile = "$($destinationPath)\SharePointSites - $($publisherDomain) - $(Get-Date -UFormat %d-%m-%Y-%H.%M.%S).csv"
        Write-Host "Copying $($file) > $($newFile)"
        Copy-Item "$($file)" -Destination "$($newFile)"
        (Import-CSV $file -Header SiteUrl, ItemType | 
        Select-Object "SiteUrl" | 
        ConvertTo-Csv -NoTypeInformation | 
        Select-Object -Skip 1) -replace '"' | Set-Content $file
    }
    $file = Join-Path -Path $workFolder -ChildPath "MicrosoftTeamGroup.csv" 
    if ((Test-Path -Path $file -PathType Leaf)) {
        $newFile = "$($destinationPath)\MicrosoftTeamGroup - $($publisherDomain) - $(Get-Date -UFormat %d-%m-%Y-%H.%M.%S).csv"
        Write-Host "Copying $($file) > $($newFile)"
        Copy-Item "$($file)" -Destination "$($newFile)"
        (Import-CSV $file -Header Email, MicrosoftTeamGroupItemType | 
        Select-Object "Email", "MicrosoftTeamGroupItemType" | 
        ConvertTo-Csv -NoTypeInformation | 
        Select-Object -Skip 1) -replace '"' | Set-Content $file
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

$WorkFolder = "C:\Projects\cloudm-public\Migrate\PowerShell"
$MailGroupAlias = "CloudM-LimitedTestApp"
$TenantId = "test365.cloudm.io"
$ClientAppId = "03cb630a-cb4e-43c2-a38b-b0eadc289ad2"
$AdminAppClientId = "ad583816-4d3f-480d-b5b5-2e203427fe83"
$AdminAppCertificate = "C:\Projects\cloudm-public\Migrate\PowerShell\CloudM Admin App - test365.cloudm.io\CloudM Admin App.pfx"
$ClientAppCertificate = "C:\Projects\cloudm-public\Migrate\PowerShell\CloudM-LimitedTestApp - test365.cloudm.io\CloudM-LimitedTestApp-test365.cloudm.io.pfx"


ImportCloudMModules -WorkFolder $WorkFolder -limitedScope $true


$ProcessMicrosoftTeamGroupCsv = @{
    WorkFolder                = $WorkFolder
    SecureCertificatePassword = GetSecurePassword("")
    MailGroupAlias            = $MailGroupAlias
    AdminAppClientId          = $AdminAppClientId
    TenantId                  = $TenantId
    AdminAppCertificate       = $AdminAppCertificate
    ClientAppId               = $ClientAppId
    ClientAppCertificate      = $ClientAppCertificate
}

ProcessMicrosoftTeamGroupCsv @ProcessMicrosoftTeamGroupCsv -DisconnectSesstion


#Copy Reports
MoveFiles -sourceFolder $WorkFolder -appName $MailGroupAlias -publisherDomain $TenantId