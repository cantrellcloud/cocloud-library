# Define the list of computers
$computers = @("cotpa-dc01", "cotpa-dc02", "cotpa-dc03" , "copine-dc01") # Replace with your actual computer names or IP addresses

# Function to get network details
function Get-NetworkDetails {
    param (
        [string]$ComputerName
    )

    try {
        # Get network adapter configuration
        $networkConfig = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ComputerName $ComputerName -Filter "IPEnabled = 'True'"

        foreach ($adapter in $networkConfig) {
            [PSCustomObject]@{
                ComputerName   = $ComputerName
                IPAddress      = $adapter.IPAddress -join ", "
                SubnetMask     = $adapter.IPSubnet -join ", "
                DefaultGateway = $adapter.DefaultIPGateway -join ", "
                DNSServers     = $adapter.DNSServerSearchOrder -join ", "
            }
        }
    } catch {
        Write-Warning "Failed to retrieve network details for $ComputerName : $_"
    }
}

# Loop through each computer and get network details
$networkDetails = foreach ($computer in $computers) {
    Get-NetworkDetails -ComputerName $computer
}

# Output the network details
$networkDetails | Format-Table -AutoSize
