#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

apt update && apt install -y figlet e2fsprogs socat

clear

figlet "Dlpve UEFI"
echo
echo "Enter the hostname for your Proxmox server (e.g. pve.local):"
read -rp "> " NEW_HOSTNAME

echo "Detecting main ethernet interface..."

MAIN_IFACE=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | grep ^e | head -n1)

if [[ -z "$MAIN_IFACE" ]]; then
  ip a
  echo "No ethernet interface found. Please enter interface name manually:"
  read -rp "> " MAIN_IFACE
fi

HOST_IP=$(ip -4 addr show "$MAIN_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

if [[ -z "$HOST_IP" ]]; then
  echo "No IP detected on $MAIN_IFACE. Please enter IP manually:"
  read -rp "> " HOST_IP
else
  echo "Detected IP on $MAIN_IFACE: $HOST_IP"
fi

SHORT_HOSTNAME="${NEW_HOSTNAME%%.*}"

figlet "Setting Hostname"
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "$NEW_HOSTNAME" > /etc/hostname
chattr +i /etc/hostname

echo "Updating /etc/hosts with hostname and IP..."
cat > /etc/hosts <<EOF
127.0.0.1       localhost
$HOST_IP        $SHORT_HOSTNAME $NEW_HOSTNAME
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# FIX UEFI: Go bo grub-pc va cai dat grub-efi-amd64
apt-get purge -y grub-pc || true
apt-get install -y grub-efi-amd64

clear
figlet "Selecting Fastest Mirror"

MIRRORS=(
  download.proxmox.com
  sg.cdn.proxmox.com
  na.cdn.proxmox.com
)

BEST_LINE=$(
  for m in "${MIRRORS[@]}"; do
    RTT=$(ping -c1 -W1 "$m" 2>/dev/null \
      | grep -oP 'time=\K[0-9]+(\.[0-9]+)?' || echo 9999)
    echo "$RTT $m"
  done | sort -n | head -n1
)

BEST_MIRROR=${BEST_LINE#* }
echo "Fastest mirror: $BEST_MIRROR"
echo "deb [arch=amd64 trusted=yes] http://$BEST_MIRROR/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list

clear
figlet "Updating System"
apt update && apt full-upgrade -y

clear
figlet "Nuking Cloudinit"
apt remove --purge -y cloud-init qemu-utils
apt autoremove -y

clear
figlet "Installing PVE Kernel"
apt install -y proxmox-default-kernel bc

if grep -q "auto vmbr0" /etc/network/interfaces; then
  sed -i '/auto vmbr0/,/^$/d' /etc/network/interfaces
fi

echo "Appending vmbr0 bridge..."
cat >> /etc/network/interfaces <<EOF

auto vmbr0
iface vmbr0 inet static
        address  172.16.0.1
        netmask  255.240.0.0
        bridge_ports none
        bridge_stp off
        bridge_fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up iptables -t nat -A POSTROUTING -s '172.16.0.0/12' -o $MAIN_IFACE -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '172.16.0.0/12' -o $MAIN_IFACE -j MASQUERADE
EOF

clear
figlet "Installing PVE & DHCP"
apt install -y proxmox-ve postfix open-iscsi chrony isc-dhcp-server

echo 'INTERFACESv4="vmbr0"' > /etc/default/isc-dhcp-server

cat > /etc/dhcp/dhcpd.conf <<EOD
subnet 172.16.0.0 netmask 255.240.0.0 {
  range 172.16.0.10 172.31.255.254;
  option routers 172.16.0.1;
  option domain-name-servers 1.1.1.1, 8.8.8.8;
}
EOD

systemctl enable --now isc-dhcp-server

# FIX PVE-CLUSTER: Reset db va cap lai chung chi truoc khi reboot
rm -f /var/lib/pve-cluster/config.db
systemctl restart pve-cluster
pvecm updatecerts -f

clear
figlet "443-Forward"
cat <<EOF > /etc/systemd/system/port443forward.service
[Unit]
Description=Port Forward 443 -> 8006
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:443,fork,reuseaddr TCP:127.0.0.1:8006
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now port443forward

clear
figlet "Cleaning"
apt remove -y --allow-remove-essential linux-image-amd64 'linux-image-6.1*' os-prober || true
update-grub

figlet "Done"
echo "Access: https://$HOST_IP"
sleep 5
reboot
