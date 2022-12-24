#!/bin/bash

export STORAGE_POOL="Z-NVME-01"
export VM_ID="9000"
export VM_NAME="ubuntu-2204-$(date +%F)"

export TEMP_ISO_IMAGE="$VM_NAME.img"

###
# Safety Checks
###
id_already_exists=$(cat /etc/pve/.vmlist | grep $VM_ID | wc -l)
if test $id_already_exists -gt 0; then
	echo -n "VM $VM_ID Already Exists! Would you like to re-create? [Y/n] "
	read recreate
		
	if [[ $recreate == "Y" ]] || [[ $recreate = "" ]]; then
		qm destroy $VM_ID
		echo "Destroyed VM/Template with ID $VM_ID, will now re-create"

	else
		echo "Not re-creating. Choosing to exit now..."
		exit
	fi
fi

###
# Fetch Our Base Image
###

# Download Ubuntu 22.04 cloudimg
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O $TEMP_ISO_IMAGE


###
# Adjust Image
###

# Install libguestfs-tools on Proxmox server.
apt-get install libguestfs-tools

# Install qemu-guest-agent on Ubuntu image.
virt-customize -a $TEMP_ISO_IMAGE --install qemu-guest-agent

# Enable password authentication in the template. Obviously, not recommended for except for testing.
virt-customize -a $TEMP_ISO_IMAGE --run-command "sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config"


###
# Create Proxmox Template
###

# Create Proxmox VM image from Ubuntu Cloud Image.
qm create $VM_ID --cores 2 --memory 2048 --net0 virtio,bridge=vmbr0 --ostype l26

qm importdisk $VM_ID $TEMP_ISO_IMAGE $STORAGE_POOL
qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VM_ID-disk-0
qm set $VM_ID --agent enabled=1,fstrim_cloned_disks=1
qm set $VM_ID --name $VM_NAME

# Resize disk
qm disk resize $VM_ID scsi0 +16G

# Create Cloud-Init Disk and configure boot.
qm set $VM_ID --ide2 $STORAGE_POOL:cloudinit
qm set $VM_ID --boot c --bootdisk scsi0
qm set $VM_ID --serial0 socket --vga serial0

# Set Cloud Init Defaults
qm set $VM_ID --ciuser pcsetup
qm set $VM_ID --sshkey ~/.ssh/authorized_keys
qm set $VM_ID --ipconfig0 ip=dhcp

# Convert to Template
qm template $VM_ID

###
# Keep Things Tidy
###

# Remove our base image
rm $TEMP_ISO_IMAGE
