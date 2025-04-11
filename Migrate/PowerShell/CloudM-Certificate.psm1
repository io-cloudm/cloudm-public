#region Certificate
function CreateUpdateCertificate([parameter(mandatory)][String]$appId, 
    [parameter(mandatory)][String]$workFolder, 
    [parameter(mandatory)][String]$certName, 
    [SecureString] $secureCertificatePassword, 
    [String]$certStartDate, 
    [String]$certEndDate) {
    Write-Progress "Creating certificate"
    Write-Progress "Generating certificate dates"
    $dateFormat = (Get-Culture).DateTimeFormat.ShortDatePattern
    $certStartDate = (Get-Date).ToString($dateFormat)
    $certEndDate = ([DateTime]::Now).AddYears(5).ToString($dateFormat)
    
    Write-Progress "Checking if certificate already exists"
    # Check if a non-expired certificate already exists
    $app =  (Get-MgApplication -Filter "AppId eq '$appId'")
    [Microsoft.Graph.PowerShell.Models.IMicrosoftGraphKeyCredential[]]$existingCredentials = $app.KeyCredentials
    if ($existingCredentials) {
        foreach ($credential in $existingCredentials) {
            if (IsValidCertificate -certificate $credential) {
                Write-Progress "Valid certificate exists, removing it"
                Write-Host "Certificate already exists" -ForegroundColor Yellow
                Update-MgApplication -ApplicationId $app.Id -KeyCredentials @{}
            }
        }
    }

    #Generate certificate
    if (CreateSelfSignedCertificate -certName $certName -startDate $certStartDate -endDate $certEndDate -forceCert $true) {
        ExportPFXFile -workFolder $workFolder -certName $certName -secureCertificatePassword $secureCertificatePassword
        RemoveCertsFromStore -certName $certName -store "my"
        RemoveCertsFromStore -certName $certName -store "ca"
    }
    # Upload a certificate if needed
    $certData = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("$workFolder\$certName.cer")
    $keyCreds = @{ 
        Type  = "AsymmetricX509Cert";
        Usage = "Verify";
        key   = $certData.GetRawCertData();
    }
    Update-MgApplication -ApplicationId $app.Id -KeyCredentials $keyCreds
}

function IsValidCertificate([parameter(mandatory)][Microsoft.Graph.PowerShell.Models.IMicrosoftGraphKeyCredential]$certificate) {
    if ($certificate.Type -ne "AsymmetricX509Cert") {
        return $false
    }

    $today = Get-Date
    $start = Get-Date $certificate.StartDateTime
    if ($start -gt $today) {
        return $false
    }

    $end = Get-Date $certificate.EndDateTime
    if ($end -lt $today) {
		
        return $false
    }

    return $true
}


function CreateSelfSignedCertificate([parameter(mandatory)][String]$certName, [parameter(mandatory)][String]$startDate, [parameter(mandatory)][String]$endDate, [parameter(mandatory)][System.Boolean]$forceCert) {
    Write-Progress "Creating self signed certificate"
    
    #Remove existing certificates with the same common name from personal and root stores
    #Need to be very wary of this as could break something
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }

    RemoveCertsFromStore -certName $certName -store "my"
    RemoveCertsFromStore -certName $certName -store "ca"

    Write-Progress "Creating cert name"
    $name = new-object -com "X509Enrollment.CX500DistinguishedName.1"
    $name.Encode("CN=$certName", 0)

    Write-Progress "Generating cert key"
    $key = new-object -com "X509Enrollment.CX509PrivateKey.1"
    $key.ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
    $key.KeySpec = 1
    $key.Length = 2048 
    $key.SecurityDescriptor = "D:PAI(A;;0xd01f01ff;;;SY)(A;;0xd01f01ff;;;BA)(A;;0x80120089;;;NS)"
    $key.MachineContext = 1
    $key.ExportPolicy = 1 # This is required to allow the private key to be exported

    Write-Progress "Creating cert key"
    $key.Create()

    Write-Progress "Generating cert server auth oid"
    $serverauthoid = new-object -com "X509Enrollment.CObjectId.1"
    $serverauthoid.InitializeFromValue("1.3.6.1.5.5.7.3.1") # Server Authentication
    $ekuoids = new-object -com "X509Enrollment.CObjectIds.1"
    $ekuoids.add($serverauthoid)
    $ekuext = new-object -com "X509Enrollment.CX509ExtensionEnhancedKeyUsage.1"
    $ekuext.InitializeEncode($ekuoids)

    Write-Progress "Generating cert object"
    $cert = new-object -com "X509Enrollment.CX509CertificateRequestCertificate.1"
    $cert.InitializeFromPrivateKey(2, $key, "")
    $cert.Subject = $name
    $cert.Issuer = $cert.Subject
    $cert.NotBefore = $startDate
    $cert.NotAfter = $endDate
    $cert.X509Extensions.Add($ekuext)
    Write-Progress "Encoding cert"
    $cert.Encode()

    Write-Progress "Generating cert enrollment"
    $enrollment = new-object -com "X509Enrollment.CX509Enrollment.1"
    $enrollment.InitializeFromRequest($cert)
    $certdata = $enrollment.CreateRequest(0)
    Write-Progress "Installing enrollment" -Completed
    $enrollment.InstallResponse(2, $certdata, 0, "")
    return $true
}

function CheckDirectory([parameter(mandatory)][String]$path) {
    Write-Progress ("Checking if directory exists: " + $path)
    if (!(Test-Path $path)) {
        throw "Directory does not exist " + $path
    }
    try {
        Write-Progress "Checking if new file can be created in directory"
        New-Item -Path $path -Name "permissioncheck" -ItemType "file" | Out-Null
    }
    catch {
        throw "User does not have access to directory " + $path
    }
    finally {
        try {
            Write-Progress "Removing permissioncheck file"
            Remove-Item -Path ($path + "\permissioncheck") -Force | Out-Null
        }
        catch {
            Write-Progress "Could not remove permissioncheck file. " $_.Exception.Message
            Write-Host "Could not remove permissioncheck file. " $_.Exception.Message
        }
    }
}

function ExportPFXFile([parameter(mandatory)][String]$workFolder, [parameter(mandatory)][String]$certName, [SecureString] $secureCertificatePassword) {
    Write-Progress "Exporting PFX"
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }
    Write-Progress "Finding cert from store"
    $cert = Get-ChildItem -Path Cert:\LocalMachine\my | where-object { $_.Subject -eq "CN=$certName" }
    
    Write-Progress "Generating pfx file"
    Export-PfxCertificate -Cert $cert -Password $secureCertificatePassword -FilePath "$workFolder\$certName.pfx"
    Write-Progress "Generating cer file"
    Export-Certificate -Cert $cert -Type CERT -FilePath "$workFolder\$certName.cer"
}

function RemoveCertsFromStore([parameter(mandatory)][String]$certName, [parameter(mandatory)][String]$store) {
    Write-Progress "Removing certs from store" $store
    # Once the certificates have been been exported we can safely remove them from the store
    if ($certName.ToLower().StartsWith("cn=")) {
        # Remove CN from common name
        $certName = $certName.Substring(3)
    }
    $certs = Get-ChildItem -Path ("Cert:\LocalMachine\" + $store) | Where-Object { $_.Subject -eq "CN=$certName" }
    foreach ($c in $certs) {
        Write-Progress ("Removing cert " + $c.PSPath)
        remove-item $c.PSPath
    }
}


#endregion
Export-ModuleMember -Function 'CreateUpdateCertificate'
Export-ModuleMember -Function 'CheckDirectory'
# SIG # Begin signature block
# MIJ42gYJKoZIhvcNAQcCoIJ4yzCCeMcCAQExDTALBglghkgBZQMEAgEweQYKKwYB
# BAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+
# 81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQgHFRVVlGvuu6kq3AL
# 3r0d7cBuUAEyie7ynyOTFXjAbpmgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVwikHP
# bwG47rSpVDANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJv
# b3QgQ0EgLSBSMzETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFs
# U2lnbjAeFw0yMDA3MjgwMDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxT
# aWduIENvZGUgU2lnbmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALYtxTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uY
# RYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiC
# kV37WYgFC5cGwpj4LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0
# oYCve+YzCgxZa4689Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o
# 3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHf
# HgIB2DvhZ0OEts/8dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2d
# K4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+Y
# nuYE7kJuZ35CFnFi5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35G
# b03FhRIrz5oiRAiohTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUa
# qhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqR
# LIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4OJGTfAgMBAAGj
# ggF3MIIBczAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYD
# VR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYD
# VR0jBBgwFoAUj/BLf6guRSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0G
# CCsGAQUFBzABhiFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYI
# KwYBBQUHMAKGL2h0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jv
# b3QtcjMuY3J0MDYGA1UdHwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2ln
# bi5jb20vcm9vdC1yMy5jcmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUH
# AgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqG
# SIb3DQEBDAUAA4IBAQCs98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFyw
# vRNdHSOuOVB2N6pE/V8BI1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbs
# n4cxB2X1OadRgnXh8i+X9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LW
# d7uptDRKqW899PMNlV3m+XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMO
# tH2gCm2SxLRmP32nWO6s9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBg
# SA14q88XrZKTYiB3dWy9yDK03E3r2d/BkJYpvcF/MIIG6DCCBNCgAwIBAgIQd70O
# BbdZC7YdR2FTHj917TANBgkqhkiG9w0BAQsFADBTMQswCQYDVQQGEwJCRTEZMBcG
# A1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2Rl
# IFNpZ25pbmcgUm9vdCBSNDUwHhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4MDAwMDAw
# WjBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAG
# A1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLIO+XHrkBMkOgW6mKI/0g
# Xq44EovKLNT/QdgaVdQZU7f9oxfnejlcwPfOEaP5pe0B+rW6k++vk9z44rMZTIOw
# SkRQBHiEEGqk1paQjoH4fKsvtaNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS0PC0VV+W
# CxHlmrUsshHPJRt9USuYH0mjX/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS7L1AldMR
# yubNswWcyFPrUtd4TFEBkoLeE/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+p7JBMyB1
# zLHV7R0HGcTrJnfyq20Xk0mpt+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HPmFWjJKKI
# NvL5n76TLrIGnybADAFWEuGyip8OHtyYiy7P2uKJNKYfJqCornht7KGIFTzC6u63
# 2K1hpa9wNqJ5jtwNc8Dx5CyrlOxYBjk2SNY7WugiznQOryzxFdrRtJXorNVJbeWv
# 3ZtrYyBdjn47skPYYjqU5c20mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5tx2nTbrcB
# bA3gl6cW5iaLiPcDRIZfYmdMtac3qFXcAzaMbs9tNibxDo+wPXHA4TKnguS2MgIy
# MHy1k8gh/TyI5mlj+O51yYvCq++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuVxBKH5xq4
# Tu4swd+hZegkg8kqwv25UwIDAQABo4IBrTCCAakwDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYE
# FCWd0PxZCYZjxezzsRM7VxwDkjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4ObeltEPZ
# VlC7zpY7MIGTBggrBgEFBQcBAQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0cDovL29j
# c3AuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1MEYGCCsGAQUFBzAC
# hjpodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9jb2Rlc2lnbmlu
# Z3Jvb3RyNDUuY3J0MEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFs
# c2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1LmNybDBVBgNVHSAETjBMMEEGCSsG
# AQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNv
# bS9yZXBvc2l0b3J5LzAHBgVngQwBAzANBgkqhkiG9w0BAQsFAAOCAgEAJXWgCck5
# urehOYkvGJ+r1usdS+iUfA0HaJscne9xthdqawJPsz+GRYfMZZtM41gGAiJm1WEC
# xWOP1KLxtl4lC3eW6c1xQDOIKezu86JtvE21PgZLyXMzyggULT1M6LC6daZ0LaRY
# OmwTSfilFQoUloWxamg0JUKvllb0EPokffErcsEW4Wvr5qmYxz5a9NAYnf10l4Z3
# Rio9I30oc4qu7ysbmr9sU6cUnjyHccBejsj70yqSM+pXTV4HXsrBGKyBLRoh+m7P
# l2F733F6Ospj99UwRDcy/rtDhdy6/KbKMxkrd23bywXwfl91LqK2vzWqNmPJzmTZ
# vfy8LPNJVgDIEivGJ7s3r1fvxM8eKcT04i3OKmHPV+31CkDi9RjWHumQL8rTh1+T
# ikgaER3lN4WfLmZiml6BTpWsVVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4hu5/XanGA
# v5becgPY2CIr8ycWTzjoUUAMrpLvvj1994DGTDZXhJWnhBVIMA5SJwiNjqK9IscZ
# yabKDqh6NttqumFfESSVpOKOaO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGHJNPE+6lj
# y3dI1fpi/CTgBHpO0ORu3s6eOFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV0NMe9n9S
# 4kmNuRFyDIhEJjNmAUTf5DMOId5iiUgH2vUwggfPMIIFt6ADAgECAgxK83pmt0Fj
# EC8TCzUwDQYJKoZIhvcNAQELBQAwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBD
# b2RlU2lnbmluZyBDQSAyMDIwMB4XDTI0MDQwMzE1NDExNloXDTI1MDQwNDE1NDEx
# NlowggEOMR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjERMA8GA1UEBRMI
# MTMzMzczNDMxEzARBgsrBgEEAYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdCMRswGQYD
# VQQIExJHcmVhdGVyIE1hbmNoZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0ZXIxGTAX
# BgNVBAkTEDE3IE1hcmJsZSBTdHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBTb2Z0d2Fy
# ZSBMaW1pdGVkMSAwHgYDVQQDExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEnMCUG
# CSqGSIb3DQEJARYYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAngoTokY2HYu5xPv9s5LrBGLS72AwwIEk4hua
# smriK3lFC7ludj4D+m+khHMDGX/dAWmLDIvW3LiNcmfQtJYW28grUXCo95ZXP6nR
# 8J/cI2iOtHHp2/HvfNVV60hzhZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq3f+CSOSZ
# 4FdU6ISsAqZeRsazr/XA2b0apQceLiYVPeORUNsIgfElvcCHhmA5jB8Sl/2F5JUp
# vPC58Tc53dQUWpz5dFW5Cav1BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj0E2TxzAD
# esGjJ4CZ8PU8JTVBhIcb7d+9WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1ouCfJEsY
# eeBny8EQIy1lFuoLfBOGHf+tsT++wKHVkr4BjHhjOT+XwUItwXt/WmwKLuH0t6lg
# BHGlstap+6dBcQC66ZUCMi8OiZ8+3dM8ySiRO4UHBH26lSWc7oMYQexgX6O1XCgy
# xCX3MJfEcJrIlOEEBq11M9cHKvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W1b7LusHp
# yFwd3pRPpaF6pKloa7bmPm8R6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7h9fTCdJM
# u0QADsLAokrZed2D6HKX/uCmJ8fJwgxSalOUwyufT2r9LtRBr+fS6NNgHEhMP+pJ
# xFajqpECAwEAAaOCAdswggHXMA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYBBQUHAQEE
# gZIwgY8wTAYIKwYBBQUHMAKGQGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20v
# Y2FjZXJ0L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYBBQUHMAGG
# M2h0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNh
# MjAyMDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRw
# czovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAJBgNV
# HRMEAjAAMEcGA1UdHwRAMD4wPKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5j
# b20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNybDAjBgNVHREEHDAagRhtYXR0
# Lm1ja2luc3RyeUBjbG91ZG0uaW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMwHwYDVR0j
# BBgwFoAUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp6FGOpQ5r
# uRZYclGhR1msMA0GCSqGSIb3DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlhqLQpOawq
# xF133UUTN4wKocLfqlsv9p1a5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJomnX76voj
# invqiLsNr0f2zKcquyfBmaCKxg+ubXXuWNhysM5602eelsSF5wFpKm1SmKAuvolB
# 79Pq5uS2y8ZU37b9NkYulcyFDIPTuBSZydUvNQP4ATVocen0hIGkZFGfqnIowfyz
# FjvXU3+T9Vrc3BTAUoYEsUK0OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAolFZHqEfI
# y+K1HkWkq0dz4+bVpJlTqTAHHRIwoR5oe4GniTXTrH7/MlFzC+M4EriU7A0evdDR
# hxHA3D8IAMU2rS5rkQkk7h+rQ/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d9H8R46iW
# 393Lg8vpitandd37zKUfUuvbG/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+ye29b4/3S
# JDk+3eZ+Agabmym+o40LTSBng0jXHr+rbNm4z6Tooghd2dfoOPxzFC2VsVUK+WwC
# sJJZYa2upE49ayk2RI2QkZGgaXDk94woo6pBuYq+yGeyDm6a0rnuAimIxNDc3KNS
# Liaw48DP9nAYS8bO1yirSh77l/83vMoLySHTU3fvcHMLpnpCSRha6iYCz1q9xwrR
# eCYrgJxc+y2IyxK95zGCY80wgmPJAgEBMGwwXDELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0
# NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZIAWUD
# BAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQg91ISFxVKSN3BbNOsCJN0f/q5uZcFENzLHvQbu31EksIwDQYJKoZIhvcNAQEB
# BQAEggIAHoYhfFnHhklmT9OZ9Qj7uHuRzBrDX7PJUEn3UhpAXyEDSBtLPMp6nWxc
# DvsPq0mrPygRaPFtAc1JAOG5flX53hRDgIBHYI2Vc0AzvkLFrp/UKhHW+XjNmIzF
# 7GsS4X8yIBuq4nQygfKa6120EqVHXuoS/k9T+2viyVlG3YlO82J1pO0MF88TG/sH
# r9j3fCfpj48YZjkWZiBI4aUweUg4xsCS5+9XXLdXqdCntL56SurtNBVEijjiYrjP
# LfueegMI2agp0Pk1DqxsJ7xMO9HLTCd1UMB7jseUnjAWiZT4TT1cDTSqXaHnKBvK
# GWOx0p+ZvkXagJIlX8soxZCQxgPkvYGPCGVwvxYJHgsnNJDDww1LRi+0EGW0STpq
# mk/9FO6fRf5O1XfMIEzuAk7xQNBVz4JtlI9ypjL5uM1gXig4EyOqPltX+MiqomJ9
# A/fT4zEPmkCt/O3DQV/we9qoQhzNxPe512G8GcZXhkSDKZ+ZV4ryYc0hVxGuHwJs
# UZMMlVP1DH70SczLoOmoWt0RnJes/68nh+wjJKlD1LJDlUcFtwwuRdQheqjT74TF
# BmUsSuLxYthKOlJVucRD40HxlTZ5HLeVWFWUi69tUCERgH2fsdEWc7CCZdHk2DQt
# 5sLFWo0PBxloh612Vf3/AqfYWwb45epMJULDqYItwdwg6bV9CiyhgmC0MIJgsAYK
# KwYBBAGCNwIEATGCYKAwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEPMA0GCWCG
# SAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4wJgIDAQAA
# BBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIB
# BQAEIBxUVVZRr7rupKtwC969He3AblABMonu8p8jkxV4wG6ZoIIUZTCCBaIwggSK
# oAMCAQICEHgDGEJFcIpBz28BuO60qVQwDQYJKoZIhvcNAQEMBQAwTDEgMB4GA1UE
# CxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjMxEzARBgNVBAoTCkdsb2JhbFNpZ24x
# EzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMjAwNzI4MDAwMDAwWhcNMjkwMzE4MDAw
# MDAwWjBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEp
# MCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC2LcUw3Xroq5A9A3KwOkuZFmGy5f+l
# Zx03HOV+7JODqoT1o0ObmEWKuGNXXZsAiAQl6fhokkuC2EvJSgPzqH9qj4phJ72h
# RND99T8iwqNPkY2zBbIogpFd+1mIBQuXBsKY+CynMyTuUDpBzPCgsHsdTdKoWDiW
# 6d/5G5G7ixAs0sdDHaIJdKGAr3vmMwoMWWuOvPSrWpd7f65V+4TwgP6ETNfiur3E
# daFvvWEQdESymAfidKv/aNxsJj7pH+XgBIetMNMMjQN8VbgWcFwkeCAl62dniKu6
# TjSYa3AR3jjK1L6hwJzh3x4CAdg74WdDhLbP/HS3L4Sjv7oJNz1nbLFFXBlhq0GD
# 9awd63cNRkdzzr+9lZXtnSuIEP76WOinV+Gzz6ha6QclmxLEnoByPZPcjJTfO0Tm
# JoD80sMD8IwM0kXWLuePmJ7mBO5Cbmd+QhZxYucE+WDGZKG2nIEhTivGbWiUhsaZ
# dHNnMXqR8tSMeW58prt+Rm9NxYUSK8+aIkQIqIU3zgdhVwYXEiTAxDFzoZg1V0d+
# EDpF2S2kUZCYqaAHN8RlGqocaxZ396eX7D8ZMJlvMfvqQLLn0sT6ydDwUHZ0WfqN
# bRcyvvjpfgP054d1mtRKkSyFAxMCK0KA8olqNs/ITKDOnvjLja0Wp9Pe1ZsYp8aS
# OvGCY/EuDiRk3wIDAQABo4IBdzCCAXMwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFB8Av0aACvx4
# ObeltEPZVlC7zpY7MB8GA1UdIwQYMBaAFI/wS3+oLkUkrk1Q+mOai97i3Ru8MHoG
# CCsGAQUFBwEBBG4wbDAtBggrBgEFBQcwAYYhaHR0cDovL29jc3AuZ2xvYmFsc2ln
# bi5jb20vcm9vdHIzMDsGCCsGAQUFBzAChi9odHRwOi8vc2VjdXJlLmdsb2JhbHNp
# Z24uY29tL2NhY2VydC9yb290LXIzLmNydDA2BgNVHR8ELzAtMCugKaAnhiVodHRw
# Oi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jvb3QtcjMuY3JsMEcGA1UdIARAMD4wPAYE
# VR0gADA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9y
# ZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwFAAOCAQEArPfMFYsweagdCyiIGQnXHH/+
# hr17WjNuDWcOe2LZ4RhcsL0TXR0jrjlQdjeqRP1fASNZhlZMzK28ZBMUMKQgqOA/
# 6Jxy3H7z2Awjuqgtqjz27J+HMQdl9TmnUYJ14fIvl/bR4WWWg2T+oR1R+7Ukm/XS
# d2m8hSxc+lh30a6nsQvi1ne7qbQ0SqlvPfTzDZVd5vl6RbAlFzEu2/cPaOaDH6n3
# 5dSdmIzTYUsvwyh+et6TDrR9oAptksS0Zj99p1jurPfswwgBqzj8ChypxZeyiMgJ
# Ahn2XJoa8U1sMNSzBqsAYEgNeKvPF62Sk2Igd3VsvcgytNxN69nfwZCWKb3BfzCC
# BugwggTQoAMCAQICEHe9DgW3WQu2HUdhUx4/de0wDQYJKoZIhvcNAQELBQAwUzEL
# MAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMT
# IEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAw
# MFoXDTMwMDcyODAwMDAwMFowXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2Jh
# bFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2Rl
# U2lnbmluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# yyDvlx65ATJDoFupiiP9IF6uOBKLyizU/0HYGlXUGVO3/aMX53o5XMD3zhGj+aXt
# Afq1upPvr5Pc+OKzGUyDsEpEUAR4hBBqpNaWkI6B+HyrL7WjVzPSWHuUDm0PpZEm
# KrODT3KxintkktDwtFVflgsR5Zq1LLIRzyUbfVErmB9Jo1/4E541uAMC2qQTL4VK
# 78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT61LXeExRAZKC3hPzB450uoSAn9KkFQ7o
# r+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE6yZ38qttF5NJqbfmw5CcxrjszMl7ml7F
# xSSTY29+EIthz5hVoySiiDby+Z++ky6yBp8mwAwBVhLhsoqfDh7cmIsuz9riiTSm
# HyagqK54beyhiBU8wurut9itYaWvcDaieY7cDXPA8eQsq5TsWAY5NkjWO1roIs50
# Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+O7JD2GI6lOXNtJizNxkkEnJzqwSwCdyF
# 5tQiBO9AKh0ubcdp0263AWwN4JenFuYmi4j3A0SGX2JnTLWnN6hV3AM2jG7PbTYm
# 8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08iOZpY/judcmLwqvvujr96V6/thHxvvA9
# yjI+bn3eD36blcQSh+cauE7uLMHfoWXoJIPJKsL9uVMCAwEAAaOCAa0wggGpMA4G
# A1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzASBgNVHRMBAf8ECDAG
# AQH/AgEAMB0GA1UdDgQWBBQlndD8WQmGY8Xs87ETO1ccA5I2ETAfBgNVHSMEGDAW
# gBQfAL9GgAr8eDm3pbRD2VZQu86WOzCBkwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYB
# BQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9v
# dHI0NTBGBggrBgEFBQcwAoY6aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9j
# YWNlcnQvY29kZXNpZ25pbmdyb290cjQ1LmNydDBBBgNVHR8EOjA4MDagNKAyhjBo
# dHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NS5jcmww
# VQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93
# d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwDQYJKoZIhvcN
# AQELBQADggIBACV1oAnJObq3oTmJLxifq9brHUvolHwNB2ibHJ3vcbYXamsCT7M/
# hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZeJQt3lunNcUAziCns7vOibbxNtT4GS8lz
# M8oIFC09TOiwunWmdC2kWDpsE0n4pRUKFJaFsWpoNCVCr5ZW9BD6JH3xK3LBFuFr
# 6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOKru8rG5q/bFOnFJ48h3HAXo7I+9MqkjPq
# V01eB17KwRisgS0aIfpuz5dhe99xejrKY/fVMEQ3Mv67Q4XcuvymyjMZK3dt28sF
# 8H5fdS6itr81qjZjyc5k2b38vCzzSVYAyBIrxie7N69X78TPHinE9OItziphz1ft
# 9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeFny5mYppegU6VrFVXQ9xTiyV+PGEPigu6
# 9T+m1473BFZeIbuf12pxgL+W3nID2NgiK/MnFk846FFADK6S7749ffeAxkw2V4SV
# p4QVSDAOUicIjY6ivSLHGcmmyg6oejbbarphXxEklaTijmjuGalJmV7QtDS91vlA
# xxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk4AR6TtDkbt7OnjhQJvQhcWXXCSXUyQcA
# erjH83foxdTiVdDTHvZ/UuJJjbkRcgyIRCYzZgFE3+QzDiHeYolIB9r1MIIHzzCC
# BbegAwIBAgIMSvN6ZrdBYxAvEws1MA0GCSqGSIb3DQEBCwUAMFwxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxT
# aWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDAeFw0yNDA0MDMxNTQx
# MTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6
# YXRpb24xETAPBgNVBAUTCDEzMzM3MzQzMRMwEQYLKwYBBAGCNzwCAQMTAkdCMQsw
# CQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRMwEQYDVQQH
# EwpNYW5jaGVzdGVyMRkwFwYDVQQJExAxNyBNYXJibGUgU3RyZWV0MSAwHgYDVQQK
# ExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEgMB4GA1UEAxMXQ2xvdWRNIFNvZnR3
# YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0BCQEWGG1hdHQubWNraW5zdHJ5QGNsb3Vk
# bS5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ4KE6JGNh2LucT7
# /bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5bnY+A/pvpIRzAxl/3QFpiwyL1ty4jXJn
# 0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx6dvx73zVVetIc4WVNGcsW/YESmKq0fRq
# zbqNPK3yhrWjqt3/gkjkmeBXVOiErAKmXkbGs6/1wNm9GqUHHi4mFT3jkVDbCIHx
# Jb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3UFFqc+XRVuQmr9QXQV/M33Xeq78/GYTmC
# lqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1PCU1QYSHG+3fvVjYXGi91RnIMu5ErFSr
# twp7GFvYl4vqtaLgnyRLGHngZ8vBECMtZRbqC3wThh3/rbE/vsCh1ZK+AYx4Yzk/
# l8FCLcF7f1psCi7h9LepYARxpbLWqfunQXEAuumVAjIvDomfPt3TPMkokTuFBwR9
# upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCayJThBAatdTPXByr4XLqX7gqb71/mugor
# h00URN/mytEfltW+y7rB6chcHd6UT6WheqSpaGu25j5vEehnXBbVboU0KHRr15px
# KmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK2Xndg+hyl/7gpifHycIMUmpTlMMrn09q
# /S7UQa/n0ujTYBxITD/qScRWo6qRAgMBAAGjggHbMIIB1zAOBgNVHQ8BAf8EBAMC
# B4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUFBzAChkBodHRwOi8vc2VjdXJl
# Lmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAu
# Y3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9nc2dj
# Y3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAy
# BggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9y
# eS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8EQDA+MDygOqA4hjZodHRwOi8v
# Y3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcmww
# IwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMBMGA1UdJQQMMAoG
# CCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7VxwDkjYRMB0GA1Ud
# DgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZrDANBgkqhkiG9w0BAQsFAAOCAgEAyuIn
# yuoEW73BaqgZYai0KTmsKsRdd91FEzeMCqHC36pbL/adWuXz3Zw81B7hZ6hqCpnV
# rRztJE+KPAyyaJp1++r6I4p76oi7Da9H9synKrsnwZmgisYPrm117ljYcrDOetNn
# npbEhecBaSptUpigLr6JQe/T6ubktsvGVN+2/TZGLpXMhQyD07gUmcnVLzUD+AE1
# aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va3NwUwFKGBLFCtDkuLiXDhIqlu6tB5xWc
# Hp/s5bvRF+7gKJRWR6hHyMvitR5FpKtHc+Pm1aSZU6kwBx0SMKEeaHuBp4k106x+
# /zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADFNq0ua5EJJO4fq0P+AbgRLfxDWbPuOgM2
# SlHv38jMp9geXfR/EeOolt/dy4PL6YrWp3Xd+8ylH1Lr2xvxs90kMlEv2Zw7xHEl
# /Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIGm5spvqONC00gZ4NI1x6/q2zZuM+k6KII
# XdnX6Dj8cxQtlbFVCvlsArCSWWGtrqROPWspNkSNkJGRoGlw5PeMKKOqQbmKvshn
# sg5umtK57gIpiMTQ3NyjUi4msOPAz/ZwGEvGztcoq0oe+5f/N7zKC8kh01N373Bz
# C6Z6QkkYWuomAs9avccK0XgmK4CcXPstiMsSvecxggMVMIIDEQIBATBsMFwxCzAJ
# BgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylH
# bG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMAIMSvN6ZrdB
# YxAvEws1MA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZI
# hvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcC
# ARUwLwYJKoZIhvcNAQkEMSIEIPdSEhcVSkjdwWzTrAiTdH/6ubmXBRDcyx70G7t9
# RJLCMA0GCSqGSIb3DQEBAQUABIICAB6GIXxZx4ZJZk/TmfUI+7h7kcwaw1+zyVBJ
# 91IaQF8hA0gbSzzKep1sXA77D6tJqz8oEWjxbQHNSQDhuX5V+d4UQ4CAR2CNlXNA
# M75Cxa6f1CoR1vl4zZiMxexrEuF/MiAbquJ0MoHymutdtBKlR17qEv5PU/tr4slZ
# Rt2JTvNidaTtDBfPExv7B6/Y93wn6Y+PGGY5FmYgSOGlMHlIOMbAkufvV1y3V6nQ
# p7S+ekrq7TQVRIo44mK4zy37nnoDCNmoKdD5NQ6sbCe8TDvRy0wndVDAe47HlJ4w
# FomU+E09XA00ql2h5ygbyhljsdKfmb5F2oCSJV/LKMWQkMYD5L2BjwhlcL8WCR4L
# JzSQw8MNS0YvtBBltEk6appP/RTun0X+TtV3zCBM7gJO8UDQVc+CbZSPcqYy+bjN
# YF4oOBMjqj5bV/jIqqJifQP30+MxD5pArfztw0Ff8HvaqEIczcT3uddhvBnGV4ZE
# gymfmVeK8mHNIVcRrh8CbFGTDJVT9Qx+9EnMy6DpqFrdEZyXrP+vJ4fsIySpQ9Sy
# Q5VHBbcMLkXUIXqo0++ExQZlLEri8WLYSjpSVbnEQ+NB8ZU2eRy3lVhVlIuvbVAh
# EYB9n7HRFnOwgmXR5Ng0LebCxVqNDwcZaIetdlX9/wKn2FsG+OXqTCVCw6mCLcHc
# IOm1fQosMIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEF
# ADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlL
# CE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAcVFVW
# Ua+67qSrcAvevR3twG5QATKJ7vKfI5MVeMBumaCCFGUwggWiMIIEiqADAgECAhB4
# AxhCRXCKQc9vAbjutKlUMA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2Jh
# bFNpZ24gUm9vdCBDQSAtIFIzMRMwEQYDVQQKEwpHbG9iYWxTaWduMRMwEQYDVQQD
# EwpHbG9iYWxTaWduMB4XDTIwMDcyODAwMDAwMFoXDTI5MDMxODAwMDAwMFowUzEL
# MAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMT
# IEdsb2JhbFNpZ24gQ29kZSBTaWduaW5nIFJvb3QgUjQ1MIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAti3FMN166KuQPQNysDpLmRZhsuX/pWcdNxzlfuyT
# g6qE9aNDm5hFirhjV12bAIgEJen4aJJLgthLyUoD86h/ao+KYSe9oUTQ/fU/IsKj
# T5GNswWyKIKRXftZiAULlwbCmPgspzMk7lA6QczwoLB7HU3SqFg4lunf+RuRu4sQ
# LNLHQx2iCXShgK975jMKDFlrjrz0q1qXe3+uVfuE8ID+hEzX4rq9xHWhb71hEHRE
# spgH4nSr/2jcbCY+6R/l4ASHrTDTDI0DfFW4FnBcJHggJetnZ4iruk40mGtwEd44
# ytS+ocCc4d8eAgHYO+FnQ4S2z/x0ty+Eo7+6CTc9Z2yxRVwZYatBg/WsHet3DUZH
# c86/vZWV7Z0riBD++ljop1fhs8+oWukHJZsSxJ6Acj2T3IyU3ztE5iaA/NLDA/CM
# DNJF1i7nj5ie5gTuQm5nfkIWcWLnBPlgxmShtpyBIU4rxm1olIbGmXRzZzF6kfLU
# jHlufKa7fkZvTcWFEivPmiJECKiFN84HYVcGFxIkwMQxc6GYNVdHfhA6RdktpFGQ
# mKmgBzfEZRqqHGsWd/enl+w/GTCZbzH76kCy59LE+snQ8FB2dFn6jW0XMr746X4D
# 9OeHdZrUSpEshQMTAitCgPKJajbPyEygzp74y42tFqfT3tWbGKfGkjrxgmPxLg4k
# ZN8CAwEAAaOCAXcwggFzMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEF
# BQcDAzAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQ
# u86WOzAfBgNVHSMEGDAWgBSP8Et/qC5FJK5NUPpjmove4t0bvDB6BggrBgEFBQcB
# AQRuMGwwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL3Jv
# b3RyMzA7BggrBgEFBQcwAoYvaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9j
# YWNlcnQvcm9vdC1yMy5jcnQwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2NybC5n
# bG9iYWxzaWduLmNvbS9yb290LXIzLmNybDBHBgNVHSAEQDA+MDwGBFUdIAAwNDAy
# BggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3NpdG9y
# eS8wDQYJKoZIhvcNAQEMBQADggEBAKz3zBWLMHmoHQsoiBkJ1xx//oa9e1ozbg1n
# Dnti2eEYXLC9E10dI645UHY3qkT9XwEjWYZWTMytvGQTFDCkIKjgP+icctx+89gM
# I7qoLao89uyfhzEHZfU5p1GCdeHyL5f20eFlloNk/qEdUfu1JJv10ndpvIUsXPpY
# d9Gup7EL4tZ3u6m0NEqpbz308w2VXeb5ekWwJRcxLtv3D2jmgx+p9+XUnZiM02FL
# L8Mofnrekw60faAKbZLEtGY/fadY7qz37MMIAas4/AocqcWXsojICQIZ9lyaGvFN
# bDDUswarAGBIDXirzxetkpNiIHd1bL3IMrTcTevZ38GQlim9wX8wggboMIIE0KAD
# AgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxT
# aWduIENvZGUgU2lnbmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3
# MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52
# LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcg
# Q0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMsg75ceuQEy
# Q6BbqYoj/SBerjgSi8os1P9B2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT76+T
# 3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7
# ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTM
# MxLsvUCV0xHK5s2zBZzIU+tS13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r94n233Hw
# 0b6nskEzIHXMsdXtHQcZxOsmd/KrbReTSam35sOQnMa47MzJe5pexcUkk2NvfhCL
# Yc+YVaMkoog28vmfvpMusgafJsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8moKiueG3s
# oYgVPMLq7rfYrWGlr3A2onmO3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0
# leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTlzbSYszcZJBJyc6sEsAnchebUIgTvQCod
# Lm3HadNutwFsDeCXpxbmJouI9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9ccDh
# MqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJi8Kr77o6/elev7YR8b7wPcoyPm593g9+
# m5XEEofnGrhO7izB36Fl6CSDySrC/blTAgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8E
# BAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAd
# BgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK
# /Hg5t6W0Q9lWULvOljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1o
# dHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYI
# KwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2Nv
# ZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2Ny
# bC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1UdIARO
# MEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2Jh
# bHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUAA4IC
# AQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8DQdomxyd73G2F2prAk+zP4ZFh8xlm0zj
# WAYCImbVYQLFY4/UovG2XiULd5bpzXFAM4gp7O7zom28TbU+BkvJczPKCBQtPUzo
# sLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQlQq+WVvQQ+iR98StywRbha+vmqZjHPlr0
# 0Bid/XSXhndGKj0jfShziq7vKxuav2xTpxSePIdxwF6OyPvTKpIz6ldNXgdeysEY
# rIEtGiH6bs+XYXvfcXo6ymP31TBENzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/
# Nao2Y8nOZNm9/Lws80lWAMgSK8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe
# 6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/pteO9wRW
# XiG7n9dqcYC/lt5yA9jYIivzJxZPOOhRQAyuku++PX33gMZMNleElaeEFUgwDlIn
# CI2Oor0ixxnJpsoOqHo222q6YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUp
# EYck08T7qWPLd0jV+mL8JOAEek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N36MXU
# 4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/kMw4h3mKJSAfa9TCCB88wggW3oAMCAQIC
# DErzema3QWMQLxMLNTANBgkqhkiG9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZMBcG
# A1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0Mg
# UjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAwHhcNMjQwNDAzMTU0MTE2WhcNMjUw
# NDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8MFFByaXZhdGUgT3JnYW5pemF0aW9uMREw
# DwYDVQQFEwgxMzMzNzM0MzETMBEGCysGAQQBgjc8AgEDEwJHQjELMAkGA1UEBhMC
# R0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjETMBEGA1UEBxMKTWFuY2hl
# c3RlcjEZMBcGA1UECRMQMTcgTWFyYmxlIFN0cmVldDEgMB4GA1UEChMXQ2xvdWRN
# IFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNVBAMTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1p
# dGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCeChOiRjYdi7nE+/2zkusEYtLv
# YDDAgSTiG5qyauIreUULuW52PgP6b6SEcwMZf90BaYsMi9bcuI1yZ9C0lhbbyCtR
# cKj3llc/qdHwn9wjaI60cenb8e981VXrSHOFlTRnLFv2BEpiqtH0as26jTyt8oa1
# o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZvRqlBx4uJhU945FQ2wiB8SW9wIeGYDmM
# HxKX/YXklSm88LnxNznd1BRanPl0VbkJq/UF0FfzN913qu/PxmE5gpak+QQr3JPY
# tCPQTZPHMAN6waMngJnw9TwlNUGEhxvt371Y2FxovdUZyDLuRKxUq7cKexhb2JeL
# 6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd/62xP77AodWSvgGMeGM5P5fBQi3Be39a
# bAou4fS3qWAEcaWy1qn7p0FxALrplQIyLw6Jnz7d0zzJKJE7hQcEfbqVJZzugxhB
# 7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz1wcq+Fy6l+4Km+9f5roKK4dNFETf5srR
# H5bVvsu6wenIXB3elE+loXqkqWhrtuY+bxHoZ1wW1W6FNCh0a9eacSpqBccPahqg
# hnuH19MJ0ky7RAAOwsCiStl53YPocpf+4KYnx8nCDFJqU5TDK59Pav0u1EGv59Lo
# 02AcSEw/6knEVqOqkQIDAQABo4IB2zCCAdcwDgYDVR0PAQH/BAQDAgeAMIGfBggr
# BgEFBQcBAQSBkjCBjzBMBggrBgEFBQcwAoZAaHR0cDovL3NlY3VyZS5nbG9iYWxz
# aWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNydDA/Bggr
# BgEFBQcwAYYzaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNv
# ZGVzaWduY2EyMDIwMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYBBQUH
# AgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcGBWeB
# DAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAwPjA8oDqgOIY2aHR0cDovL2NybC5nbG9i
# YWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3JsMCMGA1UdEQQc
# MBqBGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzATBgNVHSUEDDAKBggrBgEFBQcD
# AzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs87ETO1ccA5I2ETAdBgNVHQ4EFgQUmeoy
# 5enoUY6lDmu5FlhyUaFHWawwDQYJKoZIhvcNAQELBQADggIBAMriJ8rqBFu9wWqo
# GWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2nVrl892cPNQe4WeoagqZ1a0c7SRPijwM
# smiadfvq+iOKe+qIuw2vR/bMpyq7J8GZoIrGD65tde5Y2HKwznrTZ56WxIXnAWkq
# bVKYoC6+iUHv0+rm5LbLxlTftv02Ri6VzIUMg9O4FJnJ1S81A/gBNWhx6fSEgaRk
# UZ+qcijB/LMWO9dTf5P1WtzcFMBShgSxQrQ5Li4lw4SKpburQecVnB6f7OW70Rfu
# 4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOpMAcdEjChHmh7gaeJNdOsfv8yUXML4zgS
# uJTsDR690NGHEcDcPwgAxTatLmuRCSTuH6tD/gG4ES38Q1mz7joDNkpR79/IzKfY
# Hl30fxHjqJbf3cuDy+mK1qd13fvMpR9S69sb8bPdJDJRL9mcO8RxJfwcNDqUHDAw
# z7J7b1vj/dIkOT7d5n4CBpubKb6jjQtNIGeDSNcev6ts2bjPpOiiCF3Z1+g4/HMU
# LZWxVQr5bAKwkllhra6kTj1rKTZEjZCRkaBpcOT3jCijqkG5ir7IZ7IObprSue4C
# KYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtKHvuX/ze8ygvJIdNTd+9wcwumekJJGFrq
# JgLPWr3HCtF4JiuAnFz7LYjLEr3nMYIDFTCCAxECAQEwbDBcMQswCQYDVQQGEwJC
# RTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2ln
# biBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjACDErzema3QWMQLxMLNTAN
# BglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEM
# BgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqG
# SIb3DQEJBDEiBCD3UhIXFUpI3cFs06wIk3R/+rm5lwUQ3Mse9Bu7fUSSwjANBgkq
# hkiG9w0BAQEFAASCAgAehiF8WceGSWZP05n1CPu4e5HMGsNfs8lQSfdSGkBfIQNI
# G0s8ynqdbFwO+w+rSas/KBFo8W0BzUkA4bl+VfneFEOAgEdgjZVzQDO+QsWun9Qq
# Edb5eM2YjMXsaxLhfzIgG6ridDKB8prrXbQSpUde6hL+T1P7a+LJWUbdiU7zYnWk
# 7QwXzxMb+wev2Pd8J+mPjxhmORZmIEjhpTB5SDjGwJLn71dct1ep0Ke0vnpK6u00
# FUSKOOJiuM8t+556AwjZqCnQ+TUOrGwnvEw70ctMJ3VQwHuOx5SeMBaJlPhNPVwN
# NKpdoecoG8oZY7HSn5m+RdqAkiVfyyjFkJDGA+S9gY8IZXC/FgkeCyc0kMPDDUtG
# L7QQZbRJOmqaT/0U7p9F/k7Vd8wgTO4CTvFA0FXPgm2Uj3KmMvm4zWBeKDgTI6o+
# W1f4yKqiYn0D99PjMQ+aQK387cNBX/B72qhCHM3E97nXYbwZxleGRIMpn5lXivJh
# zSFXEa4fAmxRkwyVU/UMfvRJzMug6aha3RGcl6z/ryeH7CMkqUPUskOVRwW3DC5F
# 1CF6qNPvhMUGZSxK4vFi2Eo6UlW5xEPjQfGVNnkct5VYVZSLr21QIRGAfZ+x0RZz
# sIJl0eTYNC3mwsVajQ8HGWiHrXZV/f8Cp9hbBvjl6kwlQsOpgi3B3CDptX0KLDCC
# GCQGCSqGSIb3DQEHAqCCGBUwghgRAgEBMQ8wDQYJYIZIAWUDBAIBBQAweQYKKwYB
# BAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+
# 81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQgHFRVVlGvuu6kq3AL
# 3r0d7cBuUAEyie7ynyOTFXjAbpmgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVwikHP
# bwG47rSpVDANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJv
# b3QgQ0EgLSBSMzETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFs
# U2lnbjAeFw0yMDA3MjgwMDAwMDBaFw0yOTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYT
# AkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxT
# aWduIENvZGUgU2lnbmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALYtxTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uY
# RYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLCo0+RjbMFsiiC
# kV37WYgFC5cGwpj4LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0
# oYCve+YzCgxZa4689Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o
# 3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHf
# HgIB2DvhZ0OEts/8dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1GR3POv72Vle2d
# K4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPwjAzSRdYu54+Y
# nuYE7kJuZ35CFnFi5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy1Ix5bnymu35G
# b03FhRIrz5oiRAiohTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRRkJipoAc3xGUa
# qhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqR
# LIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4OJGTfAgMBAAGj
# ggF3MIIBczAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYD
# VR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUHwC/RoAK/Hg5t6W0Q9lWULvOljswHwYD
# VR0jBBgwFoAUj/BLf6guRSSuTVD6Y5qL3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0G
# CCsGAQUFBzABhiFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9yb290cjMwOwYI
# KwYBBQUHMAKGL2h0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jv
# b3QtcjMuY3J0MDYGA1UdHwQvMC0wK6ApoCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2ln
# bi5jb20vcm9vdC1yMy5jcmwwRwYDVR0gBEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUH
# AgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqG
# SIb3DQEBDAUAA4IBAQCs98wVizB5qB0LKIgZCdccf/6GvXtaM24NZw57YtnhGFyw
# vRNdHSOuOVB2N6pE/V8BI1mGVkzMrbxkExQwpCCo4D/onHLcfvPYDCO6qC2qPPbs
# n4cxB2X1OadRgnXh8i+X9tHhZZaDZP6hHVH7tSSb9dJ3abyFLFz6WHfRrqexC+LW
# d7uptDRKqW899PMNlV3m+XpFsCUXMS7b9w9o5oMfqffl1J2YjNNhSy/DKH563pMO
# tH2gCm2SxLRmP32nWO6s9+zDCAGrOPwKHKnFl7KIyAkCGfZcmhrxTWww1LMGqwBg
# SA14q88XrZKTYiB3dWy9yDK03E3r2d/BkJYpvcF/MIIG6DCCBNCgAwIBAgIQd70O
# BbdZC7YdR2FTHj917TANBgkqhkiG9w0BAQsFADBTMQswCQYDVQQGEwJCRTEZMBcG
# A1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2Rl
# IFNpZ25pbmcgUm9vdCBSNDUwHhcNMjAwNzI4MDAwMDAwWhcNMzAwNzI4MDAwMDAw
# WjBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEyMDAG
# A1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIwMjAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDLIO+XHrkBMkOgW6mKI/0g
# Xq44EovKLNT/QdgaVdQZU7f9oxfnejlcwPfOEaP5pe0B+rW6k++vk9z44rMZTIOw
# SkRQBHiEEGqk1paQjoH4fKsvtaNXM9JYe5QObQ+lkSYqs4NPcrGKe2SS0PC0VV+W
# CxHlmrUsshHPJRt9USuYH0mjX/gTnjW4AwLapBMvhUrvxC9wDsHUzDMS7L1AldMR
# yubNswWcyFPrUtd4TFEBkoLeE/MHjnS6hICf0qQVDuiv6/eJ9t9x8NG+p7JBMyB1
# zLHV7R0HGcTrJnfyq20Xk0mpt+bDkJzGuOzMyXuaXsXFJJNjb34Qi2HPmFWjJKKI
# NvL5n76TLrIGnybADAFWEuGyip8OHtyYiy7P2uKJNKYfJqCornht7KGIFTzC6u63
# 2K1hpa9wNqJ5jtwNc8Dx5CyrlOxYBjk2SNY7WugiznQOryzxFdrRtJXorNVJbeWv
# 3ZtrYyBdjn47skPYYjqU5c20mLM3GSQScnOrBLAJ3IXm1CIE70AqHS5tx2nTbrcB
# bA3gl6cW5iaLiPcDRIZfYmdMtac3qFXcAzaMbs9tNibxDo+wPXHA4TKnguS2MgIy
# MHy1k8gh/TyI5mlj+O51yYvCq++6Ov3pXr+2EfG+8D3KMj5ufd4PfpuVxBKH5xq4
# Tu4swd+hZegkg8kqwv25UwIDAQABo4IBrTCCAakwDgYDVR0PAQH/BAQDAgGGMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYE
# FCWd0PxZCYZjxezzsRM7VxwDkjYRMB8GA1UdIwQYMBaAFB8Av0aACvx4ObeltEPZ
# VlC7zpY7MIGTBggrBgEFBQcBAQSBhjCBgzA5BggrBgEFBQcwAYYtaHR0cDovL29j
# c3AuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1MEYGCCsGAQUFBzAC
# hjpodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9jb2Rlc2lnbmlu
# Z3Jvb3RyNDUuY3J0MEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFs
# c2lnbi5jb20vY29kZXNpZ25pbmdyb290cjQ1LmNybDBVBgNVHSAETjBMMEEGCSsG
# AQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNv
# bS9yZXBvc2l0b3J5LzAHBgVngQwBAzANBgkqhkiG9w0BAQsFAAOCAgEAJXWgCck5
# urehOYkvGJ+r1usdS+iUfA0HaJscne9xthdqawJPsz+GRYfMZZtM41gGAiJm1WEC
# xWOP1KLxtl4lC3eW6c1xQDOIKezu86JtvE21PgZLyXMzyggULT1M6LC6daZ0LaRY
# OmwTSfilFQoUloWxamg0JUKvllb0EPokffErcsEW4Wvr5qmYxz5a9NAYnf10l4Z3
# Rio9I30oc4qu7ysbmr9sU6cUnjyHccBejsj70yqSM+pXTV4HXsrBGKyBLRoh+m7P
# l2F733F6Ospj99UwRDcy/rtDhdy6/KbKMxkrd23bywXwfl91LqK2vzWqNmPJzmTZ
# vfy8LPNJVgDIEivGJ7s3r1fvxM8eKcT04i3OKmHPV+31CkDi9RjWHumQL8rTh1+T
# ikgaER3lN4WfLmZiml6BTpWsVVdD3FOLJX48YQ+KC7r1P6bXjvcEVl4hu5/XanGA
# v5becgPY2CIr8ycWTzjoUUAMrpLvvj1994DGTDZXhJWnhBVIMA5SJwiNjqK9IscZ
# yabKDqh6NttqumFfESSVpOKOaO4ZqUmZXtC0NL3W+UDHEJcxUjk1KRGHJNPE+6lj
# y3dI1fpi/CTgBHpO0ORu3s6eOFAm9CFxZdcJJdTJBwB6uMfzd+jF1OJV0NMe9n9S
# 4kmNuRFyDIhEJjNmAUTf5DMOId5iiUgH2vUwggfPMIIFt6ADAgECAgxK83pmt0Fj
# EC8TCzUwDQYJKoZIhvcNAQELBQAwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBD
# b2RlU2lnbmluZyBDQSAyMDIwMB4XDTI0MDQwMzE1NDExNloXDTI1MDQwNDE1NDEx
# NlowggEOMR0wGwYDVQQPDBRQcml2YXRlIE9yZ2FuaXphdGlvbjERMA8GA1UEBRMI
# MTMzMzczNDMxEzARBgsrBgEEAYI3PAIBAxMCR0IxCzAJBgNVBAYTAkdCMRswGQYD
# VQQIExJHcmVhdGVyIE1hbmNoZXN0ZXIxEzARBgNVBAcTCk1hbmNoZXN0ZXIxGTAX
# BgNVBAkTEDE3IE1hcmJsZSBTdHJlZXQxIDAeBgNVBAoTF0Nsb3VkTSBTb2Z0d2Fy
# ZSBMaW1pdGVkMSAwHgYDVQQDExdDbG91ZE0gU29mdHdhcmUgTGltaXRlZDEnMCUG
# CSqGSIb3DQEJARYYbWF0dC5tY2tpbnN0cnlAY2xvdWRtLmlvMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAngoTokY2HYu5xPv9s5LrBGLS72AwwIEk4hua
# smriK3lFC7ludj4D+m+khHMDGX/dAWmLDIvW3LiNcmfQtJYW28grUXCo95ZXP6nR
# 8J/cI2iOtHHp2/HvfNVV60hzhZU0Zyxb9gRKYqrR9GrNuo08rfKGtaOq3f+CSOSZ
# 4FdU6ISsAqZeRsazr/XA2b0apQceLiYVPeORUNsIgfElvcCHhmA5jB8Sl/2F5JUp
# vPC58Tc53dQUWpz5dFW5Cav1BdBX8zfdd6rvz8ZhOYKWpPkEK9yT2LQj0E2TxzAD
# esGjJ4CZ8PU8JTVBhIcb7d+9WNhcaL3VGcgy7kSsVKu3CnsYW9iXi+q1ouCfJEsY
# eeBny8EQIy1lFuoLfBOGHf+tsT++wKHVkr4BjHhjOT+XwUItwXt/WmwKLuH0t6lg
# BHGlstap+6dBcQC66ZUCMi8OiZ8+3dM8ySiRO4UHBH26lSWc7oMYQexgX6O1XCgy
# xCX3MJfEcJrIlOEEBq11M9cHKvhcupfuCpvvX+a6CiuHTRRE3+bK0R+W1b7LusHp
# yFwd3pRPpaF6pKloa7bmPm8R6GdcFtVuhTQodGvXmnEqagXHD2oaoIZ7h9fTCdJM
# u0QADsLAokrZed2D6HKX/uCmJ8fJwgxSalOUwyufT2r9LtRBr+fS6NNgHEhMP+pJ
# xFajqpECAwEAAaOCAdswggHXMA4GA1UdDwEB/wQEAwIHgDCBnwYIKwYBBQUHAQEE
# gZIwgY8wTAYIKwYBBQUHMAKGQGh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20v
# Y2FjZXJ0L2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcnQwPwYIKwYBBQUHMAGG
# M2h0dHA6Ly9vY3NwLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNh
# MjAyMDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZodHRw
# czovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAJBgNV
# HRMEAjAAMEcGA1UdHwRAMD4wPKA6oDiGNmh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5j
# b20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwLmNybDAjBgNVHREEHDAagRhtYXR0
# Lm1ja2luc3RyeUBjbG91ZG0uaW8wEwYDVR0lBAwwCgYIKwYBBQUHAwMwHwYDVR0j
# BBgwFoAUJZ3Q/FkJhmPF7POxEztXHAOSNhEwHQYDVR0OBBYEFJnqMuXp6FGOpQ5r
# uRZYclGhR1msMA0GCSqGSIb3DQEBCwUAA4ICAQDK4ifK6gRbvcFqqBlhqLQpOawq
# xF133UUTN4wKocLfqlsv9p1a5fPdnDzUHuFnqGoKmdWtHO0kT4o8DLJomnX76voj
# invqiLsNr0f2zKcquyfBmaCKxg+ubXXuWNhysM5602eelsSF5wFpKm1SmKAuvolB
# 79Pq5uS2y8ZU37b9NkYulcyFDIPTuBSZydUvNQP4ATVocen0hIGkZFGfqnIowfyz
# FjvXU3+T9Vrc3BTAUoYEsUK0OS4uJcOEiqW7q0HnFZwen+zlu9EX7uAolFZHqEfI
# y+K1HkWkq0dz4+bVpJlTqTAHHRIwoR5oe4GniTXTrH7/MlFzC+M4EriU7A0evdDR
# hxHA3D8IAMU2rS5rkQkk7h+rQ/4BuBEt/ENZs+46AzZKUe/fyMyn2B5d9H8R46iW
# 393Lg8vpitandd37zKUfUuvbG/Gz3SQyUS/ZnDvEcSX8HDQ6lBwwMM+ye29b4/3S
# JDk+3eZ+Agabmym+o40LTSBng0jXHr+rbNm4z6Tooghd2dfoOPxzFC2VsVUK+WwC
# sJJZYa2upE49ayk2RI2QkZGgaXDk94woo6pBuYq+yGeyDm6a0rnuAimIxNDc3KNS
# Liaw48DP9nAYS8bO1yirSh77l/83vMoLySHTU3fvcHMLpnpCSRha6iYCz1q9xwrR
# eCYrgJxc+y2IyxK95zGCAxUwggMRAgEBMGwwXDELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0
# NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZIAWUD
# BAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQg91ISFxVKSN3BbNOsCJN0f/q5uZcFENzLHvQbu31EksIwDQYJKoZIhvcNAQEB
# BQAEggIAHoYhfFnHhklmT9OZ9Qj7uHuRzBrDX7PJUEn3UhpAXyEDSBtLPMp6nWxc
# DvsPq0mrPygRaPFtAc1JAOG5flX53hRDgIBHYI2Vc0AzvkLFrp/UKhHW+XjNmIzF
# 7GsS4X8yIBuq4nQygfKa6120EqVHXuoS/k9T+2viyVlG3YlO82J1pO0MF88TG/sH
# r9j3fCfpj48YZjkWZiBI4aUweUg4xsCS5+9XXLdXqdCntL56SurtNBVEijjiYrjP
# LfueegMI2agp0Pk1DqxsJ7xMO9HLTCd1UMB7jseUnjAWiZT4TT1cDTSqXaHnKBvK
# GWOx0p+ZvkXagJIlX8soxZCQxgPkvYGPCGVwvxYJHgsnNJDDww1LRi+0EGW0STpq
# mk/9FO6fRf5O1XfMIEzuAk7xQNBVz4JtlI9ypjL5uM1gXig4EyOqPltX+MiqomJ9
# A/fT4zEPmkCt/O3DQV/we9qoQhzNxPe512G8GcZXhkSDKZ+ZV4ryYc0hVxGuHwJs
# UZMMlVP1DH70SczLoOmoWt0RnJes/68nh+wjJKlD1LJDlUcFtwwuRdQheqjT74TF
# BmUsSuLxYthKOlJVucRD40HxlTZ5HLeVWFWUi69tUCERgH2fsdEWc7CCZdHk2DQt
# 5sLFWo0PBxloh612Vf3/AqfYWwb45epMJULDqYItwdwg6bV9CiwwghgkBgkqhkiG
# 9w0BBwKgghgVMIIYEQIBATEPMA0GCWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSg
# azBpMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEA
# AgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIBBQAEIBxUVVZRr7rupKtwC969He3AblAB
# Monu8p8jkxV4wG6ZoIIUZTCCBaIwggSKoAMCAQICEHgDGEJFcIpBz28BuO60qVQw
# DQYJKoZIhvcNAQEMBQAwTDEgMB4GA1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0g
# UjMxEzARBgNVBAoTCkdsb2JhbFNpZ24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcN
# MjAwNzI4MDAwMDAwWhcNMjkwMzE4MDAwMDAwWjBTMQswCQYDVQQGEwJCRTEZMBcG
# A1UEChMQR2xvYmFsU2lnbiBudi1zYTEpMCcGA1UEAxMgR2xvYmFsU2lnbiBDb2Rl
# IFNpZ25pbmcgUm9vdCBSNDUwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQC2LcUw3Xroq5A9A3KwOkuZFmGy5f+lZx03HOV+7JODqoT1o0ObmEWKuGNXXZsA
# iAQl6fhokkuC2EvJSgPzqH9qj4phJ72hRND99T8iwqNPkY2zBbIogpFd+1mIBQuX
# BsKY+CynMyTuUDpBzPCgsHsdTdKoWDiW6d/5G5G7ixAs0sdDHaIJdKGAr3vmMwoM
# WWuOvPSrWpd7f65V+4TwgP6ETNfiur3EdaFvvWEQdESymAfidKv/aNxsJj7pH+Xg
# BIetMNMMjQN8VbgWcFwkeCAl62dniKu6TjSYa3AR3jjK1L6hwJzh3x4CAdg74WdD
# hLbP/HS3L4Sjv7oJNz1nbLFFXBlhq0GD9awd63cNRkdzzr+9lZXtnSuIEP76WOin
# V+Gzz6ha6QclmxLEnoByPZPcjJTfO0TmJoD80sMD8IwM0kXWLuePmJ7mBO5Cbmd+
# QhZxYucE+WDGZKG2nIEhTivGbWiUhsaZdHNnMXqR8tSMeW58prt+Rm9NxYUSK8+a
# IkQIqIU3zgdhVwYXEiTAxDFzoZg1V0d+EDpF2S2kUZCYqaAHN8RlGqocaxZ396eX
# 7D8ZMJlvMfvqQLLn0sT6ydDwUHZ0WfqNbRcyvvjpfgP054d1mtRKkSyFAxMCK0KA
# 8olqNs/ITKDOnvjLja0Wp9Pe1ZsYp8aSOvGCY/EuDiRk3wIDAQABo4IBdzCCAXMw
# DgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA8GA1UdEwEB/wQF
# MAMBAf8wHQYDVR0OBBYEFB8Av0aACvx4ObeltEPZVlC7zpY7MB8GA1UdIwQYMBaA
# FI/wS3+oLkUkrk1Q+mOai97i3Ru8MHoGCCsGAQUFBwEBBG4wbDAtBggrBgEFBQcw
# AYYhaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vcm9vdHIzMDsGCCsGAQUFBzAC
# hi9odHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9yb290LXIzLmNy
# dDA2BgNVHR8ELzAtMCugKaAnhiVodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jv
# b3QtcjMuY3JsMEcGA1UdIARAMD4wPAYEVR0gADA0MDIGCCsGAQUFBwIBFiZodHRw
# czovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwF
# AAOCAQEArPfMFYsweagdCyiIGQnXHH/+hr17WjNuDWcOe2LZ4RhcsL0TXR0jrjlQ
# djeqRP1fASNZhlZMzK28ZBMUMKQgqOA/6Jxy3H7z2Awjuqgtqjz27J+HMQdl9Tmn
# UYJ14fIvl/bR4WWWg2T+oR1R+7Ukm/XSd2m8hSxc+lh30a6nsQvi1ne7qbQ0Sqlv
# PfTzDZVd5vl6RbAlFzEu2/cPaOaDH6n35dSdmIzTYUsvwyh+et6TDrR9oAptksS0
# Zj99p1jurPfswwgBqzj8ChypxZeyiMgJAhn2XJoa8U1sMNSzBqsAYEgNeKvPF62S
# k2Igd3VsvcgytNxN69nfwZCWKb3BfzCCBugwggTQoAMCAQICEHe9DgW3WQu2HUdh
# Ux4/de0wDQYJKoZIhvcNAQELBQAwUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5n
# IFJvb3QgUjQ1MB4XDTIwMDcyODAwMDAwMFoXDTMwMDcyODAwMDAwMFowXDELMAkG
# A1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUds
# b2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwMIICIjANBgkq
# hkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyyDvlx65ATJDoFupiiP9IF6uOBKLyizU
# /0HYGlXUGVO3/aMX53o5XMD3zhGj+aXtAfq1upPvr5Pc+OKzGUyDsEpEUAR4hBBq
# pNaWkI6B+HyrL7WjVzPSWHuUDm0PpZEmKrODT3KxintkktDwtFVflgsR5Zq1LLIR
# zyUbfVErmB9Jo1/4E541uAMC2qQTL4VK78QvcA7B1MwzEuy9QJXTEcrmzbMFnMhT
# 61LXeExRAZKC3hPzB450uoSAn9KkFQ7or+v3ifbfcfDRvqeyQTMgdcyx1e0dBxnE
# 6yZ38qttF5NJqbfmw5CcxrjszMl7ml7FxSSTY29+EIthz5hVoySiiDby+Z++ky6y
# Bp8mwAwBVhLhsoqfDh7cmIsuz9riiTSmHyagqK54beyhiBU8wurut9itYaWvcDai
# eY7cDXPA8eQsq5TsWAY5NkjWO1roIs50Dq8s8RXa0bSV6KzVSW3lr92ba2MgXY5+
# O7JD2GI6lOXNtJizNxkkEnJzqwSwCdyF5tQiBO9AKh0ubcdp0263AWwN4JenFuYm
# i4j3A0SGX2JnTLWnN6hV3AM2jG7PbTYm8Q6PsD1xwOEyp4LktjICMjB8tZPIIf08
# iOZpY/judcmLwqvvujr96V6/thHxvvA9yjI+bn3eD36blcQSh+cauE7uLMHfoWXo
# JIPJKsL9uVMCAwEAAaOCAa0wggGpMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBQlndD8WQmG
# Y8Xs87ETO1ccA5I2ETAfBgNVHSMEGDAWgBQfAL9GgAr8eDm3pbRD2VZQu86WOzCB
# kwYIKwYBBQUHAQEEgYYwgYMwOQYIKwYBBQUHMAGGLWh0dHA6Ly9vY3NwLmdsb2Jh
# bHNpZ24uY29tL2NvZGVzaWduaW5ncm9vdHI0NTBGBggrBgEFBQcwAoY6aHR0cDov
# L3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvY29kZXNpZ25pbmdyb290cjQ1
# LmNydDBBBgNVHR8EOjA4MDagNKAyhjBodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29t
# L2NvZGVzaWduaW5ncm9vdHI0NS5jcmwwVQYDVR0gBE4wTDBBBgkrBgEEAaAyAQIw
# NDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFsc2lnbi5jb20vcmVwb3Np
# dG9yeS8wBwYFZ4EMAQMwDQYJKoZIhvcNAQELBQADggIBACV1oAnJObq3oTmJLxif
# q9brHUvolHwNB2ibHJ3vcbYXamsCT7M/hkWHzGWbTONYBgIiZtVhAsVjj9Si8bZe
# JQt3lunNcUAziCns7vOibbxNtT4GS8lzM8oIFC09TOiwunWmdC2kWDpsE0n4pRUK
# FJaFsWpoNCVCr5ZW9BD6JH3xK3LBFuFr6+apmMc+WvTQGJ39dJeGd0YqPSN9KHOK
# ru8rG5q/bFOnFJ48h3HAXo7I+9MqkjPqV01eB17KwRisgS0aIfpuz5dhe99xejrK
# Y/fVMEQ3Mv67Q4XcuvymyjMZK3dt28sF8H5fdS6itr81qjZjyc5k2b38vCzzSVYA
# yBIrxie7N69X78TPHinE9OItziphz1ft9QpA4vUY1h7pkC/K04dfk4pIGhEd5TeF
# ny5mYppegU6VrFVXQ9xTiyV+PGEPigu69T+m1473BFZeIbuf12pxgL+W3nID2Ngi
# K/MnFk846FFADK6S7749ffeAxkw2V4SVp4QVSDAOUicIjY6ivSLHGcmmyg6oejbb
# arphXxEklaTijmjuGalJmV7QtDS91vlAxxCXMVI5NSkRhyTTxPupY8t3SNX6Yvwk
# 4AR6TtDkbt7OnjhQJvQhcWXXCSXUyQcAerjH83foxdTiVdDTHvZ/UuJJjbkRcgyI
# RCYzZgFE3+QzDiHeYolIB9r1MIIHzzCCBbegAwIBAgIMSvN6ZrdBYxAvEws1MA0G
# CSqGSIb3DQEBCwUAMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWdu
# IG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25p
# bmcgQ0EgMjAyMDAeFw0yNDA0MDMxNTQxMTZaFw0yNTA0MDQxNTQxMTZaMIIBDjEd
# MBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xETAPBgNVBAUTCDEzMzM3MzQz
# MRMwEQYLKwYBBAGCNzwCAQMTAkdCMQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3Jl
# YXRlciBNYW5jaGVzdGVyMRMwEQYDVQQHEwpNYW5jaGVzdGVyMRkwFwYDVQQJExAx
# NyBNYXJibGUgU3RyZWV0MSAwHgYDVQQKExdDbG91ZE0gU29mdHdhcmUgTGltaXRl
# ZDEgMB4GA1UEAxMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxJzAlBgkqhkiG9w0B
# CQEWGG1hdHQubWNraW5zdHJ5QGNsb3VkbS5pbzCCAiIwDQYJKoZIhvcNAQEBBQAD
# ggIPADCCAgoCggIBAJ4KE6JGNh2LucT7/bOS6wRi0u9gMMCBJOIbmrJq4it5RQu5
# bnY+A/pvpIRzAxl/3QFpiwyL1ty4jXJn0LSWFtvIK1FwqPeWVz+p0fCf3CNojrRx
# 6dvx73zVVetIc4WVNGcsW/YESmKq0fRqzbqNPK3yhrWjqt3/gkjkmeBXVOiErAKm
# XkbGs6/1wNm9GqUHHi4mFT3jkVDbCIHxJb3Ah4ZgOYwfEpf9heSVKbzwufE3Od3U
# FFqc+XRVuQmr9QXQV/M33Xeq78/GYTmClqT5BCvck9i0I9BNk8cwA3rBoyeAmfD1
# PCU1QYSHG+3fvVjYXGi91RnIMu5ErFSrtwp7GFvYl4vqtaLgnyRLGHngZ8vBECMt
# ZRbqC3wThh3/rbE/vsCh1ZK+AYx4Yzk/l8FCLcF7f1psCi7h9LepYARxpbLWqfun
# QXEAuumVAjIvDomfPt3TPMkokTuFBwR9upUlnO6DGEHsYF+jtVwoMsQl9zCXxHCa
# yJThBAatdTPXByr4XLqX7gqb71/mugorh00URN/mytEfltW+y7rB6chcHd6UT6Wh
# eqSpaGu25j5vEehnXBbVboU0KHRr15pxKmoFxw9qGqCGe4fX0wnSTLtEAA7CwKJK
# 2Xndg+hyl/7gpifHycIMUmpTlMMrn09q/S7UQa/n0ujTYBxITD/qScRWo6qRAgMB
# AAGjggHbMIIB1zAOBgNVHQ8BAf8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwG
# CCsGAQUFBzAChkBodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9n
# c2djY3I0NWV2Y29kZXNpZ25jYTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8v
# b2NzcC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYD
# VR0gBE4wTDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cu
# Z2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBH
# BgNVHR8EQDA+MDygOqA4hjZodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2Nj
# cjQ1ZXZjb2Rlc2lnbmNhMjAyMC5jcmwwIwYDVR0RBBwwGoEYbWF0dC5tY2tpbnN0
# cnlAY2xvdWRtLmlvMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd
# 0PxZCYZjxezzsRM7VxwDkjYRMB0GA1UdDgQWBBSZ6jLl6ehRjqUOa7kWWHJRoUdZ
# rDANBgkqhkiG9w0BAQsFAAOCAgEAyuInyuoEW73BaqgZYai0KTmsKsRdd91FEzeM
# CqHC36pbL/adWuXz3Zw81B7hZ6hqCpnVrRztJE+KPAyyaJp1++r6I4p76oi7Da9H
# 9synKrsnwZmgisYPrm117ljYcrDOetNnnpbEhecBaSptUpigLr6JQe/T6ubktsvG
# VN+2/TZGLpXMhQyD07gUmcnVLzUD+AE1aHHp9ISBpGRRn6pyKMH8sxY711N/k/Va
# 3NwUwFKGBLFCtDkuLiXDhIqlu6tB5xWcHp/s5bvRF+7gKJRWR6hHyMvitR5FpKtH
# c+Pm1aSZU6kwBx0SMKEeaHuBp4k106x+/zJRcwvjOBK4lOwNHr3Q0YcRwNw/CADF
# Nq0ua5EJJO4fq0P+AbgRLfxDWbPuOgM2SlHv38jMp9geXfR/EeOolt/dy4PL6YrW
# p3Xd+8ylH1Lr2xvxs90kMlEv2Zw7xHEl/Bw0OpQcMDDPsntvW+P90iQ5Pt3mfgIG
# m5spvqONC00gZ4NI1x6/q2zZuM+k6KIIXdnX6Dj8cxQtlbFVCvlsArCSWWGtrqRO
# PWspNkSNkJGRoGlw5PeMKKOqQbmKvshnsg5umtK57gIpiMTQ3NyjUi4msOPAz/Zw
# GEvGztcoq0oe+5f/N7zKC8kh01N373BzC6Z6QkkYWuomAs9avccK0XgmK4CcXPst
# iMsSvecxggMVMIIDEQIBATBsMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9i
# YWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29k
# ZVNpZ25pbmcgQ0EgMjAyMAIMSvN6ZrdBYxAvEws1MA0GCWCGSAFlAwQCAQUAoHww
# EAYKKwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPdSEhcV
# SkjdwWzTrAiTdH/6ubmXBRDcyx70G7t9RJLCMA0GCSqGSIb3DQEBAQUABIICAB6G
# IXxZx4ZJZk/TmfUI+7h7kcwaw1+zyVBJ91IaQF8hA0gbSzzKep1sXA77D6tJqz8o
# EWjxbQHNSQDhuX5V+d4UQ4CAR2CNlXNAM75Cxa6f1CoR1vl4zZiMxexrEuF/MiAb
# quJ0MoHymutdtBKlR17qEv5PU/tr4slZRt2JTvNidaTtDBfPExv7B6/Y93wn6Y+P
# GGY5FmYgSOGlMHlIOMbAkufvV1y3V6nQp7S+ekrq7TQVRIo44mK4zy37nnoDCNmo
# KdD5NQ6sbCe8TDvRy0wndVDAe47HlJ4wFomU+E09XA00ql2h5ygbyhljsdKfmb5F
# 2oCSJV/LKMWQkMYD5L2BjwhlcL8WCR4LJzSQw8MNS0YvtBBltEk6appP/RTun0X+
# TtV3zCBM7gJO8UDQVc+CbZSPcqYy+bjNYF4oOBMjqj5bV/jIqqJifQP30+MxD5pA
# rfztw0Ff8HvaqEIczcT3uddhvBnGV4ZEgymfmVeK8mHNIVcRrh8CbFGTDJVT9Qx+
# 9EnMy6DpqFrdEZyXrP+vJ4fsIySpQ9SyQ5VHBbcMLkXUIXqo0++ExQZlLEri8WLY
# SjpSVbnEQ+NB8ZU2eRy3lVhVlIuvbVAhEYB9n7HRFnOwgmXR5Ng0LebCxVqNDwcZ
# aIetdlX9/wKn2FsG+OXqTCVCw6mCLcHcIOm1fQos
# SIG # End signature block
