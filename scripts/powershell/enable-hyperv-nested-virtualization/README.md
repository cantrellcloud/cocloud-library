# enable-hyperv-nested-virtualization
 Enables Hyper-V nested virtualization. The script takes the computer name as a parameter.

This script first checks if Hyper-V is enabled on the host machine. If not, it outputs a message and exits. Then it retrieves the VM with the specified name. If no such VM exists, it outputs a message and exits. It then checks if the VM is in the ‘Off’ state, as nested virtualization can only be enabled when the VM is off. If the VM is not off, it outputs a message and exits. Finally, it enables nested virtualization for the VM and outputs a success message.

Please note that you need to run this script with administrative privileges. Also, keep in mind that enabling nested virtualization might have some side effects, such as making dynamic memory not work.