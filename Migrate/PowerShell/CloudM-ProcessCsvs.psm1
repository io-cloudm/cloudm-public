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

function ProcessMicrosoftTeamGroupSite ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId, [parameter(mandatory)][String]$TenantHost) {
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
                $sitePath = $webUrl.Replace("https://$($TenantHost)", "")
                $siteId = (Invoke-MgGraphRequest -Uri "v1.0/sites/$($TenantHost):$($sitePath)" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult).Id
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

function ProcessDrive ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId, [parameter(mandatory)][String]$TenantHost) {

    Write-Host "Processing Drive"
    $driveUrl = $null
    try {
        $drive = Get-MgUserDefaultDrive -UserId $Row.Email -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
        if ((HasError -Row $Row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }
        $driveUrl = (GetDriveUrl -webUrl $drive.WebUrl -strip 1)

        
        $modifiedUrl = $driveUrl -replace '^.*/personal', '/personal'
        $siteId = (Invoke-MgGraphRequest -Uri "v1.0/sites/$($TenantHost):$($modifiedUrl)" -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError).Id
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

function ProcessSharePointSite ([parameter(mandatory)][System.Object]$Row, [parameter(mandatory)][String]$ClientAppId, [parameter(mandatory)][String]$TenantHost) {

    Write-Host "Processing SharePoint Site"
    try {
        $sitePath = $Row.SiteUrl.Replace("https://$($TenantHost)", "")
        $site = Invoke-MgGraphRequest -Uri "v1.0/sites/$($TenantHost):$($sitePath)" -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
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

function GetRootSiteId() {
    $siteId = {
        (Get-MgSite -SiteId "Root" -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ErrorResult).Id
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgSite Root"
  
    return $siteId
}

function GetHost([parameter(mandatory)][String]$id, [string]$insertUrl) {
    $index = $id.IndexOf(',') 
    $mySiteHost = $null
    if ($index -ne -1) {
        $mySiteHost = $id.Substring(0, $index)
        $index = $mySiteHost.IndexOf('.')
        if ($index -ne -1) {
            $mySiteHost = $mySiteHost.Insert($index, $insertUrl)
        }
    }
    return $mySiteHost
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
        New-ApplicationAccessPolicy -AppId $AppId -PolicyScopeGroupId $MailGroupAlias -AccessRight RestrictAccess -Description “Restricted policy for App $AppName ($AppId)" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult 
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
        $siteId = GetRootSiteId 
        $tenantHost = GetHost -id $siteId -insertUrl "-my"
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
                    ProcessDrive -Row $Row -ClientAppId $ClientAppId  -TenantHost $tenantHost
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
                    ProcessDrive -Row $Row -ClientAppId $ClientAppId  -TenantHost $tenantHost
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
        $siteId = GetRootSiteId 
        $tenantHost = GetHost -id $siteId -insertUrl ""
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
                    ProcessMicrosoftTeamGroupSite -Row $Row  -ClientAppId $ClientAppId -TenantHost $tenantHost
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
                    ProcessMicrosoftTeamGroupSite -Row $Row  -ClientAppId $ClientAppId -TenantHost $tenantHost
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
        $siteId = GetRootSiteId 
        $tenantHost = GetHost -id $siteId -insertUrl ""
        $csv = Import-Csv $file
        Write-Host "$($nl)$($nl)--------------------------------Processing SharePointSites.csv-----------------------------------------"
        foreach ($Row in $csv) {
            $Row | Add-Member -NotePropertyName "SiteId" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $Row | Add-Member -NotePropertyName "SiteErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            Write-Host "$($nl)$($nl)--------------------------------Processing $($Row.SiteUrl) Starting-----------------------------------------"
            ProcessSharePointSite -Row $Row -ClientAppId $ClientAppId  -TenantHost $tenantHost
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