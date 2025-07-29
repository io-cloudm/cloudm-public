$ErrorActionPreference = "Stop"
New-Variable -Name NOT_APPLICABLE -Value "N/A" -Option ReadOnly
New-Variable -Name SUCCESS -Value "Success" -Option ReadOnly
New-Variable -Name WARNING -Value "Warning" -Option ReadOnly
New-Variable -Name FAILED -Value "Failed" -Option ReadOnly
New-Variable -Name ALREADY_EXISTS -Value "Already Exists" -Option ReadOnly
New-Variable -Name SITE_PROPERTY_REQUEST -Value "id,webUrl"

$script:DistributionGroup = $null
$script:DistributionGroupMembers = $null
enum ItemType {
    Drive
    Email
    EmailDrive
}
enum MicrosoftTeamGroupItemType {
    Site
    Email
    EmailSite
}
function GetMailGroup([parameter(mandatory)][String]$MailGroupAlias) {
    $distributionGroup = Get-DistributionGroup -Identity $MailGroupAlias -ErrorAction SilentlyContinue
    if ($distributionGroup) {
        Write-Host "Found Group: " $distributionGroup.PrimarySmtpAddress
        return $distributionGroup;
    }
    else {
        Write-Host "$MailGroupAlias could not befound" 
    }
    return $distributionGroup;
}

function ProcessEmail ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$MailGroupAlias, $Attempt) {
    try {
        Write-Host "Processing Email"
        if ($script:DistributionGroup -eq $false -and $Attempt -ge 1) {
            Write-Host "$($MailGroupAlias) does not exist" -ForegroundColor Red
            return
        }
        if ($null -eq $script:DistributionGroup -and $Attempt -eq 0) {
            $script:DistributionGroup = GetMailGroup -MailGroupAlias $MailGroupAlias
            if (!$script:DistributionGroup) {
                Write-Host "$($MailGroupAlias) does not exist" -ForegroundColor Red
                return
            }
      
            if ($null -eq $script:DistributionGroupMembers -and $Attempt -eq 0) {
                $script:DistributionGroupMembers = Get-DistributionGroupMember -Identity $distributionGroup.Id
            }
  
            Write-Host "Processing : $($distributionGroup.Id)"
        }
        if (!($script:DistributionGroupMembers.PrimarySmtpAddress -contains $Row.Email)) {
            Add-DistributionGroupMember -Identity $distributionGroup.Id -Member $Row.Email -BypassSecurityGroupManagerCheck -ErrorAction Stop
            $Row.EmailStatus = $($SUCCESS)
            $Row.EmailErrorMessage = $NOT_APPLICABLE
            Write-Host "$($Row.Email) added to $($MailGroupAlias). $($SUCCESS)" -ForegroundColor Green
        }
        else {
            Write-Host "$($Row.Email) $($ALREADY_EXISTS) in $($MailGroupAlias)" -ForegroundColor Yellow
            $Row.EmailStatus = $($ALREADY_EXISTS)
            $Row.EmailErrorMessage = $NOT_APPLICABLE
        }
    }
    catch {
        Write-Host "Failed to add $($Row.Email). The message was: $($_)" -ForegroundColor Red
        $Row.EmailStatus = $($FAILED)
        $Row.EmailErrorMessage = $_
    }

}

function ProcessMicrosoftTeamGroupSite ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId) {
    try {
        Write-Host "Processing Microsoft Team/Group"
        $group = {
            Get-MgGroup -Property "Id,resourceProvisioningOptions" -Filter "Mail eq '$($Row.Email)'"
        } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgGroup: $($Row.Email)"

        $site = {
            Get-MgGroupSite -GroupId $group.Id -SiteId "Root" -Property $SITE_PROPERTY_REQUEST
        } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgGroupSite Root: $($group.Id)"

        $permission = New-MgSitePermission -SiteId $site.Id -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $ClientAppId  -roles @("FullControl"))
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }
        Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
        $isMicrosoftTeam = $false
        if ($group.AdditionalProperties.ContainsKey("resourceProvisioningOptions")) {
            $isMicrosoftTeam = $group.AdditionalProperties["resourceProvisioningOptions"].Contains("Team")
        }
        $successSiteUrls = @("$($site.WebUrl) - ($($site.Id))")
    
        if ($isMicrosoftTeam) {
            Write-Host "Checking for Private/Shared Channels"
            $teamChannels = Get-MgTeamChannel -TeamId $group.Id -Filter "MembershipType ne 'standard'" -Property "Id, MembershipType" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
            if ((HasError -Row $Row -ProcessDriveError $ErrorResult -isUser $false)) {
                return
            }
      
            foreach ($channel in $teamChannels) {
                $webUrl = Get-MgTeamChannelFileFolder -TeamId $group.Id -ChannelId $channel.Id -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
                if ($ErrorResult.Count -ge 1) {
                    Write-Host "Private/Shared Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)" -ForegroundColor Red
                    $privateChannelErrors += "Private/Shared Channel: $($channel.DisplayName) failed with: $($ErrorResult[0].Exception)"
                    $ErrorResult.Clear()
                    continue
                }
                $strip = 1
                if($channel.MembershipType -eq "private"){
                    $strip = 2
                }
                $webUrl = GetDriveUrl -webUrl $webUrl.WebUrl -strip $strip
                $uri = [System.Uri]::new($webUrl)
                $siteId = (Invoke-MgGraphRequest -Uri "v1.0/sites/$($uri.Host):$($uri.AbsolutePath)" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult).Id
                if ($ErrorResult.Count -ge 1) {
                    Write-Host "Private/Shared Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)" -ForegroundColor Red
                    $privateChannelErrors += "Private/Shared Channel: $($channel.DisplayName) failed with: $($ErrorResult[0].Exception)"
                    $ErrorResult.Clear()
                    continue
                }
                $permission = New-MgSitePermission -SiteId $siteId -ErrorAction SilentlyContinue -ErrorVariable ErrorResult -BodyParameter (BuildPermission -applicationId $ClientAppId  -roles @("FullControl"))
                if ($ErrorResult.Count -ge 1) {
                    Write-Host "Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)" -ForegroundColor Red
                    $privateChannelErrors += "Private/Shared Channel: $($channel.DisplayName) failed with: $($ErrorResult[0].Exception)"
                    $ErrorResult.Clear()
                    continue
                }
                $successSiteUrls += "$($webUrl) - ($($siteId))"
                Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId -siteUrl $webUrl) -ForegroundColor Green
            }
        }
        $Row.SiteUrl = ($successSiteUrls | Out-String)
        if ($privateChannelErrors.Count -ge 1) {
            $Row.SiteStatus = $($WARNING)
            $Row.SiteErrorMessage = ($privateChannelErrors | Out-String)
        }
        else {
            $Row.SiteStatus = $($SUCCESS)
            $Row.SiteErrorMessage = $NOT_APPLICABLE
        }
    
    }
    catch {
        Write-Host "Failed to add $($Row.Email). The message was: $($_)" -ForegroundColor Red
        $Row.EmailStatus = $($FAILED)
        $Row.EmailErrorMessage = $_
    }
  
}

function ProcessDrive ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId) {

    Write-Host "Processing Drive"
    $driveUrl = $null
    try {
        $drive = Get-MgUser -UserId $Row.Email -Property "mySite" -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }
        $driveUrl = $drive.MySite
        $uri = [System.Uri]::new($driveUrl)
        $siteId = (Invoke-MgGraphRequest -Uri "v1.0/sites/$($uri.Host):$($uri.AbsolutePath)" -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError).Id
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }

        $permission = New-MgSitePermission -SiteId $siteId -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $ClientAppId  -roles @("FullControl"))
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }
    
        $Row.DriveUrl = "$($driveUrl) - ($($siteId ))"
        $Row.DriveStatus = $($SUCCESS)
        $Row.DriveErrorMessage = $NOT_APPLICABLE
        Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId -siteUrl $driveUrl) -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $($Row.Email). The message was: $($_)" -ForegroundColor Red
        if ([String]::IsNullOrEmpty($driveUrl) -or [String]::IsNullOrWhitespace($driveUrl) ) {
            $Row.DriveUrl = $NOT_APPLICABLE
        }
        else {
            $Row.DriveUrl = $driveUrl
        }
        $Row.DriveStatus = $($FAILED)
        $Row.DriveErrorMessage = $_
    }
}

function ProcessSharePointSite ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId) {

    Write-Host "Processing SharePoint Site"
    try {
        $uri = [System.Uri]::new($Row.SiteUrl)
        $site = Invoke-MgGraphRequest -Uri "v1.0/sites/$($uri.Host):$($uri.AbsolutePath)" -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }

        $permission = New-MgSitePermission -SiteId $site.Id -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $ClientAppId  -roles @("FullControl"))
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }
    
        $Row.SiteId = "($($site.Id)"
        $Row.SiteStatus = $($SUCCESS)
        $Row.SiteErrorMessage = $NOT_APPLICABLE
        Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $($Row.Email). The message was: $($_)" -ForegroundColor Red
        $Row.SiteStatus = $($FAILED)
        $Row.SiteErrorMessage = $_
    }
}

function HasError ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][System.Object]$ProcessDriveError, [bool]$isUser) {
    if ($ProcessDriveError.Count -ge 1) {
        if ($isUser) {
            Write-Host "Failed to add $($Row.Email). The message was: $($ProcessDriveError[0].Exception)" -ForegroundColor Red
            $Row.DriveStatus = $($FAILED)
            $Row.DriveErrorMessage = $ProcessDriveError[0].Exception
        }
        else {
            Write-Host "Failed to add $($Row.SiteUrl). The message was: $($ProcessDriveError[0].Exception)" -ForegroundColor Red
            $Row.SiteStatus = $($FAILED)
            $Row.SiteErrorMessage = $ProcessDriveError[0].Exception
        }
        $ProcessDriveError.Clear()
        return $true
    }
    return $false
}

function BuildPermission([parameter(mandatory)][String]$applicationId, [parameter(mandatory)][string[]]$roles) {
    $params = @{
        roles               = $roles
        grantedToIdentities = @(
            @{
                application = @{
                    id          = $applicationId
                    displayName = "CloudM-Limited-$($applicationId)"
                }
            }
        )
    }
    return $params
}

function BuildPermissionMessage ([parameter(mandatory)][Microsoft.Graph.PowerShell.Models.IMicrosoftGraphPermission]$permission, [parameter(mandatory)][String]$siteId, [parameter(mandatory)][String]$siteUrl) {
    return "Site Url: $($siteUrl) ($siteId). Permission Id: $($permission.Id), Roles: $($permission.Roles)"
}

function GetDriveUrl([parameter(mandatory)][String]$webUrl, [int]$strip) {
    while ($val -ne $strip) {
        $val++
        $index = $webUrl.LastIndexOf('/') 
        if ($index -ne -1) {
            $webUrl = $webUrl.Substring(0, $index)
        }
    }
    return $webUrl
}

function CreateUpdateApplicationAccessPolicy([parameter(mandatory)][String]$AppId, [parameter(mandatory)][String]$AppName, [parameter(mandatory)][String]$CertPath, [parameter(mandatory)][String]$MailGroupAlias) {
    $appPolicies = { 
        Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult 
    } | RetryCommand -TimeoutInSeconds 5 -RetryCount 10 -Context "Get Application Access Policy" -OnFinalExceptionContinue
  
    if ($appPolicies) {
        foreach ($policie in $appPolicies) {
            if ($policie.AppId -eq $AppId) {
                Write-Host "Access Policy already exists for: $AppId" -ForegroundColor Yellow 
                return $policie
            }
        }
    }
  
    Write-Host "Creating Policy for: $MailGroupAlias"
    $policy = { 
        New-ApplicationAccessPolicy -AppId $AppId -PolicyScopeGroupId $MailGroupAlias -AccessRight RestrictAccess -Description "Restricted policy for App $AppName ($AppId)" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult 
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Create Application Access Policy"
    Write-Host "Created Policy for: $MailGroupAlias with Id: $($policy.Identity)" -ForegroundColor Green
  
    return $policy
}

function ApplyLimitedMailPolicy([parameter(mandatory)][String]$AppId, 
    [parameter(mandatory)][String]$AppName, 
    [parameter(mandatory)][String]$CertPath, 
    [parameter(mandatory)][String]$TenantName,
    [parameter(mandatory)][String]$MailGroupAlias,
    [SecureString]$SecureCertificatePassword) {
    Write-Host "Waiting: $AppId 15 Seconds"
    Start-Sleep -Seconds 15
    ConnectExchangeOnline -AppId $AppId -CertPath $CertPath -SecureCertificatePassword $SecureCertificatePassword -TenantName $TenantName
    $distributionGroup = GetCreateMailGroup -MailGroupAlias $MailGroupAlias
    $policy = CreateUpdateApplicationAccessPolicy -AppId $AppId -AppName $AppName -CertPath $CertPath -MailGroupAlias $distributionGroup.PrimarySmtpAddress
    return $policy
}

function GetCreateMailGroup([parameter(mandatory)][String]$MailGroupAlias) {
    $distributionGroup = Get-DistributionGroup -Identity $MailGroupAlias -ErrorAction SilentlyContinue
    if ($distributionGroup) {
        Write-Host "$($distributionGroup.PrimarySmtpAddress) already exists." -ForegroundColor Yellow
    }
    else {
        Write-Host "Creating Distribution Group: $($MailGroupAlias)"
        $distributionGroup = New-DistributionGroup -Name $MailGroupAlias -Alias $MailGroupAlias -Type security -Description “Restricted group for App $AppName ($AppId)"
        Write-Host "Created Distribution Group: $($MailGroupAlias)" -ForegroundColor Green
    }
    return $distributionGroup;
}

function ProcessEmailDriveCsv (
    [parameter(mandatory)][String]$WorkFolder, 
    [parameter(mandatory)][String]$MailGroupAlias, 
    [parameter(mandatory)][String]$Environment,
    [parameter(mandatory)][String]$TenantName,
    [parameter(mandatory)][String]$ClientAppId, 
    [parameter(mandatory)][String]$ClientAppCertificate,
    [SecureString]$SecureCertificatePassword, 
    [System.Management.Automation.SwitchParameter]$DisconnectSession) {
    try {
    
        $file = Join-Path -Path $WorkFolder -ChildPath "EmailDrive.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }
        $nl = [Environment]::NewLine
        $script:DistributionGroup = $null
        $script:DistributionGroupMembers = $null
        ConnectMsGraph -Environment $Environment
        ConnectExchangeOnline -AppId $ClientAppId -CertPath $ClientAppCertificate -SecureCertificatePassword $SecureCertificatePassword -TenantName $TenantName
        $csv = Import-Csv $file
        $initEmailCounter = 0
        Write-Host "$($nl)$($nl)--------------------------------Processing EmailDrive.csv-----------------------------------------"
        foreach ($Row in $csv) {
            $Row | Add-Member -NotePropertyName "EmailStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "EmailErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "DriveUrl" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "DriveStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "DriveErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $itemType = [ItemType]$Row.ItemType
            Write-Host "$($nl)$($nl)--------------------------------Processing $($Row.Email) Starting-----------------------------------------"
            switch ($itemType) {
                Drive {
                    ProcessDrive -Row $Row -ClientAppId $ClientAppId
                    break
                }
                EMail {
                    ProcessEmail -Row $Row -MailGroupAlias $MailGroupAlias -Attempt $initEmailCounter
                    $initEmailCounter++
                    break
                }
                EmailDrive {
                    ProcessEmail -Row $Row -MailGroupAlias $MailGroupAlias -Attempt $initEmailCounter
                    $initEmailCounter++
                    ProcessDrive -Row $Row -ClientAppId $ClientAppId
                    break
                }
                default {
                    Write-Host "Unknown ItemType: $_" -ForegroundColor Yellow
                }
            }
            Write-Host "--------------------------------Processing $($Row.Email) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($DisconnectSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessMicrosoftTeamGroupCsv (
    [parameter(mandatory)][String]$WorkFolder, 
    [parameter(mandatory)][String]$MailGroupAlias, 
    [parameter(mandatory)][String]$Environment,
    [parameter(mandatory)][String]$TenantName,
    [parameter(mandatory)][String]$ClientAppId, 
    [parameter(mandatory)][String]$ClientAppCertificate,
    
    [SecureString]$SecureCertificatePassword, 
    [System.Management.Automation.SwitchParameter]$DisconnectSession) {
    try {
    
        $file = Join-Path -Path $WorkFolder -ChildPath "MicrosoftTeamGroup.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }
        $script:DistributionGroup = $null
        $script:DistributionGroupMembers = $null
        $initEmailCounter = 0  
        $nl = [Environment]::NewLine
        ConnectMsGraph -Environment $Environment
        ConnectExchangeOnline -AppId $ClientAppId -CertPath $ClientAppCertificate -SecureCertificatePassword $SecureCertificatePassword -TenantName $TenantName
        $csv = Import-Csv $file
        Write-Host "$($nl)$($nl)--------------------------------Processing MicrosoftTeamGroup.csv-----------------------------------------"
        foreach ($Row in $csv) {
            Write-Host "$($nl)$($nl)--------------------------------Processing $($Row.Email) Starting-----------------------------------------"
            $Row | Add-Member -NotePropertyName "EmailStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "EmailErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteUrl" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $microsoftTeamGroupItemType = [MicrosoftTeamGroupItemType]$Row.MicrosoftTeamGroupItemType
            switch ($microsoftTeamGroupItemType) {
                Site {
                    ProcessMicrosoftTeamGroupSite -Row $Row  -ClientAppId $ClientAppId
                    break
                }
                EMail {
                    ProcessEmail -Row $Row -MailGroupAlias $MailGroupAlias -Attempt $initEmailCounter
                    $initEmailCounter++
                    break
                }
                EmailSite {
                    ProcessEmail -Row $Row -MailGroupAlias $MailGroupAlias -Attempt $initEmailCounter
                    $initEmailCounter++
                    ProcessMicrosoftTeamGroupSite -Row $Row  -ClientAppId $ClientAppId
                    break
                }
                default {
                    Write-Host "Unknown ItemType: $_" -ForegroundColor Yellow
                }
            }
            Write-Host "--------------------------------Processing $($Row.Email) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($DisconnectSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessSharePointSiteCsv (
    [parameter(mandatory)][String]$WorkFolder,
    [parameter(mandatory)][String]$ClientAppId,
    [parameter(mandatory)][String]$Environment, 
    [SecureString]$SecureCertificatePassword, 
    [System.Management.Automation.SwitchParameter]$DisconnectSession) {
    try {
    
        $file = Join-Path -Path $WorkFolder -ChildPath "SharePointSites.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }  
        $nl = [Environment]::NewLine
        ConnectMsGraph -Environment $Environment
        $csv = Import-Csv $file
        Write-Host "$($nl)$($nl)--------------------------------Processing SharePointSites.csv-----------------------------------------"
        foreach ($Row in $csv) {
            $Row | Add-Member -NotePropertyName "SiteId" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            Write-Host "$($nl)$($nl)--------------------------------Processing $($Row.SiteUrl) Starting-----------------------------------------"
            ProcessSharePointSite -Row $Row -ClientAppId $ClientAppId
            Write-Host "--------------------------------Processing $($Row.SiteUrl) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($DisconnectSession) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessCsv(
    [parameter(mandatory)][String]$WorkFolder, 
    [parameter(mandatory)][String]$MailGroupAlias, 
    [parameter(mandatory)][String]$ClientAppId, 
    [parameter(mandatory)][String]$ClientAppCertificate,
    
    [parameter(mandatory)][String]$Environment, 
    [SecureString]$SecureCertificatePassword) {
    try {
        ProcessEmailDriveCsv -WorkFolder $WorkFolder -SecureCertificatePassword $SecureCertificatePassword -MailGroupAlias $MailGroupAlias -ClientAppId $ClientAppId -ClientAppCertificate $ClientAppCertificate -Environment $Environment 
        ProcessMicrosoftTeamGroupCsv -WorkFolder $WorkFolder -SecureCertificatePassword $SecureCertificatePassword -MailGroupAlias $MailGroupAlias -ClientAppId $ClientAppId -ClientAppCertificate $ClientAppCertificate -Environment $Environment 
        ProcessSharePointSiteCsv -WorkFolder $WorkFolder -SecureCertificatePassword $SecureCertificatePassword -ClientAppId $ClientAppId -Environment $Environment 
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-MgGraph"
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-ExchangeOnline"
    }
}

function ConnectMsGraph ([parameter(mandatory)][String]$Environment) {
    {
        $neededScopes = @(
            "Group.Read.All"
            "Sites.FullControl.All"
        )
        Connect-MgGraph -Environment $Environment -Scope $neededScopes -NoWelcome -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 10 -RetryCount 10 -Context "Connect to MgGraph"
}
function ConnectExchangeOnline([parameter(mandatory)][String]$AppId, [parameter(mandatory)][String]$CertPath, [SecureString]$SecureCertificatePassword, [parameter(mandatory)][String]$TenantName) {
    $contextAppId = (Get-ConnectionInformation -ErrorAction SilentlyContinue).AppId
    if ($contextAppId -ne $AppId) {
        {
            Connect-ExchangeOnline -CertificateFilePath $CertPath -CertificatePassword $SecureCertificatePassword -AppId $AppId -Organization $TenantName -ShowBanner:$false -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
            CheckErrors -ErrorToProcess $ErrorResult
        } | RetryCommand -TimeoutInSeconds 15 -RetryCount 10 -Context "Connect to Exchange Online"
    }
}

Export-ModuleMember -Function ProcessSharePointSiteCsv
Export-ModuleMember -Function ProcessMicrosoftTeamGroupCsv
Export-ModuleMember -Function ProcessEmailDriveCsv
Export-ModuleMember -Function ProcessCsv
Export-ModuleMember -Function ApplyLimitedMailPolicy

# SIG # Begin signature block
# MIKpKgYJKoZIhvcNAQcCoIKpGzCCqRcCAQExDTALBglghkgBZQMEAgEweQYKKwYB
# BAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+
# 81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQgqxlGej+db006SeHw
# jz1+QGeEXUZ8xV6jfIqfPwihBoKgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVwikHP
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
# eCYrgJxc+y2IyxK95zGClB0wgpQZAgEBMGwwXDELMAkGA1UEBhMCQkUxGTAXBgNV
# BAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0
# NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwAgxK83pmt0FjEC8TCzUwDQYJYIZIAWUD
# BAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQgSd17vBARnVqZ4qUE5ZzS5flKADQwl/nZffTCa5d6UMgwDQYJKoZIhvcNAQEB
# BQAEggIActhBL9dieM7NwWGLMEyaZIjmdH7unltRcmcC+p6oqxA+fUtQ5bQ9aX/Z
# CXJyzoNMV61jWXlo0lQW49EpOJzCSVWlDFeeqpotNeMlnckuA+XWzFOeA/bLwL2H
# 4jsMDP2VmdnRPUZfWInks9jN8xCP4c/2Xx33oAjc7XcUtAIoSV4unuovmrNFvJ7j
# tTKdQxkMh7N2eK048ef1Z4fdHoYK5jeFO5UA7PUN8WNy96pxGMPqUx6hfiS2MH81
# mQeKI4bIhh/69FcWdPMWV3dw7kyvyjHiJgMJ6INWKkAEiNo5UTI8/DlT5Kp2FLud
# 8wNZyaWl1F+EbukBzgSOVSgD0zzA6F5NHuw+lQk8Y2I0Stpd94N9PLdJVL2d84BC
# dKT5hqR9YyW9afusfN0Pmi0Zj5YeDxT5g++uyP+XqTz0Cib9/0ADJIA0O29+uPY4
# 7V8nebruHmIHJr+Zeq67/F2mqKwdNVS8gmmYJxeHkavWLHvK1AJfBhIAdNX7iY/x
# pLgbeI/nCGW9bNwxlVzogiFdztz1o16o9ZaFJ1H/aEFALQqHhMv8SJOc+ICyj+2D
# nMzUfabDdeJlTifD/cmYumnmgDAnVJ0fiiAVMobRY520QPFvXC924HVCvLaIP2Yy
# +a3QwLYoCNF7fiRY0Kj7gakQZQ+roskywB94GA7rH5x9FDZIFzWhgpEEMIKRAAYK
# KwYBBAGCNwIEATGCkPAwghgkBgkqhkiG9w0BBwKgghgVMIIYEQIBATEPMA0GCWCG
# SAFlAwQCAQUAMHkGCisGAQQBgjcCAQSgazBpMDQGCisGAQQBgjcCAR4wJgIDAQAA
# BBAfzDtgWUsITrck0sYpfvNRAgEAAgEAAgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIB
# BQAEIKsZRno/nW9NOknh8I89fkBnhF1GfMVeo3yKnz8IoQaCoIIUZTCCBaIwggSK
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
# ARUwLwYJKoZIhvcNAQkEMSIEIEnde7wQEZ1ameKlBOWc0uX5SgA0MJf52X30wmuX
# elDIMA0GCSqGSIb3DQEBAQUABIICAHLYQS/XYnjOzcFhizBMmmSI5nR+7p5bUXJn
# AvqeqKsQPn1LUOW0PWl/2Qlycs6DTFetY1l5aNJUFuPRKTicwklVpQxXnqqaLTXj
# JZ3JLgPl1sxTngP2y8C9h+I7DAz9lZnZ0T1GX1iJ5LPYzfMQj+HP9l8d96AI3O13
# FLQCKEleLp7qL5qzRbye47UynUMZDIezdnitOPHn9WeH3R6GCuY3hTuVAOz1DfFj
# cveqcRjD6lMeoX4ktjB/NZkHiiOGyIYf+vRXFnTzFld3cO5Mr8ox4iYDCeiDVipA
# BIjaOVEyPPw5U+SqdhS7nfMDWcmlpdRfhG7pAc4EjlUoA9M8wOheTR7sPpUJPGNi
# NEraXfeDfTy3SVS9nfOAQnSk+YakfWMlvWn7rHzdD5otGY+WHg8U+YPvrsj/l6k8
# 9Aom/f9AAySANDtvfrj2OO1fJ3m67h5iBya/mXquu/xdpqisHTVUvIJpmCcXh5Gr
# 1ix7ytQCXwYSAHTV+4mP8aS4G3iP5whlvWzcMZVc6IIhXc7c9aNeqPWWhSdR/2hB
# QC0Kh4TL/EiTnPiAso/tg5zM1H2mw3XiZU4nw/3JmLpp5oAwJ1SdH4ogFTKG0WOd
# tEDxb1wvduB1Qry2iD9mMvmt0MC2KAjRe34kWNCo+4GpEGUPq6LJMsAfeBgO6x+c
# fRQ2SBc1MIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEF
# ADB5BgorBgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlL
# CE63JNLGKX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCrGUZ6
# P51vTTpJ4fCPPX5AZ4RdRnzFXqN8ip8/CKEGgqCCFGUwggWiMIIEiqADAgECAhB4
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
# SIb3DQEJBDEiBCBJ3Xu8EBGdWpnipQTlnNLl+UoANDCX+dl99MJrl3pQyDANBgkq
# hkiG9w0BAQEFAASCAgBy2EEv12J4zs3BYYswTJpkiOZ0fu6eW1FyZwL6nqirED59
# S1DltD1pf9kJcnLOg0xXrWNZeWjSVBbj0Sk4nMJJVaUMV56qmi014yWdyS4D5dbM
# U54D9svAvYfiOwwM/ZWZ2dE9Rl9YieSz2M3zEI/hz/ZfHfegCNztdxS0AihJXi6e
# 6i+as0W8nuO1Mp1DGQyHs3Z4rTjx5/Vnh90ehgrmN4U7lQDs9Q3xY3L3qnEYw+pT
# HqF+JLYwfzWZB4ojhsiGH/r0VxZ08xZXd3DuTK/KMeImAwnog1YqQASI2jlRMjz8
# OVPkqnYUu53zA1nJpaXUX4Ru6QHOBI5VKAPTPMDoXk0e7D6VCTxjYjRK2l33g308
# t0lUvZ3zgEJ0pPmGpH1jJb1p+6x83Q+aLRmPlh4PFPmD767I/5epPPQKJv3/QAMk
# gDQ7b3649jjtXyd5uu4eYgcmv5l6rrv8XaaorB01VLyCaZgnF4eRq9Yse8rUAl8G
# EgB01fuJj/GkuBt4j+cIZb1s3DGVXOiCIV3O3PWjXqj1loUnUf9oQUAtCoeEy/xI
# k5z4gLKP7YOczNR9psN14mVOJ8P9yZi6aeaAMCdUnR+KIBUyhtFjnbRA8W9cL3bg
# dUK8tog/ZjL5rdDAtigI0Xt+JFjQqPuBqRBlD6uiyTLAH3gYDusfnH0UNkgXNTCC
# GCQGCSqGSIb3DQEHAqCCGBUwghgRAgEBMQ8wDQYJYIZIAWUDBAIBBQAweQYKKwYB
# BAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIBHjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+
# 81ECAQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQgqxlGej+db006SeHw
# jz1+QGeEXUZ8xV6jfIqfPwihBoKgghRlMIIFojCCBIqgAwIBAgIQeAMYQkVwikHP
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
# IgQgSd17vBARnVqZ4qUE5ZzS5flKADQwl/nZffTCa5d6UMgwDQYJKoZIhvcNAQEB
# BQAEggIActhBL9dieM7NwWGLMEyaZIjmdH7unltRcmcC+p6oqxA+fUtQ5bQ9aX/Z
# CXJyzoNMV61jWXlo0lQW49EpOJzCSVWlDFeeqpotNeMlnckuA+XWzFOeA/bLwL2H
# 4jsMDP2VmdnRPUZfWInks9jN8xCP4c/2Xx33oAjc7XcUtAIoSV4unuovmrNFvJ7j
# tTKdQxkMh7N2eK048ef1Z4fdHoYK5jeFO5UA7PUN8WNy96pxGMPqUx6hfiS2MH81
# mQeKI4bIhh/69FcWdPMWV3dw7kyvyjHiJgMJ6INWKkAEiNo5UTI8/DlT5Kp2FLud
# 8wNZyaWl1F+EbukBzgSOVSgD0zzA6F5NHuw+lQk8Y2I0Stpd94N9PLdJVL2d84BC
# dKT5hqR9YyW9afusfN0Pmi0Zj5YeDxT5g++uyP+XqTz0Cib9/0ADJIA0O29+uPY4
# 7V8nebruHmIHJr+Zeq67/F2mqKwdNVS8gmmYJxeHkavWLHvK1AJfBhIAdNX7iY/x
# pLgbeI/nCGW9bNwxlVzogiFdztz1o16o9ZaFJ1H/aEFALQqHhMv8SJOc+ICyj+2D
# nMzUfabDdeJlTifD/cmYumnmgDAnVJ0fiiAVMobRY520QPFvXC924HVCvLaIP2Yy
# +a3QwLYoCNF7fiRY0Kj7gakQZQ+roskywB94GA7rH5x9FDZIFzUwghgkBgkqhkiG
# 9w0BBwKgghgVMIIYEQIBATEPMA0GCWCGSAFlAwQCAQUAMHkGCisGAQQBgjcCAQSg
# azBpMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNRAgEAAgEA
# AgEAAgEAAgEAMDEwDQYJYIZIAWUDBAIBBQAEIKsZRno/nW9NOknh8I89fkBnhF1G
# fMVeo3yKnz8IoQaCoIIUZTCCBaIwggSKoAMCAQICEHgDGEJFcIpBz28BuO60qVQw
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIEnde7wQ
# EZ1ameKlBOWc0uX5SgA0MJf52X30wmuXelDIMA0GCSqGSIb3DQEBAQUABIICAHLY
# QS/XYnjOzcFhizBMmmSI5nR+7p5bUXJnAvqeqKsQPn1LUOW0PWl/2Qlycs6DTFet
# Y1l5aNJUFuPRKTicwklVpQxXnqqaLTXjJZ3JLgPl1sxTngP2y8C9h+I7DAz9lZnZ
# 0T1GX1iJ5LPYzfMQj+HP9l8d96AI3O13FLQCKEleLp7qL5qzRbye47UynUMZDIez
# dnitOPHn9WeH3R6GCuY3hTuVAOz1DfFjcveqcRjD6lMeoX4ktjB/NZkHiiOGyIYf
# +vRXFnTzFld3cO5Mr8ox4iYDCeiDVipABIjaOVEyPPw5U+SqdhS7nfMDWcmlpdRf
# hG7pAc4EjlUoA9M8wOheTR7sPpUJPGNiNEraXfeDfTy3SVS9nfOAQnSk+YakfWMl
# vWn7rHzdD5otGY+WHg8U+YPvrsj/l6k89Aom/f9AAySANDtvfrj2OO1fJ3m67h5i
# Bya/mXquu/xdpqisHTVUvIJpmCcXh5Gr1ix7ytQCXwYSAHTV+4mP8aS4G3iP5whl
# vWzcMZVc6IIhXc7c9aNeqPWWhSdR/2hBQC0Kh4TL/EiTnPiAso/tg5zM1H2mw3Xi
# ZU4nw/3JmLpp5oAwJ1SdH4ogFTKG0WOdtEDxb1wvduB1Qry2iD9mMvmt0MC2KAjR
# e34kWNCo+4GpEGUPq6LJMsAfeBgO6x+cfRQ2SBc1MIIYJAYJKoZIhvcNAQcCoIIY
# FTCCGBECAQExDzANBglghkgBZQMEAgEFADB5BgorBgEEAYI3AgEEoGswaTA0Bgor
# BgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLGKX7zUQIBAAIBAAIBAAIBAAIB
# ADAxMA0GCWCGSAFlAwQCAQUABCCrGUZ6P51vTTpJ4fCPPX5AZ4RdRnzFXqN8ip8/
# CKEGgqCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCKQc9vAbjutKlUMA0GCSqGSIb3
# DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2JhbFNpZ24gUm9vdCBDQSAtIFIzMRMwEQYD
# VQQKEwpHbG9iYWxTaWduMRMwEQYDVQQDEwpHbG9iYWxTaWduMB4XDTIwMDcyODAw
# MDAwMFoXDTI5MDMxODAwMDAwMFowUzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExKTAnBgNVBAMTIEdsb2JhbFNpZ24gQ29kZSBTaWduaW5n
# IFJvb3QgUjQ1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAti3FMN16
# 6KuQPQNysDpLmRZhsuX/pWcdNxzlfuyTg6qE9aNDm5hFirhjV12bAIgEJen4aJJL
# gthLyUoD86h/ao+KYSe9oUTQ/fU/IsKjT5GNswWyKIKRXftZiAULlwbCmPgspzMk
# 7lA6QczwoLB7HU3SqFg4lunf+RuRu4sQLNLHQx2iCXShgK975jMKDFlrjrz0q1qX
# e3+uVfuE8ID+hEzX4rq9xHWhb71hEHREspgH4nSr/2jcbCY+6R/l4ASHrTDTDI0D
# fFW4FnBcJHggJetnZ4iruk40mGtwEd44ytS+ocCc4d8eAgHYO+FnQ4S2z/x0ty+E
# o7+6CTc9Z2yxRVwZYatBg/WsHet3DUZHc86/vZWV7Z0riBD++ljop1fhs8+oWukH
# JZsSxJ6Acj2T3IyU3ztE5iaA/NLDA/CMDNJF1i7nj5ie5gTuQm5nfkIWcWLnBPlg
# xmShtpyBIU4rxm1olIbGmXRzZzF6kfLUjHlufKa7fkZvTcWFEivPmiJECKiFN84H
# YVcGFxIkwMQxc6GYNVdHfhA6RdktpFGQmKmgBzfEZRqqHGsWd/enl+w/GTCZbzH7
# 6kCy59LE+snQ8FB2dFn6jW0XMr746X4D9OeHdZrUSpEshQMTAitCgPKJajbPyEyg
# zp74y42tFqfT3tWbGKfGkjrxgmPxLg4kZN8CAwEAAaOCAXcwggFzMA4GA1UdDwEB
# /wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDAzAPBgNVHRMBAf8EBTADAQH/MB0G
# A1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQu86WOzAfBgNVHSMEGDAWgBSP8Et/qC5F
# JK5NUPpjmove4t0bvDB6BggrBgEFBQcBAQRuMGwwLQYIKwYBBQUHMAGGIWh0dHA6
# Ly9vY3NwLmdsb2JhbHNpZ24uY29tL3Jvb3RyMzA7BggrBgEFBQcwAoYvaHR0cDov
# L3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvcm9vdC1yMy5jcnQwNgYDVR0f
# BC8wLTAroCmgJ4YlaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9yb290LXIzLmNy
# bDBHBgNVHSAEQDA+MDwGBFUdIAAwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cu
# Z2xvYmFsc2lnbi5jb20vcmVwb3NpdG9yeS8wDQYJKoZIhvcNAQEMBQADggEBAKz3
# zBWLMHmoHQsoiBkJ1xx//oa9e1ozbg1nDnti2eEYXLC9E10dI645UHY3qkT9XwEj
# WYZWTMytvGQTFDCkIKjgP+icctx+89gMI7qoLao89uyfhzEHZfU5p1GCdeHyL5f2
# 0eFlloNk/qEdUfu1JJv10ndpvIUsXPpYd9Gup7EL4tZ3u6m0NEqpbz308w2VXeb5
# ekWwJRcxLtv3D2jmgx+p9+XUnZiM02FLL8Mofnrekw60faAKbZLEtGY/fadY7qz3
# 7MMIAas4/AocqcWXsojICQIZ9lyaGvFNbDDUswarAGBIDXirzxetkpNiIHd1bL3I
# MrTcTevZ38GQlim9wX8wggboMIIE0KADAgECAhB3vQ4Ft1kLth1HYVMeP3XtMA0G
# CSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWdu
# IG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0
# NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwxCzAJBgNVBAYTAkJF
# MRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQDEylHbG9iYWxTaWdu
# IEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgSi8os1P9B2BpV1BlT
# t/2jF+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAEeIQQaqTWlpCOgfh8
# qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWatSyyEc8lG31RK5gf
# SaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2zBZzIU+tS13hMUQGS
# gt4T8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXtHQcZxOsmd/KrbReT
# Sam35sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmfvpMusgafJsAMAVYS
# 4bKKnw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGlr3A2onmO3A1zwPHk
# LKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tjIF2OfjuyQ9hiOpTl
# zbSYszcZJBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCXpxbmJouI9wNEhl9i
# Z0y1pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWTyCH9PIjmaWP47nXJ
# i8Kr77o6/elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB36Fl6CSDySrC/blT
# AgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUH
# AwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q/FkJhmPF7POxEztX
# HAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvOljswgZMGCCsGAQUF
# BwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5nbG9iYWxzaWduLmNv
# bS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0dHA6Ly9zZWN1cmUu
# Z2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9vdHI0NS5jcnQwQQYD
# VR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9jb2Rlc2ln
# bmluZ3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGgMgECMDQwMgYIKwYB
# BQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAcG
# BWeBDAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5iS8Yn6vW6x1L6JR8
# DQdomxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/UovG2XiULd5bpzXFA
# M4gp7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ+KUVChSWhbFqaDQl
# Qq+WVvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0jfShziq7vKxuav2xT
# pxSePIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvfcXo6ymP31TBENzL+
# u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws80lWAMgSK8Ynuzev
# V+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoRHeU3hZ8uZmKaXoFO
# laxVV0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5yA9jYIivzJxZPOOhR
# QAyuku++PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoOqHo222q6YV8RJJWk
# 4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV+mL8JOAEek7Q5G7e
# zp44UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25EXIMiEQmM2YBRN/k
# Mw4h3mKJSAfa9TCCB88wggW3oAMCAQICDErzema3QWMQLxMLNTANBgkqhkiG9w0B
# AQsFADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEy
# MDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5nIENBIDIw
# MjAwHhcNMjQwNDAzMTU0MTE2WhcNMjUwNDA0MTU0MTE2WjCCAQ4xHTAbBgNVBA8M
# FFByaXZhdGUgT3JnYW5pemF0aW9uMREwDwYDVQQFEwgxMzMzNzM0MzETMBEGCysG
# AQQBgjc8AgEDEwJHQjELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFu
# Y2hlc3RlcjETMBEGA1UEBxMKTWFuY2hlc3RlcjEZMBcGA1UECRMQMTcgTWFyYmxl
# IFN0cmVldDEgMB4GA1UEChMXQ2xvdWRNIFNvZnR3YXJlIExpbWl0ZWQxIDAeBgNV
# BAMTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMScwJQYJKoZIhvcNAQkBFhhtYXR0
# Lm1ja2luc3RyeUBjbG91ZG0uaW8wggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCeChOiRjYdi7nE+/2zkusEYtLvYDDAgSTiG5qyauIreUULuW52PgP6b6SE
# cwMZf90BaYsMi9bcuI1yZ9C0lhbbyCtRcKj3llc/qdHwn9wjaI60cenb8e981VXr
# SHOFlTRnLFv2BEpiqtH0as26jTyt8oa1o6rd/4JI5JngV1TohKwCpl5GxrOv9cDZ
# vRqlBx4uJhU945FQ2wiB8SW9wIeGYDmMHxKX/YXklSm88LnxNznd1BRanPl0VbkJ
# q/UF0FfzN913qu/PxmE5gpak+QQr3JPYtCPQTZPHMAN6waMngJnw9TwlNUGEhxvt
# 371Y2FxovdUZyDLuRKxUq7cKexhb2JeL6rWi4J8kSxh54GfLwRAjLWUW6gt8E4Yd
# /62xP77AodWSvgGMeGM5P5fBQi3Be39abAou4fS3qWAEcaWy1qn7p0FxALrplQIy
# Lw6Jnz7d0zzJKJE7hQcEfbqVJZzugxhB7GBfo7VcKDLEJfcwl8RwmsiU4QQGrXUz
# 1wcq+Fy6l+4Km+9f5roKK4dNFETf5srRH5bVvsu6wenIXB3elE+loXqkqWhrtuY+
# bxHoZ1wW1W6FNCh0a9eacSpqBccPahqghnuH19MJ0ky7RAAOwsCiStl53YPocpf+
# 4KYnx8nCDFJqU5TDK59Pav0u1EGv59Lo02AcSEw/6knEVqOqkQIDAQABo4IB2zCC
# AdcwDgYDVR0PAQH/BAQDAgeAMIGfBggrBgEFBQcBAQSBkjCBjzBMBggrBgEFBQcw
# AoZAaHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvZ3NnY2NyNDVl
# dmNvZGVzaWduY2EyMDIwLmNydDA/BggrBgEFBQcwAYYzaHR0cDovL29jc3AuZ2xv
# YmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2EyMDIwMFUGA1UdIAROMEww
# QQYJKwYBBAGgMgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNp
# Z24uY29tL3JlcG9zaXRvcnkvMAcGBWeBDAEDMAkGA1UdEwQCMAAwRwYDVR0fBEAw
# PjA8oDqgOIY2aHR0cDovL2NybC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29k
# ZXNpZ25jYTIwMjAuY3JsMCMGA1UdEQQcMBqBGG1hdHQubWNraW5zdHJ5QGNsb3Vk
# bS5pbzATBgNVHSUEDDAKBggrBgEFBQcDAzAfBgNVHSMEGDAWgBQlndD8WQmGY8Xs
# 87ETO1ccA5I2ETAdBgNVHQ4EFgQUmeoy5enoUY6lDmu5FlhyUaFHWawwDQYJKoZI
# hvcNAQELBQADggIBAMriJ8rqBFu9wWqoGWGotCk5rCrEXXfdRRM3jAqhwt+qWy/2
# nVrl892cPNQe4WeoagqZ1a0c7SRPijwMsmiadfvq+iOKe+qIuw2vR/bMpyq7J8GZ
# oIrGD65tde5Y2HKwznrTZ56WxIXnAWkqbVKYoC6+iUHv0+rm5LbLxlTftv02Ri6V
# zIUMg9O4FJnJ1S81A/gBNWhx6fSEgaRkUZ+qcijB/LMWO9dTf5P1WtzcFMBShgSx
# QrQ5Li4lw4SKpburQecVnB6f7OW70Rfu4CiUVkeoR8jL4rUeRaSrR3Pj5tWkmVOp
# MAcdEjChHmh7gaeJNdOsfv8yUXML4zgSuJTsDR690NGHEcDcPwgAxTatLmuRCSTu
# H6tD/gG4ES38Q1mz7joDNkpR79/IzKfYHl30fxHjqJbf3cuDy+mK1qd13fvMpR9S
# 69sb8bPdJDJRL9mcO8RxJfwcNDqUHDAwz7J7b1vj/dIkOT7d5n4CBpubKb6jjQtN
# IGeDSNcev6ts2bjPpOiiCF3Z1+g4/HMULZWxVQr5bAKwkllhra6kTj1rKTZEjZCR
# kaBpcOT3jCijqkG5ir7IZ7IObprSue4CKYjE0Nzco1IuJrDjwM/2cBhLxs7XKKtK
# HvuX/ze8ygvJIdNTd+9wcwumekJJGFrqJgLPWr3HCtF4JiuAnFz7LYjLEr3nMYID
# FTCCAxECAQEwbDBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBu
# di1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVTaWduaW5n
# IENBIDIwMjACDErzema3QWMQLxMLNTANBglghkgBZQMEAgEFAKB8MBAGCisGAQQB
# gjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBJ3Xu8EBGdWpnipQTl
# nNLl+UoANDCX+dl99MJrl3pQyDANBgkqhkiG9w0BAQEFAASCAgBy2EEv12J4zs3B
# YYswTJpkiOZ0fu6eW1FyZwL6nqirED59S1DltD1pf9kJcnLOg0xXrWNZeWjSVBbj
# 0Sk4nMJJVaUMV56qmi014yWdyS4D5dbMU54D9svAvYfiOwwM/ZWZ2dE9Rl9YieSz
# 2M3zEI/hz/ZfHfegCNztdxS0AihJXi6e6i+as0W8nuO1Mp1DGQyHs3Z4rTjx5/Vn
# h90ehgrmN4U7lQDs9Q3xY3L3qnEYw+pTHqF+JLYwfzWZB4ojhsiGH/r0VxZ08xZX
# d3DuTK/KMeImAwnog1YqQASI2jlRMjz8OVPkqnYUu53zA1nJpaXUX4Ru6QHOBI5V
# KAPTPMDoXk0e7D6VCTxjYjRK2l33g308t0lUvZ3zgEJ0pPmGpH1jJb1p+6x83Q+a
# LRmPlh4PFPmD767I/5epPPQKJv3/QAMkgDQ7b3649jjtXyd5uu4eYgcmv5l6rrv8
# XaaorB01VLyCaZgnF4eRq9Yse8rUAl8GEgB01fuJj/GkuBt4j+cIZb1s3DGVXOiC
# IV3O3PWjXqj1loUnUf9oQUAtCoeEy/xIk5z4gLKP7YOczNR9psN14mVOJ8P9yZi6
# aeaAMCdUnR+KIBUyhtFjnbRA8W9cL3bgdUK8tog/ZjL5rdDAtigI0Xt+JFjQqPuB
# qRBlD6uiyTLAH3gYDusfnH0UNkgXNTCCGCQGCSqGSIb3DQEHAqCCGBUwghgRAgEB
# MQ8wDQYJYIZIAWUDBAIBBQAweQYKKwYBBAGCNwIBBKBrMGkwNAYKKwYBBAGCNwIB
# HjAmAgMBAAAEEB/MO2BZSwhOtyTSxil+81ECAQACAQACAQACAQACAQAwMTANBglg
# hkgBZQMEAgEFAAQgqxlGej+db006SeHwjz1+QGeEXUZ8xV6jfIqfPwihBoKgghRl
# MIIFojCCBIqgAwIBAgIQeAMYQkVwikHPbwG47rSpVDANBgkqhkiG9w0BAQwFADBM
# MSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMzETMBEGA1UEChMKR2xv
# YmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjAeFw0yMDA3MjgwMDAwMDBaFw0y
# OTAzMTgwMDAwMDBaMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWdu
# IG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0
# NTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALYtxTDdeuirkD0DcrA6
# S5kWYbLl/6VnHTcc5X7sk4OqhPWjQ5uYRYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oo
# f2qPimEnvaFE0P31PyLCo0+RjbMFsiiCkV37WYgFC5cGwpj4LKczJO5QOkHM8KCw
# ex1N0qhYOJbp3/kbkbuLECzSx0Mdogl0oYCve+YzCgxZa4689Ktal3t/rlX7hPCA
# /oRM1+K6vcR1oW+9YRB0RLKYB+J0q/9o3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4
# ICXrZ2eIq7pONJhrcBHeOMrUvqHAnOHfHgIB2DvhZ0OEts/8dLcvhKO/ugk3PWds
# sUVcGWGrQYP1rB3rdw1GR3POv72Vle2dK4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9
# k9yMlN87ROYmgPzSwwPwjAzSRdYu54+YnuYE7kJuZ35CFnFi5wT5YMZkobacgSFO
# K8ZtaJSGxpl0c2cxepHy1Ix5bnymu35Gb03FhRIrz5oiRAiohTfOB2FXBhcSJMDE
# MXOhmDVXR34QOkXZLaRRkJipoAc3xGUaqhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ
# 0PBQdnRZ+o1tFzK++Ol+A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan
# 097VmxinxpI68YJj8S4OJGTfAgMBAAGjggF3MIIBczAOBgNVHQ8BAf8EBAMCAYYw
# EwYDVR0lBAwwCgYIKwYBBQUHAwMwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU
# HwC/RoAK/Hg5t6W0Q9lWULvOljswHwYDVR0jBBgwFoAUj/BLf6guRSSuTVD6Y5qL
# 3uLdG7wwegYIKwYBBQUHAQEEbjBsMC0GCCsGAQUFBzABhiFodHRwOi8vb2NzcC5n
# bG9iYWxzaWduLmNvbS9yb290cjMwOwYIKwYBBQUHMAKGL2h0dHA6Ly9zZWN1cmUu
# Z2xvYmFsc2lnbi5jb20vY2FjZXJ0L3Jvb3QtcjMuY3J0MDYGA1UdHwQvMC0wK6Ap
# oCeGJWh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vcm9vdC1yMy5jcmwwRwYDVR0g
# BEAwPjA8BgRVHSAAMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNp
# Z24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4IBAQCs98wVizB5qB0L
# KIgZCdccf/6GvXtaM24NZw57YtnhGFywvRNdHSOuOVB2N6pE/V8BI1mGVkzMrbxk
# ExQwpCCo4D/onHLcfvPYDCO6qC2qPPbsn4cxB2X1OadRgnXh8i+X9tHhZZaDZP6h
# HVH7tSSb9dJ3abyFLFz6WHfRrqexC+LWd7uptDRKqW899PMNlV3m+XpFsCUXMS7b
# 9w9o5oMfqffl1J2YjNNhSy/DKH563pMOtH2gCm2SxLRmP32nWO6s9+zDCAGrOPwK
# HKnFl7KIyAkCGfZcmhrxTWww1LMGqwBgSA14q88XrZKTYiB3dWy9yDK03E3r2d/B
# kJYpvcF/MIIG6DCCBNCgAwIBAgIQd70OBbdZC7YdR2FTHj917TANBgkqhkiG9w0B
# AQsFADBTMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEp
# MCcGA1UEAxMgR2xvYmFsU2lnbiBDb2RlIFNpZ25pbmcgUm9vdCBSNDUwHhcNMjAw
# NzI4MDAwMDAwWhcNMzAwNzI4MDAwMDAwWjBcMQswCQYDVQQGEwJCRTEZMBcGA1UE
# ChMQR2xvYmFsU2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1
# IEVWIENvZGVTaWduaW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDLIO+XHrkBMkOgW6mKI/0gXq44EovKLNT/QdgaVdQZU7f9oxfnejlc
# wPfOEaP5pe0B+rW6k++vk9z44rMZTIOwSkRQBHiEEGqk1paQjoH4fKsvtaNXM9JY
# e5QObQ+lkSYqs4NPcrGKe2SS0PC0VV+WCxHlmrUsshHPJRt9USuYH0mjX/gTnjW4
# AwLapBMvhUrvxC9wDsHUzDMS7L1AldMRyubNswWcyFPrUtd4TFEBkoLeE/MHjnS6
# hICf0qQVDuiv6/eJ9t9x8NG+p7JBMyB1zLHV7R0HGcTrJnfyq20Xk0mpt+bDkJzG
# uOzMyXuaXsXFJJNjb34Qi2HPmFWjJKKINvL5n76TLrIGnybADAFWEuGyip8OHtyY
# iy7P2uKJNKYfJqCornht7KGIFTzC6u632K1hpa9wNqJ5jtwNc8Dx5CyrlOxYBjk2
# SNY7WugiznQOryzxFdrRtJXorNVJbeWv3ZtrYyBdjn47skPYYjqU5c20mLM3GSQS
# cnOrBLAJ3IXm1CIE70AqHS5tx2nTbrcBbA3gl6cW5iaLiPcDRIZfYmdMtac3qFXc
# AzaMbs9tNibxDo+wPXHA4TKnguS2MgIyMHy1k8gh/TyI5mlj+O51yYvCq++6Ov3p
# Xr+2EfG+8D3KMj5ufd4PfpuVxBKH5xq4Tu4swd+hZegkg8kqwv25UwIDAQABo4IB
# rTCCAakwDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMBIGA1Ud
# EwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFCWd0PxZCYZjxezzsRM7VxwDkjYRMB8G
# A1UdIwQYMBaAFB8Av0aACvx4ObeltEPZVlC7zpY7MIGTBggrBgEFBQcBAQSBhjCB
# gzA5BggrBgEFBQcwAYYtaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vY29kZXNp
# Z25pbmdyb290cjQ1MEYGCCsGAQUFBzAChjpodHRwOi8vc2VjdXJlLmdsb2JhbHNp
# Z24uY29tL2NhY2VydC9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3J0MEEGA1UdHwQ6MDgw
# NqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vY29kZXNpZ25pbmdyb290
# cjQ1LmNybDBVBgNVHSAETjBMMEEGCSsGAQQBoDIBAjA0MDIGCCsGAQUFBwIBFiZo
# dHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzAHBgVngQwBAzAN
# BgkqhkiG9w0BAQsFAAOCAgEAJXWgCck5urehOYkvGJ+r1usdS+iUfA0HaJscne9x
# thdqawJPsz+GRYfMZZtM41gGAiJm1WECxWOP1KLxtl4lC3eW6c1xQDOIKezu86Jt
# vE21PgZLyXMzyggULT1M6LC6daZ0LaRYOmwTSfilFQoUloWxamg0JUKvllb0EPok
# ffErcsEW4Wvr5qmYxz5a9NAYnf10l4Z3Rio9I30oc4qu7ysbmr9sU6cUnjyHccBe
# jsj70yqSM+pXTV4HXsrBGKyBLRoh+m7Pl2F733F6Ospj99UwRDcy/rtDhdy6/KbK
# Mxkrd23bywXwfl91LqK2vzWqNmPJzmTZvfy8LPNJVgDIEivGJ7s3r1fvxM8eKcT0
# 4i3OKmHPV+31CkDi9RjWHumQL8rTh1+TikgaER3lN4WfLmZiml6BTpWsVVdD3FOL
# JX48YQ+KC7r1P6bXjvcEVl4hu5/XanGAv5becgPY2CIr8ycWTzjoUUAMrpLvvj19
# 94DGTDZXhJWnhBVIMA5SJwiNjqK9IscZyabKDqh6NttqumFfESSVpOKOaO4ZqUmZ
# XtC0NL3W+UDHEJcxUjk1KRGHJNPE+6ljy3dI1fpi/CTgBHpO0ORu3s6eOFAm9CFx
# ZdcJJdTJBwB6uMfzd+jF1OJV0NMe9n9S4kmNuRFyDIhEJjNmAUTf5DMOId5iiUgH
# 2vUwggfPMIIFt6ADAgECAgxK83pmt0FjEC8TCzUwDQYJKoZIhvcNAQELBQAwXDEL
# MAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAwBgNVBAMT
# KUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIwMB4XDTI0
# MDQwMzE1NDExNloXDTI1MDQwNDE1NDExNlowggEOMR0wGwYDVQQPDBRQcml2YXRl
# IE9yZ2FuaXphdGlvbjERMA8GA1UEBRMIMTMzMzczNDMxEzARBgsrBgEEAYI3PAIB
# AxMCR0IxCzAJBgNVBAYTAkdCMRswGQYDVQQIExJHcmVhdGVyIE1hbmNoZXN0ZXIx
# EzARBgNVBAcTCk1hbmNoZXN0ZXIxGTAXBgNVBAkTEDE3IE1hcmJsZSBTdHJlZXQx
# IDAeBgNVBAoTF0Nsb3VkTSBTb2Z0d2FyZSBMaW1pdGVkMSAwHgYDVQQDExdDbG91
# ZE0gU29mdHdhcmUgTGltaXRlZDEnMCUGCSqGSIb3DQEJARYYbWF0dC5tY2tpbnN0
# cnlAY2xvdWRtLmlvMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAngoT
# okY2HYu5xPv9s5LrBGLS72AwwIEk4huasmriK3lFC7ludj4D+m+khHMDGX/dAWmL
# DIvW3LiNcmfQtJYW28grUXCo95ZXP6nR8J/cI2iOtHHp2/HvfNVV60hzhZU0Zyxb
# 9gRKYqrR9GrNuo08rfKGtaOq3f+CSOSZ4FdU6ISsAqZeRsazr/XA2b0apQceLiYV
# PeORUNsIgfElvcCHhmA5jB8Sl/2F5JUpvPC58Tc53dQUWpz5dFW5Cav1BdBX8zfd
# d6rvz8ZhOYKWpPkEK9yT2LQj0E2TxzADesGjJ4CZ8PU8JTVBhIcb7d+9WNhcaL3V
# Gcgy7kSsVKu3CnsYW9iXi+q1ouCfJEsYeeBny8EQIy1lFuoLfBOGHf+tsT++wKHV
# kr4BjHhjOT+XwUItwXt/WmwKLuH0t6lgBHGlstap+6dBcQC66ZUCMi8OiZ8+3dM8
# ySiRO4UHBH26lSWc7oMYQexgX6O1XCgyxCX3MJfEcJrIlOEEBq11M9cHKvhcupfu
# CpvvX+a6CiuHTRRE3+bK0R+W1b7LusHpyFwd3pRPpaF6pKloa7bmPm8R6GdcFtVu
# hTQodGvXmnEqagXHD2oaoIZ7h9fTCdJMu0QADsLAokrZed2D6HKX/uCmJ8fJwgxS
# alOUwyufT2r9LtRBr+fS6NNgHEhMP+pJxFajqpECAwEAAaOCAdswggHXMA4GA1Ud
# DwEB/wQEAwIHgDCBnwYIKwYBBQUHAQEEgZIwgY8wTAYIKwYBBQUHMAKGQGh0dHA6
# Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2dzZ2NjcjQ1ZXZjb2Rlc2ln
# bmNhMjAyMC5jcnQwPwYIKwYBBQUHMAGGM2h0dHA6Ly9vY3NwLmdsb2JhbHNpZ24u
# Y29tL2dzZ2NjcjQ1ZXZjb2Rlc2lnbmNhMjAyMDBVBgNVHSAETjBMMEEGCSsGAQQB
# oDIBAjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9y
# ZXBvc2l0b3J5LzAHBgVngQwBAzAJBgNVHRMEAjAAMEcGA1UdHwRAMD4wPKA6oDiG
# Nmh0dHA6Ly9jcmwuZ2xvYmFsc2lnbi5jb20vZ3NnY2NyNDVldmNvZGVzaWduY2Ey
# MDIwLmNybDAjBgNVHREEHDAagRhtYXR0Lm1ja2luc3RyeUBjbG91ZG0uaW8wEwYD
# VR0lBAwwCgYIKwYBBQUHAwMwHwYDVR0jBBgwFoAUJZ3Q/FkJhmPF7POxEztXHAOS
# NhEwHQYDVR0OBBYEFJnqMuXp6FGOpQ5ruRZYclGhR1msMA0GCSqGSIb3DQEBCwUA
# A4ICAQDK4ifK6gRbvcFqqBlhqLQpOawqxF133UUTN4wKocLfqlsv9p1a5fPdnDzU
# HuFnqGoKmdWtHO0kT4o8DLJomnX76vojinvqiLsNr0f2zKcquyfBmaCKxg+ubXXu
# WNhysM5602eelsSF5wFpKm1SmKAuvolB79Pq5uS2y8ZU37b9NkYulcyFDIPTuBSZ
# ydUvNQP4ATVocen0hIGkZFGfqnIowfyzFjvXU3+T9Vrc3BTAUoYEsUK0OS4uJcOE
# iqW7q0HnFZwen+zlu9EX7uAolFZHqEfIy+K1HkWkq0dz4+bVpJlTqTAHHRIwoR5o
# e4GniTXTrH7/MlFzC+M4EriU7A0evdDRhxHA3D8IAMU2rS5rkQkk7h+rQ/4BuBEt
# /ENZs+46AzZKUe/fyMyn2B5d9H8R46iW393Lg8vpitandd37zKUfUuvbG/Gz3SQy
# US/ZnDvEcSX8HDQ6lBwwMM+ye29b4/3SJDk+3eZ+Agabmym+o40LTSBng0jXHr+r
# bNm4z6Tooghd2dfoOPxzFC2VsVUK+WwCsJJZYa2upE49ayk2RI2QkZGgaXDk94wo
# o6pBuYq+yGeyDm6a0rnuAimIxNDc3KNSLiaw48DP9nAYS8bO1yirSh77l/83vMoL
# ySHTU3fvcHMLpnpCSRha6iYCz1q9xwrReCYrgJxc+y2IyxK95zGCAxUwggMRAgEB
# MGwwXDELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMjAw
# BgNVBAMTKUdsb2JhbFNpZ24gR0NDIFI0NSBFViBDb2RlU2lnbmluZyBDQSAyMDIw
# AgxK83pmt0FjEC8TCzUwDQYJYIZIAWUDBAIBBQCgfDAQBgorBgEEAYI3AgEMMQIw
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYK
# KwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgSd17vBARnVqZ4qUE5ZzS5flKADQw
# l/nZffTCa5d6UMgwDQYJKoZIhvcNAQEBBQAEggIActhBL9dieM7NwWGLMEyaZIjm
# dH7unltRcmcC+p6oqxA+fUtQ5bQ9aX/ZCXJyzoNMV61jWXlo0lQW49EpOJzCSVWl
# DFeeqpotNeMlnckuA+XWzFOeA/bLwL2H4jsMDP2VmdnRPUZfWInks9jN8xCP4c/2
# Xx33oAjc7XcUtAIoSV4unuovmrNFvJ7jtTKdQxkMh7N2eK048ef1Z4fdHoYK5jeF
# O5UA7PUN8WNy96pxGMPqUx6hfiS2MH81mQeKI4bIhh/69FcWdPMWV3dw7kyvyjHi
# JgMJ6INWKkAEiNo5UTI8/DlT5Kp2FLud8wNZyaWl1F+EbukBzgSOVSgD0zzA6F5N
# Huw+lQk8Y2I0Stpd94N9PLdJVL2d84BCdKT5hqR9YyW9afusfN0Pmi0Zj5YeDxT5
# g++uyP+XqTz0Cib9/0ADJIA0O29+uPY47V8nebruHmIHJr+Zeq67/F2mqKwdNVS8
# gmmYJxeHkavWLHvK1AJfBhIAdNX7iY/xpLgbeI/nCGW9bNwxlVzogiFdztz1o16o
# 9ZaFJ1H/aEFALQqHhMv8SJOc+ICyj+2DnMzUfabDdeJlTifD/cmYumnmgDAnVJ0f
# iiAVMobRY520QPFvXC924HVCvLaIP2Yy+a3QwLYoCNF7fiRY0Kj7gakQZQ+rosky
# wB94GA7rH5x9FDZIFzU=
# SIG # End signature block
