#!/bin/bash

# Update package index
sudo apt-get update

# Install prerequisites
sudo apt-get install -y ca-certificates curl 

# Create directory for Docker's GPG key
sudo install -m 0755 -d /etc/apt/keyrings

# Download Docker's GPG key
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc

# Set appropriate permissions for Docker's GPG key
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again after adding Docker repository
sudo apt-get update

# Install Docker packages
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

#install nordvpn
sudo sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

#install wireguard
sudo apt install wireguard -y

#install dns checker tool
sudo curl https://raw.githubusercontent.com/macvk/dnsleaktest/master/dnsleaktest.sh -o /ms4/tools/dnsleaktest.sh
sudo chmod +x /ms4/tools/dnsleaktest.sh
