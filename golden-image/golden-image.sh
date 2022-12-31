#!/bin/bash

usage () {
    echo "Create Proxmox/KVM Template from Cloud Image"
    echo "Usage: $0 
			[-c CPU Cores] [-m Memory (Bytes)] [-n Network Bridge] 
			[-s Disk Size] [-p Storage Pool] [-i VM ID] 
			[-v VM Name] [-u ISO URL]" 1>&2 
}

# Defaults
CORES=2
MEMORY=2048
BRIDGE="vmbr0"
STORAGE=16
STORAGE_POOL="Z-NVME-01"
VM_ID="9000"
VM_NAME="ubuntu-2204-$(date +%F)"
TEMP_ISO_IMAGE="/tmp/$VM_NAME.img"
ISO_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

# Handle our Arguments
while getopts c:m:n:s:p:i:v:u: opt 
do
    case "${opt}" in
        c) CORES=${OPTARG};;
        m) MEMORY=${OPTARG};;
        n) BRIDGE=${OPTARG};;
        s) STORAGE=${OPTARG};;
        p) STORAGE_POOL=${OPTARG};;
		i) VM_ID=${OPTARG};;
		v) 
			VM_NAME=${OPTARG}
			TEMP_ISO_IMAGE="/tmp/${OPTARG}.img"
			;;
		u) ISO_URL=${OPTARG};;

        :)
            echo "Error: -${OPTARG} requires an argument."
            usage
            exit 1;;

        *)
            usage
            exit 1;;
    esac
done

# Setup
failed=0
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Our current working directory
vm_list_file="/etc/pve/.vmlist"

# Safety Check - Is the desired VM ID already in use?
if [ ! -f "$vm_list_file" ]; then
	echo "[!] VM List File ($vm_list_file) does not exist. Are you running on a KVM / Proxmox node?"
	exit 1
fi

id_already_exists=$(cat $vm_list_file | grep $VM_ID | wc -l)
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

# Do we have requried commands?

if ! command -v wget &> /dev/null; then
    echo "[!] wget is not installed"
	failed = 1
fi

if ! command -v virt-customize &> /dev/null; then
    echo "[!] libguestfs-tools is not installed"
	failed = 1
fi

if ! command -v qm &> /dev/null; then
    echo "[!] qm is not installed. Are you running on a KVM / Proxmox node?"
	failed = 1
fi

if test $failed -gt 0; then
	echo "[!] He's Dead Jim. Check for errors above. Exiting..."
	exit 1
fi

# Fetch Our Base Image
wget $ISO_URL -O $TEMP_ISO_IMAGE

# Perform Image Adjustments
# Install libguestfs-tools on Proxmox server.
#apt-get install libguestfs-tools

# Install required packages in our image. QEMU Guest Agent, plus anything else we desire
virt-customize -a $TEMP_ISO_IMAGE --install qemu-guest-agent,vim,parted,fail2ban,grc,htop,mc,tmux,tree,iftop,ufw,curl,vim-nox,net-tools,aptitude,unattended-upgrades,git,wget,snap,software-properties-common,bc,facter,tasksel

# Enable password authentication in the template. Obviously, not recommended for except for testing.
virt-customize -a $TEMP_ISO_IMAGE --run-command "sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config"

# Create Proxmox Template
qm create $VM_ID --cores $CORES --memory $MEMORY --net0 virtio,bridge=$BRIDGE --ostype l26
qm importdisk $VM_ID $TEMP_ISO_IMAGE $STORAGE_POOL
qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VM_ID-disk-0
qm set $VM_ID --agent enabled=1,fstrim_cloned_disks=1
qm set $VM_ID --name $VM_NAME
qm set $VM_ID --description "Created as \"Golden Image\" on $(date +%F)"

# Resize disk
qm disk resize $VM_ID scsi0 +${STORAGE}G

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

# Keep Things Tidy
rm $TEMP_ISO_IMAGE # Remove our base image
