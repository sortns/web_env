#!/usr/bin/env bash

echo 'lscpu | grep -i "Model name\\|Socket(s)\\|core"'
lscpu | grep -i "Model name\\|Socket(s)\\|core"

echo 'dmidecode -t memory | grep "Size\|Type:\|Speed" | sort -u'
dmidecode -t memory | grep "Size\|Type:\|Speed" | sort -u

echo 'free -mh'
free -mh

echo 'lsblk -o NAME,SIZE,MODEL,TYPE | grep -v "pve-vm"'
lsblk -o NAME,SIZE,MODEL,TYPE | grep -v "pve-vm"

echo 'smartctl --scan | awk -F# '{print $1}' | xargs -I{} echo "smartctl -a {} " | bash | grep "Device Model\|User Capacity\|SATA Version\|Vendor\|Product\|protocol"'
smartctl --scan | awk -F# '{print $1}' | xargs -I{} echo "smartctl -a {} " | bash | grep "Device Model\|User Capacity\|SATA Version\|Vendor\|Product\|protocol"

echo 'blkid | grep -v mapper | awk -F: '{print $1}' | xargs -I{} smartctl -a {} | grep "Device Model\\|User Capacity\\|SATA Version\|Model Number:\|Total NVM Capacity:"'
blkid | grep -v mapper | awk -F: '{print $1}' | xargs -I{} smartctl -a {} | grep "Device Model\\|User Capacity\\|SATA Version\|Model Number:\|Total NVM Capacity:"

echo 'racadm getversion'
racadm getversion

echo 'racadm storage get controllers'
racadm storage get controllers

echo 'racadm storage get vdisks -o'
racadm storage get vdisks -o

echo 'dmidecode -t bios | grep "Vendor\|Version"'
dmidecode -t bios | grep "Vendor\|Version"

echo 'uname -r'
uname -r

echo 'dmidecode -t system | grep "Product Name\|Serial Number"'
dmidecode -t system | grep "Product Name\|Serial Number"

echo 'ip addr show | grep -v "veth\|link\| fw"'
ip addr show | grep -v "veth\|link\| fw"

echo 'cat /proc/mdstat | awk '/^md/ {print $1}' | xargs -I {} mdadm --detail /dev/{}'
cat /proc/mdstat | awk '/^md/ {print $1}' | xargs -I {} mdadm --detail /dev/{}

echo 'get free space'
echo 'df -hT'
df -hT
echo 'lvs'
lvs