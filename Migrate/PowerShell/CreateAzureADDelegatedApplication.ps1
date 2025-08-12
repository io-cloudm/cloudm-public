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

function CreateInteractiveConnection($azureEnvironment) {
    Write-Host "Connecting to MgGraph using an Interactive login"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'China' }
        2 { 'USGov' }
        3 { 'USGovDoD' }
    }
    $neededScopes = "offline_access openid profile Application.ReadWrite.All Organization.Read.All Directory.Read.All RoleManagement.Read.Directory AppRoleAssignment.ReadWrite.All";
    Connect-MgGraph -Environment $ae -Scope $neededScopes  -ErrorAction Stop
}

function CreateConnection($token, $azureEnvironment) {
    Write-Progress "Connecting to MgGraph using an Access token"
    $ae = switch ( $azureEnvironment ) {
        0 { 'Global' }
        1 { 'Global' }
        2 { 'China' }
        3 { 'USGov' }
        4 { 'USGovDoD' }
    }
    $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
    Connect-MgGraph -Environment $ae -AccessToken $secureToken -ErrorAction Stop
}

function CreateApplication($appNameProvided, $redirectUris) {
    $appName = "CloudM Migrate Delegated"
    if (-not ([string]::IsNullOrWhiteSpace($appNameProvided))) {
        $appName = $appNameProvided
    }
    $appHomePageUrl = "https://cloudm.io/"
    $requiredResourceAccess = GenerateDelegatedApplicationApiPermissions
    $alwaysOnUI = New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication
    $alwaysOnUI.DisplayName = $appName
    $alwaysOnUI.Web.ImplicitGrantSettings.EnableIdTokenIssuance = $true
    $alwaysOnUI.Web.RedirectUris = @('{0}/api/OfficeExport/callback' -f $redirectUris), ('{0}/api/connectionsOfficeDelegatedAd/callback' -f $redirectUris), ('{0}/api/OfficeImport/callback' -f $redirectUris)
    $alwaysOnUI.Web.HomePageUrl = $appHomePageUrl
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    $alwaysOnUI.SignInAudience = "AzureADMyOrg"
    $alwaysOnUI.Info.PrivacyStatementUrl = "https://www.cloudm.io/legal/privacy-policy"
    $alwaysOnUI.Info.TermsOfServiceUrl = "https://www.cloudm.io/legal/terms-conditions"
    $alwaysOnUI.RequiredResourceAccess = $requiredResourceAccess
    # Check if app has already been installed
    Write-Progress "Checking if app already exists"
    if ($app = Get-MgApplication -Filter "DisplayName eq '$($appName)'" -ErrorAction SilentlyContinue) {
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
    $requiredResourceAccess = @{
        ResourceAppId  = "00000003-0000-0000-c000-000000000000";
        ResourceAccess = @(
            @{
                #Chat.ReadWrite
                Id   = "9ff7295e-131b-4d94-90e1-69fde507ac11";
                Type = "Scope"
            },
            @{
                #ChannelMessage.Send
                Id   = "ebf0f66e-9fb1-49e4-a278-222f76911cf4";
                Type = "Scope"
            },
            @{
                #User.Read
                Id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d";
                Type = "Scope"
            },
            @{
                #offline 
                Id   = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182";
                Type = "Scope"
            }
        )
    }
    return $requiredResourceAccess;
}

function GenerateResourceAccess($resourceId, $resourceType) {
    $resourceAccess = New-Object Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess
    $resourceAccess.Type = $resourceType
    $resourceAccess.Id = $resourceId 
    return $resourceAccess
}


function CreateAppDelegatedRegistration([parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$redirectUris, [parameter(mandatory)][String]$azureEnvironment, $token) {
    Write-Progress ("Running as " + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $internal = $token;
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
        ImportModules -moduleName Microsoft.Graph.Identity.DirectoryManagement -requiredVersion 2.10.0
        ImportModules -moduleName Microsoft.Graph.Applications -requiredVersion 2.10.0
        Write-Host "Modules imported" -ForegroundColor DarkGreen

        if (!$internal) {
            CreateInteractiveConnection -azureEnvironment $azureEnvironment
        }
        else {
            CreateConnection -token $token -azureEnvironment $azureEnvironment
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
     

        if ($app.passwordcredentials.count -eq 0) {
            $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
            write-host "Application password created" -foregroundcolor darkgreen
        }
        else
        { #Client Secret already exists. We need to delete it and generate a new one.
            foreach ($key in $app.PasswordCredentials) {
                Remove-MgApplicationPassword -ApplicationId $appId -KeyId $key.KeyId
                Write-Host "Application password removed successfully" -ForegroundColor DarkGreen
            }
            $appsecret = Add-MgApplicationPassword -applicationId $appId -PasswordCredential $passwordCred
            write-host "Application password created: " $appsecret -foregroundcolor darkgreen
        }
        
        if ($internal) {
            return $appClientId + "|" + $appsecret.SecretText
        }
        # Display user friendly output
        $nl = [Environment]::NewLine
        $output = ($nl + $nl + "Delegated Permissions Client ID: " + $appClientId)
        $output += ($nl + "Delegated Permissions Client Secret: " + $appsecret.SecretText)
       
        $output = $nl + $nl + "Azure AD Delegated application successfully registered." + $output
        Write-Host $output -ForegroundColor Green
    }
    catch {
        Write-Host "The message was: $($_)" -ForegroundColor Red
        throw
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-MgGraph"
    }
}


function CreateAzureAppRegistration() {
    $requireProxy = Read-Host "$($nl)Do you need to connect to Microsoft Graph via a proxy? (yes/no)"
    if($requireProxy -eq "yes") {
        if (Connect-MgWithProxy) {
            Write-Host "Proxy connection successful." -ForegroundColor Green
        } else {
            Write-Host "Proxy connection failed. Exiting script." -ForegroundColor Red
            return
        }
    }
    $appName = Read-Host 'Enter the application Name'
    $redirectUris = Read-Host "Enter the redirect URI`nIf using CloudM Migrate Hosted, enter the URL of https://migrate.cloudm.io`nIf using CloudM Migrate Self Hosted, enter the URL of your CloudM Migrate Self Hosted instance eg https://cloudm.local"
    $azureEnvironment = Read-Host "Enter the number that corresponds to your Cloud Deployment`n`n0 Global`n1 China`n2 US Gov `n3 US GovDoD"
    Read-Host "$($nl)$($nl)You are using the interactive mode. You will be prompted by a window to connect to Graph via your Global Admin Credentails. Please enter to continue"
    CreateAppDelegatedRegistration -appName $appName -redirectUris $redirectUris -azureEnvironment $azureEnvironment
}

function Connect-MgWithProxy {
    [CmdletBinding()]
    param ()

    Write-Host "`n=== Microsoft Graph Proxy Connector ===`n" -ForegroundColor Cyan
       
    $proxyServer = Read-Host "Enter Proxy Server (e.g., http://your.proxy.server)"
    $proxyPort = Read-Host "Enter Proxy Port (e.g., 8080)"
    $useAuth = Read-Host "Does your proxy require authentication? (yes/no)"

    $proxyUri = "${proxyServer}:${proxyPort}"
    $proxy = New-Object System.Net.WebProxy($proxyUri, $true)

    if ($useAuth -eq "yes") {
        $proxyUser = Read-Host "Enter Proxy Username"
        $proxyPass = Read-Host "Enter Proxy Password" -AsSecureString
        $proxy.Credentials = New-Object System.Net.NetworkCredential($proxyUser, $proxyPass)
    }

    [System.Net.WebRequest]::DefaultWebProxy = $proxy
    $env:http_proxy = $proxyUri
    $env:https_proxy = $proxyUri

    Write-Host "`nTesting proxy connection to Microsoft Graph..." -ForegroundColor Cyan

    try {
        $testResponse = Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/$metadata" -Proxy $proxyUri -UseBasicParsing -TimeoutSec 10
        if ($testResponse.StatusCode -eq 200) {
            Write-Host "Proxy test successful. Microsoft Graph is reachable." -ForegroundColor Green
            return $true
        } else {
            Write-Host "Unexpected response code: $($testResponse.StatusCode)" -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "Proxy test failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

CreateAzureAppRegistration

# SIG # Begin signature block
# MIMBBcQGCSqGSIb3DQEHAqCDAQW0MIMBBa8CAQExDTALBglghkgBZQMEAgEweQYK
# KwYBBAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTS
# xil+81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQg4+kYL6VkSxow
# kPpdzr9JgY2aYt4BtHpYZdAFEK7pSBSggidoMIIFjTCCBHWgAwIBAgIQDpsYjvnQ
# Lefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYD
# VQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAw
# WhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNl
# cnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdp
# Q2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QN
# xDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DC
# srp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTr
# BcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17l
# Necxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WC
# QTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1
# EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KS
# Op493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAs
# QWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUO
# UlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtv
# sauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCC
# ATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4c
# D08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQD
# AgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaG
# NGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9D
# XFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6
# Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuW
# cqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLih
# Vo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBj
# xZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02f
# c7cBqZ9Xql4o4rmUMIIFojCCBIqgAwIBAgIQeAMYQkVwikHPbwG47rSpVDANBgkq
# hkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzET
# MBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjAeFw0yMDA3
# MjgwMDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2ln
# bmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALYt
# xTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uYRYq4Y1ddmwCIBCXp
# +GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiCkV37WYgFC5cGwpj4
# LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0oYCve+YzCgxZa468
# 9Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o3GwmPukf5eAEh60w
# 0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHfHgIB2DvhZ0OEts/8
# dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2dK4gQ/vpY6KdX4bPP
# qFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+YnuYE7kJuZ35CFnFi
# 5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35Gb03FhRIrz5oiRAio
# hTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUaqhxrFnf3p5fsPxkw
# mW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2
# z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4OJGTfAgMBAAGjggF3MIIBczAOBgNV
# HQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYDVR0TAQH/BAUwAwEB
# /zAdBgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYDVR0jBBgwFoAUj/BL
# f6guRSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0GCCsGAQUFBzABhiFo
# dHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYIKwYBBQUHMAKGL2h0
# dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jvb3QtcjMuY3J0MDYG
# A1UdHwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vcm9vdC1y
# My5jcmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8v
# d3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4IB
# AQCs98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFywvRNdHSOuOVB2N6pE
# /V8BI1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbsn4cxB2X1OadRgnXh
# 8i+X9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LWd7uptDRKqW899PMN
# lV3m+XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMOtH2gCm2SxLRmP32n
# WO6s9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBgSA14q88XrZKTYiB3
# dWy9yDK03E3r2d/BkJYpvcF/MIIGrjCCBJagAwIBAgIQBzY3tyRUfNhHrP0oZipe
# WzANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNl
# cnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdp
# Q2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjIwMzIzMDAwMDAwWhcNMzcwMzIyMjM1
# OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5
# BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0
# YW1waW5nIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxoY1Bkmz
# wT1ySVFVxyUDxPKRN6mXUaHW0oPRnkyibaCwzIP5WvYRoUQVQl+kiPNo+n3znIkL
# f50fng8zH1ATCyZzlm34V6gCff1DtITaEfFzsbPuK4CEiiIY3+vaPcQXf6sZKz5C
# 3GeO6lE98NZW1OcoLevTsbV15x8GZY2UKdPZ7Gnf2ZCHRgB720RBidx8ald68Dd5
# n12sy+iEZLRS8nZH92GDGd1ftFQLIWhuNyG7QKxfst5Kfc71ORJn7w6lY2zkpsUd
# zTYNXNXmG6jBZHRAp8ByxbpOH7G1WE15/tePc5OsLDnipUjW8LAxE6lXKZYnLvWH
# po9OdhVVJnCYJn+gGkcgQ+NDY4B7dW4nJZCYOjgRs/b2nuY7W+yB3iIU2YIqx5K/
# oN7jPqJz+ucfWmyU8lKVEStYdEAoq3NDzt9KoRxrOMUp88qqlnNCaJ+2RrOdOqPV
# A+C/8KI8ykLcGEh/FDTP0kyr75s9/g64ZCr6dSgkQe1CvwWcZklSUPRR8zZJTYsg
# 0ixXNXkrqPNFYLwjjVj33GHek/45wPmyMKVM1+mYSlg+0wOI/rOP015LdhJRk8mM
# DDtbiiKowSYI+RQQEgN9XyO7ZONj4KbhPvbCdLI/Hgl27KtdRnXiYKNYCQEoAA6E
# VO7O6V3IXjASvUaetdN2udIOa5kM0jO0zbECAwEAAaOCAV0wggFZMBIGA1UdEwEB
# /wQIMAYBAf8CAQAwHQYDVR0OBBYEFLoW2W1NhS9zKXaaL3WMaiCPnshvMB8GA1Ud
# IwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNV
# HSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0
# dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2Vy
# dHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0f
# BDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1
# c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcB
# MA0GCSqGSIb3DQEBCwUAA4ICAQB9WY7Ak7ZvmKlEIgF+ZtbYIULhsBguEE0TzzBT
# zr8Y+8dQXeJLKftwig2qKWn8acHPHQfpPmDI2AvlXFvXbYf6hCAlNDFnzbYSlm/E
# UExiHQwIgqgWvalWzxVzjQEiJc6VaT9Hd/tydBTX/6tPiix6q4XNQ1/tYLaqT5Fm
# niye4Iqs5f2MvGQmh2ySvZ180HAKfO+ovHVPulr3qRCyXen/KFSJ8NWKcXZl2szw
# cqMj+sAngkSumScbqyQeJsG33irr9p6xeZmBo1aGqwpFyd/EjaDnmPv7pp1yr8TH
# wcFqcdnGE4AJxLafzYeHJLtPo0m5d2aR8XKc6UsCUqc3fpNTrDsdCEkPlM05et3/
# JWOZJyw9P2un8WbDQc1PtkCbISFA0LcTJM3cHXg65J6t5TRxktcma+Q4c6umAU+9
# Pzt4rUyt+8SVe+0KXzM5h0F4ejjpnOHdI/0dKNPH+ejxmF/7K9h+8kaddSweJywm
# 228Vex4Ziza4k9Tm8heZWcpw8De/mADfIBZPJ/tgZxahZrrdVcA6KYawmKAr7ZVB
# tzrVFZgxtGIJDwq9gdkT/r+k0fNX2bwE+oLeMt8EifAAzV3C+dAjfwAL5HYCJtnw
# ZXZCpimHCUcr5n8apIUP/JiW9lVUKx+A+sDyDivl1vupL0QVSucTDh3bNzgaoSv2
# 7dZ8/DCCBrwwggSkoAMCAQICEAuuZrxaun+Vh8b56QTjMwQwDQYJKoZIhvcNAQEL
# BQAwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFt
# cGluZyBDQTAeFw0yNDA5MjYwMDAwMDBaFw0zNTExMjUyMzU5NTlaMEIxCzAJBgNV
# BAYTAlVTMREwDwYDVQQKEwhEaWdpQ2VydDEgMB4GA1UEAxMXRGlnaUNlcnQgVGlt
# ZXN0YW1wIDIwMjQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC+anOf
# 9pUhq5Ywultt5lmjtej9kR8YxIg7apnjpcH9CjAgQxK+CMR0Rne/i+utMeV5bUlY
# YSuuM4vQngvQepVHVzNLO9RDnEXvPghCaft0djvKKO+hDu6ObS7rJcXa/UKvNmin
# KQPTv/1+kBPgHGlP28mgmoCw/xi6FG9+Un1h4eN6zh926SxMe6We2r1Z6VFZj75M
# U/HNmtsgtFjKfITLutLWUdAoWle+jYZ49+wxGE1/UXjWfISDmHuI5e/6+NfQrxGF
# SKx+rDdNMsePW6FLrphfYtk/FLihp/feun0eV+pIF496OVh4R1TvjQYpAztJpVIf
# dNsEvxHofBf1BWkadc+Up0Th8EifkEEWdX4rA/FE1Q0rqViTbLVZIqi6viEk3RIy
# Sho1XyHLIAOJfXG5PEppc3XYeBH7xa6VTZ3rOHNeiYnY+V4j1XbJ+Z9dI8ZhqcaD
# HOoj5KGg4YuiYx3eYm33aebsyF6eD9MF5IDbPgjvwmnAalNEeJPvIeoGJXaeBQjI
# K13SlnzODdLtuThALhGtyconcVuPI8AaiCaiJnfdzUcb3dWnqUnjXkRFwLtsVAxF
# vGqsxUA2Jq/WTjbnNjIUzIs3ITVC6VBKAOlb2u29Vwgfta8b2ypi6n2PzP0nVeps
# Fk8nlcuWfyZLzBaZ0MucEdeBiXL+nUOGhCjl+QIDAQABo4IBizCCAYcwDgYDVR0P
# AQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgw
# IAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW
# 2W1NhS9zKXaaL3WMaiCPnshvMB0GA1UdDgQWBBSfVywDdw4oFZBmpWNe7k+SH3ag
# WzBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQ
# BggrBgEFBQcBAQSBgzCBgDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tMFgGCCsGAQUFBzAChkxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0
# MA0GCSqGSIb3DQEBCwUAA4ICAQA9rR4fdplb4ziEEkfZQ5H2EdubTggd0ShPz9Pc
# e4FLJl6reNKLkZd5Y/vEIqFWKt4oKcKz7wZmXa5VgW9B76k9NJxUl4JlKwyjUkKh
# k3aYx7D8vi2mpU1tKlY71AYXB8wTLrQeh83pXnWwwsxc1Mt+FWqz57yFq6laICtK
# jPICYYf/qgxACHTvypGHrC8k1TqCeHk6u4I/VBQC9VK7iSpU5wlWjNlHlFFv/M93
# 748YTeoXU/fFa9hWJQkuzG2+B7+bMDvmgF8VlJt1qQcl7YFUMYgZU1WM6nyw23vT
# 6QSgwX5Pq2m0xQ2V6FJHu8z4LXe/371k5QrN9FQBhLLISZi2yemW0P8ZZfx4zvSW
# zVXpAb9k4Hpvpi6bUe8iK6WonUSV6yPlMwerwJZP/Gtbu3CKldMnn+LmmRTkTXpF
# IEB06nXZrDwhCGED+8RsWQSIXZpuG4WLFQOhtloDRWGoCwwc6ZpPddOFkM2LlTbM
# cqFSzm4cd0boGhBq7vkqI1uHRz6Fq1IX7TaRQuR+0BGOzISkcqwXu7nMpFu3mgrl
# gbAW+BzikRVQ3K2YHcGkiKjA4gi4OA/kz1YCsdhIBHXqBzR0/Zd2QwQ/l4Gxftt/
# 8wY3grcc/nS//TVkej9nmUYu83BDtccHHXKibMs/yXHhDXNkoPIdynhVAku7aRZO
# wqw6pDCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQEL
# BQAwUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAn
# BgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcy
# ODAwMDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBF
# ViBDb2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3
# zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuU
# Dm0PpZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC
# 2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSA
# n9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5Ccxrjs
# zMl7ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsu
# z9riiTSmHyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjW
# O1roIs50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJz
# qwSwCdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2
# jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/
# thHxvvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0w
# ggGpMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMB
# Af8ECDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNV
# HSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMw
# OQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWdu
# aW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWdu
# LmNvbS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDag
# NKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0
# NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0
# cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJ
# KoZIhvcNAQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYX
# amsCT7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxN
# tT4GS8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3x
# K3LBFuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I
# +9MqkjPqV01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZ
# K3dt28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OIt
# ziphz1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+
# PGEPigu69T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeA
# xkw2V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7Q
# tDS91vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXX
# CSXUyQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1
# MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylH
# bG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0
# MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBP
# cmdhbml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMT
# AkdCMQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMw
# EQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAw
# HgYDVQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRN
# IFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5
# QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JG
# Nh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL
# 1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YE
# SmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3j
# kVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq
# 78/GYTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnI
# Mu5ErFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+
# AYx4Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMko
# kTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb
# 71/mugorh00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0
# KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpT
# lMMrn09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8B
# Af8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8v
# c2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25j
# YTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNv
# bS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAy
# AQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZo
# dHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAy
# MC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYR
# MB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOC
# AgEAyuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7h
# Z6hqCpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljY
# crDOetNnnpbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnV
# LzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIql
# u6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuB
# p4k106x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxD
# WbPuOgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv
# 2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZ
# uM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOq
# QbmKvshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh
# 01N373BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxgt2yMILdrgIBATBs
# MFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYD
# VQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIM
# SvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICVh2Wby5+CwJbwg0hXPdeXS6mbjriDQ
# rE0WO1xYGZNjMA0GCSqGSIb3DQEBAQUABIICAEPkJZCwrYt/3SSaYBnS7HkIN85S
# TZT/yszDAGHn29lkV5btKeAsGTNHjEXaBuexIsyamsdjCPiOzNSv1hGzogPaqL5S
# ULMPkggr8gU9RzplQtcMMlgTW1kGK+c/H+o4E6MJH+32o+TLQqf0t854uEu6V5Kw
# 0cba0Gu02voWuNb6q2efJ6McEGtODkp95vxuGSdqyR+9gOn35Zh4qQrfSLxc45u/
# uEbbHvEPniErDPQf+XXJrEF3iKn1hdPFU4mgdjOOsEC5EYBZnR2apxbtmV2Yul22
# EfUehPfzbTcik5OrhiKli5lBC+OHreiAQHbIlc6SFH1SAb4jGE4wJBMDPgqu0qiC
# TBVK5uag+aISzdH9uRdhNYM+hZzrQ5tnYwYD4nGkS5IBhd+iRa8xsPbPzJdSWFCf
# VDH29zwcBbRYf0gTkfIVSDK0/GDMKfVXua9LFe6jg3JQXhbzb5E9AgXhz9ADRuDa
# UqA4+4DgLeMgWXScAY0BS7+9XzwjqUWSRZjbxoBHYfsH7ydQUSsoUAlg9cG5XrYR
# BO+LctxzQfdMREy5uhnuQrhwuycZ6c8DzXSCbM1p9f/ViS9V6bURHHvGQ7qui2ZP
# oZgOdIQ3+BY3DLAgsmN4pIY/Q6T8/yzbdZOaqdHtilfIxhQsjR/7Zx08wG1jDg0S
# ECai3knQXUZXOV+BoYLamTCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEBMHcwYzEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJE
# aWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBD
# QQIQC65mvFq6f5WHxvnpBOMzBDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJ
# AzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MTAwNDEzMDg1OVowLwYJ
# KoZIhvcNAQkEMSIEIFIl8oJ0DMN/K4Dzp1DLH8wwaDTAyYu5iTA26akcIDagMA0G
# CSqGSIb3DQEBAQUABIICAIDaGRal2XQYOWfzm4lnZcDz5Te9wQpSnHPCal8BZcSU
# OtT6uW37euBeDvY6fnfDqvSXe6YauZvX55vv4OsmmzZeAuFXCVmfUdaatA7fLMoa
# SmAqSijdHOSat/AvDdvs5hdas8BFhDc0YUfGy0j+KdV4L7kkcKl0di0Dvp8TtWz5
# DaD7SOR60sXguGHfUwdcL+4qavs/TlMID7dLy5Q1Es0GfxzbWng9bdXmRIt73bsh
# QxOdgKviRlOFKpo8vA0ljcPYqBxVrSUsMmcNGDUK+hV0CurvmqnQJQwFXIXjnfcA
# lPmKczZ+72DFsJ+9S6B5Eb1q8J0EJs38gqRGJDJpPwECPnTVw5FrTJMpJ19vZQUk
# aFyMx8PlVTQvyQla2Tzu5B6LFqv0NbHCPn6z5CiLazan9G1E7TAaDw9vW+hv3QiU
# 9htiNlOTqT5HS3gyZb7b5yZZ2ybyHY6CLCudBPUdcysZ6kH4BQBJTHscVjsdaHzw
# tkJPenzJZD23bPTTP3W9zCmoktVDFhofIQGJqMVY5iZStapRMFUXoyD8qBUVxX8H
# oDYIjZffeU/M2Fr9XTWED3ZF98Tkj5q1fYsMi1qjyasXlA8rOgvo4BsCg2PMzF3M
# w+gNH5oYKbonaH9hBC/ajZptJbwjcTd6IL9PGHW6Qp2sFS+5OF91QVR11f1CCZ8X
# MILXdQYKKwYBBAGCNwIEATGC12UwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEP
# MA0GCWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4w
# JgIDAQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZI
# AWUDBAIBBQAEIBbq6SusIBLk1T/QAbmR2QMawTysKiIEHe8ivwbbGod0oIIUZTCC
# BaIwggSKoAMCAQICEHgDGEJFcIpBz28BuO60qVQwDQYJKoZIhvcNAQEMBQAwTDEg
# MB4GA1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjMxEzARBgNVBAoTCkdsb2Jh
# bFNpZ24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMjAwNzI4MDAwMDAwWhcNMjkw
# MzE4MDAwMDAwWjBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBu
# di1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC2LcUw3Xroq5A9A3KwOkuZ
# FmGy5f+lZx03HOV+7JODqoT1o0ObmEWKuGNXXZsAiAQl6fhokkuC2EvJSgPzqH9q
# j4phJ72hRND99T8iwqNPkY2zBbIogpFd+1mIBQuXBsKY+CynMyTuUDpBzPCgsHsd
# TdKoWDiW6d/5G5G7ixAs0sdDHaIJdKGAr3vmMwoMWWuOvPSrWpd7f65V+4TwgP6E
# TNfiur3EdaFvvWEQdESymAfidKv/aNxsJj7pH+XgBIetMNMMjQN8VbgWcFwkeCAl
# 62dniKu6TjSYa3AR3jjK1L6hwJzh3x4CAdg74WdDhLbP/HS3L4Sjv7oJNz1nbLFF
# XBlhq0GD9awd63cNRkdzzr+9lZXtnSuIEP76WOinV+Gzz6ha6QclmxLEnoByPZPc
# jJTfO0TmJoD80sMD8IwM0kXWLuePmJ7mBO5Cbmd+QhZxYucE+WDGZKG2nIEhTivG
# bWiUhsaZdHNnMXqR8tSMeW58prt+Rm9NxYUSK8+aIkQIqIU3zgdhVwYXEiTAxDFz
# oZg1V0d+EDpF2S2kUZCYqaAHN8RlGqocaxZ396eX7D8ZMJlvMfvqQLLn0sT6ydDw
# UHZ0WfqNbRcyvvjpfgP054d1mtRKkSyFAxMCK0KA8olqNs/ITKDOnvjLja0Wp9Pe
# 1ZsYp8aSOvGCY/EuDiRk3wIDAQABo4IBdzCCAXMwDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFB8A
# v0aACvx4ObeltEPZVlC7zpY7MB8GA1UdIwQYMBaAFI/wS3+oLkUkrk1Q+mOai97i
# 3Ru8MHoGCCsGAQUFBwEBBG4wbDAtBggrBgEFBQcwAYYhaHR0cDovL29jc3AuZ2xv
# YmFsc2lnbi5jb20vcm9vdHIzMDsGCCsGAQUFBzAChi9odHRwOi8vc2VjdXJlLmds
# b2JhbHNpZ24uY29tL2NhY2VydC9yb290LXIzLmNydDA2BgNVHR8ELzAtMCugKaAn
# hiVodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jvb3QtcjMuY3JsMEcGA1UdIARA
# MD4wPAYEVR0gADA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWdu
# LmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwFAAOCAQEArPfMFYsweagdCyiI
# GQnXHH/+hr17WjNuDWcOe2LZ4RhcsL0TXR0jrjlQdjeqRP1fASNZhlZMzK28ZBMU
# MKQgqOA/6Jxy3H7z2Awjuqgtqjz27J+HMQdl9TmnUYJ14fIvl/bR4WWWg2T+oR1R
# +7Ukm/XSd2m8hSxc+lh30a6nsQvi1ne7qbQ0SqlvPfTzDZVd5vl6RbAlFzEu2/cP
# aOaDH6n35dSdmIzTYUsvwyh+et6TDrR9oAptksS0Zj99p1jurPfswwgBqzj8Chyp
# xZeyiMgJAhn2XJoa8U1sMNSzBqsAYEgNeKvPF62Sk2Igd3VsvcgytNxN69nfwZCW
# Kb3BfzCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQEL
# BQAwUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAn
# BgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcy
# ODAwMDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBF
# ViBDb2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3
# zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuU
# Dm0PpZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC
# 2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSA
# n9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5Ccxrjs
# zMl7ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsu
# z9riiTSmHyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjW
# O1roIs50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJz
# qwSwCdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2
# jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/
# thHxvvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0w
# ggGpMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMB
# Af8ECDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNV
# HSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMw
# OQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWdu
# aW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWdu
# LmNvbS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDag
# NKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0
# NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0
# cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJ
# KoZIhvcNAQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYX
# amsCT7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxN
# tT4GS8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3x
# K3LBFuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I
# +9MqkjPqV01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZ
# K3dt28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OIt
# ziphz1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+
# PGEPigu69T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeA
# xkw2V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7Q
# tDS91vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXX
# CSXUyQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1
# MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylH
# bG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0
# MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBP
# cmdhbml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMT
# AkdCMQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMw
# EQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAw
# HgYDVQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRN
# IFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5
# QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JG
# Nh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL
# 1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YE
# SmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3j
# kVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq
# 78/GYTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnI
# Mu5ErFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+
# AYx4Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMko
# kTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb
# 71/mugorh00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0
# KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpT
# lMMrn09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8B
# Af8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8v
# c2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25j
# YTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNv
# bS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAy
# AQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZo
# dHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAy
# MC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYR
# MB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOC
# AgEAyuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7h
# Z6hqCpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljY
# crDOetNnnpbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnV
# LzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIql
# u6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuB
# p4k106x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxD
# WbPuOgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv
# 2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZ
# uM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOq
# QbmKvshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh
# 01N373BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxggMVMIIDEQIBATBs
# MFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYD
# VQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIM
# SvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIC0GzN676Q+O3ZVionUC5WQDwp4o7Y0R
# 2cOp/Idx/JscMA0GCSqGSIb3DQEBAQUABIICAG1IA3eCk1aUzaJCoBrxoJyNjfW6
# fp/mVIHG4jtvZGN2VXolkeSc5I755OEPWVyPqtrVR+TKG9WYaECFYjOEGhIdCMPS
# JOjtCS9wrDwxvOARIl1RrmUyPMxb96gJ0vTyAs5NNan9MgyxRVdwMoifR0LJG00a
# fUiQAI8I4KpPKQfFdtdHfJXp9VqhZIVE722sK2x9S/B0aB0K12DEm67PqWKNlG3I
# 7WJkr2IODHzCvvEnxCiqTbF2yYf05f02nl2aCNrrrjJErbGmkEGKyJZO3HSEHblZ
# hJDcqXE84WvbSTp4h/SSf6hBBMnf3jptVuxVEZ4KyQl5iQep7iBi9NOUXcgzpvuT
# qUi6cP17NWyJ0CrGdJejuEl5XGQ3vb+yud4zHA/x/ML0u7NO7OJ/7800HX2mUAv0
# wvoVrcuYmkb3eOG6tI/mVfrNYNfwkPkg1Qrhrzt30A9j3SV7zBPXas7rKxBJDdsQ
# JrzA63tQ/ZwuppvN5Tu2j5LlijheOZgwFrpDj5QTb3i/v0vLs32DO3xXMJpcTeQH
# 9KcixIl/t9Eof9YPbOFW1QZ2xKUFa2G+Ab7BZVFhDoXUunmZWjk3Ev4pJpgpiPqI
# LiSFL8NZ+Yc1jDMqA1lg5A31wzjuq3KClJhcr/DBbKaEpUZSszOH4jy4AJeY8bG+
# Q+CAwdOmV1wD4bXTMIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgB
# ZQMEAgEFADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQ
# H8w7YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUA
# BCAW6ukrrCAS5NU/0AG5kdkDGsE8rCoiBB3vIr8G2xqHdKCCFGUwggWiMIIEiqAD
# AgECAhB4AxhCRXCKQc9vAbjutKlUMA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsT
# F0dsb2JhbFNpZ24gUm9vdCBDQSAtIFIzMRMwEQYDVQQKEwpHbG9iYWxTaWduMRMw
# EQYDVQQDEwpHbG9iYWxTaWduMB4XDTIwMDcyODAwMDAwMFoXDTI5MDMxODAwMDAw
# MFowUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAn
# BgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAti3FMN166KuQPQNysDpLmRZhsuX/pWcd
# NxzlfuyTg6qE9aNDm5hFirhjV12bAIgEJen4aJJLgthLyUoD86h/ao+KYSe9oUTQ
# /fU/IsKjT5GNswWyKIKRXftZiAULlwbCmPgspzMk7lA6QczwoLB7HU3SqFg4lunf
# +RuRu4sQLNLHQx2iCXShgK975jMKDFlrjrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWh
# b71hEHREspgH4nSr/2jcbCY+6R/l4ASHrTDTDI0DfFW4FnBcJHggJetnZ4iruk40
# mGtwEd44ytS+ocCc4d8eAgHYO+FnQ4S2z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/Ws
# Het3DUZHc86/vZWV7Z0riBD++ljop1fhs8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA
# /NLDA/CMDNJF1i7nj5ie5gTuQm5nfkIWcWLnBPlgxmShtpyBIU4rxm1olIbGmXRz
# ZzF6kfLUjHlufKa7fkZvTcWFEivPmiJECKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6
# RdktpFGQmKmgBzfEZRqqHGsWd/enl+w/GTCZbzH76kCy59LE+snQ8FB2dFn6jW0X
# Mr746X4D9OeHdZrUSpEshQMTAitCgPKJajbPyEygzp74y42tFqfT3tWbGKfGkjrx
# gmPxLg4kZN8CAwEAAaOCAXcwggFzMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3
# pbRD2VZQu86WOzAfBgNVHSMEGDAWgBSP8Et/qC5FJK5NUPpjmove4t0bvDB6Bggr
# BgEFBQcBAQRuMGwwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24u
# Y29tL3Jvb3RyMzA7BggrBgEFBQcwAoYvaHR0cDovL3NlY3VyZS5nbG9iYWxzaWdu
# LmNvbS9jYWNlcnQvcm9vdC1yMy5jcnQwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDov
# L2NybC5nbG9iYWxzaWduLmNvbS9yb290LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUd
# IAAwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wDQYJKoZIhvcNAQEMBQADggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9
# e1ozbg1nDnti2eEYXLC9E10dI645UHY3qkT9XwEjWYZWTMytvGQTFDCkIKjgP+ic
# ctx+89gMI7qoLao89uyfhzEHZfU5p1GCdeHyL5f20eFlloNk/qEdUfu1JJv10ndp
# vIUsXPpYd9Gup7EL4tZ3u6m0NEqpbz308w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XU
# nZiM02FLL8Mofnrekw60faAKbZLEtGY/fadY7qz37MMIAas4/AocqcWXsojICQIZ
# 9lyaGvFNbDDUswarAGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggbo
# MIIE0KADAgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBH
# bG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBa
# Fw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxT
# aWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNp
# Z25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMsg
# 75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6
# tbqT76+T3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqz
# g09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gfSaNf+BOeNbgDAtqkEy+FSu/E
# L3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r
# 94n233Hw0b6nskEzIHXMsdXtHQcZxOsmd/KrbReTSam35sOQnMa47MzJe5pexcUk
# k2NvfhCLYc+YVaMkoog28vmfvpMusgafJsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8m
# oKiueG3soYgVPMLq7rfYrWGlr3A2onmO3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6v
# LPEV2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTlzbSYszcZJBJyc6sEsAnchebU
# IgTvQCodLm3HadNutwFsDeCXpxbmJouI9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEO
# j7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJi8Kr77o6/elev7YR8b7wPcoy
# Pm593g9+m5XEEofnGrhO7izB36Fl6CSDySrC/blTAgMBAAGjggGtMIIBqTAOBgNV
# HQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB
# /wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHwYDVR0jBBgwFoAU
# HwC/RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUF
# BzABhi1odHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3Ry
# NDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2Fj
# ZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0
# cDovL2NybC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUG
# A1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3
# Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEB
# CwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8DQdomxyd73G2F2prAk+zP4ZF
# h8xlm0zjWAYCImbVYQLFY4/UovG2XiULd5bpzXFAM4gp7O7zom28TbU+BkvJczPK
# CBQtPUzosLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQlQq+WVvQQ+iR98StywRbha+vm
# qZjHPlr00Bid/XSXhndGKj0jfShziq7vKxuav2xTpxSePIdxwF6OyPvTKpIz6ldN
# XgdeysEYrIEtGiH6bs+XYXvfcXo6ymP31TBENzL+u0OF3Lr8psozGSt3bdvLBfB+
# X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgSK8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUK
# QOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/
# pteO9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZPOOhRQAyuku++PX33gMZMNleElaeE
# FUgwDlInCI2Oor0ixxnJpsoOqHo222q6YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQ
# lzFSOTUpEYck08T7qWPLd0jV+mL8JOAEek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4
# x/N36MXU4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/kMw4h3mKJSAfa9TCCB88wggW3
# oAMCAQICDErzema3QWMQLxMLNTANBgkqhkiG9w0BAQsFADBcMQswCQYDVQQGEwJC
# RTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2ln
# biBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwHhcNMjQwNDAzMTU0MTE2
# WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8MFFByaXZhdGUgT3JnYW5pemF0
# aW9uMREwDwYDVQQFEwgxMzMzNzM0MzETMBEGCysGAQQBgjc8AgEDEwJHQjELMAkG
# A1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjETMBEGA1UEBxMK
# TWFuY2hlc3RlcjEZMBcGA1UECRMQMTcgTWFyYmxlIFN0cmVldDEgMB4GA1UEChMX
# Q2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNVBAMTF0Nsb3VkTSBTb2Z0d2Fy
# ZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0Lm1ja2luc3RyeUBjbG91ZG0u
# aW8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCeChOiRjYdi7nE+/2z
# kusEYtLvYDDAgSTiG5qyauIreUULuW52PgP6b6SEcwMZf90BaYsMi9bcuI1yZ9C0
# lhbbyCtRcKj3llc/qdHwn9wjaI60cenb8e981VXrSHOFlTRnLFv2BEpiqtH0as26
# jTyt8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZvRqlBx4uJhU945FQ2wiB8SW9
# wIeGYDmMHxKX/YXklSm88LnxNznd1BRanPl0VbkJq/UF0FfzN913qu/PxmE5gpak
# +QQr3JPYtCPQTZPHMAN6waMngJnw9TwlNUGEhxvt371Y2FxovdUZyDLuRKxUq7cK
# exhb2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd/62xP77AodWSvgGMeGM5P5fB
# Qi3Be39abAou4fS3qWAEcaWy1qn7p0FxALrplQIyLw6Jnz7d0zzJKJE7hQcEfbqV
# JZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz1wcq+Fy6l+4Km+9f5roKK4dN
# FETf5srRH5bVvsu6wenIXB3elE+loXqkqWhrtuY+bxHoZ1wW1W6FNCh0a9eacSpq
# BccPahqghnuH19MJ0ky7RAAOwsCiStl53YPocpf+4KYnx8nCDFJqU5TDK59Pav0u
# 1EGv59Lo02AcSEw/6knEVqOqkQIDAQABo4IB2zCCAdcwDgYDVR0PAQH/BAQDAgeA
# MIGfBggrBgEFBQcBAQSBkjCBjzBMBggrBgEFBQcwAoZAaHR0cDovL3NlY3VyZS5n
# bG9iYWxzaWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNy
# dDA/BggrBgEFBQcwAYYzaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2Ny
# NDVldmNvZGVzaWduY2EyMDIwMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYI
# KwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkv
# MAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAwPjA8oDqgOIY2aHR0cDovL2Ny
# bC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3JsMCMG
# A1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzATBgNVHSUEDDAKBggr
# BgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs87ETO1ccA5I2ETAdBgNVHQ4E
# FgQUmeoy5enoUY6lDmu5FlhyUaFHWawwDQYJKoZIhvcNAQELBQADggIBAMriJ8rq
# BFu9wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2nVrl892cPNQe4WeoagqZ1a0c
# 7SRPijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7J8GZoIrGD65tde5Y2HKwznrTZ56W
# xIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTftv02Ri6VzIUMg9O4FJnJ1S81A/gBNWhx
# 6fSEgaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBShgSxQrQ5Li4lw4SKpburQecVnB6f
# 7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOpMAcdEjChHmh7gaeJNdOsfv8y
# UXML4zgSuJTsDR690NGHEcDcPwgAxTatLmuRCSTuH6tD/gG4ES38Q1mz7joDNkpR
# 79/IzKfYHl30fxHjqJbf3cuDy+mK1qd13fvMpR9S69sb8bPdJDJRL9mcO8RxJfwc
# NDqUHDAwz7J7b1vj/dIkOT7d5n4CBpubKb6jjQtNIGeDSNcev6ts2bjPpOiiCF3Z
# 1+g4/HMULZWxVQr5bAKwkllhra6kTj1rKTZEjZCRkaBpcOT3jCijqkG5ir7IZ7IO
# bprSue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtKHvuX/ze8ygvJIdNTd+9wcwum
# ekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3nMYIDFTCCAxECAQEwbDBcMQswCQYD
# VQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xv
# YmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjACDErzema3QWMQ
# LxMLNTANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3
# DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEV
# MC8GCSqGSIb3DQEJBDEiBCAtBszeu+kPjt2VYqJ1AuVkA8KeKO2NEdnDqfyHcfyb
# HDANBgkqhkiG9w0BAQEFAASCAgBtSAN3gpNWlM2iQqAa8aCcjY31un6f5lSBxuI7
# b2RjdlV6JZHknOSO+eThD1lcj6ra1UfkyhvVmGhAhWIzhBoSHQjD0iTo7QkvcKw8
# MbzgESJdUa5lMjzMW/eoCdL08gLOTTWp/TIMsUVXcDKIn0dCyRtNGn1IkACPCOCq
# TykHxXbXR3yV6fVaoWSFRO9trCtsfUvwdGgdCtdgxJuuz6lijZRtyO1iZK9iDgx8
# wr7xJ8Qoqk2xdsmH9OX9Np5dmgja664yRK2xppBBisiWTtx0hB25WYSQ3KlxPOFr
# 20k6eIf0kn+oQQTJ3946bVbsVRGeCskJeYkHqe4gYvTTlF3IM6b7k6lIunD9ezVs
# idAqxnSXo7hJeVxkN72/srneMxwP8fzC9LuzTuzif+/NNB19plAL9ML6Fa3LmJpG
# 93jhurSP5lX6zWDX8JD5INUK4a87d9APY90le8wT12rO6ysQSQ3bECa8wOt7UP2c
# LqabzeU7to+S5Yo4XjmYMBa6Q4+UE294v79Ly7N9gzt8VzCaXE3kB/SnIsSJf7fR
# KH/WD2zhVtUGdsSlBWthvgG+wWVRYQ6F1Lp5mVo5NxL+KSaYKYj6iC4khS/DWfmH
# NYwzKgNZYOQN9cM47qtygpSYXK/wwWymhKVGUrMzh+I8uACXmPGxvkPggMHTpldc
# A+G10zCCGCQGCSqGSIb3DQEHAqCCGBUwghgRAgEBMQ8wDQYJYIZIAWUDBAIBBQAw
# eQYKKwYBBAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhO
# tyTSxil+81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQgFurpK6wg
# EuTVP9ABuZHZAxrBPKwqIgQd7yK/Btsah3SgghRlMIIFojCCBIqgAwIBAgIQeAMY
# QkVwikHPbwG47rSpVDANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxT
# aWduIFJvb3QgQ0EgLSBSMzETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMK
# R2xvYmFsU2lnbjAeFw0yMDA3MjgwMDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBH
# bG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALYtxTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4Oq
# hPWjQ5uYRYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+R
# jbMFsiiCkV37WYgFC5cGwpj4LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzS
# x0Mdogl0oYCve+YzCgxZa4689Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKY
# B+J0q/9o3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrU
# vqHAnOHfHgIB2DvhZ0OEts/8dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3PO
# v72Vle2dK4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzS
# RdYu54+YnuYE7kJuZ35CFnFi5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5
# bnymu35Gb03FhRIrz5oiRAiohTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJip
# oAc3xGUaqhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tn
# h3Wa1EqRLIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4OJGTf
# AgMBAAGjggF3MIIBczAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUH
# AwMwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvO
# ljswHwYDVR0jBBgwFoAUj/BLf6guRSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEE
# bjBsMC0GCCsGAQUFBzABhiFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290
# cjMwOwYIKwYBBQUHMAKGL2h0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2Fj
# ZXJ0L3Jvb3QtcjMuY3J0MDYGA1UdHwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xv
# YmFsc2lnbi5jb20vcm9vdC1yMy5jcmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYI
# KwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkv
# MA0GCSqGSIb3DQEBDAUAA4IBAQCs98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57
# YtnhGFywvRNdHSOuOVB2N6pE/V8BI1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6
# qC2qPPbsn4cxB2X1OadRgnXh8i+X9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfR
# rqexC+LWd7uptDRKqW899PMNlV3m+XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/D
# KH563pMOtH2gCm2SxLRmP32nWO6s9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww
# 1LMGqwBgSA14q88XrZKTYiB3dWy9yDK03E3r2d/BkJYpvcF/MIIG6DCCBNCgAwIB
# AgIQd70OBbdZC7YdR2FTHj917TANBgkqhkiG9w0BAQsFADBTMQswCQYDVQQGEwJC
# RTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2ln
# biBDb2RlIFNpZ25pbmcgUm9vdCBSNDUwHhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4
# MDAwMDAwWjBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1z
# YTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENB
# IDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLIO+XHrkBMkOg
# W6mKI/0gXq44EovKLNT/QdgaVdQZU7f9oxfnejlcwPfOEaP5pe0B+rW6k++vk9z4
# 4rMZTIOwSkRQBHiEEGqk1paQjoH4fKsvtaNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS
# 0PC0VV+WCxHlmrUsshHPJRt9USuYH0mjX/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS
# 7L1AldMRyubNswWcyFPrUtd4TFEBkoLeE/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+
# p7JBMyB1zLHV7R0HGcTrJnfyq20Xk0mpt+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HP
# mFWjJKKINvL5n76TLrIGnybADAFWEuGyip8OHtyYiy7P2uKJNKYfJqCornht7KGI
# FTzC6u632K1hpa9wNqJ5jtwNc8Dx5CyrlOxYBjk2SNY7WugiznQOryzxFdrRtJXo
# rNVJbeWv3ZtrYyBdjn47skPYYjqU5c20mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5t
# x2nTbrcBbA3gl6cW5iaLiPcDRIZfYmdMtac3qFXcAzaMbs9tNibxDo+wPXHA4TKn
# guS2MgIyMHy1k8gh/TyI5mlj+O51yYvCq++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuV
# xBKH5xq4Tu4swd+hZegkg8kqwv25UwIDAQABo4IBrTCCAakwDgYDVR0PAQH/BAQD
# AgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYD
# VR0OBBYEFCWd0PxZCYZjxezzsRM7VxwDkjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4
# ObeltEPZVlC7zpY7MIGTBggrBgEFBQcBAQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0
# cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1MEYGCCsG
# AQUFBzAChjpodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9jb2Rl
# c2lnbmluZ3Jvb3RyNDUuY3J0MEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwu
# Z2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1LmNybDBVBgNVHSAETjBM
# MEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxz
# aWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzANBgkqhkiG9w0BAQsFAAOCAgEA
# JXWgCck5urehOYkvGJ+r1usdS+iUfA0HaJscne9xthdqawJPsz+GRYfMZZtM41gG
# AiJm1WECxWOP1KLxtl4lC3eW6c1xQDOIKezu86JtvE21PgZLyXMzyggULT1M6LC6
# daZ0LaRYOmwTSfilFQoUloWxamg0JUKvllb0EPokffErcsEW4Wvr5qmYxz5a9NAY
# nf10l4Z3Rio9I30oc4qu7ysbmr9sU6cUnjyHccBejsj70yqSM+pXTV4HXsrBGKyB
# LRoh+m7Pl2F733F6Ospj99UwRDcy/rtDhdy6/KbKMxkrd23bywXwfl91LqK2vzWq
# NmPJzmTZvfy8LPNJVgDIEivGJ7s3r1fvxM8eKcT04i3OKmHPV+31CkDi9RjWHumQ
# L8rTh1+TikgaER3lN4WfLmZiml6BTpWsVVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4h
# u5/XanGAv5becgPY2CIr8ycWTzjoUUAMrpLvvj1994DGTDZXhJWnhBVIMA5SJwiN
# jqK9IscZyabKDqh6NttqumFfESSVpOKOaO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGH
# JNPE+6ljy3dI1fpi/CTgBHpO0ORu3s6eOFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV
# 0NMe9n9S4kmNuRFyDIhEJjNmAUTf5DMOId5iiUgH2vUwggfPMIIFt6ADAgECAgxK
# 83pmt0FjEC8TCzUwDQYJKoZIhvcNAQELBQAwXDELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0
# NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwMB4XDTI0MDQwMzE1NDExNloXDTI1MDQw
# NDE1NDExNlowggEOMR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjERMA8G
# A1UEBRMIMTMzMzczNDMxEzARBgsrBgEEAYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdC
# MRswGQYDVQQIExJHcmVhdGVyIE1hbmNoZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0
# ZXIxGTAXBgNVBAkTEDE3IE1hcmJsZSBTdHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBT
# b2Z0d2FyZSBMaW1pdGVkMSAwHgYDVQQDExdDbG91ZE0gU29mdHdhcmUgTGltaXRl
# ZDEnMCUGCSqGSIb3DQEJARYYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAngoTokY2HYu5xPv9s5LrBGLS72Aw
# wIEk4huasmriK3lFC7ludj4D+m+khHMDGX/dAWmLDIvW3LiNcmfQtJYW28grUXCo
# 95ZXP6nR8J/cI2iOtHHp2/HvfNVV60hzhZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq
# 3f+CSOSZ4FdU6ISsAqZeRsazr/XA2b0apQceLiYVPeORUNsIgfElvcCHhmA5jB8S
# l/2F5JUpvPC58Tc53dQUWpz5dFW5Cav1BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj
# 0E2TxzADesGjJ4CZ8PU8JTVBhIcb7d+9WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1
# ouCfJEsYeeBny8EQIy1lFuoLfBOGHf+tsT++wKHVkr4BjHhjOT+XwUItwXt/WmwK
# LuH0t6lgBHGlstap+6dBcQC66ZUCMi8OiZ8+3dM8ySiRO4UHBH26lSWc7oMYQexg
# X6O1XCgyxCX3MJfEcJrIlOEEBq11M9cHKvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W
# 1b7LusHpyFwd3pRPpaF6pKloa7bmPm8R6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7
# h9fTCdJMu0QADsLAokrZed2D6HKX/uCmJ8fJwgxSalOUwyufT2r9LtRBr+fS6NNg
# HEhMP+pJxFajqpECAwEAAaOCAdswggHXMA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYB
# BQUHAQEEgZIwgY8wTAYIKwYBBQUHMAKGQGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2ln
# bi5jb20vY2FjZXJ0L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYB
# BQUHMAGGM2h0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rl
# c2lnbmNhMjAyMDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIB
# FiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwB
# AzAJBgNVHRMEAjAAMEcGA1UdHwRAMD4wPKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFs
# c2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNybDAjBgNVHREEHDAa
# gRhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# HwYDVR0jBBgwFoAUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp
# 6FGOpQ5ruRZYclGhR1msMA0GCSqGSIb3DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlh
# qLQpOawqxF133UUTN4wKocLfqlsv9p1a5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJo
# mnX76vojinvqiLsNr0f2zKcquyfBmaCKxg+ubXXuWNhysM5602eelsSF5wFpKm1S
# mKAuvolB79Pq5uS2y8ZU37b9NkYulcyFDIPTuBSZydUvNQP4ATVocen0hIGkZFGf
# qnIowfyzFjvXU3+T9Vrc3BTAUoYEsUK0OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAo
# lFZHqEfIy+K1HkWkq0dz4+bVpJlTqTAHHRIwoR5oe4GniTXTrH7/MlFzC+M4EriU
# 7A0evdDRhxHA3D8IAMU2rS5rkQkk7h+rQ/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d
# 9H8R46iW393Lg8vpitandd37zKUfUuvbG/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+y
# e29b4/3SJDk+3eZ+Agabmym+o40LTSBng0jXHr+rbNm4z6Tooghd2dfoOPxzFC2V
# sVUK+WwCsJJZYa2upE49ayk2RI2QkZGgaXDk94woo6pBuYq+yGeyDm6a0rnuAimI
# xNDc3KNSLiaw48DP9nAYS8bO1yirSh77l/83vMoLySHTU3fvcHMLpnpCSRha6iYC
# z1q9xwrReCYrgJxc+y2IyxK95zGCAxUwggMRAgEBMGwwXDELMAkGA1UEBhMCQkUx
# GTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24g
# R0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJ
# YIZIAWUDBAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYK
# KwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG
# 9w0BCQQxIgQgLQbM3rvpD47dlWKidQLlZAPCnijtjRHZw6n8h3H8mxwwDQYJKoZI
# hvcNAQEBBQAEggIAbUgDd4KTVpTNokKgGvGgnI2N9bp+n+ZUgcbiO29kY3ZVeiWR
# 5Jzkjvnk4Q9ZXI+q2tVH5Mob1ZhoQIViM4QaEh0Iw9Ik6O0JL3CsPDG84BEiXVGu
# ZTI8zFv3qAnS9PICzk01qf0yDLFFV3AyiJ9HQskbTRp9SJAAjwjgqk8pB8V210d8
# len1WqFkhUTvbawrbH1L8HRoHQrXYMSbrs+pYo2UbcjtYmSvYg4MfMK+8SfEKKpN
# sXbJh/Tl/TaeXZoI2uuuMkStsaaQQYrIlk7cdIQduVmEkNypcTzha9tJOniH9JJ/
# qEEEyd/eOm1W7FURngrJCXmJB6nuIGL005RdyDOm+5OpSLpw/Xs1bInQKsZ0l6O4
# SXlcZDe9v7K53jMcD/H8wvS7s07s4n/vzTQdfaZQC/TC+hWty5iaRvd44bq0j+ZV
# +s1g1/CQ+SDVCuGvO3fQD2PdJXvME9dqzusrEEkN2xAmvMDre1D9nC6mm83lO7aP
# kuWKOF45mDAWukOPlBNveL+/S8uzfYM7fFcwmlxN5Af0pyLEiX+30Sh/1g9s4VbV
# BnbEpQVrYb4BvsFlUWEOhdS6eZlaOTcS/ikmmCmI+oguJIUvw1n5hzWMMyoDWWDk
# DfXDOO6rcoKUmFyv8MFspoSlRlKzM4fiPLgAl5jxsb5D4IDB06ZXXAPhtdMwghgk
# BgkqhkiG9w0BBwKgghgVMIIYEQIBATEPMA0GCWCGSAFlAwQCAQUAMHkGCisGAQQB
# gjcCAQSgazBpMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIBBQAEIOPpGC+lZEsaMJD6Xc6/
# SYGNmmLeAbR6WGXQBRCu6UgUoIIUZTCCBaIwggSKoAMCAQICEHgDGEJFcIpBz28B
# uO60qVQwDQYJKoZIhvcNAQEMBQAwTDEgMB4GA1UECxMXR2xvYmFsU2lnbiBSb290
# IENBIC0gUjMxEzARBgNVBAoTCkdsb2JhbFNpZ24xEzARBgNVBAMTCkdsb2JhbFNp
# Z24wHhcNMjAwNzI4MDAwMDAwWhcNMjkwMzE4MDAwMDAwWjBTMQswCQYDVQQGEwJC
# RTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2ln
# biBDb2RlIFNpZ25pbmcgUm9vdCBSNDUwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC2LcUw3Xroq5A9A3KwOkuZFmGy5f+lZx03HOV+7JODqoT1o0ObmEWK
# uGNXXZsAiAQl6fhokkuC2EvJSgPzqH9qj4phJ72hRND99T8iwqNPkY2zBbIogpFd
# +1mIBQuXBsKY+CynMyTuUDpBzPCgsHsdTdKoWDiW6d/5G5G7ixAs0sdDHaIJdKGA
# r3vmMwoMWWuOvPSrWpd7f65V+4TwgP6ETNfiur3EdaFvvWEQdESymAfidKv/aNxs
# Jj7pH+XgBIetMNMMjQN8VbgWcFwkeCAl62dniKu6TjSYa3AR3jjK1L6hwJzh3x4C
# Adg74WdDhLbP/HS3L4Sjv7oJNz1nbLFFXBlhq0GD9awd63cNRkdzzr+9lZXtnSuI
# EP76WOinV+Gzz6ha6QclmxLEnoByPZPcjJTfO0TmJoD80sMD8IwM0kXWLuePmJ7m
# BO5Cbmd+QhZxYucE+WDGZKG2nIEhTivGbWiUhsaZdHNnMXqR8tSMeW58prt+Rm9N
# xYUSK8+aIkQIqIU3zgdhVwYXEiTAxDFzoZg1V0d+EDpF2S2kUZCYqaAHN8RlGqoc
# axZ396eX7D8ZMJlvMfvqQLLn0sT6ydDwUHZ0WfqNbRcyvvjpfgP054d1mtRKkSyF
# AxMCK0KA8olqNs/ITKDOnvjLja0Wp9Pe1ZsYp8aSOvGCY/EuDiRk3wIDAQABo4IB
# dzCCAXMwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA8GA1Ud
# EwEB/wQFMAMBAf8wHQYDVR0OBBYEFB8Av0aACvx4ObeltEPZVlC7zpY7MB8GA1Ud
# IwQYMBaAFI/wS3+oLkUkrk1Q+mOai97i3Ru8MHoGCCsGAQUFBwEBBG4wbDAtBggr
# BgEFBQcwAYYhaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vcm9vdHIzMDsGCCsG
# AQUFBzAChi9odHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9yb290
# LXIzLmNydDA2BgNVHR8ELzAtMCugKaAnhiVodHRwOi8vY3JsLmdsb2JhbHNpZ24u
# Y29tL3Jvb3QtcjMuY3JsMEcGA1UdIARAMD4wPAYEVR0gADA0MDIGCCsGAQUFBwIB
# FiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG
# 9w0BAQwFAAOCAQEArPfMFYsweagdCyiIGQnXHH/+hr17WjNuDWcOe2LZ4RhcsL0T
# XR0jrjlQdjeqRP1fASNZhlZMzK28ZBMUMKQgqOA/6Jxy3H7z2Awjuqgtqjz27J+H
# MQdl9TmnUYJ14fIvl/bR4WWWg2T+oR1R+7Ukm/XSd2m8hSxc+lh30a6nsQvi1ne7
# qbQ0SqlvPfTzDZVd5vl6RbAlFzEu2/cPaOaDH6n35dSdmIzTYUsvwyh+et6TDrR9
# oAptksS0Zj99p1jurPfswwgBqzj8ChypxZeyiMgJAhn2XJoa8U1sMNSzBqsAYEgN
# eKvPF62Sk2Igd3VsvcgytNxN69nfwZCWKb3BfzCCBugwggTQoAMCAQICEHe9DgW3
# WQu2HUdhUx4/de0wDQYJKoZIhvcNAQELBQAwUzELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBT
# aWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAwMFoXDTMwMDcyODAwMDAwMFow
# XDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNV
# BAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyyDvlx65ATJDoFupiiP9IF6u
# OBKLyizU/0HYGlXUGVO3/aMX53o5XMD3zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpE
# UAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuUDm0PpZEmKrODT3KxintkktDwtFVflgsR
# 5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrm
# zbMFnMhT61LXeExRAZKC3hPzB450uoSAn9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx
# 1e0dBxnE6yZ38qttF5NJqbfmw5CcxrjszMl7ml7FxSSTY29+EIthz5hVoySiiDby
# +Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsuz9riiTSmHyagqK54beyhiBU8wurut9it
# YaWvcDaieY7cDXPA8eQsq5TsWAY5NkjWO1roIs50Dq8s8RXa0bSV6KzVSW3lr92b
# a2MgXY5+O7JD2GI6lOXNtJizNxkkEnJzqwSwCdyF5tQiBO9AKh0ubcdp0263AWwN
# 4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8
# tZPIIf08iOZpY/judcmLwqvvujr96V6/thHxvvA9yjI+bn3eD36blcQSh+cauE7u
# LMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0wggGpMA4GA1UdDwEB/wQEAwIBhjATBgNV
# HSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBQl
# ndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNVHSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQ
# u86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3Nw
# Lmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6
# aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvY29kZXNpZ25pbmdy
# b290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAyhjBodHRwOi8vY3JsLmdsb2JhbHNp
# Z24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEE
# AaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20v
# cmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJKoZIhvcNAQELBQADggIBACV1oAnJObq3
# oTmJLxifq9brHUvolHwNB2ibHJ3vcbYXamsCT7M/hkWHzGWbTONYBgIiZtVhAsVj
# j9Si8bZeJQt3lunNcUAziCns7vOibbxNtT4GS8lzM8oIFC09TOiwunWmdC2kWDps
# E0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3xK3LBFuFr6+apmMc+WvTQGJ39dJeGd0Yq
# PSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I+9MqkjPqV01eB17KwRisgS0aIfpuz5dh
# e99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZK3dt28sF8H5fdS6itr81qjZjyc5k2b38
# vCzzSVYAyBIrxie7N69X78TPHinE9OItziphz1ft9QpA4vUY1h7pkC/K04dfk4pI
# GhEd5TeFny5mYppegU6VrFVXQ9xTiyV+PGEPigu69T+m1473BFZeIbuf12pxgL+W
# 3nID2NgiK/MnFk846FFADK6S7749ffeAxkw2V4SVp4QVSDAOUicIjY6ivSLHGcmm
# yg6oejbbarphXxEklaTijmjuGalJmV7QtDS91vlAxxCXMVI5NSkRhyTTxPupY8t3
# SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXXCSXUyQcAerjH83foxdTiVdDTHvZ/UuJJ
# jbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAv
# Ews1MA0GCSqGSIb3DQEBCwUAMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9i
# YWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29k
# ZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZa
# MIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xETAPBgNVBAUTCDEz
# MzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMTAkdCMQswCQYDVQQGEwJHQjEbMBkGA1UE
# CBMSR3JlYXRlciBNYW5jaGVzdGVyMRMwEQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYD
# VQQJExAxNyBNYXJibGUgU3RyZWV0MSAwHgYDVQQKExdDbG91ZE0gU29mdHdhcmUg
# TGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkq
# hkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBAJ4KE6JGNh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq
# 4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf
# 3CNojrRx6dvx73zVVetIc4WVNGcsW/YESmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBX
# VOiErAKmXkbGs6/1wNm9GqUHHi4mFT3jkVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzw
# ufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq78/GYTmClqT5BCvck9i0I9BNk8cwA3rB
# oyeAmfD1PCU1QYSHG+3fvVjYXGi91RnIMu5ErFSrtwp7GFvYl4vqtaLgnyRLGHng
# Z8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+AYx4Yzk/l8FCLcF7f1psCi7h9LepYARx
# pbLWqfunQXEAuumVAjIvDomfPt3TPMkokTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl
# 9zCXxHCayJThBAatdTPXByr4XLqX7gqb71/mugorh00URN/mytEfltW+y7rB6chc
# Hd6UT6WheqSpaGu25j5vEehnXBbVboU0KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtE
# AA7CwKJK2Xndg+hyl/7gpifHycIMUmpTlMMrn09q/S7UQa/n0ujTYBxITD/qScRW
# o6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8BAf8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGS
# MIGPMEwGCCsGAQUFBzAChkBodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2Nh
# Y2VydC9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3J0MD8GCCsGAQUFBzABhjNo
# dHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIw
# MjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6
# Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0T
# BAIwADBHBgNVHR8EQDA+MDygOqA4hjZodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29t
# L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5t
# Y2tpbnN0cnlAY2xvdWRtLmlvMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQY
# MBaAFCWd0PxZCYZjxezzsRM7VxwDkjYRMB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kW
# WHJRoUdZrDANBgkqhkiG9w0BAQsFAAOCAgEAyuInyuoEW73BaqgZYai0KTmsKsRd
# d91FEzeMCqHC36pbL/adWuXz3Zw81B7hZ6hqCpnVrRztJE+KPAyyaJp1++r6I4p7
# 6oi7Da9H9synKrsnwZmgisYPrm117ljYcrDOetNnnpbEhecBaSptUpigLr6JQe/T
# 6ubktsvGVN+2/TZGLpXMhQyD07gUmcnVLzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY7
# 11N/k/Va3NwUwFKGBLFCtDkuLiXDhIqlu6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvi
# tR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuBp4k106x+/zJRcwvjOBK4lOwNHr3Q0YcR
# wNw/CADFNq0ua5EJJO4fq0P+AbgRLfxDWbPuOgM2SlHv38jMp9geXfR/EeOolt/d
# y4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5
# Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZuM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCS
# WWGtrqROPWspNkSNkJGRoGlw5PeMKKOqQbmKvshnsg5umtK57gIpiMTQ3NyjUi4m
# sOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh01N373BzC6Z6QkkYWuomAs9avccK0Xgm
# K4CcXPstiMsSvecxggMVMIIDEQIBATBsMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUg
# RVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMSvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQC
# AQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcC
# AQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIE
# ICVh2Wby5+CwJbwg0hXPdeXS6mbjriDQrE0WO1xYGZNjMA0GCSqGSIb3DQEBAQUA
# BIICAEPkJZCwrYt/3SSaYBnS7HkIN85STZT/yszDAGHn29lkV5btKeAsGTNHjEXa
# BuexIsyamsdjCPiOzNSv1hGzogPaqL5SULMPkggr8gU9RzplQtcMMlgTW1kGK+c/
# H+o4E6MJH+32o+TLQqf0t854uEu6V5Kw0cba0Gu02voWuNb6q2efJ6McEGtODkp9
# 5vxuGSdqyR+9gOn35Zh4qQrfSLxc45u/uEbbHvEPniErDPQf+XXJrEF3iKn1hdPF
# U4mgdjOOsEC5EYBZnR2apxbtmV2Yul22EfUehPfzbTcik5OrhiKli5lBC+OHreiA
# QHbIlc6SFH1SAb4jGE4wJBMDPgqu0qiCTBVK5uag+aISzdH9uRdhNYM+hZzrQ5tn
# YwYD4nGkS5IBhd+iRa8xsPbPzJdSWFCfVDH29zwcBbRYf0gTkfIVSDK0/GDMKfVX
# ua9LFe6jg3JQXhbzb5E9AgXhz9ADRuDaUqA4+4DgLeMgWXScAY0BS7+9XzwjqUWS
# RZjbxoBHYfsH7ydQUSsoUAlg9cG5XrYRBO+LctxzQfdMREy5uhnuQrhwuycZ6c8D
# zXSCbM1p9f/ViS9V6bURHHvGQ7qui2ZPoZgOdIQ3+BY3DLAgsmN4pIY/Q6T8/yzb
# dZOaqdHtilfIxhQsjR/7Zx08wG1jDg0SECai3knQXUZXOV+BMIIYJAYJKoZIhvcN
# AQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5BgorBgEEAYI3AgEEoGsw
# aTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLGKX7zUQIBAAIBAAIB
# AAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDj6RgvpWRLGjCQ+l3Ov0mBjZpi3gG0
# elhl0AUQrulIFKCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCKQc9vAbjutKlUMA0G
# CSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2JhbFNpZ24gUm9vdCBDQSAtIFIz
# MRMwEQYDVQQKEwpHbG9iYWxTaWduMRMwEQYDVQQDEwpHbG9iYWxTaWduMB4XDTIw
# MDcyODAwMDAwMFoXDTI5MDMxODAwMDAwMFowUzELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBT
# aWduaW5nIFJvb3QgUjQ1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# ti3FMN166KuQPQNysDpLmRZhsuX/pWcdNxzlfuyTg6qE9aNDm5hFirhjV12bAIgE
# Jen4aJJLgthLyUoD86h/ao+KYSe9oUTQ/fU/IsKjT5GNswWyKIKRXftZiAULlwbC
# mPgspzMk7lA6QczwoLB7HU3SqFg4lunf+RuRu4sQLNLHQx2iCXShgK975jMKDFlr
# jrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWhb71hEHREspgH4nSr/2jcbCY+6R/l4ASH
# rTDTDI0DfFW4FnBcJHggJetnZ4iruk40mGtwEd44ytS+ocCc4d8eAgHYO+FnQ4S2
# z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/WsHet3DUZHc86/vZWV7Z0riBD++ljop1fh
# s8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA/NLDA/CMDNJF1i7nj5ie5gTuQm5nfkIW
# cWLnBPlgxmShtpyBIU4rxm1olIbGmXRzZzF6kfLUjHlufKa7fkZvTcWFEivPmiJE
# CKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6RdktpFGQmKmgBzfEZRqqHGsWd/enl+w/
# GTCZbzH76kCy59LE+snQ8FB2dFn6jW0XMr746X4D9OeHdZrUSpEshQMTAitCgPKJ
# ajbPyEygzp74y42tFqfT3tWbGKfGkjrxgmPxLg4kZN8CAwEAAaOCAXcwggFzMA4G
# A1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzAPBgNVHRMBAf8EBTAD
# AQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQu86WOzAfBgNVHSMEGDAWgBSP
# 8Et/qC5FJK5NUPpjmove4t0bvDB6BggrBgEFBQcBAQRuMGwwLQYIKwYBBQUHMAGG
# IWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL3Jvb3RyMzA7BggrBgEFBQcwAoYv
# aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvcm9vdC1yMy5jcnQw
# NgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9yb290
# LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUdIAAwNDAyBggrBgEFBQcCARYmaHR0cHM6
# Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wDQYJKoZIhvcNAQEMBQAD
# ggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9e1ozbg1nDnti2eEYXLC9E10dI645UHY3
# qkT9XwEjWYZWTMytvGQTFDCkIKjgP+icctx+89gMI7qoLao89uyfhzEHZfU5p1GC
# deHyL5f20eFlloNk/qEdUfu1JJv10ndpvIUsXPpYd9Gup7EL4tZ3u6m0NEqpbz30
# 8w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XUnZiM02FLL8Mofnrekw60faAKbZLEtGY/
# fadY7qz37MMIAas4/AocqcWXsojICQIZ9lyaGvFNbDDUswarAGBIDXirzxetkpNi
# IHd1bL3IMrTcTevZ38GQlim9wX8wggboMIIE0KADAgECAhB3vQ4Ft1kLth1HYVMe
# P3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9i
# YWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBS
# b290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNV
# BAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9i
# YWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B
# 2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAEeIQQaqTW
# lpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8l
# G31RK5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS
# 13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXtHQcZxOsm
# d/KrbReTSam35sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmfvpMusgaf
# JsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGlr3A2onmO
# 3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tjIF2Ofjuy
# Q9hiOpTlzbSYszcZJBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCXpxbmJouI
# 9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjm
# aWP47nXJi8Kr77o6/elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB36Fl6CSD
# ySrC/blTAgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF
# 7POxEztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvOljswgZMG
# CCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5nbG9iYWxz
# aWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9z
# ZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5j
# cnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9j
# b2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQw
# MgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRv
# cnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW
# 6x1L6JR8DQdomxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/UovG2XiUL
# d5bpzXFAM4gp7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ+KUVChSW
# hbFqaDQlQq+WVvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0jfShziq7v
# Kxuav2xTpxSePIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvfcXo6ymP3
# 1TBENzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgS
# K8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8u
# ZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5yA9jYIivz
# JxZPOOhRQAyuku++PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoOqHo222q6
# YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV+mL8JOAE
# ek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25EXIMiEQm
# M2YBRN/kMw4h3mKJSAfa9TCCB88wggW3oAMCAQICDErzema3QWMQLxMLNTANBgkq
# hkiG9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBu
# di1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5n
# IENBIDIwMjAwHhcNMjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAb
# BgNVBA8MFFByaXZhdGUgT3JnYW5pemF0aW9uMREwDwYDVQQFEwgxMzMzNzM0MzET
# MBEGCysGAQQBgjc8AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0
# ZXIgTWFuY2hlc3RlcjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZMBcGA1UECRMQMTcg
# TWFyYmxlIFN0cmVldDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQx
# IDAeBgNVBAMTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkB
# FhhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCeChOiRjYdi7nE+/2zkusEYtLvYDDAgSTiG5qyauIreUULuW52
# PgP6b6SEcwMZf90BaYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/qdHwn9wjaI60cenb
# 8e981VXrSHOFlTRnLFv2BEpiqtH0as26jTyt8oa1o6rd/4JI5JngV1TohKwCpl5G
# xrOv9cDZvRqlBx4uJhU945FQ2wiB8SW9wIeGYDmMHxKX/YXklSm88LnxNznd1BRa
# nPl0VbkJq/UF0FfzN913qu/PxmE5gpak+QQr3JPYtCPQTZPHMAN6waMngJnw9Twl
# NUGEhxvt371Y2FxovdUZyDLuRKxUq7cKexhb2JeL6rWi4J8kSxh54GfLwRAjLWUW
# 6gt8E4Yd/62xP77AodWSvgGMeGM5P5fBQi3Be39abAou4fS3qWAEcaWy1qn7p0Fx
# ALrplQIyLw6Jnz7d0zzJKJE7hQcEfbqVJZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU
# 4QQGrXUz1wcq+Fy6l+4Km+9f5roKK4dNFETf5srRH5bVvsu6wenIXB3elE+loXqk
# qWhrtuY+bxHoZ1wW1W6FNCh0a9eacSpqBccPahqghnuH19MJ0ky7RAAOwsCiStl5
# 3YPocpf+4KYnx8nCDFJqU5TDK59Pav0u1EGv59Lo02AcSEw/6knEVqOqkQIDAQAB
# o4IB2zCCAdcwDgYDVR0PAQH/BAQDAgeAMIGfBggrBgEFBQcBAQSBkjCBjzBMBggr
# BgEFBQcwAoZAaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3Nn
# Y2NyNDVldmNvZGVzaWduY2EyMDIwLmNydDA/BggrBgEFBQcwAYYzaHR0cDovL29j
# c3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwMFUGA1Ud
# IAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmds
# b2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYD
# VR0fBEAwPjA8oDqgOIY2aHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9nc2djY3I0
# NWV2Y29kZXNpZ25jYTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5
# QGNsb3VkbS5pbzATBgNVHSUEDDAKBggrBgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8
# WQmGY8Xs87ETO1ccA5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6lDmu5FlhyUaFHWaww
# DQYJKoZIhvcNAQELBQADggIBAMriJ8rqBFu9wWqoGWGotCk5rCrEXXfdRRM3jAqh
# wt+qWy/2nVrl892cPNQe4WeoagqZ1a0c7SRPijwMsmiadfvq+iOKe+qIuw2vR/bM
# pyq7J8GZoIrGD65tde5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTf
# tv02Ri6VzIUMg9O4FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB/LMWO9dTf5P1Wtzc
# FMBShgSxQrQ5Li4lw4SKpburQecVnB6f7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj
# 5tWkmVOpMAcdEjChHmh7gaeJNdOsfv8yUXML4zgSuJTsDR690NGHEcDcPwgAxTat
# LmuRCSTuH6tD/gG4ES38Q1mz7joDNkpR79/IzKfYHl30fxHjqJbf3cuDy+mK1qd1
# 3fvMpR9S69sb8bPdJDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj/dIkOT7d5n4CBpub
# Kb6jjQtNIGeDSNcev6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5bAKwkllhra6kTj1r
# KTZEjZCRkaBpcOT3jCijqkG5ir7IZ7IObprSue4CKYjE0Nzco1IuJrDjwM/2cBhL
# xs7XKKtKHvuX/ze8ygvJIdNTd+9wcwumekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjL
# Er3nMYIDFTCCAxECAQEwbDBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFs
# U2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVT
# aWduaW5nIENBIDIwMjACDErzema3QWMQLxMLNTANBglghkgBZQMEAgEFAKB8MBAG
# CisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAlYdlm8ufg
# sCW8INIVz3Xl0upm464g0KxNFjtcWBmTYzANBgkqhkiG9w0BAQEFAASCAgBD5CWQ
# sK2Lf90kmmAZ0ux5CDfOUk2U/8rMwwBh59vZZFeW7SngLBkzR4xF2gbnsSLMmprH
# Ywj4jszUr9YRs6ID2qi+UlCzD5IIK/IFPUc6ZULXDDJYE1tZBivnPx/qOBOjCR/t
# 9qPky0Kn9LfOeLhLuleSsNHG2tBrtNr6FrjW+qtnnyejHBBrTg5Kfeb8bhknaskf
# vYDp9+WYeKkK30i8XOObv7hG2x7xD54hKwz0H/l1yaxBd4ip9YXTxVOJoHYzjrBA
# uRGAWZ0dmqcW7ZldmLpdthH1HoT38203IpOTq4YipYuZQQvjh63ogEB2yJXOkhR9
# UgG+IxhOMCQTAz4KrtKogkwVSubmoPmiEs3R/bkXYTWDPoWc60ObZ2MGA+JxpEuS
# AYXfokWvMbD2z8yXUlhQn1Qx9vc8HAW0WH9IE5HyFUgytPxgzCn1V7mvSxXuo4Ny
# UF4W82+RPQIF4c/QA0bg2lKgOPuA4C3jIFl0nAGNAUu/vV88I6lFkkWY28aAR2H7
# B+8nUFErKFAJYPXBuV62EQTvi3Lcc0H3TERMuboZ7kK4cLsnGenPA810gmzNafX/
# 1YkvVem1ERx7xkO6rotmT6GYDnSEN/gWNwywILJjeKSGP0Ok/P8s23WTmqnR7YpX
# yMYULI0f+2cdPMBtYw4NEhAmot5J0F1GVzlfgTCCGCQGCSqGSIb3DQEHAqCCGBUw
# ghgRAgEBMQ8wDQYJYIZIAWUDBAIBBQAweQYKKwYBBAGCNwIBBKBrMGkwNAYKKwYB
# BAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+81ECAQACAQACAQACAQACAQAw
# MTANBglghkgBZQMEAgEFAAQg4+kYL6VkSxowkPpdzr9JgY2aYt4BtHpYZdAFEK7p
# SBSgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVwikHPbwG47rSpVDANBgkqhkiG9w0B
# AQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzETMBEGA1UE
# ChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjAeFw0yMDA3MjgwMDAw
# MDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9i
# YWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBS
# b290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALYtxTDdeuir
# kD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uYRYq4Y1ddmwCIBCXp+GiSS4LY
# S8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiCkV37WYgFC5cGwpj4LKczJO5Q
# OkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0oYCve+YzCgxZa4689Ktal3t/
# rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o3GwmPukf5eAEh60w0wyNA3xV
# uBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHfHgIB2DvhZ0OEts/8dLcvhKO/
# ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2dK4gQ/vpY6KdX4bPPqFrpByWb
# EsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+YnuYE7kJuZ35CFnFi5wT5YMZk
# obacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35Gb03FhRIrz5oiRAiohTfOB2FX
# BhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUaqhxrFnf3p5fsPxkwmW8x++pA
# sufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2z8hMoM6e
# +MuNrRan097VmxinxpI68YJj8S4OJGTfAgMBAAGjggF3MIIBczAOBgNVHQ8BAf8E
# BAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYDVR0TAQH/BAUwAwEB/zAdBgNV
# HQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYDVR0jBBgwFoAUj/BLf6guRSSu
# TVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0GCCsGAQUFBzABhiFodHRwOi8v
# b2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYIKwYBBQUHMAKGL2h0dHA6Ly9z
# ZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jvb3QtcjMuY3J0MDYGA1UdHwQv
# MC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vcm9vdC1yMy5jcmww
# RwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmds
# b2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4IBAQCs98wV
# izB5qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFywvRNdHSOuOVB2N6pE/V8BI1mG
# VkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbsn4cxB2X1OadRgnXh8i+X9tHh
# ZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LWd7uptDRKqW899PMNlV3m+XpF
# sCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMOtH2gCm2SxLRmP32nWO6s9+zD
# CAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBgSA14q88XrZKTYiB3dWy9yDK0
# 3E3r2d/BkJYpvcF/MIIG6DCCBNCgAwIBAgIQd70OBbdZC7YdR2FTHj917TANBgkq
# hkiG9w0BAQsFADBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBu
# di1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUw
# HhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4MDAwMDAwWjBcMQswCQYDVQQGEwJCRTEZ
# MBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBH
# Q0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDLIO+XHrkBMkOgW6mKI/0gXq44EovKLNT/QdgaVdQZU7f9
# oxfnejlcwPfOEaP5pe0B+rW6k++vk9z44rMZTIOwSkRQBHiEEGqk1paQjoH4fKsv
# taNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS0PC0VV+WCxHlmrUsshHPJRt9USuYH0mj
# X/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS7L1AldMRyubNswWcyFPrUtd4TFEBkoLe
# E/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+p7JBMyB1zLHV7R0HGcTrJnfyq20Xk0mp
# t+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HPmFWjJKKINvL5n76TLrIGnybADAFWEuGy
# ip8OHtyYiy7P2uKJNKYfJqCornht7KGIFTzC6u632K1hpa9wNqJ5jtwNc8Dx5Cyr
# lOxYBjk2SNY7WugiznQOryzxFdrRtJXorNVJbeWv3ZtrYyBdjn47skPYYjqU5c20
# mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5tx2nTbrcBbA3gl6cW5iaLiPcDRIZfYmdM
# tac3qFXcAzaMbs9tNibxDo+wPXHA4TKnguS2MgIyMHy1k8gh/TyI5mlj+O51yYvC
# q++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuVxBKH5xq4Tu4swd+hZegkg8kqwv25UwID
# AQABo4IBrTCCAakwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMD
# MBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFCWd0PxZCYZjxezzsRM7VxwD
# kjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4ObeltEPZVlC7zpY7MIGTBggrBgEFBQcB
# AQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20v
# Y29kZXNpZ25pbmdyb290cjQ1MEYGCCsGAQUFBzAChjpodHRwOi8vc2VjdXJlLmds
# b2JhbHNpZ24uY29tL2NhY2VydC9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3J0MEEGA1Ud
# HwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25p
# bmdyb290cjQ1LmNybDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUF
# BwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVn
# gQwBAzANBgkqhkiG9w0BAQsFAAOCAgEAJXWgCck5urehOYkvGJ+r1usdS+iUfA0H
# aJscne9xthdqawJPsz+GRYfMZZtM41gGAiJm1WECxWOP1KLxtl4lC3eW6c1xQDOI
# Kezu86JtvE21PgZLyXMzyggULT1M6LC6daZ0LaRYOmwTSfilFQoUloWxamg0JUKv
# llb0EPokffErcsEW4Wvr5qmYxz5a9NAYnf10l4Z3Rio9I30oc4qu7ysbmr9sU6cU
# njyHccBejsj70yqSM+pXTV4HXsrBGKyBLRoh+m7Pl2F733F6Ospj99UwRDcy/rtD
# hdy6/KbKMxkrd23bywXwfl91LqK2vzWqNmPJzmTZvfy8LPNJVgDIEivGJ7s3r1fv
# xM8eKcT04i3OKmHPV+31CkDi9RjWHumQL8rTh1+TikgaER3lN4WfLmZiml6BTpWs
# VVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4hu5/XanGAv5becgPY2CIr8ycWTzjoUUAM
# rpLvvj1994DGTDZXhJWnhBVIMA5SJwiNjqK9IscZyabKDqh6NttqumFfESSVpOKO
# aO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGHJNPE+6ljy3dI1fpi/CTgBHpO0ORu3s6e
# OFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV0NMe9n9S4kmNuRFyDIhEJjNmAUTf5DMO
# Id5iiUgH2vUwggfPMIIFt6ADAgECAgxK83pmt0FjEC8TCzUwDQYJKoZIhvcNAQEL
# BQAwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAw
# BgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIw
# MB4XDTI0MDQwMzE1NDExNloXDTI1MDQwNDE1NDExNlowggEOMR0wGwYDVQQPDBRQ
# cml2YXRlIE9yZ2FuaXphdGlvbjERMA8GA1UEBRMIMTMzMzczNDMxEzARBgsrBgEE
# AYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdCMRswGQYDVQQIExJHcmVhdGVyIE1hbmNo
# ZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0ZXIxGTAXBgNVBAkTEDE3IE1hcmJsZSBT
# dHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMSAwHgYDVQQD
# ExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEnMCUGCSqGSIb3DQEJARYYbWF0dC5t
# Y2tpbnN0cnlAY2xvdWRtLmlvMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEAngoTokY2HYu5xPv9s5LrBGLS72AwwIEk4huasmriK3lFC7ludj4D+m+khHMD
# GX/dAWmLDIvW3LiNcmfQtJYW28grUXCo95ZXP6nR8J/cI2iOtHHp2/HvfNVV60hz
# hZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq3f+CSOSZ4FdU6ISsAqZeRsazr/XA2b0a
# pQceLiYVPeORUNsIgfElvcCHhmA5jB8Sl/2F5JUpvPC58Tc53dQUWpz5dFW5Cav1
# BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj0E2TxzADesGjJ4CZ8PU8JTVBhIcb7d+9
# WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1ouCfJEsYeeBny8EQIy1lFuoLfBOGHf+t
# sT++wKHVkr4BjHhjOT+XwUItwXt/WmwKLuH0t6lgBHGlstap+6dBcQC66ZUCMi8O
# iZ8+3dM8ySiRO4UHBH26lSWc7oMYQexgX6O1XCgyxCX3MJfEcJrIlOEEBq11M9cH
# KvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W1b7LusHpyFwd3pRPpaF6pKloa7bmPm8R
# 6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7h9fTCdJMu0QADsLAokrZed2D6HKX/uCm
# J8fJwgxSalOUwyufT2r9LtRBr+fS6NNgHEhMP+pJxFajqpECAwEAAaOCAdswggHX
# MA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYBBQUHAQEEgZIwgY8wTAYIKwYBBQUHMAKG
# QGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2dzZ2NjcjQ1ZXZj
# b2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYBBQUHMAGGM2h0dHA6Ly9vY3NwLmdsb2Jh
# bHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMDBVBgNVHSAETjBMMEEG
# CSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWdu
# LmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAJBgNVHRMEAjAAMEcGA1UdHwRAMD4w
# PKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVz
# aWduY2EyMDIwLmNybDAjBgNVHREEHDAagRhtYXR0Lm1ja2luc3RyeUBjbG91ZG0u
# aW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMwHwYDVR0jBBgwFoAUJZ3Q/FkJhmPF7POx
# EztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp6FGOpQ5ruRZYclGhR1msMA0GCSqGSIb3
# DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlhqLQpOawqxF133UUTN4wKocLfqlsv9p1a
# 5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJomnX76vojinvqiLsNr0f2zKcquyfBmaCK
# xg+ubXXuWNhysM5602eelsSF5wFpKm1SmKAuvolB79Pq5uS2y8ZU37b9NkYulcyF
# DIPTuBSZydUvNQP4ATVocen0hIGkZFGfqnIowfyzFjvXU3+T9Vrc3BTAUoYEsUK0
# OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAolFZHqEfIy+K1HkWkq0dz4+bVpJlTqTAH
# HRIwoR5oe4GniTXTrH7/MlFzC+M4EriU7A0evdDRhxHA3D8IAMU2rS5rkQkk7h+r
# Q/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d9H8R46iW393Lg8vpitandd37zKUfUuvb
# G/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+ye29b4/3SJDk+3eZ+Agabmym+o40LTSBn
# g0jXHr+rbNm4z6Tooghd2dfoOPxzFC2VsVUK+WwCsJJZYa2upE49ayk2RI2QkZGg
# aXDk94woo6pBuYq+yGeyDm6a0rnuAimIxNDc3KNSLiaw48DP9nAYS8bO1yirSh77
# l/83vMoLySHTU3fvcHMLpnpCSRha6iYCz1q9xwrReCYrgJxc+y2IyxK95zGCAxUw
# ggMRAgEBMGwwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYt
# c2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBD
# QSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZIAWUDBAIBBQCgfDAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgEL
# MQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJWHZZvLn4LAlvCDSFc91
# 5dLqZuOuINCsTRY7XFgZk2MwDQYJKoZIhvcNAQEBBQAEggIAQ+QlkLCti3/dJJpg
# GdLseQg3zlJNlP/KzMMAYefb2WRXlu0p4CwZM0eMRdoG57EizJqax2MI+I7M1K/W
# EbOiA9qovlJQsw+SCCvyBT1HOmVC1wwyWBNbWQYr5z8f6jgTowkf7faj5MtCp/S3
# zni4S7pXkrDRxtrQa7Ta+ha41vqrZ58noxwQa04OSn3m/G4ZJ2rJH72A6fflmHip
# Ct9IvFzjm7+4Rtse8Q+eISsM9B/5dcmsQXeIqfWF08VTiaB2M46wQLkRgFmdHZqn
# Fu2ZXZi6XbYR9R6E9/NtNyKTk6uGIqWLmUEL44et6IBAdsiVzpIUfVIBviMYTjAk
# EwM+Cq7SqIJMFUrm5qD5ohLN0f25F2E1gz6FnOtDm2djBgPicaRLkgGF36JFrzGw
# 9s/Ml1JYUJ9UMfb3PBwFtFh/SBOR8hVIMrT8YMwp9Ve5r0sV7qODclBeFvNvkT0C
# BeHP0ANG4NpSoDj7gOAt4yBZdJwBjQFLv71fPCOpRZJFmNvGgEdh+wfvJ1BRKyhQ
# CWD1wblethEE74ty3HNB90xETLm6Ge5CuHC7JxnpzwPNdIJszWn1/9WJL1XptREc
# e8ZDuq6LZk+hmA50hDf4FjcMsCCyY3ikhj9DpPz/LNt1k5qp0e2KV8jGFCyNH/tn
# HTzAbWMODRIQJqLeSdBdRlc5X4EwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEP
# MA0GCWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4w
# JgIDAQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZI
# AWUDBAIBBQAEIOPpGC+lZEsaMJD6Xc6/SYGNmmLeAbR6WGXQBRCu6UgUoIIUZTCC
# BaIwggSKoAMCAQICEHgDGEJFcIpBz28BuO60qVQwDQYJKoZIhvcNAQEMBQAwTDEg
# MB4GA1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjMxEzARBgNVBAoTCkdsb2Jh
# bFNpZ24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMjAwNzI4MDAwMDAwWhcNMjkw
# MzE4MDAwMDAwWjBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBu
# di1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC2LcUw3Xroq5A9A3KwOkuZ
# FmGy5f+lZx03HOV+7JODqoT1o0ObmEWKuGNXXZsAiAQl6fhokkuC2EvJSgPzqH9q
# j4phJ72hRND99T8iwqNPkY2zBbIogpFd+1mIBQuXBsKY+CynMyTuUDpBzPCgsHsd
# TdKoWDiW6d/5G5G7ixAs0sdDHaIJdKGAr3vmMwoMWWuOvPSrWpd7f65V+4TwgP6E
# TNfiur3EdaFvvWEQdESymAfidKv/aNxsJj7pH+XgBIetMNMMjQN8VbgWcFwkeCAl
# 62dniKu6TjSYa3AR3jjK1L6hwJzh3x4CAdg74WdDhLbP/HS3L4Sjv7oJNz1nbLFF
# XBlhq0GD9awd63cNRkdzzr+9lZXtnSuIEP76WOinV+Gzz6ha6QclmxLEnoByPZPc
# jJTfO0TmJoD80sMD8IwM0kXWLuePmJ7mBO5Cbmd+QhZxYucE+WDGZKG2nIEhTivG
# bWiUhsaZdHNnMXqR8tSMeW58prt+Rm9NxYUSK8+aIkQIqIU3zgdhVwYXEiTAxDFz
# oZg1V0d+EDpF2S2kUZCYqaAHN8RlGqocaxZ396eX7D8ZMJlvMfvqQLLn0sT6ydDw
# UHZ0WfqNbRcyvvjpfgP054d1mtRKkSyFAxMCK0KA8olqNs/ITKDOnvjLja0Wp9Pe
# 1ZsYp8aSOvGCY/EuDiRk3wIDAQABo4IBdzCCAXMwDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFB8A
# v0aACvx4ObeltEPZVlC7zpY7MB8GA1UdIwQYMBaAFI/wS3+oLkUkrk1Q+mOai97i
# 3Ru8MHoGCCsGAQUFBwEBBG4wbDAtBggrBgEFBQcwAYYhaHR0cDovL29jc3AuZ2xv
# YmFsc2lnbi5jb20vcm9vdHIzMDsGCCsGAQUFBzAChi9odHRwOi8vc2VjdXJlLmds
# b2JhbHNpZ24uY29tL2NhY2VydC9yb290LXIzLmNydDA2BgNVHR8ELzAtMCugKaAn
# hiVodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jvb3QtcjMuY3JsMEcGA1UdIARA
# MD4wPAYEVR0gADA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWdu
# LmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwFAAOCAQEArPfMFYsweagdCyiI
# GQnXHH/+hr17WjNuDWcOe2LZ4RhcsL0TXR0jrjlQdjeqRP1fASNZhlZMzK28ZBMU
# MKQgqOA/6Jxy3H7z2Awjuqgtqjz27J+HMQdl9TmnUYJ14fIvl/bR4WWWg2T+oR1R
# +7Ukm/XSd2m8hSxc+lh30a6nsQvi1ne7qbQ0SqlvPfTzDZVd5vl6RbAlFzEu2/cP
# aOaDH6n35dSdmIzTYUsvwyh+et6TDrR9oAptksS0Zj99p1jurPfswwgBqzj8Chyp
# xZeyiMgJAhn2XJoa8U1sMNSzBqsAYEgNeKvPF62Sk2Igd3VsvcgytNxN69nfwZCW
# Kb3BfzCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQEL
# BQAwUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAn
# BgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcy
# ODAwMDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBF
# ViBDb2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3
# zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuU
# Dm0PpZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC
# 2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSA
# n9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5Ccxrjs
# zMl7ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsu
# z9riiTSmHyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjW
# O1roIs50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJz
# qwSwCdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2
# jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/
# thHxvvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0w
# ggGpMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMB
# Af8ECDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNV
# HSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMw
# OQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWdu
# aW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWdu
# LmNvbS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDag
# NKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0
# NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0
# cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJ
# KoZIhvcNAQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYX
# amsCT7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxN
# tT4GS8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3x
# K3LBFuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I
# +9MqkjPqV01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZ
# K3dt28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OIt
# ziphz1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+
# PGEPigu69T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeA
# xkw2V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7Q
# tDS91vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXX
# CSXUyQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1
# MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylH
# bG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0
# MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBP
# cmdhbml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMT
# AkdCMQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMw
# EQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAw
# HgYDVQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRN
# IFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5
# QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JG
# Nh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL
# 1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YE
# SmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3j
# kVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq
# 78/GYTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnI
# Mu5ErFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+
# AYx4Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMko
# kTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb
# 71/mugorh00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0
# KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpT
# lMMrn09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8B
# Af8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8v
# c2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25j
# YTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNv
# bS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAy
# AQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZo
# dHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAy
# MC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYR
# MB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOC
# AgEAyuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7h
# Z6hqCpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljY
# crDOetNnnpbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnV
# LzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIql
# u6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuB
# p4k106x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxD
# WbPuOgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv
# 2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZ
# uM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOq
# QbmKvshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh
# 01N373BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxggMVMIIDEQIBATBs
# MFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYD
# VQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIM
# SvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAw
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICVh2Wby5+CwJbwg0hXPdeXS6mbjriDQ
# rE0WO1xYGZNjMA0GCSqGSIb3DQEBAQUABIICAEPkJZCwrYt/3SSaYBnS7HkIN85S
# TZT/yszDAGHn29lkV5btKeAsGTNHjEXaBuexIsyamsdjCPiOzNSv1hGzogPaqL5S
# ULMPkggr8gU9RzplQtcMMlgTW1kGK+c/H+o4E6MJH+32o+TLQqf0t854uEu6V5Kw
# 0cba0Gu02voWuNb6q2efJ6McEGtODkp95vxuGSdqyR+9gOn35Zh4qQrfSLxc45u/
# uEbbHvEPniErDPQf+XXJrEF3iKn1hdPFU4mgdjOOsEC5EYBZnR2apxbtmV2Yul22
# EfUehPfzbTcik5OrhiKli5lBC+OHreiAQHbIlc6SFH1SAb4jGE4wJBMDPgqu0qiC
# TBVK5uag+aISzdH9uRdhNYM+hZzrQ5tnYwYD4nGkS5IBhd+iRa8xsPbPzJdSWFCf
# VDH29zwcBbRYf0gTkfIVSDK0/GDMKfVXua9LFe6jg3JQXhbzb5E9AgXhz9ADRuDa
# UqA4+4DgLeMgWXScAY0BS7+9XzwjqUWSRZjbxoBHYfsH7ydQUSsoUAlg9cG5XrYR
# BO+LctxzQfdMREy5uhnuQrhwuycZ6c8DzXSCbM1p9f/ViS9V6bURHHvGQ7qui2ZP
# oZgOdIQ3+BY3DLAgsmN4pIY/Q6T8/yzbdZOaqdHtilfIxhQsjR/7Zx08wG1jDg0S
# ECai3knQXUZXOV+BMIIuSQYJKoZIhvcNAQcCoIIuOjCCLjYCAQExDzANBglghkgB
# ZQMEAgEFADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQ
# H8w7YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUA
# BCDj6RgvpWRLGjCQ+l3Ov0mBjZpi3gG0elhl0AUQrulIFKCCJ2QwggWiMIIEiqAD
# AgECAhB4AxhCRXCKQc9vAbjutKlUMA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsT
# F0dsb2JhbFNpZ24gUm9vdCBDQSAtIFIzMRMwEQYDVQQKEwpHbG9iYWxTaWduMRMw
# EQYDVQQDEwpHbG9iYWxTaWduMB4XDTIwMDcyODAwMDAwMFoXDTI5MDMxODAwMDAw
# MFowUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAn
# BgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAti3FMN166KuQPQNysDpLmRZhsuX/pWcd
# NxzlfuyTg6qE9aNDm5hFirhjV12bAIgEJen4aJJLgthLyUoD86h/ao+KYSe9oUTQ
# /fU/IsKjT5GNswWyKIKRXftZiAULlwbCmPgspzMk7lA6QczwoLB7HU3SqFg4lunf
# +RuRu4sQLNLHQx2iCXShgK975jMKDFlrjrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWh
# b71hEHREspgH4nSr/2jcbCY+6R/l4ASHrTDTDI0DfFW4FnBcJHggJetnZ4iruk40
# mGtwEd44ytS+ocCc4d8eAgHYO+FnQ4S2z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/Ws
# Het3DUZHc86/vZWV7Z0riBD++ljop1fhs8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA
# /NLDA/CMDNJF1i7nj5ie5gTuQm5nfkIWcWLnBPlgxmShtpyBIU4rxm1olIbGmXRz
# ZzF6kfLUjHlufKa7fkZvTcWFEivPmiJECKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6
# RdktpFGQmKmgBzfEZRqqHGsWd/enl+w/GTCZbzH76kCy59LE+snQ8FB2dFn6jW0X
# Mr746X4D9OeHdZrUSpEshQMTAitCgPKJajbPyEygzp74y42tFqfT3tWbGKfGkjrx
# gmPxLg4kZN8CAwEAAaOCAXcwggFzMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3
# pbRD2VZQu86WOzAfBgNVHSMEGDAWgBSP8Et/qC5FJK5NUPpjmove4t0bvDB6Bggr
# BgEFBQcBAQRuMGwwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24u
# Y29tL3Jvb3RyMzA7BggrBgEFBQcwAoYvaHR0cDovL3NlY3VyZS5nbG9iYWxzaWdu
# LmNvbS9jYWNlcnQvcm9vdC1yMy5jcnQwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDov
# L2NybC5nbG9iYWxzaWduLmNvbS9yb290LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUd
# IAAwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wDQYJKoZIhvcNAQEMBQADggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9
# e1ozbg1nDnti2eEYXLC9E10dI645UHY3qkT9XwEjWYZWTMytvGQTFDCkIKjgP+ic
# ctx+89gMI7qoLao89uyfhzEHZfU5p1GCdeHyL5f20eFlloNk/qEdUfu1JJv10ndp
# vIUsXPpYd9Gup7EL4tZ3u6m0NEqpbz308w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XU
# nZiM02FLL8Mofnrekw60faAKbZLEtGY/fadY7qz37MMIAas4/AocqcWXsojICQIZ
# 9lyaGvFNbDDUswarAGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggYU
# MIID/KADAgECAhB6I67aU2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJ
# BgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNl
# Y3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAw
# MDAwWhcNMzYwMzIxMjM1OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2Vj
# dGlnbyBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1w
# aW5nIENBIFIzNjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENB
# q26CK+z2M34mNOSJjNPvIhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjf
# a3ajoW3cS3ElcJzkyZlBnwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpect
# RGhhnOSwcjPMI3G0hedv2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11Xx
# M2AVZn0GiOUC9+XE0wI7CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8W
# xTlA+uBvq1KO8RSHUQLgzb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp
# 6KNL19zpHsODLIsgZ+WZ1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9
# /CRezKe7WNyxRf4e4bwUtrYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaF
# Vhf5sMM/caEZLtOYqYadtn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQAB
# o4IBXDCCAVgwHwYDVR0jBBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0O
# BBYEFF9Y7UwxeqJhQo1SgLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMB
# Af8ECDAGAQH/AgEAMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBMBgNVHR8ERTBDMEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1Nl
# Y3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRw
# MG4wRwYIKwYBBQUHMAKGO2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY1RpbWVTdGFtcGluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8v
# b2NzcC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEd
# JVj9TC1ndK/HYiYh9lVUacahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5
# UkPCbXKspioYMdbOnBWQUn733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt
# 51UlmJElUICZYBodzD3M/SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nD
# O+Db8qNcTbJZRAiSazr7KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTq
# V2ifikkVtB3RNBUgwu/mSiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752
# LmESsRVVoypJVt8/N3qQ1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1g
# Qrnh1TA8ldXuJzPSuALOz1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pW
# SGH2opXZYKYG4Lbukg7HpNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0c
# Jqlmnx9HCDxF+3BLbUufrV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA
# 3DE8MORZeFb6BmzBtqKJ7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRri
# WklUPsetMSf2NvUQa/E5vVyefQIwggZdMIIExaADAgECAhA6UmoshM5V5h1l/MwS
# 2OmJMA0GCSqGSIb3DQEBDAUAMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0
# aWdvIExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBp
# bmcgQ0EgUjM2MB4XDTI0MDExNTAwMDAwMFoXDTM1MDQxNDIzNTk1OVowbjELMAkG
# A1UEBhMCR0IxEzARBgNVBAgTCk1hbmNoZXN0ZXIxGDAWBgNVBAoTD1NlY3RpZ28g
# TGltaXRlZDEwMC4GA1UEAxMnU2VjdGlnbyBQdWJsaWMgVGltZSBTdGFtcGluZyBT
# aWduZXIgUjM1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjdFn9MFI
# m739OEk6TWGBm8PY3EWlYQQ2jQae45iWgPXUGVuYoIa1xjTGIyuw3suUSBzKiyG0
# /c/Yn++d5mG6IyayljuGT9DeXQU9k8GWWj2/BPoamg2fFctnPsdTYhMGxM06z1+F
# t0Bav8ybww21ii/faiy+NhiUM195+cFqOtCpJXxZ/lm9tpjmVmEqpAlRpfGmLhNd
# kqiEuDFTuD1GsV3jvuPuPGKUJTam3P53U4LM0UCxeDI8Qz40Qw9TPar6S02XExlc
# 8X1YsiE6ETcTz+g1ImQ1OqFwEaxsMj/WoJT18GG5KiNnS7n/X4iMwboAg3IjpcvE
# zw4AZCZowHyCzYhnFRM4PuNMVHYcTXGgvuq9I7j4ke281x4e7/90Z5Wbk92RrLcS
# 35hO30TABcGx3Q8+YLRy6o0k1w4jRefCMT7b5mTxtq5XPmKvtgfPuaWPkGZ/tbxI
# nyNDA7YgOgccULjp4+D56g2iuzRCsLQ9ac6AN4yRbqCYsG2rcIQ5INTyI2JzA2w1
# vsAHPRbUTeqVLDuNOY2gYIoKBWQsPYVoyzaoBVU6O5TG+a1YyfWkgVVS9nXKs8hV
# ti3VpOV3aeuaHnjgC6He2CCDL9aW6gteUe0AmC8XCtWwpePx6QW3ROZo8vSUe9AR
# 7mMdu5+FzTmW8K13Bt8GX/YBFJO7LWzwKAUCAwEAAaOCAY4wggGKMB8GA1UdIwQY
# MBaAFF9Y7UwxeqJhQo1SgLqzYZcZojKbMB0GA1UdDgQWBBRo76QySWm2Ujgd6kM5
# LPQUap4MhTAOBgNVHQ8BAf8EBAMCBsAwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8E
# DDAKBggrBgEFBQcDCDBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDCDAlMCMGCCsG
# AQUFBwIBFhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAIwSgYDVR0f
# BEMwQTA/oD2gO4Y5aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGlj
# VGltZVN0YW1waW5nQ0FSMzYuY3JsMHoGCCsGAQUFBwEBBG4wbDBFBggrBgEFBQcw
# AoY5aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljVGltZVN0YW1w
# aW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNv
# bTANBgkqhkiG9w0BAQwFAAOCAYEAsNwuyfpPNkyKL/bJT9XvGE8fnw7Gv/4SetmO
# kjK9hPPa7/Nsv5/MHuVus+aXwRFqM5Vu51qfrHTwnVExcP2EHKr7IR+m/Ub7Pama
# eWfle5x8D0x/MsysICs00xtSNVxFywCvXx55l6Wg3lXiPCui8N4s51mXS0Ht85fk
# Xo3auZdo1O4lHzJLYX4RZovlVWD5EfwV6Ve1G9UMslnm6pI0hyR0Zr95QWG0MpNP
# P0u05SHjq/YkPlDee3yYOECNMqnZ+j8onoUtZ0oC8CkbOOk/AOoV4kp/6Ql2gEp3
# bNC7DOTlaCmH24DjpVgryn8FMklqEoK4Z3IoUgV8R9qQLg1dr6/BjghGnj2XNA8u
# jta2JyoxpqpvyETZCYIUjIs69YiDjzftt37rQVwIZsfCYv+DU5sh/StFL1x4rgNj
# 2t8GccUfa/V3iFFW9lfIJWWsvtlC5XOOOQswr1UmVdNWQem4LwrlLgcdO/YAnHqY
# 52QwnBLiAuUnuBeshWmfEb5oieIYMIIGgjCCBGqgAwIBAgIQNsKwvXwbOuejs902
# y8l1aDANBgkqhkiG9w0BAQwFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCk5l
# dyBKZXJzZXkxFDASBgNVBAcTC0plcnNleSBDaXR5MR4wHAYDVQQKExVUaGUgVVNF
# UlRSVVNUIE5ldHdvcmsxLjAsBgNVBAMTJVVTRVJUcnVzdCBSU0EgQ2VydGlmaWNh
# dGlvbiBBdXRob3JpdHkwHhcNMjEwMzIyMDAwMDAwWhcNMzgwMTE4MjM1OTU5WjBX
# MQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS4wLAYDVQQD
# EyVTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFJvb3QgUjQ2MIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAiJ3YuUVnnR3d6LkmgZpUVMB8SQWbzFoV
# D9mUEES0QUCBdxSZqdTkdizICFNeINCSJS+lV1ipnW5ihkQyC0cRLWXUJzodqpnM
# Rs46npiJPHrfLBOifjfhpdXJ2aHHsPHggGsCi7uE0awqKggE/LkYw3sqaBia67h/
# 3awoqNvGqiFRJ+OTWYmUCO2GAXsePHi+/JUNAax3kpqstbl3vcTdOGhtKShvZIvj
# wulRH87rbukNyHGWX5tNK/WABKf+Gnoi4cmisS7oSimgHUI0Wn/4elNd40BFdSZ1
# EwpuddZ+Wr7+Dfo0lcHflm/FDDrOJ3rWqauUP8hsokDoI7D/yUVI9DAE/WK3Jl3C
# 4LKwIpn1mNzMyptRwsXKrop06m7NUNHdlTDEMovXAIDGAvYynPt5lutv8lZeI5w3
# MOlCybAZDpK3Dy1MKo+6aEtE9vtiTMzz/o2dYfdP0KWZwZIXbYsTIlg1YIetCpi5
# s14qiXOpRsKqFKqav9R1R5vj3NgevsAsvxsAnI8Oa5s2oy25qhsoBIGo/zi6GpxF
# j+mOdh35Xn91y72J4RGOJEoqzEIbW3q0b2iPuWLA911cRxgY5SJYubvjay3nSMbB
# PPFsyl6mY4/WYucmyS9lo3l7jk27MAe145GWxK4O3m3gEFEIkv7kRmefDR7Oe2T1
# HxAnICQvr9sCAwEAAaOCARYwggESMB8GA1UdIwQYMBaAFFN5v1qqK0rPVIDh2JvA
# nfKyA2bLMB0GA1UdDgQWBBT2d2rdP/0BE/8WoWyCAi/QCj0UJTAOBgNVHQ8BAf8E
# BAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUEDDAKBggrBgEFBQcDCDARBgNV
# HSAECjAIMAYGBFUdIAAwUAYDVR0fBEkwRzBFoEOgQYY/aHR0cDovL2NybC51c2Vy
# dHJ1c3QuY29tL1VTRVJUcnVzdFJTQUNlcnRpZmljYXRpb25BdXRob3JpdHkuY3Js
# MDUGCCsGAQUFBwEBBCkwJzAlBggrBgEFBQcwAYYZaHR0cDovL29jc3AudXNlcnRy
# dXN0LmNvbTANBgkqhkiG9w0BAQwFAAOCAgEADr5lQe1oRLjlocXUEYfktzsljOt+
# 2sgXke3Y8UPEooU5y39rAARaAdAxUeiX1ktLJ3+lgxtoLQhn5cFb3GF2SSZRX8pt
# Q6IvuD3wz/LNHKpQ5nX8hjsDLRhsyeIiJsms9yAWnvdYOdEMq1W61KE9JlBkB20X
# Bee6JaXx4UBErc+YuoSb1SxVf7nkNtUjPfcxuFtrQdRMRi/fInV/AobE8Gw/8yBM
# QKKaHt5eia8ybT8Y/Ffa6HAJyz9gvEOcF1VWXG8OMeM7Vy7Bs6mSIkYeYtddU1ux
# 1dQLbEGur18ut97wgGwDiGinCwKPyFO7ApcmVJOtlw9FVJxw/mL1TbyBns4zOgka
# XFnnfzg4qbSvnrwyj1NiurMp4pmAWjR+Pb/SIduPnmFzbSN/G8reZCL4fvGlvPFk
# 4Uab/JVCSmj59+/mB2Gn6G/UYOy8k60mKcmaAZsEVkhOFuoj4we8CYyaR9vd9PGZ
# KSinaZIkvVjbH/3nlLb0a7SBIkiRzfPfS9T+JesylbHa1LtRV9U/7m0q7Ma2CQ/t
# 392ioOssXW7oKLdOmMBl14suVFBmbzrt5V5cQPnwtd3UOTpS9oCG+ZZheiIvPgkD
# mA8FzPsnfXW5qHELB43ET7HHFHeRPRYrMBKjkb8/IN7Po0d0hQoF4TeMM+zYAJzo
# KQnVKOLg8pZVPT8wggboMIIE0KADAgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0GCSqG
# SIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52
# LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTAe
# Fw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJFMRkw
# FwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdD
# QyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV1BlTt/2j
# F+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8qy+1
# o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gfSaNf
# +BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS13hMUQGSgt4T
# 8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXtHQcZxOsmd/KrbReTSam3
# 5sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmfvpMusgafJsAMAVYS4bKK
# nw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGlr3A2onmO3A1zwPHkLKuU
# 7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTlzbSY
# szcZJBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCXpxbmJouI9wNEhl9iZ0y1
# pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJi8Kr
# 77o6/elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB36Fl6CSDySrC/blTAgMB
# AAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# EgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztXHAOS
# NhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsGAQUFBwEB
# BIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9j
# b2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUuZ2xv
# YmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYDVR0f
# BDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmlu
# Z3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUH
# AgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeB
# DAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8DQdo
# mxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/UovG2XiULd5bpzXFAM4gp
# 7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQlQq+W
# VvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0jfShziq7vKxuav2xTpxSe
# PIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvfcXo6ymP31TBENzL+u0OF
# 3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgSK8YnuzevV+/E
# zx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFOlaxV
# V0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZPOOhRQAyu
# ku++PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoOqHo222q6YV8RJJWk4o5o
# 7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV+mL8JOAEek7Q5G7ezp44
# UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/kMw4h
# 3mKJSAfa9TCCB88wggW3oAMCAQICDErzema3QWMQLxMLNTANBgkqhkiG9w0BAQsF
# ADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAG
# A1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAw
# HhcNMjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8MFFBy
# aXZhdGUgT3JnYW5pemF0aW9uMREwDwYDVQQFEwgxMzMzNzM0MzETMBEGCysGAQQB
# gjc8AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hl
# c3RlcjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZMBcGA1UECRMQMTcgTWFyYmxlIFN0
# cmVldDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNVBAMT
# F0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0Lm1j
# a2luc3RyeUBjbG91ZG0uaW8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQCeChOiRjYdi7nE+/2zkusEYtLvYDDAgSTiG5qyauIreUULuW52PgP6b6SEcwMZ
# f90BaYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/qdHwn9wjaI60cenb8e981VXrSHOF
# lTRnLFv2BEpiqtH0as26jTyt8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZvRql
# Bx4uJhU945FQ2wiB8SW9wIeGYDmMHxKX/YXklSm88LnxNznd1BRanPl0VbkJq/UF
# 0FfzN913qu/PxmE5gpak+QQr3JPYtCPQTZPHMAN6waMngJnw9TwlNUGEhxvt371Y
# 2FxovdUZyDLuRKxUq7cKexhb2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd/62x
# P77AodWSvgGMeGM5P5fBQi3Be39abAou4fS3qWAEcaWy1qn7p0FxALrplQIyLw6J
# nz7d0zzJKJE7hQcEfbqVJZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz1wcq
# +Fy6l+4Km+9f5roKK4dNFETf5srRH5bVvsu6wenIXB3elE+loXqkqWhrtuY+bxHo
# Z1wW1W6FNCh0a9eacSpqBccPahqghnuH19MJ0ky7RAAOwsCiStl53YPocpf+4KYn
# x8nCDFJqU5TDK59Pav0u1EGv59Lo02AcSEw/6knEVqOqkQIDAQABo4IB2zCCAdcw
# DgYDVR0PAQH/BAQDAgeAMIGfBggrBgEFBQcBAQSBkjCBjzBMBggrBgEFBQcwAoZA
# aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVldmNv
# ZGVzaWduY2EyMDIwLmNydDA/BggrBgEFBQcwAYYzaHR0cDovL29jc3AuZ2xvYmFs
# c2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwMFUGA1UdIAROMEwwQQYJ
# KwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24u
# Y29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAwPjA8
# oDqgOIY2aHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNp
# Z25jYTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5p
# bzATBgNVHSUEDDAKBggrBgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs87ET
# O1ccA5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6lDmu5FlhyUaFHWawwDQYJKoZIhvcN
# AQELBQADggIBAMriJ8rqBFu9wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2nVrl
# 892cPNQe4WeoagqZ1a0c7SRPijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7J8GZoIrG
# D65tde5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTftv02Ri6VzIUM
# g9O4FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBShgSxQrQ5
# Li4lw4SKpburQecVnB6f7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOpMAcd
# EjChHmh7gaeJNdOsfv8yUXML4zgSuJTsDR690NGHEcDcPwgAxTatLmuRCSTuH6tD
# /gG4ES38Q1mz7joDNkpR79/IzKfYHl30fxHjqJbf3cuDy+mK1qd13fvMpR9S69sb
# 8bPdJDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj/dIkOT7d5n4CBpubKb6jjQtNIGeD
# SNcev6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5bAKwkllhra6kTj1rKTZEjZCRkaBp
# cOT3jCijqkG5ir7IZ7IObprSue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtKHvuX
# /ze8ygvJIdNTd+9wcwumekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3nMYIGOzCC
# BjcCAQEwbDBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1z
# YTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENB
# IDIwMjACDErzema3QWMQLxMLNTANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcC
# AQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsx
# DjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAlYdlm8ufgsCW8INIVz3Xl
# 0upm464g0KxNFjtcWBmTYzANBgkqhkiG9w0BAQEFAASCAgBD5CWQsK2Lf90kmmAZ
# 0ux5CDfOUk2U/8rMwwBh59vZZFeW7SngLBkzR4xF2gbnsSLMmprHYwj4jszUr9YR
# s6ID2qi+UlCzD5IIK/IFPUc6ZULXDDJYE1tZBivnPx/qOBOjCR/t9qPky0Kn9LfO
# eLhLuleSsNHG2tBrtNr6FrjW+qtnnyejHBBrTg5Kfeb8bhknaskfvYDp9+WYeKkK
# 30i8XOObv7hG2x7xD54hKwz0H/l1yaxBd4ip9YXTxVOJoHYzjrBAuRGAWZ0dmqcW
# 7ZldmLpdthH1HoT38203IpOTq4YipYuZQQvjh63ogEB2yJXOkhR9UgG+IxhOMCQT
# Az4KrtKogkwVSubmoPmiEs3R/bkXYTWDPoWc60ObZ2MGA+JxpEuSAYXfokWvMbD2
# z8yXUlhQn1Qx9vc8HAW0WH9IE5HyFUgytPxgzCn1V7mvSxXuo4NyUF4W82+RPQIF
# 4c/QA0bg2lKgOPuA4C3jIFl0nAGNAUu/vV88I6lFkkWY28aAR2H7B+8nUFErKFAJ
# YPXBuV62EQTvi3Lcc0H3TERMuboZ7kK4cLsnGenPA810gmzNafX/1YkvVem1ERx7
# xkO6rotmT6GYDnSEN/gWNwywILJjeKSGP0Ok/P8s23WTmqnR7YpXyMYULI0f+2cd
# PMBtYw4NEhAmot5J0F1GVzlfgaGCAyIwggMeBgkqhkiG9w0BCQYxggMPMIIDCwIB
# ATBpMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLDAq
# BgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcgQ0EgUjM2AhA6Umos
# hM5V5h1l/MwS2OmJMA0GCWCGSAFlAwQCAgUAoHkwGAYJKoZIhvcNAQkDMQsGCSqG
# SIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjQxMDA0MTMxNzQ2WjA/BgkqhkiG9w0B
# CQQxMgQwJ5XV19+pH6PnNbD/atOtUg4lT6uQWoPdUavstTJkUpjbPf7U2Wsim3m3
# K7FQpHBGMA0GCSqGSIb3DQEBAQUABIICAC7aYXp5s/GpEvE4DZ44r4WV8mwTKE00
# ghKdB8kfX5qoeNNpd73z6sN8+/emreR0JsXYisRAVfUndATAPn5AQAgw9jXF621H
# BdVut5nFb5yhSjbzCWpNGeQ1PnWfrbWi2qaWvVVOfFhqR6TQvH2Gori2SzPgJc5E
# A9zHuS37sMtITdBn4xB+wQdyul+76axXpa2Zx3DlauUXjRoBqtq7N5JGlMead807
# qImKUlR7aiolSl+cVm3l/HaE4DjkfMCMf4uYY7NZIApCY+StV91J6EkMJQXMbXAG
# gCdRklmclloetGzOTHCFtobgpqcOouAFXpYQs+sTSLGSXK05N0v66CoHkIKw5p5O
# opEXp0asB0qAokq0zKRid2rfm+fYqYKip07bTc+kypbL1WsEG098cJF23QmJXblo
# qRrD8O1yJrmMPz9v8ZcwmpqL4l6EJV+OyICD75+J55rCyCOYkqiEdwhHgPiEidrO
# vO9FhF68jKPMQK6ovhNm7VcwO7j8/S00Azan6XgSelFmMFCBag894nrsa7kjZD91
# lN24YtQDwMgLqQffC1gq0fYrmNAes6eg/cVXzwUWM8ujGUay4wPrOKnPyfuOmznD
# 2R0LMm1WFGha90Ztn5Gx+lzsbaEAWo32BQ3wTmYKcYi4FlDqTN6QMJdvvUOs6BsD
# PwgxTznCVLGp
# SIG # End signature block
