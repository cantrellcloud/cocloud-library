# create-hyperv-vm
 Creates a new Hyper-V virtual machine. This script takes parameters for the VM name, memory allocation, number of CPUs, hard disk size, and the installation media path.

This script assumes that Hyper-V is installed and enabled on your system. Please replace the parameter values with your actual values when running this script. Also, make sure to run this script with administrative privileges. The path for the new hard disk is set to C:\Hyper-V\$vmName\, you can change this if you want to use a different location. The -Dynamic parameter is used when creating the hard disk which means it will start small and grow as needed up to the size specified. If you want to create a fixed size disk, you can replace -Dynamic with -Fixed. The VM is set to boot from the installation media specified in $vmInstallMediaPath, so it should point to a valid ISO file.

create-hyperv-vm.ps1 `
   -vmName COTPA-DC11 `
   -vmSwitchName "cotpa-vlans_vsw" `
   -vmNetworkVLAN 10 `
   -vmCPU 2 `
   -vmMemory 2048 `
   -vmOSDiskSize 64 `
   -vmOSDiskPath "H:\Hyper-V\Virtual Hard Disks" `
   -vmInstallMediaPath "H:\ISOs\en-us_windows_server_2022_updated_sep_2023_x64_dvd_892eeda9.iso"


   