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
# MILVcgYJKoZIhvcNAQcCoILVYzCC1V8CAQExDTALBglghkgBZQMEAgEweQYKKwYB
# BAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+
# 81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQg4+kYL6VkSxowkPpd
# zr9JgY2aYt4BtHpYZdAFEK7pSBSggidoMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv
# 21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMM
# RGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQD
# ExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcN
# MzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQg
# SW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2Vy
# dCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf
# 8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1
# mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe
# 7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecx
# y9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX
# 2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX
# 9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp49
# 3ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCq
# sWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFH
# dL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauG
# i0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYw
# DwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08w
# HwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGG
# MHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0
# dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5j
# cmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXn
# OF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23
# OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFI
# tJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7s
# pNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgi
# wbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cB
# qZ9Xql4o4rmUMIIFojCCBIqgAwIBAgIQeAMYQkVwikHPbwG47rSpVDANBgkqhkiG
# 9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzETMBEG
# A1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjAeFw0yMDA3Mjgw
# MDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBH
# bG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmlu
# ZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALYtxTDd
# euirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uYRYq4Y1ddmwCIBCXp+GiS
# S4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiCkV37WYgFC5cGwpj4LKcz
# JO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0oYCve+YzCgxZa4689Kta
# l3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o3GwmPukf5eAEh60w0wyN
# A3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHfHgIB2DvhZ0OEts/8dLcv
# hKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2dK4gQ/vpY6KdX4bPPqFrp
# ByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+YnuYE7kJuZ35CFnFi5wT5
# YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35Gb03FhRIrz5oiRAiohTfO
# B2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUaqhxrFnf3p5fsPxkwmW8x
# ++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2z8hM
# oM6e+MuNrRan097VmxinxpI68YJj8S4OJGTfAgMBAAGjggF3MIIBczAOBgNVHQ8B
# Af8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYDVR0TAQH/BAUwAwEB/zAd
# BgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYDVR0jBBgwFoAUj/BLf6gu
# RSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0GCCsGAQUFBzABhiFodHRw
# Oi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYIKwYBBQUHMAKGL2h0dHA6
# Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jvb3QtcjMuY3J0MDYGA1Ud
# HwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vcm9vdC1yMy5j
# cmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3
# Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4IBAQCs
# 98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFywvRNdHSOuOVB2N6pE/V8B
# I1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbsn4cxB2X1OadRgnXh8i+X
# 9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LWd7uptDRKqW899PMNlV3m
# +XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMOtH2gCm2SxLRmP32nWO6s
# 9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBgSA14q88XrZKTYiB3dWy9
# yDK03E3r2d/BkJYpvcF/MIIGrjCCBJagAwIBAgIQBzY3tyRUfNhHrP0oZipeWzAN
# BgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQg
# SW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2Vy
# dCBUcnVzdGVkIFJvb3QgRzQwHhcNMjIwMzIzMDAwMDAwWhcNMzcwMzIyMjM1OTU5
# WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNV
# BAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1w
# aW5nIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxoY1BkmzwT1y
# SVFVxyUDxPKRN6mXUaHW0oPRnkyibaCwzIP5WvYRoUQVQl+kiPNo+n3znIkLf50f
# ng8zH1ATCyZzlm34V6gCff1DtITaEfFzsbPuK4CEiiIY3+vaPcQXf6sZKz5C3GeO
# 6lE98NZW1OcoLevTsbV15x8GZY2UKdPZ7Gnf2ZCHRgB720RBidx8ald68Dd5n12s
# y+iEZLRS8nZH92GDGd1ftFQLIWhuNyG7QKxfst5Kfc71ORJn7w6lY2zkpsUdzTYN
# XNXmG6jBZHRAp8ByxbpOH7G1WE15/tePc5OsLDnipUjW8LAxE6lXKZYnLvWHpo9O
# dhVVJnCYJn+gGkcgQ+NDY4B7dW4nJZCYOjgRs/b2nuY7W+yB3iIU2YIqx5K/oN7j
# PqJz+ucfWmyU8lKVEStYdEAoq3NDzt9KoRxrOMUp88qqlnNCaJ+2RrOdOqPVA+C/
# 8KI8ykLcGEh/FDTP0kyr75s9/g64ZCr6dSgkQe1CvwWcZklSUPRR8zZJTYsg0ixX
# NXkrqPNFYLwjjVj33GHek/45wPmyMKVM1+mYSlg+0wOI/rOP015LdhJRk8mMDDtb
# iiKowSYI+RQQEgN9XyO7ZONj4KbhPvbCdLI/Hgl27KtdRnXiYKNYCQEoAA6EVO7O
# 6V3IXjASvUaetdN2udIOa5kM0jO0zbECAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHQYDVR0OBBYEFLoW2W1NhS9zKXaaL3WMaiCPnshvMB8GA1UdIwQY
# MBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUE
# DDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDww
# OjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0G
# CSqGSIb3DQEBCwUAA4ICAQB9WY7Ak7ZvmKlEIgF+ZtbYIULhsBguEE0TzzBTzr8Y
# +8dQXeJLKftwig2qKWn8acHPHQfpPmDI2AvlXFvXbYf6hCAlNDFnzbYSlm/EUExi
# HQwIgqgWvalWzxVzjQEiJc6VaT9Hd/tydBTX/6tPiix6q4XNQ1/tYLaqT5Fmniye
# 4Iqs5f2MvGQmh2ySvZ180HAKfO+ovHVPulr3qRCyXen/KFSJ8NWKcXZl2szwcqMj
# +sAngkSumScbqyQeJsG33irr9p6xeZmBo1aGqwpFyd/EjaDnmPv7pp1yr8THwcFq
# cdnGE4AJxLafzYeHJLtPo0m5d2aR8XKc6UsCUqc3fpNTrDsdCEkPlM05et3/JWOZ
# Jyw9P2un8WbDQc1PtkCbISFA0LcTJM3cHXg65J6t5TRxktcma+Q4c6umAU+9Pzt4
# rUyt+8SVe+0KXzM5h0F4ejjpnOHdI/0dKNPH+ejxmF/7K9h+8kaddSweJywm228V
# ex4Ziza4k9Tm8heZWcpw8De/mADfIBZPJ/tgZxahZrrdVcA6KYawmKAr7ZVBtzrV
# FZgxtGIJDwq9gdkT/r+k0fNX2bwE+oLeMt8EifAAzV3C+dAjfwAL5HYCJtnwZXZC
# pimHCUcr5n8apIUP/JiW9lVUKx+A+sDyDivl1vupL0QVSucTDh3bNzgaoSv27dZ8
# /DCCBrwwggSkoAMCAQICEAuuZrxaun+Vh8b56QTjMwQwDQYJKoZIhvcNAQELBQAw
# YzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQD
# EzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGlu
# ZyBDQTAeFw0yNDA5MjYwMDAwMDBaFw0zNTExMjUyMzU5NTlaMEIxCzAJBgNVBAYT
# AlVTMREwDwYDVQQKEwhEaWdpQ2VydDEgMB4GA1UEAxMXRGlnaUNlcnQgVGltZXN0
# YW1wIDIwMjQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC+anOf9pUh
# q5Ywultt5lmjtej9kR8YxIg7apnjpcH9CjAgQxK+CMR0Rne/i+utMeV5bUlYYSuu
# M4vQngvQepVHVzNLO9RDnEXvPghCaft0djvKKO+hDu6ObS7rJcXa/UKvNminKQPT
# v/1+kBPgHGlP28mgmoCw/xi6FG9+Un1h4eN6zh926SxMe6We2r1Z6VFZj75MU/HN
# mtsgtFjKfITLutLWUdAoWle+jYZ49+wxGE1/UXjWfISDmHuI5e/6+NfQrxGFSKx+
# rDdNMsePW6FLrphfYtk/FLihp/feun0eV+pIF496OVh4R1TvjQYpAztJpVIfdNsE
# vxHofBf1BWkadc+Up0Th8EifkEEWdX4rA/FE1Q0rqViTbLVZIqi6viEk3RIySho1
# XyHLIAOJfXG5PEppc3XYeBH7xa6VTZ3rOHNeiYnY+V4j1XbJ+Z9dI8ZhqcaDHOoj
# 5KGg4YuiYx3eYm33aebsyF6eD9MF5IDbPgjvwmnAalNEeJPvIeoGJXaeBQjIK13S
# lnzODdLtuThALhGtyconcVuPI8AaiCaiJnfdzUcb3dWnqUnjXkRFwLtsVAxFvGqs
# xUA2Jq/WTjbnNjIUzIs3ITVC6VBKAOlb2u29Vwgfta8b2ypi6n2PzP0nVepsFk8n
# lcuWfyZLzBaZ0MucEdeBiXL+nUOGhCjl+QIDAQABo4IBizCCAYcwDgYDVR0PAQH/
# BAQDAgeAMAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW2W1N
# hS9zKXaaL3WMaiCPnshvMB0GA1UdDgQWBBSfVywDdw4oFZBmpWNe7k+SH3agWzBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQBggr
# BgEFBQcBAQSBgzCBgDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMFgGCCsGAQUFBzAChkxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkRzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0MA0G
# CSqGSIb3DQEBCwUAA4ICAQA9rR4fdplb4ziEEkfZQ5H2EdubTggd0ShPz9Pce4FL
# Jl6reNKLkZd5Y/vEIqFWKt4oKcKz7wZmXa5VgW9B76k9NJxUl4JlKwyjUkKhk3aY
# x7D8vi2mpU1tKlY71AYXB8wTLrQeh83pXnWwwsxc1Mt+FWqz57yFq6laICtKjPIC
# YYf/qgxACHTvypGHrC8k1TqCeHk6u4I/VBQC9VK7iSpU5wlWjNlHlFFv/M93748Y
# TeoXU/fFa9hWJQkuzG2+B7+bMDvmgF8VlJt1qQcl7YFUMYgZU1WM6nyw23vT6QSg
# wX5Pq2m0xQ2V6FJHu8z4LXe/371k5QrN9FQBhLLISZi2yemW0P8ZZfx4zvSWzVXp
# Ab9k4Hpvpi6bUe8iK6WonUSV6yPlMwerwJZP/Gtbu3CKldMnn+LmmRTkTXpFIEB0
# 6nXZrDwhCGED+8RsWQSIXZpuG4WLFQOhtloDRWGoCwwc6ZpPddOFkM2LlTbMcqFS
# zm4cd0boGhBq7vkqI1uHRz6Fq1IX7TaRQuR+0BGOzISkcqwXu7nMpFu3mgrlgbAW
# +BzikRVQ3K2YHcGkiKjA4gi4OA/kz1YCsdhIBHXqBzR0/Zd2QwQ/l4Gxftt/8wY3
# grcc/nS//TVkej9nmUYu83BDtccHHXKibMs/yXHhDXNkoPIdynhVAku7aRZOwqw6
# pDCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQELBQAw
# UzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNV
# BAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAw
# MDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBD
# b2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3zhGj
# +aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuUDm0P
# pZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC2qQT
# L4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSAn9Kk
# FQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5CcxrjszMl7
# ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsuz9ri
# iTSmHyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjWO1ro
# Is50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJzqwSw
# CdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2jG7P
# bTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/thHx
# vvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0wggGp
# MA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8E
# CDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNVHSME
# GDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYI
# KwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5n
# cm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNv
# bS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAy
# hjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5j
# cmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6
# Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJKoZI
# hvcNAQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYXamsC
# T7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxNtT4G
# S8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3xK3LB
# FuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I+9Mq
# kjPqV01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZK3dt
# 28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OItziph
# z1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+PGEP
# igu69T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeAxkw2
# V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7QtDS9
# 1vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXXCSXU
# yQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1MIIH
# zzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJBgNV
# BAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9i
# YWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0MDMx
# NTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdh
# bml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMTAkdC
# MQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMwEQYD
# VQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAwHgYD
# VQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRNIFNv
# ZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5QGNs
# b3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JGNh2L
# ucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL1ty4
# jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YESmKq
# 0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3jkVDb
# CIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq78/G
# YTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnIMu5E
# rFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+AYx4
# Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMkokTuF
# BwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb71/m
# ugorh00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0KHRr
# 15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpTlMMr
# n09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8BAf8E
# BAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8vc2Vj
# dXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25jYTIw
# MjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9n
# c2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIw
# NDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3Np
# dG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZodHRw
# Oi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5j
# cmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYRMB0G
# A1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOCAgEA
# yuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7hZ6hq
# CpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljYcrDO
# etNnnpbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnVLzUD
# +AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIqlu6tB
# 5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuBp4k1
# 06x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxDWbPu
# OgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv2Zw7
# xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZuM+k
# 6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOqQbmK
# vshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh01N3
# 73BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxgq1iMIKtXgIBATBsMFwx
# CzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQD
# EylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMSvN6
# ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJ
# KoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQB
# gjcCARUwLwYJKoZIhvcNAQkEMSIEICVh2Wby5+CwJbwg0hXPdeXS6mbjriDQrE0W
# O1xYGZNjMA0GCSqGSIb3DQEBAQUABIICAEPkJZCwrYt/3SSaYBnS7HkIN85STZT/
# yszDAGHn29lkV5btKeAsGTNHjEXaBuexIsyamsdjCPiOzNSv1hGzogPaqL5SULMP
# kggr8gU9RzplQtcMMlgTW1kGK+c/H+o4E6MJH+32o+TLQqf0t854uEu6V5Kw0cba
# 0Gu02voWuNb6q2efJ6McEGtODkp95vxuGSdqyR+9gOn35Zh4qQrfSLxc45u/uEbb
# HvEPniErDPQf+XXJrEF3iKn1hdPFU4mgdjOOsEC5EYBZnR2apxbtmV2Yul22EfUe
# hPfzbTcik5OrhiKli5lBC+OHreiAQHbIlc6SFH1SAb4jGE4wJBMDPgqu0qiCTBVK
# 5uag+aISzdH9uRdhNYM+hZzrQ5tnYwYD4nGkS5IBhd+iRa8xsPbPzJdSWFCfVDH2
# 9zwcBbRYf0gTkfIVSDK0/GDMKfVXua9LFe6jg3JQXhbzb5E9AgXhz9ADRuDaUqA4
# +4DgLeMgWXScAY0BS7+9XzwjqUWSRZjbxoBHYfsH7ydQUSsoUAlg9cG5XrYRBO+L
# ctxzQfdMREy5uhnuQrhwuycZ6c8DzXSCbM1p9f/ViS9V6bURHHvGQ7qui2ZPoZgO
# dIQ3+BY3DLAgsmN4pIY/Q6T8/yzbdZOaqdHtilfIxhQsjR/7Zx08wG1jDg0SECai
# 3knQXUZXOV+BoYKqSTCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEBMHcwYzELMAkG
# A1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdp
# Q2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQQIQ
# C65mvFq6f5WHxvnpBOMzBDANBglghkgBZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzEL
# BgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MTAwNDEzMDg1OVowLwYJKoZI
# hvcNAQkEMSIEIFIl8oJ0DMN/K4Dzp1DLH8wwaDTAyYu5iTA26akcIDagMA0GCSqG
# SIb3DQEBAQUABIICAIDaGRal2XQYOWfzm4lnZcDz5Te9wQpSnHPCal8BZcSUOtT6
# uW37euBeDvY6fnfDqvSXe6YauZvX55vv4OsmmzZeAuFXCVmfUdaatA7fLMoaSmAq
# SijdHOSat/AvDdvs5hdas8BFhDc0YUfGy0j+KdV4L7kkcKl0di0Dvp8TtWz5DaD7
# SOR60sXguGHfUwdcL+4qavs/TlMID7dLy5Q1Es0GfxzbWng9bdXmRIt73bshQxOd
# gKviRlOFKpo8vA0ljcPYqBxVrSUsMmcNGDUK+hV0CurvmqnQJQwFXIXjnfcAlPmK
# czZ+72DFsJ+9S6B5Eb1q8J0EJs38gqRGJDJpPwECPnTVw5FrTJMpJ19vZQUkaFyM
# x8PlVTQvyQla2Tzu5B6LFqv0NbHCPn6z5CiLazan9G1E7TAaDw9vW+hv3QiU9hti
# NlOTqT5HS3gyZb7b5yZZ2ybyHY6CLCudBPUdcysZ6kH4BQBJTHscVjsdaHzwtkJP
# enzJZD23bPTTP3W9zCmoktVDFhofIQGJqMVY5iZStapRMFUXoyD8qBUVxX8HoDYI
# jZffeU/M2Fr9XTWED3ZF98Tkj5q1fYsMi1qjyasXlA8rOgvo4BsCg2PMzF3Mw+gN
# H5oYKbonaH9hBC/ajZptJbwjcTd6IL9PGHW6Qp2sFS+5OF91QVR11f1CCZ8XMIKn
# JQYKKwYBBAGCNwIEATGCpxUwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEPMA0G
# CWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4wJgID
# AQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUD
# BAIBBQAEIBbq6SusIBLk1T/QAbmR2QMawTysKiIEHe8ivwbbGod0oIIUZTCCBaIw
# ggSKoAMCAQICEHgDGEJFcIpBz28BuO60qVQwDQYJKoZIhvcNAQEMBQAwTDEgMB4G
# A1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjMxEzARBgNVBAoTCkdsb2JhbFNp
# Z24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMjAwNzI4MDAwMDAwWhcNMjkwMzE4
# MDAwMDAwWjBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1z
# YTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC2LcUw3Xroq5A9A3KwOkuZFmGy
# 5f+lZx03HOV+7JODqoT1o0ObmEWKuGNXXZsAiAQl6fhokkuC2EvJSgPzqH9qj4ph
# J72hRND99T8iwqNPkY2zBbIogpFd+1mIBQuXBsKY+CynMyTuUDpBzPCgsHsdTdKo
# WDiW6d/5G5G7ixAs0sdDHaIJdKGAr3vmMwoMWWuOvPSrWpd7f65V+4TwgP6ETNfi
# ur3EdaFvvWEQdESymAfidKv/aNxsJj7pH+XgBIetMNMMjQN8VbgWcFwkeCAl62dn
# iKu6TjSYa3AR3jjK1L6hwJzh3x4CAdg74WdDhLbP/HS3L4Sjv7oJNz1nbLFFXBlh
# q0GD9awd63cNRkdzzr+9lZXtnSuIEP76WOinV+Gzz6ha6QclmxLEnoByPZPcjJTf
# O0TmJoD80sMD8IwM0kXWLuePmJ7mBO5Cbmd+QhZxYucE+WDGZKG2nIEhTivGbWiU
# hsaZdHNnMXqR8tSMeW58prt+Rm9NxYUSK8+aIkQIqIU3zgdhVwYXEiTAxDFzoZg1
# V0d+EDpF2S2kUZCYqaAHN8RlGqocaxZ396eX7D8ZMJlvMfvqQLLn0sT6ydDwUHZ0
# WfqNbRcyvvjpfgP054d1mtRKkSyFAxMCK0KA8olqNs/ITKDOnvjLja0Wp9Pe1ZsY
# p8aSOvGCY/EuDiRk3wIDAQABo4IBdzCCAXMwDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFB8Av0aA
# Cvx4ObeltEPZVlC7zpY7MB8GA1UdIwQYMBaAFI/wS3+oLkUkrk1Q+mOai97i3Ru8
# MHoGCCsGAQUFBwEBBG4wbDAtBggrBgEFBQcwAYYhaHR0cDovL29jc3AuZ2xvYmFs
# c2lnbi5jb20vcm9vdHIzMDsGCCsGAQUFBzAChi9odHRwOi8vc2VjdXJlLmdsb2Jh
# bHNpZ24uY29tL2NhY2VydC9yb290LXIzLmNydDA2BgNVHR8ELzAtMCugKaAnhiVo
# dHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jvb3QtcjMuY3JsMEcGA1UdIARAMD4w
# PAYEVR0gADA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNv
# bS9yZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwFAAOCAQEArPfMFYsweagdCyiIGQnX
# HH/+hr17WjNuDWcOe2LZ4RhcsL0TXR0jrjlQdjeqRP1fASNZhlZMzK28ZBMUMKQg
# qOA/6Jxy3H7z2Awjuqgtqjz27J+HMQdl9TmnUYJ14fIvl/bR4WWWg2T+oR1R+7Uk
# m/XSd2m8hSxc+lh30a6nsQvi1ne7qbQ0SqlvPfTzDZVd5vl6RbAlFzEu2/cPaOaD
# H6n35dSdmIzTYUsvwyh+et6TDrR9oAptksS0Zj99p1jurPfswwgBqzj8ChypxZey
# iMgJAhn2XJoa8U1sMNSzBqsAYEgNeKvPF62Sk2Igd3VsvcgytNxN69nfwZCWKb3B
# fzCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQELBQAw
# UzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNV
# BAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAw
# MDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBD
# b2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3zhGj
# +aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuUDm0P
# pZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC2qQT
# L4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSAn9Kk
# FQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5CcxrjszMl7
# ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsuz9ri
# iTSmHyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjWO1ro
# Is50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJzqwSw
# CdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2jG7P
# bTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/thHx
# vvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0wggGp
# MA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8E
# CDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNVHSME
# GDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYI
# KwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5n
# cm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNv
# bS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAy
# hjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5j
# cmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6
# Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJKoZI
# hvcNAQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYXamsC
# T7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxNtT4G
# S8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3xK3LB
# FuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I+9Mq
# kjPqV01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZK3dt
# 28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OItziph
# z1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+PGEP
# igu69T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeAxkw2
# V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7QtDS9
# 1vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXXCSXU
# yQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1MIIH
# zzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJBgNV
# BAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9i
# YWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0MDMx
# NTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdh
# bml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMTAkdC
# MQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMwEQYD
# VQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAwHgYD
# VQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRNIFNv
# ZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5QGNs
# b3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JGNh2L
# ucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL1ty4
# jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YESmKq
# 0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3jkVDb
# CIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq78/G
# YTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnIMu5E
# rFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+AYx4
# Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMkokTuF
# BwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb71/m
# ugorh00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0KHRr
# 15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpTlMMr
# n09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8BAf8E
# BAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8vc2Vj
# dXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25jYTIw
# MjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9n
# c2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIw
# NDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3Np
# dG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZodHRw
# Oi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5j
# cmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYRMB0G
# A1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOCAgEA
# yuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7hZ6hq
# CpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljYcrDO
# etNnnpbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnVLzUD
# +AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIqlu6tB
# 5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuBp4k1
# 06x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxDWbPu
# OgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv2Zw7
# xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZuM+k
# 6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOqQbmK
# vshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh01N3
# 73BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxggMVMIIDEQIBATBsMFwx
# CzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQD
# EylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMSvN6
# ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJ
# KoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQB
# gjcCARUwLwYJKoZIhvcNAQkEMSIEIC0GzN676Q+O3ZVionUC5WQDwp4o7Y0R2cOp
# /Idx/JscMA0GCSqGSIb3DQEBAQUABIICAG1IA3eCk1aUzaJCoBrxoJyNjfW6fp/m
# VIHG4jtvZGN2VXolkeSc5I755OEPWVyPqtrVR+TKG9WYaECFYjOEGhIdCMPSJOjt
# CS9wrDwxvOARIl1RrmUyPMxb96gJ0vTyAs5NNan9MgyxRVdwMoifR0LJG00afUiQ
# AI8I4KpPKQfFdtdHfJXp9VqhZIVE722sK2x9S/B0aB0K12DEm67PqWKNlG3I7WJk
# r2IODHzCvvEnxCiqTbF2yYf05f02nl2aCNrrrjJErbGmkEGKyJZO3HSEHblZhJDc
# qXE84WvbSTp4h/SSf6hBBMnf3jptVuxVEZ4KyQl5iQep7iBi9NOUXcgzpvuTqUi6
# cP17NWyJ0CrGdJejuEl5XGQ3vb+yud4zHA/x/ML0u7NO7OJ/7800HX2mUAv0wvoV
# rcuYmkb3eOG6tI/mVfrNYNfwkPkg1Qrhrzt30A9j3SV7zBPXas7rKxBJDdsQJrzA
# 63tQ/ZwuppvN5Tu2j5LlijheOZgwFrpDj5QTb3i/v0vLs32DO3xXMJpcTeQH9Kci
# xIl/t9Eof9YPbOFW1QZ2xKUFa2G+Ab7BZVFhDoXUunmZWjk3Ev4pJpgpiPqILiSF
# L8NZ+Yc1jDMqA1lg5A31wzjuq3KClJhcr/DBbKaEpUZSszOH4jy4AJeY8bG+Q+CA
# wdOmV1wD4bXTMIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQME
# AgEFADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7
# YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDj
# 6RgvpWRLGjCQ+l3Ov0mBjZpi3gG0elhl0AUQrulIFKCCFGUwggWiMIIEiqADAgEC
# AhB4AxhCRXCKQc9vAbjutKlUMA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsTF0ds
# b2JhbFNpZ24gUm9vdCBDQSAtIFIzMRMwEQYDVQQKEwpHbG9iYWxTaWduMRMwEQYD
# VQQDEwpHbG9iYWxTaWduMB4XDTIwMDcyODAwMDAwMFoXDTI5MDMxODAwMDAwMFow
# UzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNV
# BAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAti3FMN166KuQPQNysDpLmRZhsuX/pWcdNxzl
# fuyTg6qE9aNDm5hFirhjV12bAIgEJen4aJJLgthLyUoD86h/ao+KYSe9oUTQ/fU/
# IsKjT5GNswWyKIKRXftZiAULlwbCmPgspzMk7lA6QczwoLB7HU3SqFg4lunf+RuR
# u4sQLNLHQx2iCXShgK975jMKDFlrjrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWhb71h
# EHREspgH4nSr/2jcbCY+6R/l4ASHrTDTDI0DfFW4FnBcJHggJetnZ4iruk40mGtw
# Ed44ytS+ocCc4d8eAgHYO+FnQ4S2z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/WsHet3
# DUZHc86/vZWV7Z0riBD++ljop1fhs8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA/NLD
# A/CMDNJF1i7nj5ie5gTuQm5nfkIWcWLnBPlgxmShtpyBIU4rxm1olIbGmXRzZzF6
# kfLUjHlufKa7fkZvTcWFEivPmiJECKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6Rdkt
# pFGQmKmgBzfEZRqqHGsWd/enl+w/GTCZbzH76kCy59LE+snQ8FB2dFn6jW0XMr74
# 6X4D9OeHdZrUSpEshQMTAitCgPKJajbPyEygzp74y42tFqfT3tWbGKfGkjrxgmPx
# Lg4kZN8CAwEAAaOCAXcwggFzMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggr
# BgEFBQcDAzAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3pbRD
# 2VZQu86WOzAfBgNVHSMEGDAWgBSP8Et/qC5FJK5NUPpjmove4t0bvDB6BggrBgEF
# BQcBAQRuMGwwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29t
# L3Jvb3RyMzA7BggrBgEFBQcwAoYvaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNv
# bS9jYWNlcnQvcm9vdC1yMy5jcnQwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2Ny
# bC5nbG9iYWxzaWduLmNvbS9yb290LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUdIAAw
# NDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3Np
# dG9yeS8wDQYJKoZIhvcNAQEMBQADggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9e1oz
# bg1nDnti2eEYXLC9E10dI645UHY3qkT9XwEjWYZWTMytvGQTFDCkIKjgP+icctx+
# 89gMI7qoLao89uyfhzEHZfU5p1GCdeHyL5f20eFlloNk/qEdUfu1JJv10ndpvIUs
# XPpYd9Gup7EL4tZ3u6m0NEqpbz308w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XUnZiM
# 02FLL8Mofnrekw60faAKbZLEtGY/fadY7qz37MMIAas4/AocqcWXsojICQIZ9lya
# GvFNbDDUswarAGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggboMIIE
# 0KADAgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNV
# BAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9i
# YWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0z
# MDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWdu
# IG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25p
# bmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMsg75ce
# uQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT
# 76+T3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqzg09y
# sYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AO
# wdTMMxLsvUCV0xHK5s2zBZzIU+tS13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r94n2
# 33Hw0b6nskEzIHXMsdXtHQcZxOsmd/KrbReTSam35sOQnMa47MzJe5pexcUkk2Nv
# fhCLYc+YVaMkoog28vmfvpMusgafJsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8moKiu
# eG3soYgVPMLq7rfYrWGlr3A2onmO3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV
# 2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTlzbSYszcZJBJyc6sEsAnchebUIgTv
# QCodLm3HadNutwFsDeCXpxbmJouI9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9
# ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJi8Kr77o6/elev7YR8b7wPcoyPm59
# 3g9+m5XEEofnGrhO7izB36Fl6CSDySrC/blTAgMBAAGjggGtMIIBqTAOBgNVHQ8B
# Af8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIB
# ADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/
# RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzAB
# hi1odHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUw
# RgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0
# L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDov
# L2NybC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1Ud
# IAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmds
# b2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUA
# A4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8DQdomxyd73G2F2prAk+zP4ZFh8xl
# m0zjWAYCImbVYQLFY4/UovG2XiULd5bpzXFAM4gp7O7zom28TbU+BkvJczPKCBQt
# PUzosLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQlQq+WVvQQ+iR98StywRbha+vmqZjH
# Plr00Bid/XSXhndGKj0jfShziq7vKxuav2xTpxSePIdxwF6OyPvTKpIz6ldNXgde
# ysEYrIEtGiH6bs+XYXvfcXo6ymP31TBENzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uu
# ora/Nao2Y8nOZNm9/Lws80lWAMgSK8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1
# GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/pteO
# 9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZPOOhRQAyuku++PX33gMZMNleElaeEFUgw
# DlInCI2Oor0ixxnJpsoOqHo222q6YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFS
# OTUpEYck08T7qWPLd0jV+mL8JOAEek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N3
# 6MXU4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/kMw4h3mKJSAfa9TCCB88wggW3oAMC
# AQICDErzema3QWMQLxMLNTANBgkqhkiG9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZ
# MBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBH
# Q0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwHhcNMjQwNDAzMTU0MTE2WhcN
# MjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8MFFByaXZhdGUgT3JnYW5pemF0aW9u
# MREwDwYDVQQFEwgxMzMzNzM0MzETMBEGCysGAQQBgjc8AgEDEwJHQjELMAkGA1UE
# BhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjETMBEGA1UEBxMKTWFu
# Y2hlc3RlcjEZMBcGA1UECRMQMTcgTWFyYmxlIFN0cmVldDEgMB4GA1UEChMXQ2xv
# dWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNVBAMTF0Nsb3VkTSBTb2Z0d2FyZSBM
# aW1pdGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8w
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCeChOiRjYdi7nE+/2zkusE
# YtLvYDDAgSTiG5qyauIreUULuW52PgP6b6SEcwMZf90BaYsMi9bcuI1yZ9C0lhbb
# yCtRcKj3llc/qdHwn9wjaI60cenb8e981VXrSHOFlTRnLFv2BEpiqtH0as26jTyt
# 8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZvRqlBx4uJhU945FQ2wiB8SW9wIeG
# YDmMHxKX/YXklSm88LnxNznd1BRanPl0VbkJq/UF0FfzN913qu/PxmE5gpak+QQr
# 3JPYtCPQTZPHMAN6waMngJnw9TwlNUGEhxvt371Y2FxovdUZyDLuRKxUq7cKexhb
# 2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd/62xP77AodWSvgGMeGM5P5fBQi3B
# e39abAou4fS3qWAEcaWy1qn7p0FxALrplQIyLw6Jnz7d0zzJKJE7hQcEfbqVJZzu
# gxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz1wcq+Fy6l+4Km+9f5roKK4dNFETf
# 5srRH5bVvsu6wenIXB3elE+loXqkqWhrtuY+bxHoZ1wW1W6FNCh0a9eacSpqBccP
# ahqghnuH19MJ0ky7RAAOwsCiStl53YPocpf+4KYnx8nCDFJqU5TDK59Pav0u1EGv
# 59Lo02AcSEw/6knEVqOqkQIDAQABo4IB2zCCAdcwDgYDVR0PAQH/BAQDAgeAMIGf
# BggrBgEFBQcBAQSBkjCBjzBMBggrBgEFBQcwAoZAaHR0cDovL3NlY3VyZS5nbG9i
# YWxzaWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNydDA/
# BggrBgEFBQcwAYYzaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVl
# dmNvZGVzaWduY2EyMDIwMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYB
# BQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcG
# BWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAwPjA8oDqgOIY2aHR0cDovL2NybC5n
# bG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3JsMCMGA1Ud
# EQQcMBqBGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzATBgNVHSUEDDAKBggrBgEF
# BQcDAzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs87ETO1ccA5I2ETAdBgNVHQ4EFgQU
# meoy5enoUY6lDmu5FlhyUaFHWawwDQYJKoZIhvcNAQELBQADggIBAMriJ8rqBFu9
# wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2nVrl892cPNQe4WeoagqZ1a0c7SRP
# ijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7J8GZoIrGD65tde5Y2HKwznrTZ56WxIXn
# AWkqbVKYoC6+iUHv0+rm5LbLxlTftv02Ri6VzIUMg9O4FJnJ1S81A/gBNWhx6fSE
# gaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBShgSxQrQ5Li4lw4SKpburQecVnB6f7OW7
# 0Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOpMAcdEjChHmh7gaeJNdOsfv8yUXML
# 4zgSuJTsDR690NGHEcDcPwgAxTatLmuRCSTuH6tD/gG4ES38Q1mz7joDNkpR79/I
# zKfYHl30fxHjqJbf3cuDy+mK1qd13fvMpR9S69sb8bPdJDJRL9mcO8RxJfwcNDqU
# HDAwz7J7b1vj/dIkOT7d5n4CBpubKb6jjQtNIGeDSNcev6ts2bjPpOiiCF3Z1+g4
# /HMULZWxVQr5bAKwkllhra6kTj1rKTZEjZCRkaBpcOT3jCijqkG5ir7IZ7IObprS
# ue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtKHvuX/ze8ygvJIdNTd+9wcwumekJJ
# GFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3nMYIDFTCCAxECAQEwbDBcMQswCQYDVQQG
# EwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFs
# U2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjACDErzema3QWMQLxML
# NTANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8G
# CSqGSIb3DQEJBDEiBCAlYdlm8ufgsCW8INIVz3Xl0upm464g0KxNFjtcWBmTYzAN
# BgkqhkiG9w0BAQEFAASCAgBD5CWQsK2Lf90kmmAZ0ux5CDfOUk2U/8rMwwBh59vZ
# ZFeW7SngLBkzR4xF2gbnsSLMmprHYwj4jszUr9YRs6ID2qi+UlCzD5IIK/IFPUc6
# ZULXDDJYE1tZBivnPx/qOBOjCR/t9qPky0Kn9LfOeLhLuleSsNHG2tBrtNr6FrjW
# +qtnnyejHBBrTg5Kfeb8bhknaskfvYDp9+WYeKkK30i8XOObv7hG2x7xD54hKwz0
# H/l1yaxBd4ip9YXTxVOJoHYzjrBAuRGAWZ0dmqcW7ZldmLpdthH1HoT38203IpOT
# q4YipYuZQQvjh63ogEB2yJXOkhR9UgG+IxhOMCQTAz4KrtKogkwVSubmoPmiEs3R
# /bkXYTWDPoWc60ObZ2MGA+JxpEuSAYXfokWvMbD2z8yXUlhQn1Qx9vc8HAW0WH9I
# E5HyFUgytPxgzCn1V7mvSxXuo4NyUF4W82+RPQIF4c/QA0bg2lKgOPuA4C3jIFl0
# nAGNAUu/vV88I6lFkkWY28aAR2H7B+8nUFErKFAJYPXBuV62EQTvi3Lcc0H3TERM
# uboZ7kK4cLsnGenPA810gmzNafX/1YkvVem1ERx7xkO6rotmT6GYDnSEN/gWNwyw
# ILJjeKSGP0Ok/P8s23WTmqnR7YpXyMYULI0f+2cdPMBtYw4NEhAmot5J0F1GVzlf
# gTCCGCQGCSqGSIb3DQEHAqCCGBUwghgRAgEBMQ8wDQYJYIZIAWUDBAIBBQAweQYK
# KwYBBAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTS
# xil+81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQg4+kYL6VkSxow
# kPpdzr9JgY2aYt4BtHpYZdAFEK7pSBSgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVw
# ikHPbwG47rSpVDANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWdu
# IFJvb3QgQ0EgLSBSMzETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xv
# YmFsU2lnbjAeFw0yMDA3MjgwMDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNV
# BAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9i
# YWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBALYtxTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWj
# Q5uYRYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMF
# siiCkV37WYgFC5cGwpj4LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Md
# ogl0oYCve+YzCgxZa4689Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0
# q/9o3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHA
# nOHfHgIB2DvhZ0OEts/8dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72V
# le2dK4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu
# 54+YnuYE7kJuZ35CFnFi5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnym
# u35Gb03FhRIrz5oiRAiohTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3
# xGUaqhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa
# 1EqRLIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4OJGTfAgMB
# AAGjggF3MIIBczAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# DwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljsw
# HwYDVR0jBBgwFoAUj/BLf6guRSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBs
# MC0GCCsGAQUFBzABhiFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMw
# OwYIKwYBBQUHMAKGL2h0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0
# L3Jvb3QtcjMuY3J0MDYGA1UdHwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFs
# c2lnbi5jb20vcm9vdC1yMy5jcmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYB
# BQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0G
# CSqGSIb3DQEBDAUAA4IBAQCs98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57Ytnh
# GFywvRNdHSOuOVB2N6pE/V8BI1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2q
# PPbsn4cxB2X1OadRgnXh8i+X9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqex
# C+LWd7uptDRKqW899PMNlV3m+XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH56
# 3pMOtH2gCm2SxLRmP32nWO6s9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMG
# qwBgSA14q88XrZKTYiB3dWy9yDK03E3r2d/BkJYpvcF/MIIG6DCCBNCgAwIBAgIQ
# d70OBbdZC7YdR2FTHj917TANBgkqhkiG9w0BAQsFADBTMQswCQYDVQQGEwJCRTEZ
# MBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBD
# b2RlIFNpZ25pbmcgUm9vdCBSNDUwHhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4MDAw
# MDAwWjBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEy
# MDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIw
# MjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLIO+XHrkBMkOgW6mK
# I/0gXq44EovKLNT/QdgaVdQZU7f9oxfnejlcwPfOEaP5pe0B+rW6k++vk9z44rMZ
# TIOwSkRQBHiEEGqk1paQjoH4fKsvtaNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS0PC0
# VV+WCxHlmrUsshHPJRt9USuYH0mjX/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS7L1A
# ldMRyubNswWcyFPrUtd4TFEBkoLeE/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+p7JB
# MyB1zLHV7R0HGcTrJnfyq20Xk0mpt+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HPmFWj
# JKKINvL5n76TLrIGnybADAFWEuGyip8OHtyYiy7P2uKJNKYfJqCornht7KGIFTzC
# 6u632K1hpa9wNqJ5jtwNc8Dx5CyrlOxYBjk2SNY7WugiznQOryzxFdrRtJXorNVJ
# beWv3ZtrYyBdjn47skPYYjqU5c20mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5tx2nT
# brcBbA3gl6cW5iaLiPcDRIZfYmdMtac3qFXcAzaMbs9tNibxDo+wPXHA4TKnguS2
# MgIyMHy1k8gh/TyI5mlj+O51yYvCq++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuVxBKH
# 5xq4Tu4swd+hZegkg8kqwv25UwIDAQABo4IBrTCCAakwDgYDVR0PAQH/BAQDAgGG
# MBMGA1UdJQQMMAoGCCsGAQUFBwMDMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0O
# BBYEFCWd0PxZCYZjxezzsRM7VxwDkjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4Obel
# tEPZVlC7zpY7MIGTBggrBgEFBQcBAQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0cDov
# L29jc3AuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1MEYGCCsGAQUF
# BzAChjpodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9jb2Rlc2ln
# bmluZ3Jvb3RyNDUuY3J0MEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xv
# YmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1LmNybDBVBgNVHSAETjBMMEEG
# CSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWdu
# LmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzANBgkqhkiG9w0BAQsFAAOCAgEAJXWg
# Cck5urehOYkvGJ+r1usdS+iUfA0HaJscne9xthdqawJPsz+GRYfMZZtM41gGAiJm
# 1WECxWOP1KLxtl4lC3eW6c1xQDOIKezu86JtvE21PgZLyXMzyggULT1M6LC6daZ0
# LaRYOmwTSfilFQoUloWxamg0JUKvllb0EPokffErcsEW4Wvr5qmYxz5a9NAYnf10
# l4Z3Rio9I30oc4qu7ysbmr9sU6cUnjyHccBejsj70yqSM+pXTV4HXsrBGKyBLRoh
# +m7Pl2F733F6Ospj99UwRDcy/rtDhdy6/KbKMxkrd23bywXwfl91LqK2vzWqNmPJ
# zmTZvfy8LPNJVgDIEivGJ7s3r1fvxM8eKcT04i3OKmHPV+31CkDi9RjWHumQL8rT
# h1+TikgaER3lN4WfLmZiml6BTpWsVVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4hu5/X
# anGAv5becgPY2CIr8ycWTzjoUUAMrpLvvj1994DGTDZXhJWnhBVIMA5SJwiNjqK9
# IscZyabKDqh6NttqumFfESSVpOKOaO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGHJNPE
# +6ljy3dI1fpi/CTgBHpO0ORu3s6eOFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV0NMe
# 9n9S4kmNuRFyDIhEJjNmAUTf5DMOId5iiUgH2vUwggfPMIIFt6ADAgECAgxK83pm
# t0FjEC8TCzUwDQYJKoZIhvcNAQELBQAwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBF
# ViBDb2RlU2lnbmluZyBDQSAyMDIwMB4XDTI0MDQwMzE1NDExNloXDTI1MDQwNDE1
# NDExNlowggEOMR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjERMA8GA1UE
# BRMIMTMzMzczNDMxEzARBgsrBgEEAYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdCMRsw
# GQYDVQQIExJHcmVhdGVyIE1hbmNoZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0ZXIx
# GTAXBgNVBAkTEDE3IE1hcmJsZSBTdHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBTb2Z0
# d2FyZSBMaW1pdGVkMSAwHgYDVQQDExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEn
# MCUGCSqGSIb3DQEJARYYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAngoTokY2HYu5xPv9s5LrBGLS72AwwIEk
# 4huasmriK3lFC7ludj4D+m+khHMDGX/dAWmLDIvW3LiNcmfQtJYW28grUXCo95ZX
# P6nR8J/cI2iOtHHp2/HvfNVV60hzhZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq3f+C
# SOSZ4FdU6ISsAqZeRsazr/XA2b0apQceLiYVPeORUNsIgfElvcCHhmA5jB8Sl/2F
# 5JUpvPC58Tc53dQUWpz5dFW5Cav1BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj0E2T
# xzADesGjJ4CZ8PU8JTVBhIcb7d+9WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1ouCf
# JEsYeeBny8EQIy1lFuoLfBOGHf+tsT++wKHVkr4BjHhjOT+XwUItwXt/WmwKLuH0
# t6lgBHGlstap+6dBcQC66ZUCMi8OiZ8+3dM8ySiRO4UHBH26lSWc7oMYQexgX6O1
# XCgyxCX3MJfEcJrIlOEEBq11M9cHKvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W1b7L
# usHpyFwd3pRPpaF6pKloa7bmPm8R6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7h9fT
# CdJMu0QADsLAokrZed2D6HKX/uCmJ8fJwgxSalOUwyufT2r9LtRBr+fS6NNgHEhM
# P+pJxFajqpECAwEAAaOCAdswggHXMA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYBBQUH
# AQEEgZIwgY8wTAYIKwYBBQUHMAKGQGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5j
# b20vY2FjZXJ0L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYBBQUH
# MAGGM2h0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2ln
# bmNhMjAyMDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZo
# dHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAJ
# BgNVHRMEAjAAMEcGA1UdHwRAMD4wPKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFsc2ln
# bi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNybDAjBgNVHREEHDAagRht
# YXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMwHwYD
# VR0jBBgwFoAUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp6FGO
# pQ5ruRZYclGhR1msMA0GCSqGSIb3DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlhqLQp
# OawqxF133UUTN4wKocLfqlsv9p1a5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJomnX7
# 6vojinvqiLsNr0f2zKcquyfBmaCKxg+ubXXuWNhysM5602eelsSF5wFpKm1SmKAu
# volB79Pq5uS2y8ZU37b9NkYulcyFDIPTuBSZydUvNQP4ATVocen0hIGkZFGfqnIo
# wfyzFjvXU3+T9Vrc3BTAUoYEsUK0OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAolFZH
# qEfIy+K1HkWkq0dz4+bVpJlTqTAHHRIwoR5oe4GniTXTrH7/MlFzC+M4EriU7A0e
# vdDRhxHA3D8IAMU2rS5rkQkk7h+rQ/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d9H8R
# 46iW393Lg8vpitandd37zKUfUuvbG/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+ye29b
# 4/3SJDk+3eZ+Agabmym+o40LTSBng0jXHr+rbNm4z6Tooghd2dfoOPxzFC2VsVUK
# +WwCsJJZYa2upE49ayk2RI2QkZGgaXDk94woo6pBuYq+yGeyDm6a0rnuAimIxNDc
# 3KNSLiaw48DP9nAYS8bO1yirSh77l/83vMoLySHTU3fvcHMLpnpCSRha6iYCz1q9
# xwrReCYrgJxc+y2IyxK95zGCAxUwggMRAgEBMGwwXDELMAkGA1UEBhMCQkUxGTAX
# BgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0ND
# IFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZI
# AWUDBAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYB
# BAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0B
# CQQxIgQgJWHZZvLn4LAlvCDSFc915dLqZuOuINCsTRY7XFgZk2MwDQYJKoZIhvcN
# AQEBBQAEggIAQ+QlkLCti3/dJJpgGdLseQg3zlJNlP/KzMMAYefb2WRXlu0p4CwZ
# M0eMRdoG57EizJqax2MI+I7M1K/WEbOiA9qovlJQsw+SCCvyBT1HOmVC1wwyWBNb
# WQYr5z8f6jgTowkf7faj5MtCp/S3zni4S7pXkrDRxtrQa7Ta+ha41vqrZ58noxwQ
# a04OSn3m/G4ZJ2rJH72A6fflmHipCt9IvFzjm7+4Rtse8Q+eISsM9B/5dcmsQXeI
# qfWF08VTiaB2M46wQLkRgFmdHZqnFu2ZXZi6XbYR9R6E9/NtNyKTk6uGIqWLmUEL
# 44et6IBAdsiVzpIUfVIBviMYTjAkEwM+Cq7SqIJMFUrm5qD5ohLN0f25F2E1gz6F
# nOtDm2djBgPicaRLkgGF36JFrzGw9s/Ml1JYUJ9UMfb3PBwFtFh/SBOR8hVIMrT8
# YMwp9Ve5r0sV7qODclBeFvNvkT0CBeHP0ANG4NpSoDj7gOAt4yBZdJwBjQFLv71f
# PCOpRZJFmNvGgEdh+wfvJ1BRKyhQCWD1wblethEE74ty3HNB90xETLm6Ge5CuHC7
# JxnpzwPNdIJszWn1/9WJL1XptREce8ZDuq6LZk+hmA50hDf4FjcMsCCyY3ikhj9D
# pPz/LNt1k5qp0e2KV8jGFCyNH/tnHTzAbWMODRIQJqLeSdBdRlc5X4EwghgkBgkq
# hkiG9w0BBwKgghgVMIIYEQIBATEPMA0GCWCGSAFlAwQCAQUAMHkGCisGAQQBgjcC
# AQSgazBpMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNRAgEA
# AgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIBBQAEIOPpGC+lZEsaMJD6Xc6/SYGN
# mmLeAbR6WGXQBRCu6UgUoIIUZTCCBaIwggSKoAMCAQICEHgDGEJFcIpBz28BuO60
# qVQwDQYJKoZIhvcNAQEMBQAwTDEgMB4GA1UECxMXR2xvYmFsU2lnbiBSb290IENB
# IC0gUjMxEzARBgNVBAoTCkdsb2JhbFNpZ24xEzARBgNVBAMTCkdsb2JhbFNpZ24w
# HhcNMjAwNzI4MDAwMDAwWhcNMjkwMzE4MDAwMDAwWjBTMQswCQYDVQQGEwJCRTEZ
# MBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBD
# b2RlIFNpZ25pbmcgUm9vdCBSNDUwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQC2LcUw3Xroq5A9A3KwOkuZFmGy5f+lZx03HOV+7JODqoT1o0ObmEWKuGNX
# XZsAiAQl6fhokkuC2EvJSgPzqH9qj4phJ72hRND99T8iwqNPkY2zBbIogpFd+1mI
# BQuXBsKY+CynMyTuUDpBzPCgsHsdTdKoWDiW6d/5G5G7ixAs0sdDHaIJdKGAr3vm
# MwoMWWuOvPSrWpd7f65V+4TwgP6ETNfiur3EdaFvvWEQdESymAfidKv/aNxsJj7p
# H+XgBIetMNMMjQN8VbgWcFwkeCAl62dniKu6TjSYa3AR3jjK1L6hwJzh3x4CAdg7
# 4WdDhLbP/HS3L4Sjv7oJNz1nbLFFXBlhq0GD9awd63cNRkdzzr+9lZXtnSuIEP76
# WOinV+Gzz6ha6QclmxLEnoByPZPcjJTfO0TmJoD80sMD8IwM0kXWLuePmJ7mBO5C
# bmd+QhZxYucE+WDGZKG2nIEhTivGbWiUhsaZdHNnMXqR8tSMeW58prt+Rm9NxYUS
# K8+aIkQIqIU3zgdhVwYXEiTAxDFzoZg1V0d+EDpF2S2kUZCYqaAHN8RlGqocaxZ3
# 96eX7D8ZMJlvMfvqQLLn0sT6ydDwUHZ0WfqNbRcyvvjpfgP054d1mtRKkSyFAxMC
# K0KA8olqNs/ITKDOnvjLja0Wp9Pe1ZsYp8aSOvGCY/EuDiRk3wIDAQABo4IBdzCC
# AXMwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA8GA1UdEwEB
# /wQFMAMBAf8wHQYDVR0OBBYEFB8Av0aACvx4ObeltEPZVlC7zpY7MB8GA1UdIwQY
# MBaAFI/wS3+oLkUkrk1Q+mOai97i3Ru8MHoGCCsGAQUFBwEBBG4wbDAtBggrBgEF
# BQcwAYYhaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vcm9vdHIzMDsGCCsGAQUF
# BzAChi9odHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9yb290LXIz
# LmNydDA2BgNVHR8ELzAtMCugKaAnhiVodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29t
# L3Jvb3QtcjMuY3JsMEcGA1UdIARAMD4wPAYEVR0gADA0MDIGCCsGAQUFBwIBFiZo
# dHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG9w0B
# AQwFAAOCAQEArPfMFYsweagdCyiIGQnXHH/+hr17WjNuDWcOe2LZ4RhcsL0TXR0j
# rjlQdjeqRP1fASNZhlZMzK28ZBMUMKQgqOA/6Jxy3H7z2Awjuqgtqjz27J+HMQdl
# 9TmnUYJ14fIvl/bR4WWWg2T+oR1R+7Ukm/XSd2m8hSxc+lh30a6nsQvi1ne7qbQ0
# SqlvPfTzDZVd5vl6RbAlFzEu2/cPaOaDH6n35dSdmIzTYUsvwyh+et6TDrR9oApt
# ksS0Zj99p1jurPfswwgBqzj8ChypxZeyiMgJAhn2XJoa8U1sMNSzBqsAYEgNeKvP
# F62Sk2Igd3VsvcgytNxN69nfwZCWKb3BfzCCBugwggTQoAMCAQICEHe9DgW3WQu2
# HUdhUx4/de0wDQYJKoZIhvcNAQELBQAwUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWdu
# aW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAwMFoXDTMwMDcyODAwMDAwMFowXDEL
# MAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMT
# KUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyyDvlx65ATJDoFupiiP9IF6uOBKL
# yizU/0HYGlXUGVO3/aMX53o5XMD3zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4
# hBBqpNaWkI6B+HyrL7WjVzPSWHuUDm0PpZEmKrODT3KxintkktDwtFVflgsR5Zq1
# LLIRzyUbfVErmB9Jo1/4E541uAMC2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrmzbMF
# nMhT61LXeExRAZKC3hPzB450uoSAn9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0d
# BxnE6yZ38qttF5NJqbfmw5CcxrjszMl7ml7FxSSTY29+EIthz5hVoySiiDby+Z++
# ky6yBp8mwAwBVhLhsoqfDh7cmIsuz9riiTSmHyagqK54beyhiBU8wurut9itYaWv
# cDaieY7cDXPA8eQsq5TsWAY5NkjWO1roIs50Dq8s8RXa0bSV6KzVSW3lr92ba2Mg
# XY5+O7JD2GI6lOXNtJizNxkkEnJzqwSwCdyF5tQiBO9AKh0ubcdp0263AWwN4Jen
# FuYmi4j3A0SGX2JnTLWnN6hV3AM2jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8tZPI
# If08iOZpY/judcmLwqvvujr96V6/thHxvvA9yjI+bn3eD36blcQSh+cauE7uLMHf
# oWXoJIPJKsL9uVMCAwEAAaOCAa0wggGpMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUE
# DDAKBggrBgEFBQcDAzASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8
# WQmGY8Xs87ETO1ccA5I2ETAfBgNVHSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQu86W
# OzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmds
# b2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0
# cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvY29kZXNpZ25pbmdyb290
# cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24u
# Y29tL2NvZGVzaWduaW5ncm9vdHI0NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAy
# AQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVw
# b3NpdG9yeS8wBwYFZ4EMAQMwDQYJKoZIhvcNAQELBQADggIBACV1oAnJObq3oTmJ
# Lxifq9brHUvolHwNB2ibHJ3vcbYXamsCT7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si
# 8bZeJQt3lunNcUAziCns7vOibbxNtT4GS8lzM8oIFC09TOiwunWmdC2kWDpsE0n4
# pRUKFJaFsWpoNCVCr5ZW9BD6JH3xK3LBFuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9
# KHOKru8rG5q/bFOnFJ48h3HAXo7I+9MqkjPqV01eB17KwRisgS0aIfpuz5dhe99x
# ejrKY/fVMEQ3Mv67Q4XcuvymyjMZK3dt28sF8H5fdS6itr81qjZjyc5k2b38vCzz
# SVYAyBIrxie7N69X78TPHinE9OItziphz1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd
# 5TeFny5mYppegU6VrFVXQ9xTiyV+PGEPigu69T+m1473BFZeIbuf12pxgL+W3nID
# 2NgiK/MnFk846FFADK6S7749ffeAxkw2V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6o
# ejbbarphXxEklaTijmjuGalJmV7QtDS91vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6
# Yvwk4AR6TtDkbt7OnjhQJvQhcWXXCSXUyQcAerjH83foxdTiVdDTHvZ/UuJJjbkR
# cgyIRCYzZgFE3+QzDiHeYolIB9r1MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1
# MA0GCSqGSIb3DQEBCwUAMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxT
# aWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNp
# Z25pbmcgQ0EgMjAyMDAeFw0yNDA0MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIB
# DjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xETAPBgNVBAUTCDEzMzM3
# MzQzMRMwEQYLKwYBBAGCNzwCAQMTAkdCMQswCQYDVQQGEwJHQjEbMBkGA1UECBMS
# R3JlYXRlciBNYW5jaGVzdGVyMRMwEQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJ
# ExAxNyBNYXJibGUgU3RyZWV0MSAwHgYDVQQKExdDbG91ZE0gU29mdHdhcmUgTGlt
# aXRlZDEgMB4GA1UEAxMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG
# 9w0BCQEWGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAJ4KE6JGNh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5
# RQu5bnY+A/pvpIRzAxl/3QFpiwyL1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNo
# jrRx6dvx73zVVetIc4WVNGcsW/YESmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiE
# rAKmXkbGs6/1wNm9GqUHHi4mFT3jkVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3
# Od3UFFqc+XRVuQmr9QXQV/M33Xeq78/GYTmClqT5BCvck9i0I9BNk8cwA3rBoyeA
# mfD1PCU1QYSHG+3fvVjYXGi91RnIMu5ErFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vB
# ECMtZRbqC3wThh3/rbE/vsCh1ZK+AYx4Yzk/l8FCLcF7f1psCi7h9LepYARxpbLW
# qfunQXEAuumVAjIvDomfPt3TPMkokTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl9zCX
# xHCayJThBAatdTPXByr4XLqX7gqb71/mugorh00URN/mytEfltW+y7rB6chcHd6U
# T6WheqSpaGu25j5vEehnXBbVboU0KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7C
# wKJK2Xndg+hyl/7gpifHycIMUmpTlMMrn09q/S7UQa/n0ujTYBxITD/qScRWo6qR
# AgMBAAGjggHbMIIB1zAOBgNVHQ8BAf8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGP
# MEwGCCsGAQUFBzAChkBodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2Vy
# dC9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRw
# Oi8vb2NzcC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAw
# VQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93
# d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIw
# ADBHBgNVHR8EQDA+MDygOqA4hjZodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dz
# Z2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tp
# bnN0cnlAY2xvdWRtLmlvMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaA
# FCWd0PxZCYZjxezzsRM7VxwDkjYRMB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJR
# oUdZrDANBgkqhkiG9w0BAQsFAAOCAgEAyuInyuoEW73BaqgZYai0KTmsKsRdd91F
# EzeMCqHC36pbL/adWuXz3Zw81B7hZ6hqCpnVrRztJE+KPAyyaJp1++r6I4p76oi7
# Da9H9synKrsnwZmgisYPrm117ljYcrDOetNnnpbEhecBaSptUpigLr6JQe/T6ubk
# tsvGVN+2/TZGLpXMhQyD07gUmcnVLzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY711N/
# k/Va3NwUwFKGBLFCtDkuLiXDhIqlu6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5F
# pKtHc+Pm1aSZU6kwBx0SMKEeaHuBp4k106x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/
# CADFNq0ua5EJJO4fq0P+AbgRLfxDWbPuOgM2SlHv38jMp9geXfR/EeOolt/dy4PL
# 6YrWp3Xd+8ylH1Lr2xvxs90kMlEv2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3m
# fgIGm5spvqONC00gZ4NI1x6/q2zZuM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGt
# rqROPWspNkSNkJGRoGlw5PeMKKOqQbmKvshnsg5umtK57gIpiMTQ3NyjUi4msOPA
# z/ZwGEvGztcoq0oe+5f/N7zKC8kh01N373BzC6Z6QkkYWuomAs9avccK0XgmK4Cc
# XPstiMsSvecxggMVMIIDEQIBATBsMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBH
# bG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYg
# Q29kZVNpZ25pbmcgQ0EgMjAyMAIMSvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUA
# oHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICVh
# 2Wby5+CwJbwg0hXPdeXS6mbjriDQrE0WO1xYGZNjMA0GCSqGSIb3DQEBAQUABIIC
# AEPkJZCwrYt/3SSaYBnS7HkIN85STZT/yszDAGHn29lkV5btKeAsGTNHjEXaBuex
# IsyamsdjCPiOzNSv1hGzogPaqL5SULMPkggr8gU9RzplQtcMMlgTW1kGK+c/H+o4
# E6MJH+32o+TLQqf0t854uEu6V5Kw0cba0Gu02voWuNb6q2efJ6McEGtODkp95vxu
# GSdqyR+9gOn35Zh4qQrfSLxc45u/uEbbHvEPniErDPQf+XXJrEF3iKn1hdPFU4mg
# djOOsEC5EYBZnR2apxbtmV2Yul22EfUehPfzbTcik5OrhiKli5lBC+OHreiAQHbI
# lc6SFH1SAb4jGE4wJBMDPgqu0qiCTBVK5uag+aISzdH9uRdhNYM+hZzrQ5tnYwYD
# 4nGkS5IBhd+iRa8xsPbPzJdSWFCfVDH29zwcBbRYf0gTkfIVSDK0/GDMKfVXua9L
# Fe6jg3JQXhbzb5E9AgXhz9ADRuDaUqA4+4DgLeMgWXScAY0BS7+9XzwjqUWSRZjb
# xoBHYfsH7ydQUSsoUAlg9cG5XrYRBO+LctxzQfdMREy5uhnuQrhwuycZ6c8DzXSC
# bM1p9f/ViS9V6bURHHvGQ7qui2ZPoZgOdIQ3+BY3DLAgsmN4pIY/Q6T8/yzbdZOa
# qdHtilfIxhQsjR/7Zx08wG1jDg0SECai3knQXUZXOV+BMIIYJAYJKoZIhvcNAQcC
# oIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5BgorBgEEAYI3AgEEoGswaTA0
# BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIB
# AAIBADAxMA0GCWCGSAFlAwQCAQUABCDj6RgvpWRLGjCQ+l3Ov0mBjZpi3gG0elhl
# 0AUQrulIFKCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCKQc9vAbjutKlUMA0GCSqG
# SIb3DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2JhbFNpZ24gUm9vdCBDQSAtIFIzMRMw
# EQYDVQQKEwpHbG9iYWxTaWduMRMwEQYDVQQDEwpHbG9iYWxTaWduMB4XDTIwMDcy
# ODAwMDAwMFoXDTI5MDMxODAwMDAwMFowUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWdu
# aW5nIFJvb3QgUjQ1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAti3F
# MN166KuQPQNysDpLmRZhsuX/pWcdNxzlfuyTg6qE9aNDm5hFirhjV12bAIgEJen4
# aJJLgthLyUoD86h/ao+KYSe9oUTQ/fU/IsKjT5GNswWyKIKRXftZiAULlwbCmPgs
# pzMk7lA6QczwoLB7HU3SqFg4lunf+RuRu4sQLNLHQx2iCXShgK975jMKDFlrjrz0
# q1qXe3+uVfuE8ID+hEzX4rq9xHWhb71hEHREspgH4nSr/2jcbCY+6R/l4ASHrTDT
# DI0DfFW4FnBcJHggJetnZ4iruk40mGtwEd44ytS+ocCc4d8eAgHYO+FnQ4S2z/x0
# ty+Eo7+6CTc9Z2yxRVwZYatBg/WsHet3DUZHc86/vZWV7Z0riBD++ljop1fhs8+o
# WukHJZsSxJ6Acj2T3IyU3ztE5iaA/NLDA/CMDNJF1i7nj5ie5gTuQm5nfkIWcWLn
# BPlgxmShtpyBIU4rxm1olIbGmXRzZzF6kfLUjHlufKa7fkZvTcWFEivPmiJECKiF
# N84HYVcGFxIkwMQxc6GYNVdHfhA6RdktpFGQmKmgBzfEZRqqHGsWd/enl+w/GTCZ
# bzH76kCy59LE+snQ8FB2dFn6jW0XMr746X4D9OeHdZrUSpEshQMTAitCgPKJajbP
# yEygzp74y42tFqfT3tWbGKfGkjrxgmPxLg4kZN8CAwEAAaOCAXcwggFzMA4GA1Ud
# DwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzAPBgNVHRMBAf8EBTADAQH/
# MB0GA1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQu86WOzAfBgNVHSMEGDAWgBSP8Et/
# qC5FJK5NUPpjmove4t0bvDB6BggrBgEFBQcBAQRuMGwwLQYIKwYBBQUHMAGGIWh0
# dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL3Jvb3RyMzA7BggrBgEFBQcwAoYvaHR0
# cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvcm9vdC1yMy5jcnQwNgYD
# VR0fBC8wLTAroCmgJ4YlaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9yb290LXIz
# LmNybDBHBgNVHSAEQDA+MDwGBFUdIAAwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93
# d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wDQYJKoZIhvcNAQEMBQADggEB
# AKz3zBWLMHmoHQsoiBkJ1xx//oa9e1ozbg1nDnti2eEYXLC9E10dI645UHY3qkT9
# XwEjWYZWTMytvGQTFDCkIKjgP+icctx+89gMI7qoLao89uyfhzEHZfU5p1GCdeHy
# L5f20eFlloNk/qEdUfu1JJv10ndpvIUsXPpYd9Gup7EL4tZ3u6m0NEqpbz308w2V
# Xeb5ekWwJRcxLtv3D2jmgx+p9+XUnZiM02FLL8Mofnrekw60faAKbZLEtGY/fadY
# 7qz37MMIAas4/AocqcWXsojICQIZ9lyaGvFNbDDUswarAGBIDXirzxetkpNiIHd1
# bL3IMrTcTevZ38GQlim9wX8wggboMIIE0KADAgECAhB3vQ4Ft1kLth1HYVMeP3Xt
# MA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxT
# aWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290
# IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxT
# aWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV
# 1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAEeIQQaqTWlpCO
# gfh8qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31R
# K5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS13hM
# UQGSgt4T8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXtHQcZxOsmd/Kr
# bReTSam35sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmfvpMusgafJsAM
# AVYS4bKKnw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGlr3A2onmO3A1z
# wPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hi
# OpTlzbSYszcZJBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCXpxbmJouI9wNE
# hl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP4
# 7nXJi8Kr77o6/elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB36Fl6CSDySrC
# /blTAgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POx
# EztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsG
# AQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5nbG9iYWxzaWdu
# LmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1
# cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQw
# QQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9jb2Rl
# c2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYI
# KwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkv
# MAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L
# 6JR8DQdomxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/UovG2XiULd5bp
# zXFAM4gp7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ+KUVChSWhbFq
# aDQlQq+WVvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0jfShziq7vKxua
# v2xTpxSePIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvfcXo6ymP31TBE
# NzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgSK8Yn
# uzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKa
# XoFOlaxVV0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZP
# OOhRQAyuku++PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoOqHo222q6YV8R
# JJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV+mL8JOAEek7Q
# 5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25EXIMiEQmM2YB
# RN/kMw4h3mKJSAfa9TCCB88wggW3oAMCAQICDErzema3QWMQLxMLNTANBgkqhkiG
# 9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1z
# YTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENB
# IDIwMjAwHhcNMjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNV
# BA8MFFByaXZhdGUgT3JnYW5pemF0aW9uMREwDwYDVQQFEwgxMzMzNzM0MzETMBEG
# CysGAQQBgjc8AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIg
# TWFuY2hlc3RlcjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZMBcGA1UECRMQMTcgTWFy
# YmxlIFN0cmVldDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAe
# BgNVBAMTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkBFhht
# YXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCeChOiRjYdi7nE+/2zkusEYtLvYDDAgSTiG5qyauIreUULuW52PgP6
# b6SEcwMZf90BaYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/qdHwn9wjaI60cenb8e98
# 1VXrSHOFlTRnLFv2BEpiqtH0as26jTyt8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv
# 9cDZvRqlBx4uJhU945FQ2wiB8SW9wIeGYDmMHxKX/YXklSm88LnxNznd1BRanPl0
# VbkJq/UF0FfzN913qu/PxmE5gpak+QQr3JPYtCPQTZPHMAN6waMngJnw9TwlNUGE
# hxvt371Y2FxovdUZyDLuRKxUq7cKexhb2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8
# E4Yd/62xP77AodWSvgGMeGM5P5fBQi3Be39abAou4fS3qWAEcaWy1qn7p0FxALrp
# lQIyLw6Jnz7d0zzJKJE7hQcEfbqVJZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQG
# rXUz1wcq+Fy6l+4Km+9f5roKK4dNFETf5srRH5bVvsu6wenIXB3elE+loXqkqWhr
# tuY+bxHoZ1wW1W6FNCh0a9eacSpqBccPahqghnuH19MJ0ky7RAAOwsCiStl53YPo
# cpf+4KYnx8nCDFJqU5TDK59Pav0u1EGv59Lo02AcSEw/6knEVqOqkQIDAQABo4IB
# 2zCCAdcwDgYDVR0PAQH/BAQDAgeAMIGfBggrBgEFBQcBAQSBkjCBjzBMBggrBgEF
# BQcwAoZAaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3NnY2Ny
# NDVldmNvZGVzaWduY2EyMDIwLmNydDA/BggrBgEFBQcwAYYzaHR0cDovL29jc3Au
# Z2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwMFUGA1UdIARO
# MEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2Jh
# bHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0f
# BEAwPjA8oDqgOIY2aHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2
# Y29kZXNpZ25jYTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5QGNs
# b3VkbS5pbzATBgNVHSUEDDAKBggrBgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8WQmG
# Y8Xs87ETO1ccA5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6lDmu5FlhyUaFHWawwDQYJ
# KoZIhvcNAQELBQADggIBAMriJ8rqBFu9wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+q
# Wy/2nVrl892cPNQe4WeoagqZ1a0c7SRPijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7
# J8GZoIrGD65tde5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTftv02
# Ri6VzIUMg9O4FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBS
# hgSxQrQ5Li4lw4SKpburQecVnB6f7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWk
# mVOpMAcdEjChHmh7gaeJNdOsfv8yUXML4zgSuJTsDR690NGHEcDcPwgAxTatLmuR
# CSTuH6tD/gG4ES38Q1mz7joDNkpR79/IzKfYHl30fxHjqJbf3cuDy+mK1qd13fvM
# pR9S69sb8bPdJDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj/dIkOT7d5n4CBpubKb6j
# jQtNIGeDSNcev6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5bAKwkllhra6kTj1rKTZE
# jZCRkaBpcOT3jCijqkG5ir7IZ7IObprSue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7X
# KKtKHvuX/ze8ygvJIdNTd+9wcwumekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3n
# MYIDFTCCAxECAQEwbDBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2ln
# biBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWdu
# aW5nIENBIDIwMjACDErzema3QWMQLxMLNTANBglghkgBZQMEAgEFAKB8MBAGCisG
# AQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQB
# gjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAlYdlm8ufgsCW8
# INIVz3Xl0upm464g0KxNFjtcWBmTYzANBgkqhkiG9w0BAQEFAASCAgBD5CWQsK2L
# f90kmmAZ0ux5CDfOUk2U/8rMwwBh59vZZFeW7SngLBkzR4xF2gbnsSLMmprHYwj4
# jszUr9YRs6ID2qi+UlCzD5IIK/IFPUc6ZULXDDJYE1tZBivnPx/qOBOjCR/t9qPk
# y0Kn9LfOeLhLuleSsNHG2tBrtNr6FrjW+qtnnyejHBBrTg5Kfeb8bhknaskfvYDp
# 9+WYeKkK30i8XOObv7hG2x7xD54hKwz0H/l1yaxBd4ip9YXTxVOJoHYzjrBAuRGA
# WZ0dmqcW7ZldmLpdthH1HoT38203IpOTq4YipYuZQQvjh63ogEB2yJXOkhR9UgG+
# IxhOMCQTAz4KrtKogkwVSubmoPmiEs3R/bkXYTWDPoWc60ObZ2MGA+JxpEuSAYXf
# okWvMbD2z8yXUlhQn1Qx9vc8HAW0WH9IE5HyFUgytPxgzCn1V7mvSxXuo4NyUF4W
# 82+RPQIF4c/QA0bg2lKgOPuA4C3jIFl0nAGNAUu/vV88I6lFkkWY28aAR2H7B+8n
# UFErKFAJYPXBuV62EQTvi3Lcc0H3TERMuboZ7kK4cLsnGenPA810gmzNafX/1Ykv
# Vem1ERx7xkO6rotmT6GYDnSEN/gWNwywILJjeKSGP0Ok/P8s23WTmqnR7YpXyMYU
# LI0f+2cdPMBtYw4NEhAmot5J0F1GVzlfgTCCLkkGCSqGSIb3DQEHAqCCLjowgi42
# AgEBMQ8wDQYJYIZIAWUDBAIBBQAweQYKKwYBBAGCNwIBBKBrMGkwNAYKKwYBBAGC
# NwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+81ECAQACAQACAQACAQACAQAwMTAN
# BglghkgBZQMEAgEFAAQg4+kYL6VkSxowkPpdzr9JgY2aYt4BtHpYZdAFEK7pSBSg
# gidkMIIFojCCBIqgAwIBAgIQeAMYQkVwikHPbwG47rSpVDANBgkqhkiG9w0BAQwF
# ADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzETMBEGA1UEChMK
# R2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjAeFw0yMDA3MjgwMDAwMDBa
# Fw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxT
# aWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290
# IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALYtxTDdeuirkD0D
# crA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uYRYq4Y1ddmwCIBCXp+GiSS4LYS8lK
# A/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiCkV37WYgFC5cGwpj4LKczJO5QOkHM
# 8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0oYCve+YzCgxZa4689Ktal3t/rlX7
# hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o3GwmPukf5eAEh60w0wyNA3xVuBZw
# XCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHfHgIB2DvhZ0OEts/8dLcvhKO/ugk3
# PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2dK4gQ/vpY6KdX4bPPqFrpByWbEsSe
# gHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+YnuYE7kJuZ35CFnFi5wT5YMZkobac
# gSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35Gb03FhRIrz5oiRAiohTfOB2FXBhcS
# JMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUaqhxrFnf3p5fsPxkwmW8x++pAsufS
# xPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2z8hMoM6e+MuN
# rRan097VmxinxpI68YJj8S4OJGTfAgMBAAGjggF3MIIBczAOBgNVHQ8BAf8EBAMC
# AYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
# FgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYDVR0jBBgwFoAUj/BLf6guRSSuTVD6
# Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0GCCsGAQUFBzABhiFodHRwOi8vb2Nz
# cC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYIKwYBBQUHMAKGL2h0dHA6Ly9zZWN1
# cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jvb3QtcjMuY3J0MDYGA1UdHwQvMC0w
# K6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vcm9vdC1yMy5jcmwwRwYD
# VR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2Jh
# bHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4IBAQCs98wVizB5
# qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFywvRNdHSOuOVB2N6pE/V8BI1mGVkzM
# rbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbsn4cxB2X1OadRgnXh8i+X9tHhZZaD
# ZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LWd7uptDRKqW899PMNlV3m+XpFsCUX
# MS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMOtH2gCm2SxLRmP32nWO6s9+zDCAGr
# OPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBgSA14q88XrZKTYiB3dWy9yDK03E3r
# 2d/BkJYpvcF/MIIGFDCCA/ygAwIBAgIQeiOu2lNplg+RyD5c9MfjPzANBgkqhkiG
# 9w0BAQwFADBXMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk
# MS4wLAYDVQQDEyVTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFJvb3QgUjQ2
# MB4XDTIxMDMyMjAwMDAwMFoXDTM2MDMyMTIzNTk1OVowVTELMAkGA1UEBhMCR0Ix
# GDAWBgNVBAoTD1NlY3RpZ28gTGltaXRlZDEsMCoGA1UEAxMjU2VjdGlnbyBQdWJs
# aWMgVGltZSBTdGFtcGluZyBDQSBSMzYwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAw
# ggGKAoIBgQDNmNhDQatugivs9jN+JjTkiYzT7yISgFQ+7yavjA6Bg+OiIjPm/N/t
# 3nC7wYUrUlY3mFyI32t2o6Ft3EtxJXCc5MmZQZ8AxCbh5c6WzeJDB9qkQVa46xiY
# Epc81KnBkAWgsaXnLURoYZzksHIzzCNxtIXnb9njZholGw9djnjkTdAA83abEOHQ
# 4ujOGIaBhPXG2NdV8TNgFWZ9BojlAvflxNMCOwkCnzlH4oCw5+4v1nssWeN1y4+R
# laOywwRMUi54fr2vFsU5QPrgb6tSjvEUh1EC4M29YGy/SIYM8ZpHadmVjbi3Pl8h
# JiTWw9jiCKv31pcAaeijS9fc6R7DgyyLIGflmdQMwrNRxCulVq8ZpysiSYNi79tw
# 5RHWZUEhnRfs/hsp/fwkXsynu1jcsUX+HuG8FLa2BNheUPtOcgw+vHJcJ8HnJCrc
# UWhdFczf8O+pDiyGhVYX+bDDP3GhGS7TmKmGnbZ9N+MpEhWmbiAVPbgkqykSkzyY
# Vr15OApZYK8CAwEAAaOCAVwwggFYMB8GA1UdIwQYMBaAFPZ3at0//QET/xahbIIC
# L9AKPRQlMB0GA1UdDgQWBBRfWO1MMXqiYUKNUoC6s2GXGaIymzAOBgNVHQ8BAf8E
# BAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADATBgNVHSUEDDAKBggrBgEFBQcDCDAR
# BgNVHSAECjAIMAYGBFUdIAAwTAYDVR0fBEUwQzBBoD+gPYY7aHR0cDovL2NybC5z
# ZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljVGltZVN0YW1waW5nUm9vdFI0Ni5jcmww
# fAYIKwYBBQUHAQEEcDBuMEcGCCsGAQUFBzAChjtodHRwOi8vY3J0LnNlY3RpZ28u
# Y29tL1NlY3RpZ29QdWJsaWNUaW1lU3RhbXBpbmdSb290UjQ2LnA3YzAjBggrBgEF
# BQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggIB
# ABLXeyCtDjVYDJ6BHSVY/UwtZ3Svx2ImIfZVVGnGoUaGdltoX4hDskBMZx5NY5L6
# SCcwDMZhHOmbyMhyOVJDwm1yrKYqGDHWzpwVkFJ+996jKKAXyIIaUf5JVKjccev3
# w16mNIUlNTkpJEor7edVJZiRJVCAmWAaHcw9zP0hY3gj+fWp8MbOocI9Zn78xvm9
# XKGBp6rEs9sEiq/pwzvg2/KjXE2yWUQIkms6+yslCRqNXPjEnBnxuUB1fm6bPAV+
# Tsr/Qrd+mOCJemo06ldon4pJFbQd0TQVIMLv5koklInHvyaf6vATJP4DfPtKzSBP
# kKlOtyaFTAjD2Nu+di5hErEVVaMqSVbfPzd6kNXOhYm23EWm6N2s2ZHCHVhlUgHa
# C4ACMRCgXjYfQEDtYEK54dUwPJXV7icz0rgCzs9VI29DwsjVZFpO4ZIVR33LwXyP
# DbYFkLqYmgHjR3tKVkhh9qKV2WCmBuC27pIOx6TYvyqiYbntinmpOqh/QPAnhDge
# xKG9GX/n1PggkGi9HCapZp8fRwg8RftwS21Ln61euBG0yONM6noD2XQPrFwpm3Gc
# uqJMf0o8LLrFkSLRQNwxPDDkWXhW+gZswbaiie5fd/W2ygcto78XCSPfFWveUOSZ
# 5SqK95tBO8aTHmEa4lpJVD7HrTEn9jb1EGvxOb1cnn0CMIIGXTCCBMWgAwIBAgIQ
# OlJqLITOVeYdZfzMEtjpiTANBgkqhkiG9w0BAQwFADBVMQswCQYDVQQGEwJHQjEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1Ymxp
# YyBUaW1lIFN0YW1waW5nIENBIFIzNjAeFw0yNDAxMTUwMDAwMDBaFw0zNTA0MTQy
# MzU5NTlaMG4xCzAJBgNVBAYTAkdCMRMwEQYDVQQIEwpNYW5jaGVzdGVyMRgwFgYD
# VQQKEw9TZWN0aWdvIExpbWl0ZWQxMDAuBgNVBAMTJ1NlY3RpZ28gUHVibGljIFRp
# bWUgU3RhbXBpbmcgU2lnbmVyIFIzNTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAI3RZ/TBSJu9/ThJOk1hgZvD2NxFpWEENo0GnuOYloD11BlbmKCGtcY0
# xiMrsN7LlEgcyoshtP3P2J/vneZhuiMmspY7hk/Q3l0FPZPBllo9vwT6GpoNnxXL
# Zz7HU2ITBsTNOs9fhbdAWr/Mm8MNtYov32osvjYYlDNfefnBajrQqSV8Wf5ZvbaY
# 5lZhKqQJUaXxpi4TXZKohLgxU7g9RrFd477j7jxilCU2ptz+d1OCzNFAsXgyPEM+
# NEMPUz2q+ktNlxMZXPF9WLIhOhE3E8/oNSJkNTqhcBGsbDI/1qCU9fBhuSojZ0u5
# /1+IjMG6AINyI6XLxM8OAGQmaMB8gs2IZxUTOD7jTFR2HE1xoL7qvSO4+JHtvNce
# Hu//dGeVm5Pdkay3Et+YTt9EwAXBsd0PPmC0cuqNJNcOI0XnwjE+2+Zk8bauVz5i
# r7YHz7mlj5Bmf7W8SJ8jQwO2IDoHHFC46ePg+eoNors0QrC0PWnOgDeMkW6gmLBt
# q3CEOSDU8iNicwNsNb7ABz0W1E3qlSw7jTmNoGCKCgVkLD2FaMs2qAVVOjuUxvmt
# WMn1pIFVUvZ1yrPIVbYt1aTld2nrmh544Auh3tgggy/WluoLXlHtAJgvFwrVsKXj
# 8ekFt0TmaPL0lHvQEe5jHbufhc05lvCtdwbfBl/2ARSTuy1s8CgFAgMBAAGjggGO
# MIIBijAfBgNVHSMEGDAWgBRfWO1MMXqiYUKNUoC6s2GXGaIymzAdBgNVHQ4EFgQU
# aO+kMklptlI4HepDOSz0FGqeDIUwDgYDVR0PAQH/BAQDAgbAMAwGA1UdEwEB/wQC
# MAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwSgYDVR0gBEMwQTA1BgwrBgEEAbIx
# AQIBAwgwJTAjBggrBgEFBQcCARYXaHR0cHM6Ly9zZWN0aWdvLmNvbS9DUFMwCAYG
# Z4EMAQQCMEoGA1UdHwRDMEEwP6A9oDuGOWh0dHA6Ly9jcmwuc2VjdGlnby5jb20v
# U2VjdGlnb1B1YmxpY1RpbWVTdGFtcGluZ0NBUjM2LmNybDB6BggrBgEFBQcBAQRu
# MGwwRQYIKwYBBQUHMAKGOWh0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1
# YmxpY1RpbWVTdGFtcGluZ0NBUjM2LmNydDAjBggrBgEFBQcwAYYXaHR0cDovL29j
# c3Auc2VjdGlnby5jb20wDQYJKoZIhvcNAQEMBQADggGBALDcLsn6TzZMii/2yU/V
# 7xhPH58Oxr/+EnrZjpIyvYTz2u/zbL+fzB7lbrPml8ERajOVbudan6x08J1RMXD9
# hByq+yEfpv1G+z2pmnln5XucfA9MfzLMrCArNNMbUjVcRcsAr18eeZeloN5V4jwr
# ovDeLOdZl0tB7fOX5F6N2rmXaNTuJR8yS2F+EWaL5VVg+RH8FelXtRvVDLJZ5uqS
# NIckdGa/eUFhtDKTTz9LtOUh46v2JD5Q3nt8mDhAjTKp2fo/KJ6FLWdKAvApGzjp
# PwDqFeJKf+kJdoBKd2zQuwzk5Wgph9uA46VYK8p/BTJJahKCuGdyKFIFfEfakC4N
# Xa+vwY4IRp49lzQPLo7WticqMaaqb8hE2QmCFIyLOvWIg4837bd+60FcCGbHwmL/
# g1ObIf0rRS9ceK4DY9rfBnHFH2v1d4hRVvZXyCVlrL7ZQuVzjjkLMK9VJlXTVkHp
# uC8K5S4HHTv2AJx6mOdkMJwS4gLlJ7gXrIVpnxG+aIniGDCCBoIwggRqoAMCAQIC
# EDbCsL18Gzrno7PdNsvJdWgwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpOZXcgSmVyc2V5MRQwEgYDVQQHEwtKZXJzZXkgQ2l0eTEeMBwG
# A1UEChMVVGhlIFVTRVJUUlVTVCBOZXR3b3JrMS4wLAYDVQQDEyVVU0VSVHJ1c3Qg
# UlNBIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MB4XDTIxMDMyMjAwMDAwMFoXDTM4
# MDExODIzNTk1OVowVzELMAkGA1UEBhMCR0IxGDAWBgNVBAoTD1NlY3RpZ28gTGlt
# aXRlZDEuMCwGA1UEAxMlU2VjdGlnbyBQdWJsaWMgVGltZSBTdGFtcGluZyBSb290
# IFI0NjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAIid2LlFZ50d3ei5
# JoGaVFTAfEkFm8xaFQ/ZlBBEtEFAgXcUmanU5HYsyAhTXiDQkiUvpVdYqZ1uYoZE
# MgtHES1l1Cc6HaqZzEbOOp6YiTx63ywTon434aXVydmhx7Dx4IBrAou7hNGsKioI
# BPy5GMN7KmgYmuu4f92sKKjbxqohUSfjk1mJlAjthgF7Hjx4vvyVDQGsd5KarLW5
# d73E3ThobSkob2SL48LpUR/O627pDchxll+bTSv1gASn/hp6IuHJorEu6EopoB1C
# NFp/+HpTXeNARXUmdRMKbnXWflq+/g36NJXB35ZvxQw6zid61qmrlD/IbKJA6COw
# /8lFSPQwBP1ityZdwuCysCKZ9ZjczMqbUcLFyq6KdOpuzVDR3ZUwxDKL1wCAxgL2
# Mpz7eZbrb/JWXiOcNzDpQsmwGQ6Stw8tTCqPumhLRPb7YkzM8/6NnWH3T9ClmcGS
# F22LEyJYNWCHrQqYubNeKolzqUbCqhSqmr/UdUeb49zYHr7ALL8bAJyPDmubNqMt
# uaobKASBqP84uhqcRY/pjnYd+V5/dcu9ieERjiRKKsxCG1t6tG9oj7liwPddXEcY
# GOUiWLm742st50jGwTzxbMpepmOP1mLnJskvZaN5e45NuzAHteORlsSuDt5t4BBR
# CJL+5EZnnw0ezntk9R8QJyAkL6/bAgMBAAGjggEWMIIBEjAfBgNVHSMEGDAWgBRT
# eb9aqitKz1SA4dibwJ3ysgNmyzAdBgNVHQ4EFgQU9ndq3T/9ARP/FqFsggIv0Ao9
# FCUwDgYDVR0PAQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwEQYDVR0gBAowCDAGBgRVHSAAMFAGA1UdHwRJMEcwRaBDoEGGP2h0
# dHA6Ly9jcmwudXNlcnRydXN0LmNvbS9VU0VSVHJ1c3RSU0FDZXJ0aWZpY2F0aW9u
# QXV0aG9yaXR5LmNybDA1BggrBgEFBQcBAQQpMCcwJQYIKwYBBQUHMAGGGWh0dHA6
# Ly9vY3NwLnVzZXJ0cnVzdC5jb20wDQYJKoZIhvcNAQEMBQADggIBAA6+ZUHtaES4
# 5aHF1BGH5Lc7JYzrftrIF5Ht2PFDxKKFOct/awAEWgHQMVHol9ZLSyd/pYMbaC0I
# Z+XBW9xhdkkmUV/KbUOiL7g98M/yzRyqUOZ1/IY7Ay0YbMniIibJrPcgFp73WDnR
# DKtVutShPSZQZAdtFwXnuiWl8eFARK3PmLqEm9UsVX+55DbVIz33Mbhba0HUTEYv
# 3yJ1fwKGxPBsP/MgTECimh7eXomvMm0/GPxX2uhwCcs/YLxDnBdVVlxvDjHjO1cu
# wbOpkiJGHmLXXVNbsdXUC2xBrq9fLrfe8IBsA4hopwsCj8hTuwKXJlSTrZcPRVSc
# cP5i9U28gZ7OMzoJGlxZ5384OKm0r568Mo9TYrqzKeKZgFo0fj2/0iHbj55hc20j
# fxvK3mQi+H7xpbzxZOFGm/yVQkpo+ffv5gdhp+hv1GDsvJOtJinJmgGbBFZIThbq
# I+MHvAmMmkfb3fTxmSkop2mSJL1Y2x/955S29Gu0gSJIkc3z30vU/iXrMpWx2tS7
# UVfVP+5tKuzGtgkP7d/doqDrLF1u6Ci3TpjAZdeLLlRQZm867eVeXED58LXd1Dk6
# UvaAhvmWYXoiLz4JA5gPBcz7J311uahxCweNxE+xxxR3kT0WKzASo5G/PyDez6NH
# dIUKBeE3jDPs2ACc6CkJ1Sji4PKWVT0/MIIG6DCCBNCgAwIBAgIQd70OBbdZC7Yd
# R2FTHj917TANBgkqhkiG9w0BAQsFADBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQ
# R2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25p
# bmcgUm9vdCBSNDUwHhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4MDAwMDAwWjBcMQsw
# CQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMp
# R2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLIO+XHrkBMkOgW6mKI/0gXq44EovK
# LNT/QdgaVdQZU7f9oxfnejlcwPfOEaP5pe0B+rW6k++vk9z44rMZTIOwSkRQBHiE
# EGqk1paQjoH4fKsvtaNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS0PC0VV+WCxHlmrUs
# shHPJRt9USuYH0mjX/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS7L1AldMRyubNswWc
# yFPrUtd4TFEBkoLeE/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+p7JBMyB1zLHV7R0H
# GcTrJnfyq20Xk0mpt+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HPmFWjJKKINvL5n76T
# LrIGnybADAFWEuGyip8OHtyYiy7P2uKJNKYfJqCornht7KGIFTzC6u632K1hpa9w
# NqJ5jtwNc8Dx5CyrlOxYBjk2SNY7WugiznQOryzxFdrRtJXorNVJbeWv3ZtrYyBd
# jn47skPYYjqU5c20mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5tx2nTbrcBbA3gl6cW
# 5iaLiPcDRIZfYmdMtac3qFXcAzaMbs9tNibxDo+wPXHA4TKnguS2MgIyMHy1k8gh
# /TyI5mlj+O51yYvCq++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuVxBKH5xq4Tu4swd+h
# Zegkg8kqwv25UwIDAQABo4IBrTCCAakwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFCWd0PxZ
# CYZjxezzsRM7VxwDkjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4ObeltEPZVlC7zpY7
# MIGTBggrBgEFBQcBAQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0cDovL29jc3AuZ2xv
# YmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1MEYGCCsGAQUFBzAChjpodHRw
# Oi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9jb2Rlc2lnbmluZ3Jvb3Ry
# NDUuY3J0MEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5j
# b20vY29kZXNpZ25pbmdyb290cjQ1LmNybDBVBgNVHSAETjBMMEEGCSsGAQQBoDIB
# AjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBv
# c2l0b3J5LzAHBgVngQwBAzANBgkqhkiG9w0BAQsFAAOCAgEAJXWgCck5urehOYkv
# GJ+r1usdS+iUfA0HaJscne9xthdqawJPsz+GRYfMZZtM41gGAiJm1WECxWOP1KLx
# tl4lC3eW6c1xQDOIKezu86JtvE21PgZLyXMzyggULT1M6LC6daZ0LaRYOmwTSfil
# FQoUloWxamg0JUKvllb0EPokffErcsEW4Wvr5qmYxz5a9NAYnf10l4Z3Rio9I30o
# c4qu7ysbmr9sU6cUnjyHccBejsj70yqSM+pXTV4HXsrBGKyBLRoh+m7Pl2F733F6
# Ospj99UwRDcy/rtDhdy6/KbKMxkrd23bywXwfl91LqK2vzWqNmPJzmTZvfy8LPNJ
# VgDIEivGJ7s3r1fvxM8eKcT04i3OKmHPV+31CkDi9RjWHumQL8rTh1+TikgaER3l
# N4WfLmZiml6BTpWsVVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4hu5/XanGAv5becgPY
# 2CIr8ycWTzjoUUAMrpLvvj1994DGTDZXhJWnhBVIMA5SJwiNjqK9IscZyabKDqh6
# NttqumFfESSVpOKOaO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGHJNPE+6ljy3dI1fpi
# /CTgBHpO0ORu3s6eOFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV0NMe9n9S4kmNuRFy
# DIhEJjNmAUTf5DMOId5iiUgH2vUwggfPMIIFt6ADAgECAgxK83pmt0FjEC8TCzUw
# DQYJKoZIhvcNAQELBQAwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNp
# Z24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2ln
# bmluZyBDQSAyMDIwMB4XDTI0MDQwMzE1NDExNloXDTI1MDQwNDE1NDExNlowggEO
# MR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjERMA8GA1UEBRMIMTMzMzcz
# NDMxEzARBgsrBgEEAYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdCMRswGQYDVQQIExJH
# cmVhdGVyIE1hbmNoZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0ZXIxGTAXBgNVBAkT
# EDE3IE1hcmJsZSBTdHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1p
# dGVkMSAwHgYDVQQDExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEnMCUGCSqGSIb3
# DQEJARYYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAngoTokY2HYu5xPv9s5LrBGLS72AwwIEk4huasmriK3lF
# C7ludj4D+m+khHMDGX/dAWmLDIvW3LiNcmfQtJYW28grUXCo95ZXP6nR8J/cI2iO
# tHHp2/HvfNVV60hzhZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq3f+CSOSZ4FdU6ISs
# AqZeRsazr/XA2b0apQceLiYVPeORUNsIgfElvcCHhmA5jB8Sl/2F5JUpvPC58Tc5
# 3dQUWpz5dFW5Cav1BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj0E2TxzADesGjJ4CZ
# 8PU8JTVBhIcb7d+9WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1ouCfJEsYeeBny8EQ
# Iy1lFuoLfBOGHf+tsT++wKHVkr4BjHhjOT+XwUItwXt/WmwKLuH0t6lgBHGlstap
# +6dBcQC66ZUCMi8OiZ8+3dM8ySiRO4UHBH26lSWc7oMYQexgX6O1XCgyxCX3MJfE
# cJrIlOEEBq11M9cHKvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W1b7LusHpyFwd3pRP
# paF6pKloa7bmPm8R6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7h9fTCdJMu0QADsLA
# okrZed2D6HKX/uCmJ8fJwgxSalOUwyufT2r9LtRBr+fS6NNgHEhMP+pJxFajqpEC
# AwEAAaOCAdswggHXMA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYBBQUHAQEEgZIwgY8w
# TAYIKwYBBQUHMAKGQGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0
# L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYBBQUHMAGGM2h0dHA6
# Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMDBV
# BgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3
# dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAJBgNVHRMEAjAA
# MEcGA1UdHwRAMD4wPKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vZ3Nn
# Y2NyNDVldmNvZGVzaWduY2EyMDIwLmNybDAjBgNVHREEHDAagRhtYXR0Lm1ja2lu
# c3RyeUBjbG91ZG0uaW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMwHwYDVR0jBBgwFoAU
# JZ3Q/FkJhmPF7POxEztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp6FGOpQ5ruRZYclGh
# R1msMA0GCSqGSIb3DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlhqLQpOawqxF133UUT
# N4wKocLfqlsv9p1a5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJomnX76vojinvqiLsN
# r0f2zKcquyfBmaCKxg+ubXXuWNhysM5602eelsSF5wFpKm1SmKAuvolB79Pq5uS2
# y8ZU37b9NkYulcyFDIPTuBSZydUvNQP4ATVocen0hIGkZFGfqnIowfyzFjvXU3+T
# 9Vrc3BTAUoYEsUK0OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAolFZHqEfIy+K1HkWk
# q0dz4+bVpJlTqTAHHRIwoR5oe4GniTXTrH7/MlFzC+M4EriU7A0evdDRhxHA3D8I
# AMU2rS5rkQkk7h+rQ/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d9H8R46iW393Lg8vp
# itandd37zKUfUuvbG/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+ye29b4/3SJDk+3eZ+
# Agabmym+o40LTSBng0jXHr+rbNm4z6Tooghd2dfoOPxzFC2VsVUK+WwCsJJZYa2u
# pE49ayk2RI2QkZGgaXDk94woo6pBuYq+yGeyDm6a0rnuAimIxNDc3KNSLiaw48DP
# 9nAYS8bO1yirSh77l/83vMoLySHTU3fvcHMLpnpCSRha6iYCz1q9xwrReCYrgJxc
# +y2IyxK95zGCBjswggY3AgEBMGwwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBD
# b2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZIAWUDBAIBBQCg
# fDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAc
# BgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJWHZ
# ZvLn4LAlvCDSFc915dLqZuOuINCsTRY7XFgZk2MwDQYJKoZIhvcNAQEBBQAEggIA
# Q+QlkLCti3/dJJpgGdLseQg3zlJNlP/KzMMAYefb2WRXlu0p4CwZM0eMRdoG57Ei
# zJqax2MI+I7M1K/WEbOiA9qovlJQsw+SCCvyBT1HOmVC1wwyWBNbWQYr5z8f6jgT
# owkf7faj5MtCp/S3zni4S7pXkrDRxtrQa7Ta+ha41vqrZ58noxwQa04OSn3m/G4Z
# J2rJH72A6fflmHipCt9IvFzjm7+4Rtse8Q+eISsM9B/5dcmsQXeIqfWF08VTiaB2
# M46wQLkRgFmdHZqnFu2ZXZi6XbYR9R6E9/NtNyKTk6uGIqWLmUEL44et6IBAdsiV
# zpIUfVIBviMYTjAkEwM+Cq7SqIJMFUrm5qD5ohLN0f25F2E1gz6FnOtDm2djBgPi
# caRLkgGF36JFrzGw9s/Ml1JYUJ9UMfb3PBwFtFh/SBOR8hVIMrT8YMwp9Ve5r0sV
# 7qODclBeFvNvkT0CBeHP0ANG4NpSoDj7gOAt4yBZdJwBjQFLv71fPCOpRZJFmNvG
# gEdh+wfvJ1BRKyhQCWD1wblethEE74ty3HNB90xETLm6Ge5CuHC7JxnpzwPNdIJs
# zWn1/9WJL1XptREce8ZDuq6LZk+hmA50hDf4FjcMsCCyY3ikhj9DpPz/LNt1k5qp
# 0e2KV8jGFCyNH/tnHTzAbWMODRIQJqLeSdBdRlc5X4GhggMiMIIDHgYJKoZIhvcN
# AQkGMYIDDzCCAwsCAQEwaTBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5n
# IENBIFIzNgIQOlJqLITOVeYdZfzMEtjpiTANBglghkgBZQMEAgIFAKB5MBgGCSqG
# SIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI0MTAwNDEzMTc0
# NlowPwYJKoZIhvcNAQkEMTIEMCeV1dffqR+j5zWw/2rTrVIOJU+rkFqD3VGr7LUy
# ZFKY2z3+1NlrIpt5tyuxUKRwRjANBgkqhkiG9w0BAQEFAASCAgAu2mF6ebPxqRLx
# OA2eOK+FlfJsEyhNNIISnQfJH1+aqHjTaXe98+rDfPv3pq3kdCbF2IrEQFX1J3QE
# wD5+QEAIMPY1xettRwXVbreZxW+coUo28wlqTRnkNT51n621otqmlr1VTnxYakek
# 0Lx9hqK4tksz4CXORAPcx7kt+7DLSE3QZ+MQfsEHcrpfu+msV6Wtmcdw5WrlF40a
# AarauzeSRpTHmnfNO6iJilJUe2oqJUpfnFZt5fx2hOA45HzAjH+LmGOzWSAKQmPk
# rVfdSehJDCUFzG1wBoAnUZJZnJZaHrRszkxwhbaG4KanDqLgBV6WELPrE0ixklyt
# OTdL+ugqB5CCsOaeTqKRF6dGrAdKgKJKtMykYndq35vn2KmCoqdO203PpMqWy9Vr
# BBtPfHCRdt0JiV25aKkaw/Dtcia5jD8/b/GXMJqai+JehCVfjsiAg++fieeawsgj
# mJKohHcIR4D4hInazrzvRYRevIyjzECuqL4TZu1XMDu4/P0tNAM2p+l4EnpRZjBQ
# gWoPPeJ67Gu5I2Q/dZTduGLUA8DIC6kH3wtYKtH2K5jQHrOnoP3FV88FFjPLoxlG
# suMD6zipz8n7jps5w9kdCzJtVhRoWvdGbZ+Rsfpc7G2hAFqN9gUN8E5mCnGIuBZQ
# 6kzekDCXb71DrOgbAz8IMU85wlSxqQ==
# SIG # End signature block
