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

configure_docker_compose() {
    # Check if NordVPN token file exists
    token_file="/ms4/information/nordvpntoken.txt"
    if [[ -f "$token_file" ]]; then
        # NordVPN token file exists
        echo "A NordVPN token file was found. Do you want to use the token from the file? (yes/no)"
        read -r use_token_from_file
        if [[ $use_token_from_file == "yes" ]]; then
            # Read NordVPN token from file
            nordvpn_token=$(<"$token_file")
            echo "Using NordVPN token from file."
        else
            # Prompt user for NordVPN token
            echo "Please obtain your NordVPN authentication token from the NordVPN website and enter it below:"
            read -p "Enter your NordVPN authentication token: " nordvpn_token
        fi
    else
        # Prompt user for NordVPN token
        echo "Please obtain your NordVPN authentication token from the NordVPN website and enter it below:"
        read -p "Enter your NordVPN authentication token: " nordvpn_token
    fi

    # Placeholder instructions for the NordLynx private key
    echo "Please ensure you have established a NordVPN connection before proceeding to retrieve the NordLynx private key."
    read -p "Once connected, press Enter to continue..."

    # Run NordVPN login command with the provided token
    echo "Logging into NordVPN using the provided token..."
    nordvpn login --token "$nordvpn_token"

    # Set NordVPN technology to NordLynx
    echo "Setting NordVPN technology to NordLynx..."
    nordvpn set technology nordlynx

    # make a connection to establish a key
    nordvpn connect

    # Get NordLynx private key
    echo "Retrieving NordLynx private key..."
    private_key=$(sudo wg show nordlynx private-key)

    # Logout of NordVPN
    nordvpn logout --persist-token

    # Create directory if it doesn't exist
    info_directory="/ms4/information"
    sudo mkdir -p "$info_directory"

    # Write NordVPN token to file if it was entered manually
    if [[ $use_token_from_file != "yes" ]]; then
        echo "$nordvpn_token" | sudo tee "$info_directory/nordvpntoken.txt" > /dev/null
    fi

    # Write NordLynx private key to file
    echo "$private_key" | sudo tee "$info_directory/wireguardprivatekey.txt" > /dev/null

    # Escape special characters in the private key
    escaped_private_key=$(printf '%s\n' "$private_key" | sed 's:[\&/]:\\&:g;$!s/$/\\/')
    
    # Use sed to replace the placeholder with the NordLynx private key
    sed -i "s|WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=$escaped_private_key|g" docker-compose.yml

    echo "NordVPN token and WireGuard private key have been saved in the /ms4/information directory."
}

run_dns_leak_test() {
    # Check if dnsleaktest.sh script exists
    dns_leak_test_script="/ms4/tools/dnsleaktest.sh"
    if [[ ! -f "$dns_leak_test_script" ]]; then
        echo "DNS leak test script not found: $dns_leak_test_script"
        return 1
    fi

    # Get list of running containers
    running_containers=$(sudo docker ps --format "{{.Names}}")

    # Check if there are any running containers
    if [[ -z "$running_containers" ]]; then
        echo "No running containers found."
        return 1
    fi

    # Loop through each running container and execute the DNS leak test script
    for container in $running_containers; do
        echo "Running DNS leak test in container: $container"
        sudo docker exec "$container" /bin/bash tools/dnsleaktest.sh
    done
}



# Main menu function
main_menu() {
    echo "Welcome to the Debian 12 management script!"
    echo "Please select an option:"
    echo "1. Install Docker, NordVPN, WireGuard, and DNS Checker Tool"
    echo "2. Update existing installations"
    echo "3. Update Docker images"
    echo "4. Configure Docker Compose with NordVPN key"
    echo "5. run a leak test"
    echo "6. Exit"
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
            echo "Updating Docker images..."
            update_docker_images
            return_to_menu
            ;;
        4)
            echo "Configuring Docker Compose..."
            configure_docker_compose
            return_to_menu
            ;;
        5) run_dns_leak_test
            ;;
        6)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            main_menu
            ;;
    esac
}

# Start with the main menu
main_menu
