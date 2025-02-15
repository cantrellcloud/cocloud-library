# Input bindings are passed in via param block.
param(
    [Parameter(Mandatory=$true)]
    [string]$IPAddress,
   
    [Parameter(Mandatory=$true)]
    [string]$Location,
    
    [Parameter(Mandatory=$false)]
    [string]$TriggerMetadata
)

# Interact with query parameters or the body of the request.
$NewIpAddress = $IPAddress.Query.Name
$NewIsTrusted = $true
$LocationDisplayName = $Location.Query.Name

# Import required modules
Import-Module AzureADPreview

# Define your Service Principal AppId, TenantId, and Secret
$ApplicationId = "azureadmin@cohome.onmicrosoft.com"
$TenantId = "cd478b7f-db36-4f0a-8ca8-c68082242690"
$Secret = ConvertTo-SecureString -String "@S1airarosE!121889" -AsPlainText -Force

# Create a PS credential object
$Credential = New-Object System.Management.Automation.PSCredential($ApplicationId, $Secret)

# Login to Azure with the Service Principal
#Connect-AzAccount -Credential $Credential -TenantId $TenantId -ServicePrincipal
Connect-AzureAd -Credential $Credential -TenantId $TenantId -AccountId $ApplicationId

# Get Named Location Policy that matches input location
$targetPolicy = Get-AzureADMSNamedLocationPolicy | Where-Object { $_.DisplayName -eq $LocationDisplayName }

# Set input IP address as new IpRange
Set-AzureADMSNamedLocationPolicy -OdataType "#microsoft.graph.ipNamedLocation" -IsTrusted $NewIsTrusted -IpRanges $NewIpAddress -PolicyId $targetPolicy.Id