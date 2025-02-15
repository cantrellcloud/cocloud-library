param(
    [Parameter(Mandatory=$true)]
    [int]$SOASerialNumber
)

# Import the required module for DNS management
Import-Module DnsServer

# Get all DNS zones
$zones = Get-DnsServerZone

# Loop through each zone
foreach ($zone in $zones) {
    # Get the SOA record for the current zone
    $soa = Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -RRType Soa

    # Update the serial number
    $soa.RecordData.SerialNumber = $SOASerialNumber

    # Apply the updated SOA record
    Set-DnsServerResourceRecord -OldInputObject $soa -NewInputObject $soa -ZoneName $zone.ZoneName -PassThru
}