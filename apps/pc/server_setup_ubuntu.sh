#!/usr/bin/env bash
set -e

echo "NexGrab Private Tunnel - Ubuntu/Debian server setup"

sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh

echo
echo "SSH server is installed and running."
echo "Recommended next steps:"
echo "1. Create/use a normal non-root user."
echo "2. Add your SSH public key to ~/.ssh/authorized_keys"
echo "3. Allow SSH through your firewall, e.g.: sudo ufw allow OpenSSH"
echo "4. Keep password authentication disabled if you use key-based login."
echo
echo "Then enter the server IP/domain, username and private key in the app."
