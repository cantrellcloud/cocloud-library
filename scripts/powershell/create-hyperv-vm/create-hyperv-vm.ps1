param(
    [Parameter(Mandatory=$true)]
    [string]$vmName,

    [Parameter(Mandatory=$true)]
    [int]$vmNetworkVLAN, # 1-4096

    [Parameter(Mandatory=$true)]
    [int]$vmMemory, # in MB

    [Parameter(Mandatory=$true)]
    [int]$vmCPU,

    [Parameter(Mandatory=$true)]
    [int]$vmOSDiskSize, # in GB

    [Parameter(Mandatory=$true)]
    [string]$vmOSDiskPath,

    [Parameter(Mandatory=$true)]
    [string]$vmInstallMediaPath,

    [Parameter(Mandatory=$false)]
    [string]$vmSwitchName
)

Clear-Host

# Set VM OS Disk Path
$vmOSDisk = "$vmOSDiskPath\$vmName" + "_OS_Disk0.vhdx"

# Create a new VM
New-VM -Name $vmName -MemoryStartupBytes ($vmMemory * 1MB) -Generation 2

# Connect Network Adapter to virtual switch and set VLAN
Get-VM -Name $vmName | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName $vmSwitchName
Set-VMNetworkAdapterVlan -VMName $vmName -Access -VlanId $vmNetworkVLAN

# Set the number of CPUs
Set-VMProcessor -VMName $vmName -Count $vmCPU

# Create a new hard disk for the VM
New-VHD -Path $vmOSDisk -SizeBytes ($vmOSDiskSize * 1GB) -Dynamic

# Attach the hard disk to the VM
Add-VMHardDiskDrive -VMName $vmName -Path $vmOSDisk

# Set the VM to boot from the installation media
Add-VMDvdDrive -VMName $vmName -Path $vmInstallMediaPath
$firstboot = Get-VMDvdDrive -VMName $vmName
Set-VMFirmware -VMName $vmName -FirstBootDevice $firstboot


# Start the VM
#Start-VM -Name $vmName
Write-Host ""
Get-VM -Name $vmName | Format-List -Property *
Write-Host ""
Write-Host "VM created but not started. Complete settings using the Hyper-V Managment GUI."
Write-Host ""
