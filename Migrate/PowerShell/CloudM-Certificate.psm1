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