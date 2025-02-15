# Install AAD Application Proxy Connector
N:\Software\AADApplicationProxyConnectorInstaller.exe REGISTERCONNECTOR=”false” /q

# Register Azure AD App Proxy Connector
# PS! Using Credential Object cannot be used with MFA enabled administrator accounts, use offline token

$User = "azureadmin@cohome.onmicrosoft.com"
$PlainPassword = 'xwYD&x#CCDd4U*9cdxv2'
$TenantId = 'cd478b7f-db36-4f0a-8ca8-c68082242690'
$SecurePassword = $PlainPassword | ConvertTo-SecureString –AsPlainText –Force
$cred = New-Object –TypeName System.Management.Automation.PSCredential –ArgumentList $User, $SecurePassword
Set-Location "C:\Program Files\Microsoft AAD App Proxy Connector"
.\RegisterConnector.ps1 `
   -modulePath "C:\Program Files\Microsoft AAD App Proxy Connector\Modules\" `
   -moduleName "AppProxyPSModule" `
   -Authenticationmode Credentials `
   -Usercredentials $cred `
   -Feature ApplicationProxy `
   -TenantId $TenantId