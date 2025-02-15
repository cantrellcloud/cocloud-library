param(
    [Parameter(Mandatory=$true)]
    [string]$computerName
)

# Check if the Hyper-V feature is installed
if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -ne 'Enabled') {
    Write-Output "Hyper-V is not enabled on this machine. Please enable it before proceeding."
    exit 1
}

# Get the VM
$vm = Get-VM -Name $computerName

if ($null -eq $vm) {
    Write-Output "No VM found with the name $computerName"
    exit 1
}

# Check if the VM is off
if ($vm.State -ne 'Off') {
    Write-Output "The VM must be in the Off state to enable nested virtualization"
    exit 1
}

# Enable nested virtualization
Set-VMProcessor -VMName $computerName -ExposeVirtualizationExtensions $true

Write-Output "Nested virtualization enabled for VM $computerName"