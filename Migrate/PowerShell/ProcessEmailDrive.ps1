param ($certFolder, $mailGroupAlias, $adminAppClientId, $tenantId, $adminAppCertificate, $clientAppId)
New-Variable -Name NOT_APPLICABLE -Value  "N/A" -Option ReadOnly
New-Variable -Name SUCCESS -Value  "Success" -Option ReadOnly
New-Variable -Name FAILED -Value  "Failed" -Option ReadOnly
New-Variable -Name ALREADY_EXISTS -Value  "Already Exists" -Option ReadOnly
New-Variable -Name CLOUDM_ADMIN_APP -Value "CloudM Admin App" -Option ReadOnly


$script:distributionGroup = $null
$script:distributionGroupMembers = $null
enum ItemType {
    Drive
    Email
    EmailDrive
}
function GetMailGroup($mailGroupAlias) {
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

function ProcessEmail ($row, $mailGroupAlias, $attempt) {
    Write-Host "Processing Email : $($row.Email)"
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
        
    try {
        if (!($script:distributionGroupMembers.PrimarySmtpAddress -contains $row.Email)) {
            Add-DistributionGroupMember -Identity $distributionGroup.Id -Member $row.Email -BypassSecurityGroupManagerCheck -ErrorAction Stop
            $row.EmailStatus = $($SUCCESS)
            $row.EmailMessage = ""
            Write-Host "$($row.Email) added to $($mailGroupAlias). $($SUCCESS)" -ForegroundColor Green
        }
        else {
            Write-Host "$($row.Email) $($ALREADY_EXISTS) in $($mailGroupAlias)" -ForegroundColor Yellow
            $row.EmailStatus = $($ALREADY_EXISTS)
            $row.EmailMessage = ""
        }
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        $row.EmailStatus = $($FAILED)
        $row.EmailMessage = $_
    }

}

function ProcessDrive ($row, $clientAppId, $adminCentreConnection, $sharePointConnection) {
    Write-Host "Processing Drive : $($row.Email)"
    try {
        $siteId = (Get-MgUserDefaultDrive -UserId $row.Email -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError).Id
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError)) {
            return
        }
        $permission = New-MgSitePermission -SiteId $siteId -ErrorAction SilentlyContinue -ErrorVariable ProcessDriveError -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("FullControl"))
        if ((HasError -row $row -ProcessDriveError $ProcessDriveError)) {
            return
        }

        Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId) -ForegroundColor Green
        $row.DriveStatus = $($SUCCESS)
        $row.DriveMessage = $message
        Write-Host "$($message). $($SUCCESS)" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to add $($row.Email). The message was: $($_)" -ForegroundColor Red
        $row.DriveStatus = $($FAILED)
        $row.DriveMessage = $_
    }
}

function HasError ($row, $ProcessDriveError) {
    if ($ProcessDriveError.Count -ge 1) {
        Write-Host "Failed to add $($row.Email). The message was: $($ProcessDriveError[0].Exception)" -ForegroundColor Red
        $row.DriveStatus = $($FAILED)
        $row.DriveMessage = $ProcessDriveError[0].Exception
        #$ProcessDriveError
        $ProcessDriveError.Clear()
        return $true
    }
    return $false
}

function BuildPermission($applicationId, $applicationDisplayName, $roles) {
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

function BuildPermissionMessage ($permission, $siteId) {
    return "Site Id: $($siteId), Permission Id: $($permission.Id), Roles: $($permission.Roles)"
}

function ProcessCsv ($certFolder, $mailGroupAlias, $attempt, $adminAppClientId, $tenantId, $adminAppCertificate, $clientAppId) {
    try {
        $file = Join-Path -Path $certFolder -ChildPath "Emails.csv"    
        $csv = Import-Csv $file
        $counter = 0
        Write-Host "Waiting..."
        Start-Sleep -Seconds 30
        Connect-MgGraph -ClientId $adminAppClientId -TenantId $tenantId -Certificate $adminAppCertificate -NoWelcome
        $siteId = (Get-MgSite -SiteId "Root").Id
        $permission = New-MgSitePermission -SiteId $siteId -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("Read"))
        Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId) -ForegroundColor Green
        $siteId = GetMySiteHost -id $siteId
        $permission = New-MgSitePermission -SiteId $siteId -BodyParameter (BuildPermission -applicationId $clientAppId -applicationDisplayName $CLOUDM_ADMIN_APP -roles @("Read"))
        Write-Host (BuildPermissionMessage -permission $permission -siteId $siteId) -ForegroundColor Green

        

        foreach ($row in $csv) {
            $row | Add-Member -NotePropertyName "EmailStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "EmailMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "DriveStatus" -NotePropertyValue $NOT_APPLICABLE -Force
            $row | Add-Member -NotePropertyName "DriveMessage" -NotePropertyValue $NOT_APPLICABLE -Force
            $itemType = [ItemType]$row.ItemType
            switch ($itemType) {
                Drive {
                    ProcessDrive -row $row -clientAppId  $clientAppId -adminCentreConnection $adminCentreConnection -sharePointConnection $sharePointConnection
                    break
                }
                EMail {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $counter
                    break
                }
                EmailDrive {
                    ProcessEmail -row $row -mailGroupAlias $mailGroupAlias -attempt $counter
                    ProcessDrive -row $row -clientAppId  $clientAppId -adminCentreConnection $adminCentreConnection -sharePointConnection $sharePointConnection
                    break
                }
                default {
                    Write-Host "Unknown ItemType: $_" -ForegroundColor Yellow
                }
            }
            $counter++
        }
        $csv | Export-Csv $file -NoType
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Disconnect-MgGraph $($CLOUDM_ADMIN_APP)"
    }
}

function GetMySiteHost($id){
    $index = $id.IndexOf(',') 
    $test = $null
    if($index -ne -1){
    
     $test = $id.Substring(0, $index)
     $index = $test.IndexOf('.')
     if($index -ne -1){
     $test = $test.Insert($index, "-my")
     }
    
    }
    Write-Host $test
    return $test
    }
ProcessCsv -certFolder $certFolder -mailGroupAlias $mailGroupAlias -attempt 0 -adminAppClientId $adminAppClientId -tenantId $tenantId -adminAppCertificate $adminAppCertificate -clientAppId $clientAppId
    
  
        
    
    



