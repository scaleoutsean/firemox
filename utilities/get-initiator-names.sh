#!/usr/bin/env bash 

#
# (c) ScaleoutSean 2025
# License: MIT License
# 
# This script loops over an array of PVE (Debian 12) nodes, issues the below command to each host, and 
#   prints the output as well as 'tee -append' to a file pve-initiator-names.txt
# ssh root@s196 cat /etc/iscsi/initiatorname.iscsi | grep "^InitiatorName=" | awk -F "=" '{ print $2}'

# Define the array of hosts as comma-delimited values. To use this with any host (such as newly added PVE host), change hosts to "".
# Don't forget to remove IQN of removed PVE nodes from SolidFire system.
hosts="s194,s195,s196"

# if hosts is "" or null, prompt for one or more host names
if [ -z "$hosts" ] || [ "${#hosts}" -eq 0 ]; then
    read -p "Enter one or more host names (comma-separated, no space before or after each comma): " hosts
fi

# Convert the comma-delimited string into an array
IFS=',' read -r -a host_array <<< "$hosts"

# Prompt for SSH key path if non-default user SSH public key is used
echo "If you have added your public key to /root/.ssh/authorized_keys on each host, you can use your private key to connect without a password."

if [ -z "$SSH_KEY_PATH" ]; then
  read -p "Enter the path to your SSH key or just ENTER to use the (default: ~/.ssh/id_rsa): " SSH_KEY_PATH
  SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
fi

# CSV file header: "Host,InitiatorName"
timestamp=$(date +%Y%m%d_%H%M%S)
echo "Host,InitiatorName" > pve-initiator-names-$timestamp.csv

# Loop through each host in the array, get initiator names and output to a time-stamped file pve-initiator-names-{timestamp}.csv
for host in "${host_array[@]}"; do
  ssh -i "$SSH_KEY_PATH" root@"$host" cat /etc/iscsi/initiatorname.iscsi | grep "^InitiatorName=" | awk -F "=" -v h="$host" '{ print h "," $2 }' | tee -a pve-initiator-names-$timestamp.csv
done

echo "Initiator names have been saved to pve-initiator-names-$timestamp.csv"
echo "You can now use this file to add your initiator names to SolidFire (if you plan on using SolidFire VAGs with Proxmox VE)."
echo "Remember to remove IQN of removed PVE nodes from SolidFire system."

echo "Upload this file to SolidFire using the SolidFire CLI or API, or use it in your Proxmox VE configuration."

