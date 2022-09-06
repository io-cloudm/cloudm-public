##Logging

$loglocataion = Read-Host "Please enter a file location to output transcript of Domain removal script (Full File Path)"
Start-Transcript -Path $loglocataion -Append

#Get values for input parameters

$olddomain =”soucedomainname.com” 
$Newdomain="tennant.onmicrosoft.com" 

#Connect to MsolService 
Import-Module MsOnline 
$credential = get-credential 
Connect-MsolService -Credential $credential 
Write-Host "Connected to Office 365" -ForegroundColor Green
#Connect to Exchange Online: 
$ExchangeSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "https://outlook.office365.com/powershell-liveid/" -Credential $credential -Authentication "Basic" –AllowRedirection 
Import-PSSession $ExchangeSession 
Write-Host "Connected to Exvhange" -ForegroundColor Green
Write-Host "Starting O365 User UPN Switch" -ForegroundColor yellow
$users=Get-MsolUser -domain $olddomain 
$users | Foreach-Object{ 
    $user=$_ 
    $UserName =($user.UserPrincipalName -split "@")[0] 
    $UPN= $UserName+"@"+ $Newdomain 
    Set-MsolUserPrincipalName -UserPrincipalName $user.UserPrincipalName -NewUserPrincipalName $UPN -Verbose
}
write-Host "Change the UserPrincipalName for all Office 365 users is completed" 

#Connect to Exchange Online: 
$ExchangeSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "https://outlook.office365.com/powershell-liveid/" -Credential $credential -Authentication "Basic" –AllowRedirection 
Import-PSSession $ExchangeSession 
Write-Host "Starting Exchange Mailbox UPN Switch" -ForegroundColor yellow
#Change Email Addresses for all Office 365 Mailboxes 
$Users=Get-Mailbox 
$Users | Foreach-Object{ 
    $user=$_ 
    $UserName =($user.PrimarySmtpAddress -split "@")[0] 
    $SMTP ="SMTP:"+ $UserName +"@"+$Newdomain 
    $Emailaddress=$UserName+"@"+$Newdomain 
    $user | Set-Mailbox -EmailAddresses $SMTP -WindowsEmailAddress $Emailaddress -MicrosoftOnlineServicesID $Emailaddress -Verbose 
} 
write-Host "Change mail Addresses for all Office 365 Mailboxes is completed" -ForegroundColor Green 
Write-Host "Starting Exchange Group UPN Switch" -ForegroundColor yellow
#Change Email Addresses for all Groups 
$Groups=Get-DistributionGroup 
$Groups | Foreach-Object{ 
    $group=$_ 
    $groupname =($group.PrimarySmtpAddress -split "@")[0] 
    $SMTP ="SMTP:"+$groupname+"@"+$Newdomain 
    $Emailaddress=$groupname+"@"+$Newdomain 
    $group |Set-DistributionGroup -EmailAddresses $SMTP -WindowsEmailAddress $Emailaddress -MicrosoftOnlineServicesID $Emailaddress -Verbose
} 
Write-Host "Starting Exchange Dynamic Group UPN Switch" -ForegroundColor yellow
$Groups=Get-DynamicDistributionGroup 
$Groups | Foreach-Object{ 
    $group=$_ 
    $groupname =($group.PrimarySmtpAddress -split "@")[0] 
    $SMTP ="SMTP:"+$groupname+"@"+$Newdomain 
    $Emailaddress=$groupname+"@"+$Newdomain 
    $group |Set-DynamicDistributionGroup -EmailAddresses $SMTP -WindowsEmailAddress $Emailaddress -MicrosoftOnlineServicesID $Emailaddress -Verbose
} 
Write-Host "Starting O365 Group Switch" -ForegroundColor yellow
$Groups=Get-UnifiedGroup 
$Groups | Foreach-Object{ 
    $group=$_ 
    $groupname =($group.PrimarySmtpAddress -split "@")[0] 
    $SMTP ="SMTP:"+$groupname+"@"+$Newdomain 
    $Emailaddress=$groupname+"@"+$Newdomain 
    $group |Set-UnifiedGroup -EmailAddresses $SMTP -WindowsEmailAddress $Emailaddress -MicrosoftOnlineServicesID $Emailaddress -Verbose
} 
write-Host "Change Email Addresses for all Groups is completed" -ForegroundColor Green
Write-Host "Removing O365 Domain $($olddomain)" -ForegroundColor Red
#Remove the old Office 365 domain 
Remove-MsolDomain -DomainName $olddomain 

write-Host "Old Office 365 domain Successfuly removed" -ForegroundColor Green

Stop-Transcript