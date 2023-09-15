$ErrorActionPreference = "Stop"
New-Variable -Name NOT_APPLICABLE -Value  "N/A" -Option ReadOnly
New-Variable -Name SUCCESS -Value  "Success" -Option ReadOnly
New-Variable -Name WARNING -Value  "Warning" -Option ReadOnly
New-Variable -Name FAILED -Value  "Failed" -Option ReadOnly
New-Variable -Name ALREADY_EXISTS -Value  "Already Exists" -Option ReadOnly
New-Variable -Name CLOUDM_ADMIN_APP -Value "CloudM Admin App" -Option ReadOnly
New-Variable -Name SITE_PROPERTY_REQUEST -Value "id,webUrl"

$script:distributionGroup = $null
$script:distributionGroupMembers = $null
$script:msGraphContextClientId = $null
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
function GetMailGroup([parameter(mandatory)][String]$mailGroupAlias) {
    $distributionGroup = Get-DistributionGroup -Identity $mailGroupAlias -ErrorAction SilentlyContinue
    if ($distributionGroup) {
        Write-Host "Found Group: " $distributionGroup.PrimarySmtpAddress
        return $distributionGroup;
    }
    else {
        Write-Host "$mailGroupAlias could not befound" 
    }
    return $distributionGroup;
}

function ProcessEmail ([parameter(mandatory)][System.Object]$row, [parameter(mandatory)][String] $mailGroupAlias, $attempt) {
    try {
        Write-Host "Processing Email"
        if ($script:distributionGroup -eq $false -and $attempt -ge 1) {
            Write-Host "$($mailGroupAlias) does not exist" -ForegroundColor Red
            return
        }
        if ($null -eq $script:distributionGroup -and $attempt -eq 0) {
            $script:distributionGroup = GetMailGroup -mailGroupAlias $mailGroupAlias
            if (!$script:distributionGroup) {
                Write-Host "$($mailGroupAlias) does not exist" -ForegroundColor Red
                return
            }
            
            if ($null -eq $script:distributionGroupMembers -and $attempt -eq 0) {
                $script:distributionGroupMembers = Get-DistributionGroupMember -Identity $distributionGroup.Id
            }
    
            Write-Host "Processing : $($distributionGroup.Id)"
        }
        if (!($script:distributionGroupMembers.PrimarySmtpAddress -contains $row.Email)) {
            Add-DistributionGroupMember -Identity $distributionGroup.Id -Member $row.Email -BypassSecurityGroupManagerCheck -ErrorAction Stop
            $row.EmailStatus = $($SUCCESS)
            $row.EmailErrorMessage = $NOT_APPLICABLE
            Write-Host "$($row.Email) added to $($mailGroupAlias). $($SUCCESS)" -ForegroundColor Green
        }
        else {
            Write-Host "$($row.Email) $($ALREADY_EXISTS) in $($mailGroupAlias)" -ForegroundColor Yellow
            $row.EmailStatus = $($ALREADY_EXISTS)
            $row.EmailErrorMessage = $NOT_APPLICABLE
        }
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        $row.EmailStatus = $($FAILED)
        $row.EmailErrorMessage = $_
    }

}

function ProcessMicrosoftTeamGroupSite ([parameter(mandatory)][System.Object]$row) {
    try {
        Write-Host "Processing Microsoft Team/Group"
        $group = {
            Get-MgGroup -Property "Id,resourceProvisioningOptions" -Filter "Mail eq '$($row.Email)'"
        } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgGroup: $($row.Email)"

        $site = {
            Get-MgGroupSite -GroupId $group.Id -SiteId "Root" -Property $SITE_PROPERTY_REQUEST
        } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgGroupSite Root: $($group.Id)"

        $permission = New-MgSitePermission -SiteId $site.Id -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("FullControl"))
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }
        Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
        $isMicrosoftTeam = $false
        if ($group.AdditionalProperties.ContainsKey("resourceProvisioningOptions")) {
            $isMicrosoftTeam = $group.AdditionalProperties["resourceProvisioningOptions"].Contains("Team")
        }
        $success = @("$($site.WebUrl) - ($($site.Id))")
        
        if ($isMicrosoftTeam) {
            Write-Host "Checking for Private Channels"
            $teamChannels = Get-MgTeamChannel -TeamId $group.Id -Filter "MembershipType eq 'private'" -Property "Id" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
            if ((HasError -row $row -ProcessDriveError $ErrorResult -isUser $false)) {
                return
            }
            
            foreach ($channel in $teamChannels) {
                $webUrl = Get-MgTeamChannelFileFolder -TeamId $group.Id -ChannelId $channel.Id -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
                if ($ErrorResult.Count -ge 1) {
                    $privateChannelErrors += $ErrorResult[0].Exception
                    $ErrorResult.Clear()
                    continue
                }
                $webUrl = GetDriveUrl -webUrl $webUrl.WebUrl -strip 2
                $siteId = (Get-MgAllSite -Filter "WebUrl eq '$($webUrl)'" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult).Id 
                if ($ErrorResult.Count -ge 1) {
                    Write-Host "Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)" -ForegroundColor Red
                    $privateChannelErrors += "Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)"
                    $ErrorResult.Clear()
                    continue
                }
                $permission = New-MgSitePermission -SiteId $siteId -ErrorAction SilentlyContinue -ErrorVariable ErrorResult -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("FullControl"))
                if ($ErrorResult.Count -ge 1) {
                    Write-Host "Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)" -ForegroundColor Red
                    $privateChannelErrors += "Channel: $($channel.DisplayName) failed with $($ErrorResult[0].Exception)"
                    $ErrorResult.Clear()
                    continue
                }
                $success += "$($webUrl) - ($($siteId))"
                Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId -siteUrl $webUrl) -ForegroundColor Green
            }
        }
        $row.SiteUrl = ($success | Out-String)
        if ($privateChannelErrors.Count -ge 1) {
            $row.SiteStatus = $($WARNING)
            $row.SiteErrorMessage = ($privateChannelErrors | Out-String)
        }
        else {
            $row.SiteStatus = $($SUCCESS)
            $row.SiteErrorMessage = $NOT_APPLICABLE
        }
        
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        $row.EmailStatus = $($FAILED)
        $row.EmailErrorMessage = $_
    }
    
}

function ProcessDrive ([parameter(mandatory)][System.Object]$row, [parameter(mandatory)][String]$clientAppId) {

    Write-Host "Processing Drive"
    $driveUrl = $null
    try {
        $drive = Get-MgUserDefaultDrive -UserId $row.Email -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }
        $driveUrl = (GetDriveUrl -webUrl $drive.WebUrl -strip 1)

        $siteId = (Get-MgAllSite -Filter "WebUrl eq '$($driveUrl)'").Id

        $permission = New-MgSitePermission -SiteId $siteId -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("FullControl"))
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError -isUser $true)) {
            return
        }
        
        $row.DriveUrl = "$($driveUrl) - ($($siteId ))"
        $row.DriveStatus = $($SUCCESS)
        $row.DriveErrorMessage = $NOT_APPLICABLE
        Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId -siteUrl $driveUrl) -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        if ([String]::IsNullOrEmpty($driveUrl) -or [String]::IsNullOrWhitespace($driveUrl) ) {
            $row.DriveUrl = $NOT_APPLICABLE
        }
        else {
            $row.DriveUrl = $driveUrl
        }
        $row.DriveStatus = $($FAILED)
        $row.DriveErrorMessage = $_
    }
}

function ProcessSharePointSite ([parameter(mandatory)][System.Object]$row, [parameter(mandatory)][String]$clientAppId) {

    Write-Host "Processing SharePoint Site"
    try {
        $site = Get-MgAllSite -Filter "WebUrl eq '$($row.SiteUrl)'" -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }

        $permission = New-MgSitePermission -SiteId $site.Id -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("FullControl"))
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError -isUser $false)) {
            return
        }
        
        $row.SiteId = "($($site.Id)"
        $row.SiteStatus = $($SUCCESS)
        $row.SiteErrorMessage = $NOT_APPLICABLE
        Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        $row.SiteStatus = $($FAILED)
        $row.SiteErrorMessage = $_
    }
}

function HasError ([parameter(mandatory)][System.Object]$row, [parameter(mandatory)][System.Object]$ProcessDriveError, [bool]$isUser) {
    if ($ProcessDriveError.Count -ge 1) {
        if ($isUser) {
            Write-Host "Failed to add $($row.Email). The message was: $($ProcessDriveError[0].Exception)" -ForegroundColor Red
            $row.DriveStatus = $($FAILED)
            $row.DriveErrorMessage = $ProcessDriveError[0].Exception
        }
        else {
            Write-Host "Failed to add $($row.SiteUrl). The message was: $($ProcessDriveError[0].Exception)" -ForegroundColor Red
            $row.SiteStatus = $($FAILED)
            $row.SiteErrorMessage = $ProcessDriveError[0].Exception
        }
        $ProcessDriveError.Clear()
        return $true
    }
    return $false
}

function BuildPermission([parameter(mandatory)][String]$applicationId, [parameter(mandatory)][String]$applicationDisplayName, [parameter(mandatory)][string[]]$roles) {
    $params = @{
        roles               = $roles
        grantedToIdentities = @(
            @{
                application = @{
                    id          = $applicationId
                    displayName = $applicationDisplayName
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

function ProcessRootSite() {
    $site = {
        Get-MgSite -SiteId "Root" -Property $SITE_PROPERTY_REQUEST -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgSite Root"
    
    $permission = {
        New-MgSitePermission -SiteId $site.Id -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("Read")) -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "New-MgSitePermission: $($site.Id)"
    Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
    return [Microsoft.Graph.PowerShell.Models.IMicrosoftGraphSite]$site
}

function ProcessMySite([parameter(mandatory)][Microsoft.Graph.PowerShell.Models.IMicrosoftGraphSite]$site) {
    $siteId = GetMySiteHost -id $site.Id
    $site = { 
        Get-MgSite -SiteId $siteId -Property $SITE_PROPERTY_REQUEST -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get-MgSite: $($siteId)"
        
    $permission = {
        New-MgSitePermission -SiteId $site.Id -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("Read")) -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "New-MgSitePermission: $($site.Id)"
    Write-Host (BuildPermissionMessage -permission $permission -siteId $site.Id -siteUrl $site.WebUrl) -ForegroundColor Green
}

function GetMySiteHost([parameter(mandatory)][String]$id) {
    $index = $id.IndexOf(',') 
    $mySiteHost = $null
    if ($index -ne -1) {
        $mySiteHost = $id.Substring(0, $index)
        $index = $mySiteHost.IndexOf('.')
        if ($index -ne -1) {
            $mySiteHost = $mySiteHost.Insert($index, "-my")
        }
    
    }
    return $mySiteHost
}

function CreateUpdateApplicationAccessPolicy([parameter(mandatory)][String]$appId, [parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$certPath, [parameter(mandatory)][String]$tenantName, [parameter(mandatory)][String]$mailGroupAlias) {
    $appPolicies = { 
        Get-ApplicationAccessPolicy -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
        CheckErrors -ErrorToProcess $ErrorResult 
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Get Application Access Policy" -OnFinalExceptionContinue
    
    if ($appPolicies) {
        foreach ($policie in $appPolicies) {
            if ($policie.AppId -eq $appId) {
                Write-Host "Access Policy already exists for: $appId" -ForegroundColor Yellow 
                return $policie
            }
        }
    }
    
    Write-Host "Creating Policy for: $mailGroupAlias"
    $policy = { 
        New-ApplicationAccessPolicy -AppId $appId -PolicyScopeGroupId $mailGroupAlias -AccessRight RestrictAccess  -Description “Restricted policy for App $appName ($appId)" -ErrorAction SilentlyContinue -ErrorVariable ErrorResult 
        CheckErrors -ErrorToProcess $ErrorResult
    } | RetryCommand -TimeoutInSeconds 2 -RetryCount 10 -Context "Create Application Access Policy"
    Write-Host "Created Policy for: $mailGroupAlias with Id: $($policy.Id)" -ForegroundColor Green
    
    return $policy
}

function ApplyLimitedMailPolicy([parameter(mandatory)][String]$appId, [parameter(mandatory)][String]$appName, [parameter(mandatory)][String]$certPath, [parameter(mandatory)][String]$tenantName, [parameter(mandatory)][String]$mailGroupAlias, [SecureString]$secureCertificatePassword) {
    ConnectExchangeOnline -appId $appId -certPath $certPath -secureCertificatePassword $secureCertificatePassword -tenantName $tenantName
    $distributionGroup = GetCreateMailGroup -mailGroupAlias $mailGroupAlias
    $policy = CreateUpdateApplicationAccessPolicy -appId $appId -appName $appName -certPath $certPath -tenantName $tenantName -mailGroupAlias $distributionGroup.PrimarySmtpAddress
    return $policy
}

function GetCreateMailGroup([parameter(mandatory)][String]$mailGroupAlias) {
    $distributionGroup = Get-DistributionGroup -Identity $mailGroupAlias -ErrorAction SilentlyContinue
    if ($distributionGroup) {
        Write-Host "$($distributionGroup.PrimarySmtpAddress) already exists." -ForegroundColor Yellow
    }
    else {
        Write-Host "Creating Distribution Group: $($mailGroupAlias)"
        $distributionGroup = New-DistributionGroup -Name $mailGroupAlias -Alias $mailGroupAlias  -Type security -Description “Restricted group for App $appName ($appId)"
        Write-Host "Created Distribution Group: $($mailGroupAlias)" -ForegroundColor Green
    }
    return $distributionGroup;
}

function ProcessEmailDriveCsv ([parameter(mandatory)][String]$workFolder, [parameter(mandatory)][String]$mailGroupAlias, [parameter(mandatory)][String]$adminAppClientId, [parameter(mandatory)][String]$tenantId, [parameter(mandatory)][String]$adminAppCertificate, [parameter(mandatory)][String]$clientAppId, [SecureString] $secureCertificatePassword, [System.Management.Automation.SwitchParameter]$disconnectSesstion) {
    try {
        $file = Join-Path -Path $workFolder -ChildPath "EmailDrive.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }   
        $nl = [Environment]::NewLine
        ConnectMsGraph -adminAppClientId $adminAppClientId -adminAppCertificate $adminAppCertificate -secureCertificatePassword $secureCertificatePassword -tenantId $tenantId
        $csv = Import-Csv $file
        $initEmailCounter = 0
        $site = ProcessRootSite
        ProcessMySite -site $site
        Write-Host "$($nl)$($nl)--------------------------------Processing EmailDrive.csv-----------------------------------------"
        foreach ($row in $csv) {
            $row | Add-Member -NotePropertyName "EmailStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "EmailErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "DriveUrl" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "DriveStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "DriveErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $itemType = [ItemType]$row.ItemType
            Write-Host "$($nl)$($nl)--------------------------------Processing $($row.Email) Starting-----------------------------------------"
            switch ($itemType) {
                Drive {
                    ProcessDrive -row $row -clientAppId  $clientAppId
                    break
                }
                EMail {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $initEmailCounter
                    $initEmailCounter++
                    break
                }
                EmailDrive {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $initEmailCounter
                    $initEmailCounter++
                    ProcessDrive -row $row -clientAppId  $clientAppId
                    break
                }
                default {
                    Write-Host "Unknown ItemType: $_" -ForegroundColor Yellow
                }
            }
            Write-Host "--------------------------------Processing $($row.Email) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($disconnectSesstion) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph $($CLOUDM_ADMIN_APP)"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessMicrosoftTeamGroupCsv ([parameter(mandatory)][String]$workFolder, [parameter(mandatory)][String]$mailGroupAlias, [parameter(mandatory)][String]$adminAppClientId, [parameter(mandatory)][String]$tenantId, [parameter(mandatory)][String]$adminAppCertificate, [parameter(mandatory)][String]$clientAppId, [SecureString] $secureCertificatePassword, [System.Management.Automation.SwitchParameter]$disconnectSesstion) {
    try {
        $file = Join-Path -Path $workFolder -ChildPath "MicrosoftTeamGroup.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }
        $initEmailCounter = 0   
        $nl = [Environment]::NewLine
        ConnectMsGraph -adminAppClientId $adminAppClientId -adminAppCertificate $adminAppCertificate -secureCertificatePassword $secureCertificatePassword -tenantId $tenantId
        $csv = Import-Csv $file
        Write-Host "$($nl)$($nl)--------------------------------Processing MicrosoftTeamGroup.csv-----------------------------------------"
        foreach ($row in $csv) {
            Write-Host "$($nl)$($nl)--------------------------------Processing $($row.Email) Starting-----------------------------------------"
            $row | Add-Member -NotePropertyName "EmailStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "EmailErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "SiteUrl" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "SiteStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "SiteErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $microsoftTeamGroupItemType = [MicrosoftTeamGroupItemType]$row.MicrosoftTeamGroupItemType
            switch ($microsoftTeamGroupItemType) {
                Site {
                    ProcessMicrosoftTeamGroupSite -row $row
                    break
                }
                EMail {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $initEmailCounter
                    $initEmailCounter++
                    break
                }
                EmailSite {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $initEmailCounter
                    $initEmailCounter++
                    ProcessMicrosoftTeamGroupSite -row $row
                    break
                }
                default {
                    Write-Host "Unknown ItemType: $_" -ForegroundColor Yellow
                }
            }
            Write-Host "--------------------------------Processing $($row.Email) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($disconnectSesstion) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph $($CLOUDM_ADMIN_APP)"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessSharePointSiteCsv ([parameter(mandatory)][String]$workFolder, [parameter(mandatory)][String]$adminAppClientId, [parameter(mandatory)][String]$tenantId, [parameter(mandatory)][String]$adminAppCertificate, [parameter(mandatory)][String]$clientAppId, [SecureString] $secureCertificatePassword, [System.Management.Automation.SwitchParameter]$disconnectSesstion) {
    try {
        $file = Join-Path -Path $workFolder -ChildPath "SharePointSites.csv" 
        if (!(Test-Path -Path $file -PathType Leaf)) {
            Write-Host "File: $($file) could not be found. Exiting Process Csv" -ForegroundColor Yellow
            return;
        }   
        $nl = [Environment]::NewLine
        ConnectMsGraph -adminAppClientId $adminAppClientId -adminAppCertificate $adminAppCertificate -secureCertificatePassword $secureCertificatePassword -tenantId $tenantId
        $csv = Import-Csv $file
        Write-Host "$($nl)$($nl)--------------------------------Processing SharePointSites.csv-----------------------------------------"
        foreach ($row in $csv) {
            $row | Add-Member -NotePropertyName "SiteId" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "SiteStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "SiteErrorMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            Write-Host "$($nl)$($nl)--------------------------------Processing $($row.SiteUrl) Starting-----------------------------------------"
            ProcessSharePointSite -row $row -clientAppId $clientAppId
            Write-Host "--------------------------------Processing $($row.SiteUrl) Completed-----------------------------------------"
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        if ($disconnectSesstion) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-MgGraph $($CLOUDM_ADMIN_APP)"
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Host "Disconnect-ExchangeOnline"
        }
    }
}

function ProcessCsv([parameter(mandatory)][String]$workFolder, [parameter(mandatory)][String]$mailGroupAlias, [parameter(mandatory)][String]$adminAppClientId, [parameter(mandatory)][String]$tenantId, [parameter(mandatory)][String]$adminAppCertificate, [parameter(mandatory)][String]$clientAppId, [SecureString] $secureCertificatePassword) {
    try {
        #ProcessEmailDriveCsv -workFolder $workFolder -secureCertificatePassword $secureCertificatePassword -mailGroupAlias $mailGroupAlias -adminAppClientId $adminAppClientId -tenantId $tenantId -adminAppCertificate $adminAppCertificate -clientAppId $clientAppId
        #ProcessSharePointSiteCsv -workFolder $workFolder -secureCertificatePassword $secureCertificatePassword -adminAppClientId $adminAppClientId -tenantId $tenantId -adminAppCertificate $adminAppCertificate -clientAppId $clientAppId
        ProcessMicrosoftTeamGroupCsv -workFolder $workFolder -secureCertificatePassword $secureCertificatePassword -mailGroupAlias $mailGroupAlias -adminAppClientId $adminAppClientId -tenantId $tenantId -adminAppCertificate $adminAppCertificate -clientAppId $clientAppId
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-MgGraph $($CLOUDM_ADMIN_APP)"
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-ExchangeOnline"
    }
}

function ConnectMsGraph ([parameter(mandatory)][String]$adminAppClientId, [parameter(mandatory)][String]$tenantId, [parameter(mandatory)][String]$adminAppCertificate, [SecureString]$secureCertificatePassword) {
    if ($script:msGraphContextClientId -ne $adminAppClientId) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($adminAppCertificate, $secureCertificatePassword)
        {
            Connect-MgGraph -ClientId $adminAppClientId -TenantId $tenantId -Certificate $cert -NoWelcome -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
            CheckErrors -ErrorToProcess $ErrorResult
            $script:msGraphContextClientId = (Get-MgContext -ErrorAction SilentlyContinue).ClientId
        } | RetryCommand -TimeoutInSeconds 10 -RetryCount 10 -Context "Connect to MgGraph: $($CLOUDM_ADMIN_APP)"
        Start-Sleep -Seconds 10
    }
}
function ConnectExchangeOnline([parameter(mandatory)][String]$appId, [parameter(mandatory)][String]$certPath, [SecureString] $secureCertificatePassword, $tenantName) {
    if ($script:msExchangeOnlineAppId -ne $appId) {
        {
            Connect-ExchangeOnline -CertificateFilePath $certPath -CertificatePassword $secureCertificatePassword -AppId $appId  -Organization $tenantName -ShowBanner:$false -ErrorAction SilentlyContinue -ErrorVariable ErrorResult
            CheckErrors -ErrorToProcess $ErrorResult
            $script:msExchangeOnlineAppId = (Get-ConnectionInformation -ErrorAction SilentlyContinue).AppId
        } | RetryCommand -TimeoutInSeconds 5 -RetryCount 10 -Context "Connect to Exchange Online"
    }
}
Export-ModuleMember -Function ProcessSharePointSiteCsv
Export-ModuleMember -Function ProcessMicrosoftTeamGroupCsv
Export-ModuleMember -Function ProcessEmailDriveCsv
Export-ModuleMember -Function ProcessCsv
Export-ModuleMember -Function ApplyLimitedMailPolicy
