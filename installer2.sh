#!/bin/bash

# Function to install Docker
install_docker() {
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
}

# Function to install NordVPN
install_nordvpn() {
    # Download NordVPN installation script
    curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh -o nordvpn_install.sh

    # Execute NordVPN installation script
    sudo sh nordvpn_install.sh

    # Clean up
    rm nordvpn_install.sh
}

# Function to install WireGuard
install_wireguard() {
    sudo apt install wireguard -y
}

# Function to install DNS checker tool
install_dns_checker() {
    sudo curl https://raw.githubusercontent.com/macvk/dnsleaktest/master/dnsleaktest.sh -o /ms4/tools/dnsleaktest.sh
    sudo chmod +x /ms4/tools/dnsleaktest.sh
}

# Function to update installed applications
update_applications() {
    # Update package index
    sudo apt-get update

    # Upgrade installed packages
    sudo apt-get upgrade -y
}

# Function to update Docker images
update_docker_images() {
    # Update all Docker images
    sudo docker image prune -af
    echo "Images have been pruned, please remember to start applications"
}

# Function to return to the main menu
return_to_menu() {
    echo ""
    echo "Returning to the main menu..."
    echo ""
    main_menu
}

# Main menu function
main_menu() {
    echo "Welcome to the Debian 12 management script!"
    echo "Please select an option:"
    echo "1. Install Docker, NordVPN, WireGuard, and DNS Checker Tool"
    echo "2. Update existing installations"
    echo "3. Exit"
    echo "4. Update Docker images"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            install_docker
            install_nordvpn
            install_wireguard
            install_dns_checker
            return_to_menu
            ;;
        2)
            echo "Updating existing installations..."
            update_applications
            return_to_menu
            ;;
        3)
            echo "Exiting."
            exit 0
            ;;
        4)
            echo "Updating Docker images..."
            update_docker_images
            return_to_menu
            ;;
        *)
            echo "Invalid option. Please try again."
            main_menu
            ;;
    esac
}

# Start with the main menu
main_menu
