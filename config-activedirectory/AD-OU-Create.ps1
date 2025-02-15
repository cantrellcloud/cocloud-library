#-------------------------------------------------
#   AD Variables
#-------------------------------------------------
 
# Import prep settings from config file
[xml]$ConfigFile = Get-Content .\AD-OU-Create.xml

$DomainId = $ConfigFile.Settings.appSettings.DomainId
#$user = $ConfigFile.Settings.appSettings.user
$OUGroup = "_" + $ConfigFile.Settings.appSettings.OUGroup
$OUSubGroup1 = $ConfigFile.Settings.appSettings.OUSubGroup1
	$OUSubGroup11 = $ConfigFile.Settings.appSettings.OUSubGroup11
	$OUSubGroup12 = $ConfigFile.Settings.appSettings.OUSubGroup12

$OUSubGroup2 = $ConfigFile.Settings.appSettings.OUSubGroup2
	$OUSubGroup21 = $ConfigFile.Settings.appSettings.OUSubGroup21
	$OUSubGroup22 = $ConfigFile.Settings.appSettings.OUSubGroup22
	$OUSubGroup23 = $ConfigFile.Settings.appSettings.OUSubGroup23
		$OUSubGroup231 = $ConfigFile.Settings.appSettings.OUSubGroup231
		$OUSubGroup232 = $ConfigFile.Settings.appSettings.OUSubGroup232
			$OUSubGroup2321 = $ConfigFile.Settings.appSettings.OUSubGroup2321

$OUSubGroup3 = $ConfigFile.Settings.appSettings.OUSubGroup3
	$OUSubGroup31 = $ConfigFile.Settings.appSettings.OUSubGroup31
	$OUSubGroup32 = $ConfigFile.Settings.appSettings.OUSubGroup32
	$OUSubGroup33 = $ConfigFile.Settings.appSettings.OUSubGroup33
	$OUSubGroup34 = $ConfigFile.Settings.appSettings.OUSubGroup34
	$OUSubGroup35 = $ConfigFile.Settings.appSettings.OUSubGroup35

  
#-------------------------------------------------
#   Add user to Domain Admin Group
#-------------------------------------------------
# Add-ADGroupMember -Identity "Domain Admins" -Members $user

#-------------------------------------------------
#   Create AD Groups
#-------------------------------------------------
New-ADOrganizationalUnit -Name "$OUGroup" -Path "DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup1" -Path "OU=$OUGROUP,DC=$DomainId,DC=com"
    New-ADOrganizationalUnit -Name "$OUSubGroup11" -Path "OU=$OUSubGroup1,OU=$OUGROUP,DC=$DomainId,DC=com"
    New-ADOrganizationalUnit -Name "$OUSubGroup12" -Path "OU=$OUSubGroup1,OU=$OUGROUP,DC=$DomainId,DC=com"

New-ADOrganizationalUnit -Name "$OUSubGroup2" -Path "OU=$OUGROUP,DC=$DomainId,DC=com"
    New-ADOrganizationalUnit -Name "$OUSubGroup21" -Path "OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"
    New-ADOrganizationalUnit -Name "$OUSubGroup22" -Path "OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"
    New-ADOrganizationalUnit -Name "$OUSubGroup23" -Path "OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"
        New-ADOrganizationalUnit -Name "$OUSubGroup231" -Path "OU=$OUSubGroup23,OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"
        New-ADOrganizationalUnit -Name "$OUSubGroup232" -Path "OU=$OUSubGroup23,OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"
            New-ADOrganizationalUnit -Name "$OUSubGroup2321" -Path "OU=$OUSubGroup232,OU=$OUSubGroup23,OU=$OUSubGroup2,OU=$OUGROUP,DC=$DomainId,DC=com"

New-ADOrganizationalUnit -Name "$OUSubGroup3" -Path "OU=$OUGROUP,DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup31" -Path "OU=$OUSubGroup3,OU=$OUGROUP,DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup32" -Path "OU=$OUSubGroup3,OU=$OUGROUP,DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup33" -Path "OU=$OUSubGroup3,OU=$OUGROUP,DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup34" -Path "OU=$OUSubGroup3,OU=$OUGROUP,DC=$DomainId,DC=com"
New-ADOrganizationalUnit -Name "$OUSubGroup35" -Path "OU=$OUSubGroup3,OU=$OUGROUP,DC=$DomainId,DC=com"