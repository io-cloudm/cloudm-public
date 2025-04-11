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
# MIJ00gYJKoZIhvcNAQcCoIJ0wzCCdL8CAQExDTALBglghkgBZQMEAgEweQYKKwYB
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
# 73BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxgkzCMIJMvgIBATBsMFwx
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
# 3knQXUZXOV+BoYJJqTCCAxwGCSqGSIb3DQEJBjGCAw0wggMJAgEBMHcwYzELMAkG
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
# H5oYKbonaH9hBC/ajZptJbwjcTd6IL9PGHW6Qp2sFS+5OF91QVR11f1CCZ8XMIJG
# hQYKKwYBBAGCNwIEATGCRnUwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEPMA0G
# CWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4wJgID
# AQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUD
# BAIBBQAEIOPpGC+lZEsaMJD6Xc6/SYGNmmLeAbR6WGXQBRCu6UgUoIIUZTCCBaIw
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
# 3knQXUZXOV+BMIIuSQYJKoZIhvcNAQcCoIIuOjCCLjYCAQExDzANBglghkgBZQME
# AgEFADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7
# YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDj
# 6RgvpWRLGjCQ+l3Ov0mBjZpi3gG0elhl0AUQrulIFKCCJ2QwggWiMIIEiqADAgEC
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
# GvFNbDDUswarAGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggYUMIID
# /KADAgECAhB6I67aU2mWD5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNV
# BAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3Rp
# Z28gUHVibGljIFRpbWUgU3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAw
# WhcNMzYwMzIxMjM1OTU5WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGln
# byBMaW1pdGVkMSwwKgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5n
# IENBIFIzNjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26C
# K+z2M34mNOSJjNPvIhKAVD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3aj
# oW3cS3ElcJzkyZlBnwDEJuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhh
# nOSwcjPMI3G0hedv2eNmGiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AV
# Zn0GiOUC9+XE0wI7CQKfOUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA
# +uBvq1KO8RSHUQLgzb1gbL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL
# 19zpHsODLIsgZ+WZ1AzCs1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRe
# zKe7WNyxRf4e4bwUtrYE2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5
# sMM/caEZLtOYqYadtn034ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IB
# XDCCAVgwHwYDVR0jBBgwFoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYE
# FF9Y7UwxeqJhQo1SgLqzYZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8E
# CDAGAQH/AgEAMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0g
# ADBMBgNVHR8ERTBDMEGgP6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3Rp
# Z29QdWJsaWNUaW1lU3RhbXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4w
# RwYIKwYBBQUHMAKGO2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1Ymxp
# Y1RpbWVTdGFtcGluZ1Jvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2Nz
# cC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9
# TC1ndK/HYiYh9lVUacahRoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPC
# bXKspioYMdbOnBWQUn733qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51Ul
# mJElUICZYBodzD3M/SFjeCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db
# 8qNcTbJZRAiSazr7KyUJGo1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2if
# ikkVtB3RNBUgwu/mSiSUice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmES
# sRVVoypJVt8/N3qQ1c6FibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh
# 1TA8ldXuJzPSuALOz1Ujb0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2
# opXZYKYG4Lbukg7HpNi/KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlm
# nx9HCDxF+3BLbUufrV64EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8
# MORZeFb6BmzBtqKJ7l939bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklU
# PsetMSf2NvUQa/E5vVyefQIwggZdMIIExaADAgECAhA6UmoshM5V5h1l/MwS2OmJ
# MA0GCSqGSIb3DQEBDAUAMFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdv
# IExpbWl0ZWQxLDAqBgNVBAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcg
# Q0EgUjM2MB4XDTI0MDExNTAwMDAwMFoXDTM1MDQxNDIzNTk1OVowbjELMAkGA1UE
# BhMCR0IxEzARBgNVBAgTCk1hbmNoZXN0ZXIxGDAWBgNVBAoTD1NlY3RpZ28gTGlt
# aXRlZDEwMC4GA1UEAxMnU2VjdGlnbyBQdWJsaWMgVGltZSBTdGFtcGluZyBTaWdu
# ZXIgUjM1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAjdFn9MFIm739
# OEk6TWGBm8PY3EWlYQQ2jQae45iWgPXUGVuYoIa1xjTGIyuw3suUSBzKiyG0/c/Y
# n++d5mG6IyayljuGT9DeXQU9k8GWWj2/BPoamg2fFctnPsdTYhMGxM06z1+Ft0Ba
# v8ybww21ii/faiy+NhiUM195+cFqOtCpJXxZ/lm9tpjmVmEqpAlRpfGmLhNdkqiE
# uDFTuD1GsV3jvuPuPGKUJTam3P53U4LM0UCxeDI8Qz40Qw9TPar6S02XExlc8X1Y
# siE6ETcTz+g1ImQ1OqFwEaxsMj/WoJT18GG5KiNnS7n/X4iMwboAg3IjpcvEzw4A
# ZCZowHyCzYhnFRM4PuNMVHYcTXGgvuq9I7j4ke281x4e7/90Z5Wbk92RrLcS35hO
# 30TABcGx3Q8+YLRy6o0k1w4jRefCMT7b5mTxtq5XPmKvtgfPuaWPkGZ/tbxInyND
# A7YgOgccULjp4+D56g2iuzRCsLQ9ac6AN4yRbqCYsG2rcIQ5INTyI2JzA2w1vsAH
# PRbUTeqVLDuNOY2gYIoKBWQsPYVoyzaoBVU6O5TG+a1YyfWkgVVS9nXKs8hVti3V
# pOV3aeuaHnjgC6He2CCDL9aW6gteUe0AmC8XCtWwpePx6QW3ROZo8vSUe9AR7mMd
# u5+FzTmW8K13Bt8GX/YBFJO7LWzwKAUCAwEAAaOCAY4wggGKMB8GA1UdIwQYMBaA
# FF9Y7UwxeqJhQo1SgLqzYZcZojKbMB0GA1UdDgQWBBRo76QySWm2Ujgd6kM5LPQU
# ap4MhTAOBgNVHQ8BAf8EBAMCBsAwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAK
# BggrBgEFBQcDCDBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDCDAlMCMGCCsGAQUF
# BwIBFhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAIwSgYDVR0fBEMw
# QTA/oD2gO4Y5aHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljVGlt
# ZVN0YW1waW5nQ0FSMzYuY3JsMHoGCCsGAQUFBwEBBG4wbDBFBggrBgEFBQcwAoY5
# aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljVGltZVN0YW1waW5n
# Q0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTAN
# BgkqhkiG9w0BAQwFAAOCAYEAsNwuyfpPNkyKL/bJT9XvGE8fnw7Gv/4SetmOkjK9
# hPPa7/Nsv5/MHuVus+aXwRFqM5Vu51qfrHTwnVExcP2EHKr7IR+m/Ub7PamaeWfl
# e5x8D0x/MsysICs00xtSNVxFywCvXx55l6Wg3lXiPCui8N4s51mXS0Ht85fkXo3a
# uZdo1O4lHzJLYX4RZovlVWD5EfwV6Ve1G9UMslnm6pI0hyR0Zr95QWG0MpNPP0u0
# 5SHjq/YkPlDee3yYOECNMqnZ+j8onoUtZ0oC8CkbOOk/AOoV4kp/6Ql2gEp3bNC7
# DOTlaCmH24DjpVgryn8FMklqEoK4Z3IoUgV8R9qQLg1dr6/BjghGnj2XNA8ujta2
# JyoxpqpvyETZCYIUjIs69YiDjzftt37rQVwIZsfCYv+DU5sh/StFL1x4rgNj2t8G
# ccUfa/V3iFFW9lfIJWWsvtlC5XOOOQswr1UmVdNWQem4LwrlLgcdO/YAnHqY52Qw
# nBLiAuUnuBeshWmfEb5oieIYMIIGgjCCBGqgAwIBAgIQNsKwvXwbOuejs902y8l1
# aDANBgkqhkiG9w0BAQwFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCk5ldyBK
# ZXJzZXkxFDASBgNVBAcTC0plcnNleSBDaXR5MR4wHAYDVQQKExVUaGUgVVNFUlRS
# VVNUIE5ldHdvcmsxLjAsBgNVBAMTJVVTRVJUcnVzdCBSU0EgQ2VydGlmaWNhdGlv
# biBBdXRob3JpdHkwHhcNMjEwMzIyMDAwMDAwWhcNMzgwMTE4MjM1OTU5WjBXMQsw
# CQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMS4wLAYDVQQDEyVT
# ZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFJvb3QgUjQ2MIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAiJ3YuUVnnR3d6LkmgZpUVMB8SQWbzFoVD9mU
# EES0QUCBdxSZqdTkdizICFNeINCSJS+lV1ipnW5ihkQyC0cRLWXUJzodqpnMRs46
# npiJPHrfLBOifjfhpdXJ2aHHsPHggGsCi7uE0awqKggE/LkYw3sqaBia67h/3awo
# qNvGqiFRJ+OTWYmUCO2GAXsePHi+/JUNAax3kpqstbl3vcTdOGhtKShvZIvjwulR
# H87rbukNyHGWX5tNK/WABKf+Gnoi4cmisS7oSimgHUI0Wn/4elNd40BFdSZ1Ewpu
# ddZ+Wr7+Dfo0lcHflm/FDDrOJ3rWqauUP8hsokDoI7D/yUVI9DAE/WK3Jl3C4LKw
# Ipn1mNzMyptRwsXKrop06m7NUNHdlTDEMovXAIDGAvYynPt5lutv8lZeI5w3MOlC
# ybAZDpK3Dy1MKo+6aEtE9vtiTMzz/o2dYfdP0KWZwZIXbYsTIlg1YIetCpi5s14q
# iXOpRsKqFKqav9R1R5vj3NgevsAsvxsAnI8Oa5s2oy25qhsoBIGo/zi6GpxFj+mO
# dh35Xn91y72J4RGOJEoqzEIbW3q0b2iPuWLA911cRxgY5SJYubvjay3nSMbBPPFs
# yl6mY4/WYucmyS9lo3l7jk27MAe145GWxK4O3m3gEFEIkv7kRmefDR7Oe2T1HxAn
# ICQvr9sCAwEAAaOCARYwggESMB8GA1UdIwQYMBaAFFN5v1qqK0rPVIDh2JvAnfKy
# A2bLMB0GA1UdDgQWBBT2d2rdP/0BE/8WoWyCAi/QCj0UJTAOBgNVHQ8BAf8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUEDDAKBggrBgEFBQcDCDARBgNVHSAE
# CjAIMAYGBFUdIAAwUAYDVR0fBEkwRzBFoEOgQYY/aHR0cDovL2NybC51c2VydHJ1
# c3QuY29tL1VTRVJUcnVzdFJTQUNlcnRpZmljYXRpb25BdXRob3JpdHkuY3JsMDUG
# CCsGAQUFBwEBBCkwJzAlBggrBgEFBQcwAYYZaHR0cDovL29jc3AudXNlcnRydXN0
# LmNvbTANBgkqhkiG9w0BAQwFAAOCAgEADr5lQe1oRLjlocXUEYfktzsljOt+2sgX
# ke3Y8UPEooU5y39rAARaAdAxUeiX1ktLJ3+lgxtoLQhn5cFb3GF2SSZRX8ptQ6Iv
# uD3wz/LNHKpQ5nX8hjsDLRhsyeIiJsms9yAWnvdYOdEMq1W61KE9JlBkB20XBee6
# JaXx4UBErc+YuoSb1SxVf7nkNtUjPfcxuFtrQdRMRi/fInV/AobE8Gw/8yBMQKKa
# Ht5eia8ybT8Y/Ffa6HAJyz9gvEOcF1VWXG8OMeM7Vy7Bs6mSIkYeYtddU1ux1dQL
# bEGur18ut97wgGwDiGinCwKPyFO7ApcmVJOtlw9FVJxw/mL1TbyBns4zOgkaXFnn
# fzg4qbSvnrwyj1NiurMp4pmAWjR+Pb/SIduPnmFzbSN/G8reZCL4fvGlvPFk4Uab
# /JVCSmj59+/mB2Gn6G/UYOy8k60mKcmaAZsEVkhOFuoj4we8CYyaR9vd9PGZKSin
# aZIkvVjbH/3nlLb0a7SBIkiRzfPfS9T+JesylbHa1LtRV9U/7m0q7Ma2CQ/t392i
# oOssXW7oKLdOmMBl14suVFBmbzrt5V5cQPnwtd3UOTpS9oCG+ZZheiIvPgkDmA8F
# zPsnfXW5qHELB43ET7HHFHeRPRYrMBKjkb8/IN7Po0d0hQoF4TeMM+zYAJzoKQnV
# KOLg8pZVPT8wggboMIIE0KADAgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0GCSqGSIb3
# DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNh
# MSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTAeFw0y
# MDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJFMRkwFwYD
# VQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBS
# NDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV1BlTt/2jF+d6
# OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8qy+1o1cz
# 0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gfSaNf+BOe
# NbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS13hMUQGSgt4T8weO
# dLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXtHQcZxOsmd/KrbReTSam35sOQ
# nMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmfvpMusgafJsAMAVYS4bKKnw4e
# 3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGlr3A2onmO3A1zwPHkLKuU7FgG
# OTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTlzbSYszcZ
# JBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCXpxbmJouI9wNEhl9iZ0y1pzeo
# VdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJi8Kr77o6
# /elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB36Fl6CSDySrC/blTAgMBAAGj
# ggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYD
# VR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztXHAOSNhEw
# HwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsGAQUFBwEBBIGG
# MIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9jb2Rl
# c2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUuZ2xvYmFs
# c2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYDVR0fBDow
# ODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jv
# b3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEW
# Jmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAED
# MA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8DQdomxyd
# 73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/UovG2XiULd5bpzXFAM4gp7O7z
# om28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQlQq+WVvQQ
# +iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0jfShziq7vKxuav2xTpxSePIdx
# wF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvfcXo6ymP31TBENzL+u0OF3Lr8
# psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgSK8YnuzevV+/Ezx4p
# xPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFOlaxVV0Pc
# U4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZPOOhRQAyuku++
# PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoOqHo222q6YV8RJJWk4o5o7hmp
# SZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV+mL8JOAEek7Q5G7ezp44UCb0
# IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/kMw4h3mKJ
# SAfa9TCCB88wggW3oAMCAQICDErzema3QWMQLxMLNTANBgkqhkiG9w0BAQsFADBc
# MQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UE
# AxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwHhcN
# MjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8MFFByaXZh
# dGUgT3JnYW5pemF0aW9uMREwDwYDVQQFEwgxMzMzNzM0MzETMBEGCysGAQQBgjc8
# AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3Rl
# cjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZMBcGA1UECRMQMTcgTWFyYmxlIFN0cmVl
# dDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNVBAMTF0Ns
# b3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0Lm1ja2lu
# c3RyeUBjbG91ZG0uaW8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCe
# ChOiRjYdi7nE+/2zkusEYtLvYDDAgSTiG5qyauIreUULuW52PgP6b6SEcwMZf90B
# aYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/qdHwn9wjaI60cenb8e981VXrSHOFlTRn
# LFv2BEpiqtH0as26jTyt8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZvRqlBx4u
# JhU945FQ2wiB8SW9wIeGYDmMHxKX/YXklSm88LnxNznd1BRanPl0VbkJq/UF0Ffz
# N913qu/PxmE5gpak+QQr3JPYtCPQTZPHMAN6waMngJnw9TwlNUGEhxvt371Y2Fxo
# vdUZyDLuRKxUq7cKexhb2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd/62xP77A
# odWSvgGMeGM5P5fBQi3Be39abAou4fS3qWAEcaWy1qn7p0FxALrplQIyLw6Jnz7d
# 0zzJKJE7hQcEfbqVJZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz1wcq+Fy6
# l+4Km+9f5roKK4dNFETf5srRH5bVvsu6wenIXB3elE+loXqkqWhrtuY+bxHoZ1wW
# 1W6FNCh0a9eacSpqBccPahqghnuH19MJ0ky7RAAOwsCiStl53YPocpf+4KYnx8nC
# DFJqU5TDK59Pav0u1EGv59Lo02AcSEw/6knEVqOqkQIDAQABo4IB2zCCAdcwDgYD
# VR0PAQH/BAQDAgeAMIGfBggrBgEFBQcBAQSBkjCBjzBMBggrBgEFBQcwAoZAaHR0
# cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVldmNvZGVz
# aWduY2EyMDIwLmNydDA/BggrBgEFBQcwAYYzaHR0cDovL29jc3AuZ2xvYmFsc2ln
# bi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwMFUGA1UdIAROMEwwQQYJKwYB
# BAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29t
# L3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAwPjA8oDqg
# OIY2aHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25j
# YTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzAT
# BgNVHSUEDDAKBggrBgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs87ETO1cc
# A5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6lDmu5FlhyUaFHWawwDQYJKoZIhvcNAQEL
# BQADggIBAMriJ8rqBFu9wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2nVrl892c
# PNQe4WeoagqZ1a0c7SRPijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7J8GZoIrGD65t
# de5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTftv02Ri6VzIUMg9O4
# FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBShgSxQrQ5Li4l
# w4SKpburQecVnB6f7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOpMAcdEjCh
# Hmh7gaeJNdOsfv8yUXML4zgSuJTsDR690NGHEcDcPwgAxTatLmuRCSTuH6tD/gG4
# ES38Q1mz7joDNkpR79/IzKfYHl30fxHjqJbf3cuDy+mK1qd13fvMpR9S69sb8bPd
# JDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj/dIkOT7d5n4CBpubKb6jjQtNIGeDSNce
# v6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5bAKwkllhra6kTj1rKTZEjZCRkaBpcOT3
# jCijqkG5ir7IZ7IObprSue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtKHvuX/ze8
# ygvJIdNTd+9wcwumekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3nMYIGOzCCBjcC
# AQEwbDBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEy
# MDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIw
# MjACDErzema3QWMQLxMLNTANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwx
# AjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAM
# BgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAlYdlm8ufgsCW8INIVz3Xl0upm
# 464g0KxNFjtcWBmTYzANBgkqhkiG9w0BAQEFAASCAgBD5CWQsK2Lf90kmmAZ0ux5
# CDfOUk2U/8rMwwBh59vZZFeW7SngLBkzR4xF2gbnsSLMmprHYwj4jszUr9YRs6ID
# 2qi+UlCzD5IIK/IFPUc6ZULXDDJYE1tZBivnPx/qOBOjCR/t9qPky0Kn9LfOeLhL
# uleSsNHG2tBrtNr6FrjW+qtnnyejHBBrTg5Kfeb8bhknaskfvYDp9+WYeKkK30i8
# XOObv7hG2x7xD54hKwz0H/l1yaxBd4ip9YXTxVOJoHYzjrBAuRGAWZ0dmqcW7Zld
# mLpdthH1HoT38203IpOTq4YipYuZQQvjh63ogEB2yJXOkhR9UgG+IxhOMCQTAz4K
# rtKogkwVSubmoPmiEs3R/bkXYTWDPoWc60ObZ2MGA+JxpEuSAYXfokWvMbD2z8yX
# UlhQn1Qx9vc8HAW0WH9IE5HyFUgytPxgzCn1V7mvSxXuo4NyUF4W82+RPQIF4c/Q
# A0bg2lKgOPuA4C3jIFl0nAGNAUu/vV88I6lFkkWY28aAR2H7B+8nUFErKFAJYPXB
# uV62EQTvi3Lcc0H3TERMuboZ7kK4cLsnGenPA810gmzNafX/1YkvVem1ERx7xkO6
# rotmT6GYDnSEN/gWNwywILJjeKSGP0Ok/P8s23WTmqnR7YpXyMYULI0f+2cdPMBt
# Yw4NEhAmot5J0F1GVzlfgaGCAyIwggMeBgkqhkiG9w0BCQYxggMPMIIDCwIBATBp
# MFUxCzAJBgNVBAYTAkdCMRgwFgYDVQQKEw9TZWN0aWdvIExpbWl0ZWQxLDAqBgNV
# BAMTI1NlY3RpZ28gUHVibGljIFRpbWUgU3RhbXBpbmcgQ0EgUjM2AhA6UmoshM5V
# 5h1l/MwS2OmJMA0GCWCGSAFlAwQCAgUAoHkwGAYJKoZIhvcNAQkDMQsGCSqGSIb3
# DQEHATAcBgkqhkiG9w0BCQUxDxcNMjQxMDA0MTMxNzQ2WjA/BgkqhkiG9w0BCQQx
# MgQwJ5XV19+pH6PnNbD/atOtUg4lT6uQWoPdUavstTJkUpjbPf7U2Wsim3m3K7FQ
# pHBGMA0GCSqGSIb3DQEBAQUABIICAC7aYXp5s/GpEvE4DZ44r4WV8mwTKE00ghKd
# B8kfX5qoeNNpd73z6sN8+/emreR0JsXYisRAVfUndATAPn5AQAgw9jXF621HBdVu
# t5nFb5yhSjbzCWpNGeQ1PnWfrbWi2qaWvVVOfFhqR6TQvH2Gori2SzPgJc5EA9zH
# uS37sMtITdBn4xB+wQdyul+76axXpa2Zx3DlauUXjRoBqtq7N5JGlMead807qImK
# UlR7aiolSl+cVm3l/HaE4DjkfMCMf4uYY7NZIApCY+StV91J6EkMJQXMbXAGgCdR
# klmclloetGzOTHCFtobgpqcOouAFXpYQs+sTSLGSXK05N0v66CoHkIKw5p5OopEX
# p0asB0qAokq0zKRid2rfm+fYqYKip07bTc+kypbL1WsEG098cJF23QmJXbloqRrD
# 8O1yJrmMPz9v8ZcwmpqL4l6EJV+OyICD75+J55rCyCOYkqiEdwhHgPiEidrOvO9F
# hF68jKPMQK6ovhNm7VcwO7j8/S00Azan6XgSelFmMFCBag894nrsa7kjZD91lN24
# YtQDwMgLqQffC1gq0fYrmNAes6eg/cVXzwUWM8ujGUay4wPrOKnPyfuOmznD2R0L
# Mm1WFGha90Ztn5Gx+lzsbaEAWo32BQ3wTmYKcYi4FlDqTN6QMJdvvUOs6BsDPwgx
# TznCVLGp
# SIG # End signature block
