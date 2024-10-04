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
        ImportModules -moduleName Microsoft.Graph.Groups -requiredVersion 2.10.0
        ImportModules -moduleName Microsoft.Graph.Teams -requiredVersion 2.10.0
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

function MoveFiles([parameter(mandatory)][String]$sourceFolder, [parameter(mandatory)][String]$ClientAppId) {
    $destinationPath = Join-Path -Path $workFolder -ChildPath "CloudM-Limited-App-$($ClientAppId)"
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    $file = Join-Path -Path $workFolder -ChildPath "MicrosoftTeamGroup.csv" 
    if ((Test-Path -Path $file -PathType Leaf)) {
        $newFile = "$($destinationPath)\MicrosoftTeamGroup - $($ClientAppId) - $(Get-Date -UFormat %d-%m-%Y-%H.%M.%S).csv"
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

$WorkFolder = ""
$MailGroupAlias = ""
$TenantName = ""
$ClientAppId = ""
$ClientAppCertificate = ""
$ClientAppCertificatePassword = ""
$Environment = "Global"
ImportCloudMModules -WorkFolder $WorkFolder -limitedScope $true


$ProcessMicrosoftTeamGroupCsv = @{
    WorkFolder                = $WorkFolder
    SecureCertificatePassword = GetSecurePassword($ClientAppCertificatePassword)
    MailGroupAlias            = $MailGroupAlias
    ClientAppId               = $ClientAppId
    ClientAppCertificate      = $ClientAppCertificate
    Environment               = $Environment
    TenantName                = $TenantName
}

ProcessMicrosoftTeamGroupCsv @ProcessMicrosoftTeamGroupCsv -DisconnectSession


#Copy Reports
MoveFiles -sourceFolder $WorkFolder -ClientAppId $ClientAppId
# SIG # Begin signature block
# MIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDP2VBc8+zC97KI
# hdzHwSva/V2Rl8ehh5zjQsdZ0efQjaCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCK
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
# BDEiBCBJmoGwYmWGqUFVC567GkWQaXcs9WwVLgvQ5Px2r2F8ijANBgkqhkiG9w0B
# AQEFAASCAgBd2q/Cn985VUjMS51LViXDgt2aab+3EOp/YyotDlUQaRe6Pv4LZvgP
# L87YxTz37kSeCTGvTcPWeUXLeydNnRu9GTmHOaRRbjEKI0Zk/sSUCabhexpAyfS9
# FLXjCVhB9EVv5KIhmWyL7rWFVTJGGmCWmK1JktbZ1EMuR8OxeuKZmAW4Abd8dLDf
# P4PDlqVIEjaevfdZkIUmY46GIPzUU2uZNLs78PniTlc9pUD0AfXiHhU+RpKJJiyO
# 1SCv2dDJAzKSkHS9ie0/oJ8YMIxxaodnvNck4bjxzFIhZMShYZlOUD8xFCaQr1Pn
# r/YRKPF8Kw93tstovj63GbjSiyYryE2M/GTZIeSw6sHWFUwo/gGlwG8talV7ZXSI
# W/ZM6uq/H9n8QwHExCNL3S6y7/tlUDmcTp6b/jukeQHE4ZJc8VTRzbuLYS1zxFDr
# WyyEEUdqITe84migxDv9JtYFCcbuu+g3sCWcnNjCGy7X8XTHU3NwmZQgV1OuhF6h
# krqwd+BRaDslRgwrXG7EMDAbHTpCQ0PwLFA7J3CYZSKConXuiurbKwmjIQ9ShFwB
# dWgiBDzoS7MyJf/Pgmi3sOi4T0hTpwL4RhwKVAGHymR2heytm5z1+s4+jHPjl1qO
# HgPg0//WRTtOyMn/WWv2CObSufFVdxmg+V7iHD7qkaNFxeUe937LoQ==
# SIG # End signature block
