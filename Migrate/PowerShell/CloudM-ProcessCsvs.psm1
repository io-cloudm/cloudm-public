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
# MIIYJAYJKoZIhvcNAQcCoIIYFTCCGBECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCrGUZ6P51vTTpJ
# 4fCPPX5AZ4RdRnzFXqN8ip8/CKEGgqCCFGUwggWiMIIEiqADAgECAhB4AxhCRXCK
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
# BDEiBCBJ3Xu8EBGdWpnipQTlnNLl+UoANDCX+dl99MJrl3pQyDANBgkqhkiG9w0B
# AQEFAASCAgBy2EEv12J4zs3BYYswTJpkiOZ0fu6eW1FyZwL6nqirED59S1DltD1p
# f9kJcnLOg0xXrWNZeWjSVBbj0Sk4nMJJVaUMV56qmi014yWdyS4D5dbMU54D9svA
# vYfiOwwM/ZWZ2dE9Rl9YieSz2M3zEI/hz/ZfHfegCNztdxS0AihJXi6e6i+as0W8
# nuO1Mp1DGQyHs3Z4rTjx5/Vnh90ehgrmN4U7lQDs9Q3xY3L3qnEYw+pTHqF+JLYw
# fzWZB4ojhsiGH/r0VxZ08xZXd3DuTK/KMeImAwnog1YqQASI2jlRMjz8OVPkqnYU
# u53zA1nJpaXUX4Ru6QHOBI5VKAPTPMDoXk0e7D6VCTxjYjRK2l33g308t0lUvZ3z
# gEJ0pPmGpH1jJb1p+6x83Q+aLRmPlh4PFPmD767I/5epPPQKJv3/QAMkgDQ7b364
# 9jjtXyd5uu4eYgcmv5l6rrv8XaaorB01VLyCaZgnF4eRq9Yse8rUAl8GEgB01fuJ
# j/GkuBt4j+cIZb1s3DGVXOiCIV3O3PWjXqj1loUnUf9oQUAtCoeEy/xIk5z4gLKP
# 7YOczNR9psN14mVOJ8P9yZi6aeaAMCdUnR+KIBUyhtFjnbRA8W9cL3bgdUK8tog/
# ZjL5rdDAtigI0Xt+JFjQqPuBqRBlD6uiyTLAH3gYDusfnH0UNkgXNQ==
# SIG # End signature block
