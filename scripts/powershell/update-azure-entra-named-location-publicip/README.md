# update-azure-entra-named-location-publicip
To update an IP address for a named location in Azure Active Directory using PowerShell, you can use the Set-AzureADMSNamedLocationPolicy cmdlet. Here’s an example of how to use it:

    Set-AzureADMSNamedLocationPolicy `
    -PolicyId <PolicyId> `
    -OdataType "#microsoft.graph.ipNamedLocation" `
    -IsTrusted $false

    In this command, replace <PolicyId> with the ID of the policy you want to update1.

Please note that you need to have the appropriate permissions to run these commands1. Also, remember that Conditional Access policies are enforced after first-factor authentication is completed1.

For more specific information on how to use the Set-AzureADMSNamedLocationPolicy cmdlet, you may want to refer to the official Microsoft documentation.