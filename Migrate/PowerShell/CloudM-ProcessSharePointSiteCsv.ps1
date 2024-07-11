$ErrorActionPreference = "Stop"
$MaximumFunctionCount = 8192
function ImportModules([parameter(mandatory)][String]$moduleName, 
    [parameter(mandatory)][String]$requiredVersion) {
    
    # Check if the module is already loaded
    $loadedModule = Get-Module -Name $moduleName -ListAvailable -verbose
    if ($loadedModule) {
        Write-Host "$moduleName module is already loaded." -ForegroundColor Green
    }
    else {
        # Check if the module is installed
        Write-Progress "Importing modules"
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
    }
}

function ImportCloudMModules ([String]$WorkFolder, [bool]$limitedScope) {
    Set-Location -Path $workFolder
    ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement -requiredVersion 2.10.0
    ImportModules -moduleName Microsoft.Graph.Applications -requiredVersion 2.10.0
    if ($limitedScope) {
        ImportModules -moduleName Microsoft.Graph.Files -requiredVersion 2.10.0
        ImportModules -moduleName Microsoft.Graph.Sites -requiredVersion 2.10.0
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

function MoveFiles([parameter(mandatory)][String]$sourceFolder, [parameter(mandatory)][String]$ClientAppId) {
    $destinationPath = Join-Path -Path $workFolder -ChildPath "CloudM-Limited-App-$($ClientAppId)"
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    $file = Join-Path -Path $workFolder -ChildPath "SharePointSites.csv" 
    if ((Test-Path -Path $file -PathType Leaf)) {
        $newFile = "$($destinationPath)\SharePointSites - $($ClientAppId) - $(Get-Date -UFormat %d-%m-%Y-%H.%M.%S).csv"
        Write-Host "Copying $($file) > $($newFile)"
        Copy-Item "$($file)" -Destination "$($newFile)"
        (Import-CSV $file -Header SiteUrl, ItemType | 
        Select-Object "SiteUrl" | 
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

$WorkFolder = ""
$ClientAppId = ""
$Environment = "Global"

ImportCloudMModules -WorkFolder $WorkFolder -limitedScope $true


$ProcessSharePointSiteCsv = @{
    WorkFolder                = $WorkFolder
    ClientAppId               = $ClientAppId
    Environment               = $Environment
}
ProcessSharePointSiteCsv @ProcessSharePointSiteCsv -DisconnectSession

#Copy Reports
MoveFiles -sourceFolder $WorkFolder -ClientAppId $ClientAppId